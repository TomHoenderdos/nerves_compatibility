defmodule Portal.Workers.HexMetaRefresh do
  @moduledoc """
  Weekly cron (queue `:intake`) that re-fetches hex.pm metadata for every
  package in the catalog.

  Links and owners change on the order of years, but download counts drift
  week to week, and `/failing` ranks on them. This forces a full pass through
  `Portal.HexMetaBackfill` rather than the never-fetched-only default.

  Enqueues only; the hex.pm requests happen in the `PackageMeta` jobs, staggered
  1.5 s apart -- ~2,500 packages is roughly an hour, under hex.pm's
  unauthenticated rate limit.
  """

  use Oban.Worker, queue: :intake, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, _counts} = Portal.HexMetaBackfill.run(only_missing: false, stagger_ms: 1500)
    :ok
  end
end
