defmodule Portal.Workers.ReleaseFastPath do
  @moduledoc """
  Oban worker (queue `:intake`) that rebuilds, as soon as its budget
  allows, the toolchain builds a release of a popular package left behind:
  a few hundred within the hour, a release with thousands of dependents
  over several hours.

  ## Why

  A toolchain build serves a project only when the project's lock agrees
  with the build's (`Portal.Workers.ClosureDrift`). When phoenix released
  1.8.17, every build that locked phoenix 1.8.16 stopped serving a fresh
  `mix phx.new`. 21 hours later, 61 of the 675 packages whose builds lock
  phoenix had one at 1.8.17. The daily drift run queues at most
  `ClosureDrift.max_per_run/0` rebuilds across every dependency release,
  behind every new build.

  ## When

  `Portal.Workers.UpdateCheck` hands each hourly run's registry to
  `offer/2`. A package is offered when the registry changed it within
  `window_hours/0` and its newest stable, unretired release is newer than
  the version that at least `min_dependents/0` packages' passing builds
  lock. One job per release: the job is unique on package and version.

  ## What a job does

  `Portal.Workers.ClosureDrift.rebuild_dependents/2` for the package: the
  daily run's judge, for the builds that lock the package only. Each
  drifted build is rebuilt at priority 2, with the named config variants:
  behind new `with` and `without` builds (0 and 1), ahead of refreshes,
  reopens, pinned builds and the daily drift (3). It carries
  `reason: "release_fast_path"`. The build it replaces is kept in
  `earlier_builds`, as for a daily drift. The package's own build of the
  release is the toolchain sweep's, which leaves these rebuilds out of its
  top-up guard (`Portal.Workers.ToolchainSweep`), so it keeps queueing new
  releases every 15 minutes whatever the fast path has queued.

  ## The budget

  At most `budget/0` of these rebuilds are incomplete at once, across every
  release (`NCC_RELEASE_FAST_PATH_BUDGET`, 300 by default, below the
  roughly 570 toolchain builds an hour the builders drain, so priority 3
  gets a share of every hour), and one run of a job queues at most
  `max_per_release/0` of them. One job runs at a time, across nodes: a run
  takes a Postgres advisory lock (`lock_key/0`) first and snoozes a minute
  when another run holds it, so no two runs read the same room. A run that
  has no room, or that stopped at its share with candidates left, snoozes
  for an hour: the remainder carries over to the next hour rather than
  being dropped. A full budget or a held lock is checked before anything
  is read. Each run judges afresh, so a rebuild that ran since is no longer
  drift, and the release finishes once nothing it moved is left behind; it
  also finishes once its version is no longer the package's newest stable
  release, whose own job does the same work. `carry_over_hours/0` after it
  was queued it gives up and leaves the rest to the daily drift. The job is
  unique per release for longer than that plus the offer window, so a
  release carrying over is never offered a second job.

  ## Enablement

  On by default. `NCC_RELEASE_FAST_PATH=0`, or `NCC_CLOSURE_DRIFT=0`, the
  switch for the drift rebuilds it is made of, switches it off after a
  restart of the nodes that run `:intake`: no release is offered and a
  queued or snoozed job is cancelled. The rebuilds a job already queued
  stay queued; to cancel them:

      import Ecto.Query

      Oban.cancel_all_jobs(
        from(j in Oban.Job,
          where:
            j.worker == "Portal.Workers.ToolchainBuild" and
              fragment("?->>'reason'", j.args) == "release_fast_path" and
              j.state in ["available", "scheduled", "retryable"]
        )
      )

  A run holds an `:intake` slot while it judges, a few minutes for a
  release with a thousand dependents and at most `ClosureDrift.budget_ms/0`;
  a snoozed job holds none.
  """

  use Oban.Worker,
    queue: :intake,
    max_attempts: 2,
    # Longer than a job's carry-over plus the offer window (`carry_over_hours/0`,
    # `window_hours/0`), so a release still carrying over is not offered again.
    unique: [keys: [:package, :version], period: 3 * 86_400, states: :all]

  require Logger

  alias Portal.Catalog.ClosureDrift, as: Drift
  alias Portal.Repo
  alias Portal.Toolchains
  alias Portal.Workers.ClosureDrift

  @priority 2
  @reason "release_fast_path"
  @carry_over_seconds 3600
  @lock_snooze_seconds 60
  # A fixed key for `pg_try_advisory_lock/1`: one fast-path run at a time.
  @lock_key 0x52_46_50_00

  @doc "The advisory lock key a run holds while it runs."
  @spec lock_key() :: integer()
  def lock_key, do: @lock_key
  @incomplete ~w(available scheduled executing retryable)

  @doc "The `reason` its rebuilds carry, which the toolchain sweep's guard leaves out."
  @spec reason() :: String.t()
  def reason, do: @reason

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    if enabled?(),
      do: serialized(job),
      else: {:cancel, "the release fast path is off"}
  end

  # One run at a time, on every node: a session advisory lock on the one
  # connection the run uses throughout (`Repo.checkout/2`), let go when it
  # ends. A run that dies closes that connection, which lets it go too.
  defp serialized(job) do
    Repo.checkout(
      fn ->
        if locked?() do
          try do
            within_budget(job)
          after
            unlock()
          end
        else
          {:snooze, @lock_snooze_seconds}
        end
      end,
      timeout: :infinity
    )
  end

  defp locked? do
    %{rows: [[locked]]} = Repo.query!("SELECT pg_try_advisory_lock($1)", [@lock_key])
    locked
  end

  defp unlock, do: Repo.query!("SELECT pg_advisory_unlock($1)", [@lock_key])

  defp within_budget(%Oban.Job{args: %{"package" => package, "version" => version}} = job) do
    case min(budget() - in_flight(), max_per_release()) do
      room when room > 0 -> rebuild(job, package, version, room)
      _none -> carry_over(job, "no room in the budget")
    end
  end

  defp rebuild(job, package, version, room) do
    case ClosureDrift.rebuild_dependents(package,
           priority: @priority,
           reason: @reason,
           max: room,
           release: version
         ) do
      {:ok, %{superseded: newest} = summary} ->
        Logger.info("Release fast path: #{package} #{version}: superseded by #{newest}")
        {:ok, summary}

      {:ok, summary} ->
        finish(job, package, version, summary)

      other ->
        other
    end
  end

  defp finish(job, package, version, summary) do
    Logger.info(
      "Release fast path: #{package} #{version}: #{summary.drifted} builds drifted, " <>
        "#{summary.enqueued} queued, #{summary.pending} already queued"
    )

    if summary[:capped],
      do: carry_over(job, "#{summary.enqueued} queued, more left"),
      else: {:ok, summary}
  end

  # The rest of the release waits an hour; a snooze holds no `:intake` slot
  # and counts no attempt.
  #
  # By the job's age, not its snoozes: a snooze for the lock is no hour of
  # carry-over.
  defp carry_over(%Oban.Job{args: args, inserted_at: inserted_at}, why) do
    if hours_since(inserted_at) >= carry_over_hours() do
      {:cancel, "release fast path for #{args["package"]} #{args["version"]} gave up: #{why}"}
    else
      {:snooze, @carry_over_seconds}
    end
  end

  defp hours_since(nil), do: 0
  defp hours_since(at), do: DateTime.diff(DateTime.utc_now(), at, :second) / 3600

  # The fast-path rebuilds not yet finished, counted up to the budget.
  defp in_flight do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM (
          SELECT 1 FROM oban_jobs
          WHERE worker = 'Portal.Workers.ToolchainBuild' AND state::text = ANY($1)
            AND args->>'reason' = $2
          LIMIT $3
        ) j
        """,
        [@incomplete, @reason, budget()]
      )

    count
  end

  # The builds that lock each offered package at another version than its
  # newest: one pass over the passing builds for every name at once. Only
  # default config builds count the dependents, so a package with named
  # config variants counts once; the rebuild takes the variants too.
  @dependents_sql """
  SELECT r.name, r.version
  FROM unnest($1::text[], $2::text[]) AS r(name, version)
  JOIN catalog_toolchain_builds t ON t.deps_lock ? r.name
  WHERE t.status = 'pass' AND t.revoked_at IS NULL AND t.builder_version = $3
    AND t.config_variant = 'default'
    AND t.toolchain = ANY($4::text[])
    AND jsonb_typeof(t.deps_lock) = 'object'
    AND t.deps_lock -> r.name ->> 'version' IS DISTINCT FROM r.version
  GROUP BY r.name, r.version
  HAVING count(DISTINCT t.package_id) >= $5
  ORDER BY r.name
  """

  @doc """
  Queues a job for each release in `registry` (`Portal.HexRegistry.snapshot/1`
  with `all_versions: true`) that the moduledoc says is worth one, and
  returns how many it queued. A release queued before is not queued again.
  A query that fails is logged and offers nothing: the update check that
  calls this has already written its own work, and the next hour offers
  again. Option `:now` (tests) is the time the window ends.
  """
  @spec offer([map()], keyword()) :: non_neg_integer()
  def offer(registry, opts \\ []) do
    if enabled?() do
      since = DateTime.add(Keyword.get(opts, :now, DateTime.utc_now()), -window_hours(), :hour)

      registry
      |> Enum.filter(&changed_since?(&1, since))
      |> Drift.index()
      |> Enum.flat_map(&newest_release/1)
      |> popular()
      |> Enum.count(&queue/1)
    else
      0
    end
  rescue
    error in [DBConnection.ConnectionError, DBConnection.EncodeError, Postgrex.Error] ->
      Logger.warning("Release fast path could not offer: #{Exception.message(error)}")
      0
  end

  defp newest_release({_name, %{newest: nil}}), do: []
  defp newest_release({name, %{newest: newest}}), do: [{name, newest}]

  defp changed_since?(%{updated_at: %DateTime{} = at}, since),
    do: DateTime.compare(at, since) != :lt

  defp changed_since?(_entry, _since), do: false

  defp popular([]), do: []

  defp popular(releases) do
    {names, versions} = Enum.unzip(releases)

    %{rows: rows} =
      Repo.query!(
        @dependents_sql,
        [
          names,
          versions,
          Toolchains.builder_version(),
          Enum.map(Toolchains.images(), & &1.toolchain),
          min_dependents()
        ],
        timeout: :timer.minutes(2)
      )

    Enum.map(rows, fn [name, version] -> {name, version} end)
  end

  defp queue({package, version}) do
    case %{package: package, version: version} |> new() |> Oban.insert() do
      {:ok, %Oban.Job{conflict?: true}} ->
        false

      {:ok, _job} ->
        Logger.info("Release fast path: offered #{package} #{version}")
        true

      {:error, reason} ->
        Logger.warning(
          "Release fast path could not queue #{package} #{version}: #{inspect(reason)}"
        )

        false
    end
  end

  @doc """
  Whether releases are offered and rebuilt: `NCC_RELEASE_FAST_PATH`, and the
  drift rebuilds it is made of (`Portal.Workers.ClosureDrift.enabled?/0`).
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, true) == true and ClosureDrift.enabled?()

  @doc """
  At most this many fast-path rebuilds incomplete at once, across releases
  (`NCC_RELEASE_FAST_PATH_BUDGET`).
  """
  @spec budget() :: non_neg_integer()
  def budget, do: Keyword.get(config(), :budget, 300)

  @doc """
  How many hours after its job was queued a release's remainder may carry
  over before it is left to the daily drift. With `window_hours/0` it must
  stay below the job's unique period, 72 hours.
  """
  @spec carry_over_hours() :: non_neg_integer()
  def carry_over_hours, do: Keyword.get(config(), :carry_over_hours, 48)

  @doc "How many packages' builds must lock a release behind for it to be offered."
  @spec min_dependents() :: pos_integer()
  def min_dependents, do: Keyword.get(config(), :min_dependents, 10)

  @doc "How recently the registry must have changed a package for it to be offered."
  @spec window_hours() :: pos_integer()
  def window_hours, do: Keyword.get(config(), :window_hours, 3)

  @doc "At most this many rebuilds per run of a release's job; the rest carries over."
  @spec max_per_release() :: non_neg_integer()
  def max_per_release, do: Keyword.get(config(), :max_per_release, 500)

  defp config, do: Application.get_env(:portal, __MODULE__, [])
end
