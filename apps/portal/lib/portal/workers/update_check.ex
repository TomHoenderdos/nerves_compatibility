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

  ## Why a window instead of a watermark

  The obvious design remembers the timestamp of the last successful check and
  asks for everything since. That needs somewhere durable to put one timestamp,
  and there is no such store in this application -- it would mean a table, a
  migration, and a new failure mode where a lost or corrupted watermark either
  re-checks the whole registry or silently skips a day.

  Instead each run looks back a fixed window, wider than the interval it runs
  on. At the default hourly schedule and six-hour window every update is seen
  roughly six times before it falls out, so a missed tick, a restart, or a
  deploy costs nothing and there is no state to lose. Repetition is free because
  the work is idempotent three layers deep: this worker only acts on a version
  that differs from the one on record, `Portal.Workers.Backfill` is unique per
  package per day, `Portal.ScanRequests.create_once/1` is idempotent against an
  already-open request, and `Portal.Workers.Build` is unique on
  package/version/image.

  The window is the retention guarantee, so it must stay comfortably larger than
  the cron interval. Widening it is cheap -- hex.pm sees on the order of 130
  updates a day, so six hours is well under one 100-row page.

  ## Scope

  Only packages already in the catalogue. A package hex.pm updated that we have
  never tested is not stale, it is absent, and seeding new packages belongs to
  `Portal.UpstreamBackfill`. Restricting it this way also bounds the work: we
  track roughly a seventh of hex.pm, so a typical day is on the order of fifteen
  rebuilds.

  ## Why queue `:intake`

  The work here is one HTTP request to hex.pm and a handful of inserts, not a
  compile. `:intake` runs on the web host, which keeps a registry-wide check off
  the machine doing the builds it is queueing -- the same reasoning
  `Portal.Workers.Backfill` documents.

  ## Enablement

  Disabled unless `config :portal, #{inspect(__MODULE__)}, enabled: true`
  (`NCC_UPDATE_CHECK=1` at runtime). The cron entry runs regardless and returns
  immediately while disabled, which lets the schedule be verified in production
  without sending hex.pm a single request -- this polls somebody else's service,
  and that was worth asking permission for before switching on.
  """

  use Oban.Worker,
    queue: :intake,
    # A failed check waits for the next tick rather than hammering hex.pm: the
    # next run's window still covers anything this one missed. Two attempts
    # cover a transient blip without turning an outage into a retry storm.
    max_attempts: 2,
    unique: [period: :infinity, states: :incomplete]

  require Ash.Query
  require Logger

  alias Portal.Catalog.Package
  alias Portal.Catalog.Run
  alias Portal.Workers.Backfill

  @default_lookback_ms :timer.hours(6)
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
  Check hex.pm for updates and queue a rebuild for every package whose version
  has moved.

  Runs regardless of the `:enabled` flag -- that gate belongs to the scheduled
  path, not to a human at a console deciding to run one on purpose.

  Options:

    * `:lookback_ms` - how far back to ask (default six hours)
    * `:dry_run` - report what would be queued without queueing it

  Returns `{:ok, %{seen: n, moved: n, enqueued: n, deferred: n}}`, where `seen`
  counts packages hex.pm updated in the window, `moved` the subset we track that
  is worth rebuilding, `enqueued` the jobs actually inserted -- lower than
  `moved` when a package is already queued from an earlier run, or when the
  per-run cap binds -- and `deferred` the ones the cap held back for a later run.

  Options:

    * `:lookback_ms` - override the configured window.
    * `:max_per_run` - override the configured cap.
    * `:dry_run` - classify without inserting anything.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    lookback_ms = Keyword.get(opts, :lookback_ms, lookback_ms())
    since = DateTime.add(DateTime.utc_now(), -lookback_ms, :millisecond)

    max_per_run = Keyword.get(opts, :max_per_run, max_per_run())

    case updates_source().recently_updated(since: since) do
      {:ok, updates} ->
        moved = moved(updates)
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
          "Update check: #{length(updates)} updated on hex, #{length(moved)} tracked and worth rebuilding, #{enqueued} queued"
        )

        {:ok,
         %{
           seen: length(updates),
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
  # Ordering matters only when the cap binds, and then it matters a lot. The
  # window is the only thing keeping a deferred package alive: it is re-offered
  # on every run until it falls past the cutoff. So the right work to do first
  # is the work closest to expiring. Taking the newest instead would starve
  # exactly the packages about to drop out -- they would be skipped every hour
  # by fresher arrivals and then be gone, and nothing would notice.
  defp select(moved, max_per_run) do
    selected = moved |> Enum.reverse() |> Enum.take(max_per_run)
    {selected, length(moved) - length(selected)}
  end

  defp moved([]), do: []

  defp moved(updates) do
    names = Enum.map(updates, & &1.name)

    tracked =
      Package
      |> Ash.Query.filter(name in ^names)
      |> Ash.Query.select([:id, :name, :latest_version])
      |> Ash.read!(domain: Portal.Catalog)

    statuses = latest_run_statuses(Enum.map(tracked, & &1.id))
    by_name = Map.new(tracked, &{&1.name, &1})

    Enum.filter(updates, fn update ->
      case Map.fetch(by_name, update.name) do
        {:ok, package} -> rebuild?(package, update, statuses)
        :error -> false
      end
    end)
  end

  # A tracked package with no version on record has never produced a build
  # result. That is as stale as a version that moved, and the same rebuild is
  # the fix, so it belongs here rather than in a special case.
  defp rebuild?(%{latest_version: nil}, _update, _statuses), do: true

  defp rebuild?(package, update, statuses) do
    package.latest_version != update.latest_version and
      (significant?(package.latest_version, update.latest_version) or
         not passing?(package.id, statuses))
  end

  # Whether a version change is worth a rebuild on its own.
  #
  # Patch releases are 45% of the drift in this catalogue and are the releases
  # least likely to change what we measure -- compilation against a Nerves
  # target, native components, footprint. Skipping them halves the rebuild
  # volume for close to no loss of signal, and a maintainer who wants a patch
  # verified can still ask for a scan by hand.
  #
  # The exception is in `rebuild?/3` above rather than here: a package whose
  # last run did not pass is rebuilt on *any* version change. A patch release on
  # a failing package is the most informative event we can observe -- it is
  # usually the maintainer fixing the thing we flagged -- and refusing to look
  # would leave a red badge that no release can ever clear. It costs little:
  # only 8 of the 175 patch-only drifts measured here were on failing packages.
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
      # Expected on every overlapping window, and not worth logging.
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

  defp lookback_ms, do: Keyword.get(config(), :lookback_ms, @default_lookback_ms)

  defp max_per_run, do: Keyword.get(config(), :max_per_run, @default_max_per_run)

  defp config, do: Application.get_env(:portal, __MODULE__, [])

  defp updates_source,
    do: Application.get_env(:portal, :hex_updates_source, Portal.HexPm)
end
