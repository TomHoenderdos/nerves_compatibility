defmodule Portal.Workers.ModuleIndexRefresh do
  @moduledoc """
  Weekly cron (queue `:intake`) that refreshes the module index
  (`Portal.Catalog.ModuleIndex.refresh/1`): the modules the latest release
  of each package with 1,000 or more recent downloads defines. Runs after
  `Portal.Workers.HexMetaRefresh` has refreshed the download counts and
  latest versions, and fetches only the packages whose latest release
  changed since the last run (the first run reads all of them). `limit`
  (job args) caps the packages one run reads.

  At most one run waiting (`unique` over available and scheduled jobs, not
  an executing one: a deploy that kills a run leaves its job executing until
  `Oban.Plugins.Lifeline` rescues it, and the run must be resumable at once,
  round 5, R3-7). Two runs at once are safe: the newer generation
  supersedes the older, which stops at its next package and never marks
  the index complete (`Portal.Catalog.ModuleIndex`). The first run reads
  every package (about 5,000); start it by hand once a release with this
  worker is deployed, from the web host, after a dry run:

      Portal.Catalog.ModuleIndex.refresh(dry_run: true)
      Oban.insert(Portal.Workers.ModuleIndexRefresh.new(%{}))

  It fetches and parses at most 4 packages at once
  (`Portal.Catalog.ModuleIndex.max_concurrency/0`) and stores each one as
  soon as it is read, so a restart (a deploy) loses at most the 4 in flight:
  insert the job again and it fetches only the rest. Until a run completes,
  every recorded declared-absent probe refuses. Fetching and parsing measured 15 to 25 ms a package at 4 at
  once on a fast link, about 100 MB of BEAM memory at the peak; with the
  database writes and a slower host a first run should take well under 30
  minutes. The timeout below is 150 minutes.
  """

  use Oban.Worker,
    queue: :intake,
    max_attempts: 1,
    unique: [period: :infinity, states: [:available, :scheduled]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    opts = if is_integer(args["limit"]), do: [limit: args["limit"]], else: []
    _counts = Portal.Catalog.ModuleIndex.refresh(opts)
    :ok
  end

  @impl Oban.Worker
  # Under `Oban.Plugins.Lifeline`'s 3 h `rescue_after`, so a run is never
  # rescued while it still runs.
  def timeout(_job), do: :timer.minutes(150)
end
