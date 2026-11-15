defmodule Portal.Workers.CatalogSeedSweep do
  @moduledoc """
  Oban worker (queue `:intake`, daily cron) that runs `Portal.CatalogSeed.run/1`
  so the registry-wide seed is not a thing a human has to remember to run.

  Before this existed, `CatalogSeed` had no schedule at all: every package
  hex.pm published since the last manual run sat outside the catalogue with
  no build and no row, growing without anyone noticing (see
  `docs/superpowers/ops/factory/hex-all.md`, which found ~1,046 such packages
  across about six weeks). Daily is often enough -- hex.pm publishes on the
  order of a hundred-odd packages a day across the whole registry, and this
  worker only cares about the sliver of that which is genuinely new.

  ## Pacing

  Calls `CatalogSeed.run/1` with the same `stagger_ms` knob the one-off
  catalogue bootstrap used by hand (see the ops log above), rather than a bare
  call that would fall back to `CatalogSeed`'s 1 s default. A day's worth of
  new packages is small -- tens, not thousands -- so even the bootstrap's
  slower spacing finishes in well under a day; the one-off run needed 45 s
  because the gap it was closing was the entire backlog (~1,100 packages) and
  it had to arrive slower than the single remote builder of the time could
  drain, not because daily growth needs it. Kept here anyway so a growth spike
  (e.g. a registry outage followed by a flood of releases) gets the same
  protection the manual run relied on, rather than a burst of hex.pm lookups.

  ## Idempotence

  `CatalogSeed.run/1` is itself safe to re-run (`Portal.Workers.Backfill` is
  unique per package per day, and the diff against the catalogue is
  recomputed fresh every call), so a second cron tick on the same day enqueues
  nothing new for a package the first tick already queued. The `unique` below
  is a second, cheaper guard on top of that: it stops two sweep *jobs* from
  running concurrently if one is still `available`, `scheduled`, `executing`
  or `retryable` when the next day's cron fires -- the same guard
  `Portal.Workers.ToolchainSweep` carries, for the same reason. It does not
  block on `completed`, so the ordinary daily cadence is unaffected.

  ## Priority

  No priority of its own to set: `CatalogSeed.run/1` tags every job it
  enqueues with `source: catalog_seed`, which `Portal.ScanRequests` maps to
  Oban's lowest priority band (9) -- the same path the manual run used.
  """

  use Oban.Worker,
    queue: :intake,
    max_attempts: 3,
    unique: [period: 86_400, states: :incomplete]

  require Logger

  @stagger_ms 45_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Portal.CatalogSeed.run(stagger_ms: @stagger_ms) do
      {:ok, report} ->
        Logger.info("Catalog seed sweep: #{inspect(report)}")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
