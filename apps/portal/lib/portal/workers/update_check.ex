defmodule Portal.Workers.UpdateCheck do
  @moduledoc """
  Oban worker (queue `:intake`) that notices when a package we have already
  tested publishes a new release, and queues a rebuild for it.

  Without this, every result on the site is a snapshot of whatever version was
  current when the package was last built, and it silently rots: nothing in the
  system ever asks hex.pm whether a version has moved. `Package.latest_version`
  does not answer that question either -- despite the name it records the
  version *we tested*, written from the build result in
  `Portal.Catalog.Ingestion`, so it only moves when a build happens.

  ## Stateless, and not a window

  Each run compares our whole catalogue against the whole hex.pm registry, which
  `Portal.HexRegistry` delivers in two CDN requests. There is no watermark to
  store and no lookback to tune: a package that drifted last month is just as
  visible as one that drifted an hour ago, so a missed tick, a restart, or a
  deploy costs nothing.

  That is worth spelling out because the obvious alternatives are both worse. A
  stored watermark needs a table, a migration, and a new failure mode where
  losing it either re-checks everything or silently skips a day. A fixed lookback
  window needs no state but *drops* anything older than the cutoff -- which is
  exactly the backlog that accumulated before this worker existed, and which it
  would then never repair.

  Re-offering the same package on every run is free because the work is
  idempotent three layers deep: this worker only acts on a version that differs
  from the one on record, `Portal.Workers.Backfill` is unique per package per
  day, `Portal.ScanRequests.create_once/1` is idempotent against an already-open
  request, and `Portal.Workers.Build` is unique on package/version/image.

  ## What earns a rebuild

  Not every release is worth a build. A version that differs from the one on
  record is a candidate; `significant?/2` and the per-run cap decide what
  actually gets queued, and both are documented where they are implemented.

  ## Scope

  Only packages already in the catalogue. A registry package we have never
  tested is not stale, it is absent, and seeding new packages belongs to
  `Portal.UpstreamBackfill`. Restricting it this way also bounds the work: we
  track roughly a ninth of hex.pm.

  ## Why queue `:intake`

  The work here is two HTTP requests and a handful of inserts, not a compile.
  `:intake` runs on the web host, which keeps a registry-wide check off the
  machine doing the builds it is queueing -- the same reasoning
  `Portal.Workers.Backfill` documents.

  ## Enablement

  Disabled unless `config :portal, #{inspect(__MODULE__)}, enabled: true`
  (`NCC_UPDATE_CHECK=1` at runtime). The cron entry runs regardless and returns
  immediately while disabled, which lets the schedule be verified in production
  without sending hex.pm a single request.
  """

  use Oban.Worker,
    queue: :intake,
    # A failed check waits for the next tick rather than hammering hex.pm:
    # nothing is lost, because the next run sees the same drift. Two attempts
    # cover a transient blip without turning an outage into a retry storm.
    max_attempts: 2,
    unique: [period: :infinity, states: :incomplete]

  require Ash.Query
  require Logger

  alias Portal.Catalog.Package
  alias Portal.Catalog.Run
  alias Portal.Workers.Backfill

  @default_max_per_run 5

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if enabled?() do
      run()
    else
      :ok
    end
  end

  @doc """
  Diff the catalogue against the hex.pm registry and queue rebuilds.

  Runs regardless of the `:enabled` flag -- that gate belongs to the scheduled
  path, not to a human at a console deciding to run one on purpose.

  Returns `{:ok, %{seen: n, moved: n, enqueued: n, deferred: n}}`, where `seen`
  counts packages in the registry, `moved` the ones we track that are worth
  rebuilding, `enqueued` the jobs actually inserted -- lower than `moved` when a
  package is already queued from an earlier run, or when the per-run cap binds --
  and `deferred` the ones the cap held back for a later run.

  Options:

    * `:max_per_run` - override the configured cap.
    * `:dry_run` - classify without inserting anything.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    max_per_run = Keyword.get(opts, :max_per_run, max_per_run())

    case registry_source().snapshot() do
      {:ok, registry} ->
        moved = moved(registry)
        {selected, deferred} = select(moved, max_per_run)

        enqueued =
          if Keyword.get(opts, :dry_run, false) do
            0
          else
            Enum.count(selected, &enqueue/1)
          end

        if deferred > 0 do
          Logger.info(
            "Update check deferred #{deferred} package(s) over the #{max_per_run} per-run cap"
          )
        end

        Logger.info(
          "Update check: #{length(registry)} packages on hex, #{length(moved)} tracked and worth rebuilding, #{enqueued} queued"
        )

        {:ok,
         %{
           seen: length(registry),
           moved: length(moved),
           enqueued: enqueued,
           deferred: deferred
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Oldest first, then take the cap.
  #
  # Ordering only matters when the cap binds, and then it matters a lot. Without
  # it the same fresh releases win the budget on every run while the oldest
  # drift -- the packages whose published results are most wrong -- never gets a
  # turn. Sorting by the registry's `updated_at` drains the backlog in the order
  # it accumulated, so the queue makes progress instead of churning on the head.
  #
  # A package whose timestamp the registry did not carry sorts last rather than
  # first: unknown is not the same as ancient, and treating it as ancient would
  # hand it the whole budget.
  defp select(moved, max_per_run) do
    selected =
      moved
      |> Enum.sort_by(fn entry ->
        case entry.updated_at do
          nil -> {1, 0}
          at -> {0, DateTime.to_unix(at)}
        end
      end)
      |> Enum.take(max_per_run)

    {selected, length(moved) - length(selected)}
  end

  defp moved(registry) do
    by_name = Map.new(registry, &{&1.name, &1})

    # The whole catalogue, not a filtered subset. Passing ~22,000 registry names
    # to the database as an `IN` list would be absurd; reading our own 2,500 rows
    # and intersecting in memory is bounded by the size of the catalogue.
    drifted =
      Package
      |> Ash.Query.select([:id, :name, :latest_version])
      |> Ash.read!(domain: Portal.Catalog)
      |> Enum.flat_map(fn package ->
        case Map.fetch(by_name, package.name) do
          {:ok, entry} when entry.latest_version != package.latest_version -> [{package, entry}]
          _ -> []
        end
      end)

    # Run statuses are only needed to decide the patch-release exception below,
    # so they are read for the few hundred packages that actually drifted rather
    # than for the whole catalogue.
    statuses = latest_run_statuses(Enum.map(drifted, fn {package, _entry} -> package.id end))

    for {package, entry} <- drifted, rebuild?(package, entry, statuses), do: entry
  end

  # A tracked package with no version on record has never produced a build
  # result. That is as stale as a version that moved, and the same rebuild is
  # the fix, so it belongs here rather than in a special case.
  defp rebuild?(%{latest_version: nil}, _entry, _statuses), do: true

  defp rebuild?(package, entry, statuses) do
    significant?(package.latest_version, entry.latest_version) or
      not passing?(package.id, statuses)
  end

  # Whether a version change is worth a rebuild on its own.
  #
  # Patch releases are 46% of the drift in this catalogue (178 of 388 measured
  # against the live registry) and are the releases least likely to change what
  # we measure -- compilation against a Nerves target, native components,
  # footprint. Skipping them nearly halves the rebuild volume for close to no
  # loss of signal, and a maintainer who wants a patch verified can still ask
  # for a scan by hand.
  #
  # The exception is in `rebuild?/3` above rather than here: a package whose
  # last run did not pass is rebuilt on *any* version change. A patch release on
  # a failing package is the most informative event we can observe -- it is
  # usually the maintainer fixing the thing we flagged -- and refusing to look
  # would leave a red badge that no release can ever clear. It costs little:
  # honouring it turns 170 skipped patch bumps into 178.
  defp significant?(from, to) do
    case {Version.parse(from), Version.parse(to)} do
      {{:ok, from}, {:ok, to}} ->
        cond do
          from.major != to.major -> true
          from.minor != to.minor -> true
          # A prerelease graduating to stable (0.19.0-beta.2 -> 0.19.0) is the
          # release that matters, even though every number before the `-` is
          # unchanged. Prerelease-to-prerelease churn is not.
          from.pre != [] and to.pre == [] -> true
          true -> false
        end

      # Something we cannot parse as semver. Rebuilding is the safe direction:
      # the cost is one build, where the alternative is silently never
      # rebuilding a package whose scheme we failed to read.
      _ ->
        true
    end
  end

  defp passing?(package_id, statuses), do: Map.get(statuses, package_id) == :pass

  defp latest_run_statuses([]), do: %{}

  defp latest_run_statuses(package_ids) do
    # Named columns on purpose: `catalog_runs.log` holds the whole runner log of
    # every run, and an unselected read would load all of it to answer a
    # question about one atom.
    Run
    |> Ash.Query.filter(package_id in ^package_ids)
    |> Ash.Query.sort(finished_at: :desc, inserted_at: :desc)
    |> Ash.Query.select([:package_id, :overall_status, :finished_at, :inserted_at])
    |> Ash.read!(domain: Portal.Catalog)
    |> Enum.reduce(%{}, fn run, acc -> Map.put_new(acc, run.package_id, run.overall_status) end)
  end

  defp enqueue(%{name: name}) do
    case %{package: name} |> Backfill.new() |> Oban.insert() do
      # Already queued by an earlier run inside `Backfill`'s uniqueness period.
      # Expected whenever the cap defers work, and not worth logging.
      {:ok, %Oban.Job{conflict?: true}} ->
        false

      {:ok, _job} ->
        true

      {:error, reason} ->
        Logger.warning("Update check could not queue #{name}: #{inspect(reason)}")
        false
    end
  end

  defp enabled?, do: Keyword.get(config(), :enabled, false) == true

  defp max_per_run, do: Keyword.get(config(), :max_per_run, @default_max_per_run)

  defp config, do: Application.get_env(:portal, __MODULE__, [])

  defp registry_source,
    do: Application.get_env(:portal, :hex_registry_source, Portal.HexRegistry)
end
