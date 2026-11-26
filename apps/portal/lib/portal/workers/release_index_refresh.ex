defmodule Portal.Workers.ReleaseIndexRefresh do
  @moduledoc """
  Runs the module index per release (`Portal.Catalog.ReleaseIndex.refresh/1`,
  queue `:intake`), S10 round 5.

    * `%{"incremental" => true}`: the releases the registry lists that the
      index has not tried; `Portal.Workers.UpdateCheck` queues it hourly
      when there are any (`Portal.Catalog.ReleaseIndex.queue_incremental/1`).
    * `%{}` (daily cron, and the first run, started by hand once a release
      with this worker is deployed, after a dry run): the same, and the
      releases that failed before are tried again.

  At most one of each waiting (`unique` over available and scheduled jobs,
  not an executing one, so a run a deploy killed can be inserted again at
  once). Two runs at once are safe: each release is stored in a
  transaction of its own, and the same release read twice stores the same
  rows. A stopped run keeps what it stored; the next one reads the rest.
  The first run reads every release of every Hex package (184,566 on
  2026-11-26); its measurement is in the S10 report (§13).
  """

  use Oban.Worker,
    queue: :intake,
    max_attempts: 1,
    unique: [period: :infinity, states: [:available, :scheduled]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    opts = if is_integer(args["limit"]), do: [limit: args["limit"]], else: []
    opts = if args["incremental"] == true, do: opts, else: [{:retry_failed, true} | opts]
    _counts = Portal.Catalog.ReleaseIndex.refresh(opts)
    :ok
  end

  @impl Oban.Worker
  # Under `Oban.Plugins.Lifeline`'s 3 h `rescue_after`; a first run that
  # needs longer is resumed by inserting the job again.
  def timeout(_job), do: :timer.minutes(150)
end
