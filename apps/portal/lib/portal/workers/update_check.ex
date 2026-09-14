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
  alias Portal.Workers.Backfill

  @default_lookback_ms :timer.hours(6)

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

  Returns `{:ok, %{seen: n, moved: n, enqueued: n}}`, where `seen` counts
  packages hex.pm updated in the window, `moved` the subset we track whose
  version differs from the one on record, and `enqueued` the jobs actually
  inserted -- lower than `moved` when a package is already queued from an
  earlier run.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    lookback_ms = Keyword.get(opts, :lookback_ms, lookback_ms())
    since = DateTime.add(DateTime.utc_now(), -lookback_ms, :millisecond)

    case updates_source().recently_updated(since: since) do
      {:ok, updates} ->
        moved = moved(updates)

        enqueued =
          if Keyword.get(opts, :dry_run, false) do
            0
          else
            Enum.count(moved, &enqueue/1)
          end

        Logger.info(
          "Update check: #{length(updates)} updated on hex, #{length(moved)} tracked and moved, #{enqueued} queued"
        )

        {:ok, %{seen: length(updates), moved: length(moved), enqueued: enqueued}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp moved([]), do: []

  defp moved(updates) do
    names = Enum.map(updates, & &1.name)

    tested =
      Package
      |> Ash.Query.filter(name in ^names)
      |> Ash.Query.select([:name, :latest_version])
      |> Ash.read!(domain: Portal.Catalog)
      |> Map.new(&{&1.name, &1.latest_version})

    Enum.filter(updates, fn update ->
      case Map.fetch(tested, update.name) do
        # A tracked package with no version on record has never produced a build
        # result. That is as stale as a version that moved, and the same rebuild
        # is the fix, so it belongs here rather than in a special case.
        {:ok, on_record} -> on_record != update.latest_version
        :error -> false
      end
    end)
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

  defp config, do: Application.get_env(:portal, __MODULE__, [])

  defp updates_source,
    do: Application.get_env(:portal, :hex_updates_source, Portal.HexPm)
end
