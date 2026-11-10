defmodule Portal.Workers.ReportRequeueSweep do
  @moduledoc """
  Oban worker (queue `:reports`, daily at 00:29 UTC, just after the caps of
  `Portal.Reports.Quotas` reset) that retries the miss-report lines a cap
  refused or nothing decided (`Portal.Reports.Requeue.sweep/1`). A pass that
  fails, Hex not answering included, waits for the next day.
  """

  use Oban.Worker,
    queue: :reports,
    max_attempts: 1,
    unique: [period: 3_600, states: :incomplete]

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: Portal.Reports.Requeue.sweep()
end
