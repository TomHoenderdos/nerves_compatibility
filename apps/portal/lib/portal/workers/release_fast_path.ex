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
  takes a Postgres advisory lock (`lock_key/0`) first and snoozes one to one
  and a half minutes when another run holds it, so no two runs read the same room. A run that
  has no room, or that stopped at its share with candidates left, snoozes
  for an hour: the remainder carries over to the next hour rather than
  being dropped. A full budget or a held lock is checked before anything
  is read. Each run judges afresh, so a rebuild that ran since is no longer
  drift, and the release finishes once nothing it moved is left behind. It
  also finishes once its version is no longer the package's newest stable,
  unretired release: when a newer one is out, that release's own job does
  the work; when it was retired, or no stable release is left, the
  offer and the judge ignore it too, and the daily drift takes what
  remains. `carry_over_hours/0` after it
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

  A run holds an `:intake` slot and one database connection of its own
  (the lock's, outside the pool) while it judges: a few minutes for a
  release with a thousand dependents, at most `ClosureDrift.budget_ms/0`
  between candidates, and `timeout/1` for the job as a whole. Its
  statements keep their own timeouts. A snoozed job holds neither.
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
  @lock_snooze_jitter 30
  # A fixed key for `pg_try_advisory_lock/2`: one fast-path run at a time.
  # The two-key form, whose key space is apart from the one-key form the
  # `hashtext` identity locks use (`pg_advisory_xact_lock(hashtext(...))`).
  @lock_key {0x5246, 0x5000}

  @doc "The two-key advisory lock (`{classid, objid}`) a run holds while it runs."
  @spec lock_key() :: {integer(), integer()}
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

  # One run at a time, on every node: a session advisory lock held on a
  # connection of its own, outside the pool, for as long as the run lasts.
  # The run's own statements go through the pool and keep their timeouts:
  # inside `Repo.checkout/2` a statement gets no deadline of its own
  # (DBConnection sets one only at checkout), so a run held there could
  # block for as long as any statement blocked. The connection is linked to
  # the job process: a run that dies, or that `timeout/1` stops, takes the
  # connection with it, and closing it lets the lock go.
  #
  # Waiting jobs wake together (one update check offers several releases
  # at once), and each would open a connection only to find the lock busy:
  # up to an `:intake` queue's worth at once, against a shared Postgres
  # with little room. So the pool answers whether the lock is held
  # (`pg_locks`), and the lock's own connection is opened only to take it.
  # That check is a shortcut, not the lock: when it finds the lock free,
  # `pg_try_advisory_lock` on the own connection still decides, so two jobs
  # that both see it free cost one short connection each and one of them
  # waits.
  defp serialized(job) do
    case lock() do
      {:ok, conn} ->
        try do
          within_budget(job)
        after
          release(conn)
        end

      :busy ->
        lock_busy(job, "locked")

      :unreachable ->
        lock_busy(job, "its lock could not be reached")
    end
  end

  defp lock, do: if(held?(), do: :busy, else: take_lock())

  # Whether a session of this database holds the lock, through the pool.
  defp held? do
    %{rows: [[held]]} =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM pg_locks
          WHERE locktype = 'advisory' AND granted
            AND database = (SELECT oid FROM pg_database WHERE datname = current_database())
            AND classid = $1 AND objid = $2 AND objsubid = 2
        )
        """,
        lock_args()
      )

    held
  end

  defp take_lock do
    {:ok, conn} = Postgrex.start_link(lock_connection_opts())

    case Postgrex.query(conn, "SELECT pg_try_advisory_lock($1, $2)", lock_args(), timeout: 15_000) do
      {:ok, %{rows: [[true]]}} ->
        {:ok, conn}

      {:ok, _} ->
        GenServer.stop(conn)
        :busy

      {:error, error} ->
        Logger.warning("Release fast path could not reach its lock: #{Exception.message(error)}")
        GenServer.stop(conn)
        :unreachable
    end
  end

  # The unlock is for a connection that outlives the run; stopping it lets
  # the lock go anyway.
  defp release(conn) do
    _ = Postgrex.query(conn, "SELECT pg_advisory_unlock($1, $2)", lock_args(), timeout: 15_000)
    GenServer.stop(conn)
  end

  defp lock_args, do: Tuple.to_list(@lock_key)

  # The pool's connection settings, for one connection of its own.
  @connection_keys ~w(hostname port username password database socket socket_dir ssl ssl_opts
                      socket_options parameters connect_timeout handshake_timeout)a
  # `lock_connection` in this worker's config is merged over them.
  defp lock_connection_opts do
    Repo.config()
    |> Keyword.take(@connection_keys)
    |> Keyword.merge(Keyword.get(config(), :lock_connection, []))
    |> Keyword.put(:pool_size, 1)
  end

  # Another run holds the lock, or it could not be reached: try again in a
  # minute and a half at most, jittered so the waiting jobs do not wake
  # together, until the job is as old as a carry-over may be.
  defp lock_busy(%Oban.Job{args: args, inserted_at: inserted_at}, why) do
    if hours_since(inserted_at) >= carry_over_hours(),
      do:
        {:cancel, "release fast path for #{args["package"]} #{args["version"]} gave up: #{why}"},
      else: {:snooze, @lock_snooze_seconds + :rand.uniform(@lock_snooze_jitter + 1) - 1}
  end

  @impl Oban.Worker
  @doc """
  A run stops at `Portal.Workers.ClosureDrift.budget_ms/0` between
  candidates; Oban stops the job ten minutes after that whatever it is
  doing, and the lock goes with it.
  """
  def timeout(_job), do: ClosureDrift.budget_ms() + :timer.minutes(10)

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
        Logger.info("Release fast path: #{package} #{version}: #{gone(package, newest)}")
        {:ok, summary}

      {:ok, summary} ->
        finish(job, package, version, summary)

      other ->
        other
    end
  end

  # Why a job's release is no longer the one to rebuild for: a newer stable
  # release (whose own job does the work), or, for a retired one, an older
  # one (whose dependents are the daily drift's), or none at all.
  defp gone(package, nil), do: "no stable release of #{package} left on Hex"
  defp gone(_package, newest), do: "no longer the newest stable release (#{newest})"

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
