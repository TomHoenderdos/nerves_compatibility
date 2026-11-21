defmodule Portal.Workers.ModuleIndexRefresh do
  @moduledoc """
  Weekly cron (queue `:intake`) that refreshes the module index
  (`Portal.Catalog.ModuleIndex.refresh/1`): the modules the latest release
  of each package with 1,000 or more recent downloads defines. Runs after
  `Portal.Workers.HexMetaRefresh` has refreshed the download counts and
  latest versions, and fetches only the packages whose latest release
  changed since the last run (the first run reads all of them). `limit`
  (job args) caps the packages one run reads.
  """

  use Oban.Worker, queue: :intake, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    opts = if is_integer(args["limit"]), do: [limit: args["limit"]], else: []
    _counts = Portal.Catalog.ModuleIndex.refresh(opts)
    :ok
  end
end
