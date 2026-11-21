defmodule Portal.Workers.ReleaseFastPath do
  @moduledoc """
  Oban worker (queue `:intake`) that rebuilds, within the hour, the
  toolchain builds a release of a popular package left behind.

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
  drifted build is rebuilt at priority 1, ahead of named variants,
  refreshes and the daily drift, behind new `with` builds, with
  `reason: "release_fast_path"`, at most `max_per_release/0`. The build it
  replaces is kept in `earlier_builds`, as for a daily drift. Then it forces
  a toolchain sweep (`Portal.Workers.ToolchainSweep.enqueue/0`), so the
  package's own build of the release is queued without waiting out the
  sweep's top-up guard, once the update check has nominated it.

  ## Enablement

  On by default. `NCC_RELEASE_FAST_PATH=0` switches it off at runtime: no
  release is offered and a queued job is cancelled.
  """

  use Oban.Worker,
    queue: :intake,
    max_attempts: 2,
    unique: [keys: [:package, :version], period: 86_400, states: :all]

  require Logger

  alias Portal.Catalog.ClosureDrift, as: Drift
  alias Portal.Repo
  alias Portal.Toolchains
  alias Portal.Workers.{ClosureDrift, ToolchainSweep}

  @priority 1
  @reason "release_fast_path"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"package" => package, "version" => version}}) do
    if enabled?() do
      with {:ok, summary} <-
             ClosureDrift.rebuild_dependents(package,
               priority: @priority,
               reason: @reason,
               max: max_per_release()
             ) do
        _ = ToolchainSweep.enqueue()

        Logger.info(
          "Release fast path: #{package} #{version}: #{summary.drifted} builds drifted, " <>
            "#{summary.enqueued} queued, #{summary.pending} already queued"
        )

        {:ok, summary}
      end
    else
      {:cancel, "the release fast path is off"}
    end
  end

  # The builds that lock each offered package at another version than its
  # newest: one pass over the passing builds for every name at once.
  @dependents_sql """
  SELECT r.name, r.version
  FROM unnest($1::text[], $2::text[]) AS r(name, version)
  JOIN catalog_toolchain_builds t ON t.deps_lock ? r.name
  WHERE t.status = 'pass' AND t.revoked_at IS NULL AND t.builder_version = $3
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
  Option `:now` (tests) is the time the window ends.
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

  @doc "Whether releases are offered and rebuilt (`NCC_RELEASE_FAST_PATH`)."
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, true) == true

  @doc "How many packages' builds must lock a release behind for it to be offered."
  @spec min_dependents() :: pos_integer()
  def min_dependents, do: Keyword.get(config(), :min_dependents, 10)

  @doc "How recently the registry must have changed a package for it to be offered."
  @spec window_hours() :: pos_integer()
  def window_hours, do: Keyword.get(config(), :window_hours, 3)

  @doc "At most this many rebuilds per release."
  @spec max_per_release() :: non_neg_integer()
  def max_per_release, do: Keyword.get(config(), :max_per_release, 2_000)

  defp config, do: Application.get_env(:portal, __MODULE__, [])
end
