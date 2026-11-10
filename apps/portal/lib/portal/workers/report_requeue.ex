defmodule Portal.Workers.ReportRequeue do
  @moduledoc """
  Oban worker (queue `:reports`) that decides one new report's not-built
  misses (`Portal.Reports.Requeue.run_report/2`). Enqueued by
  `Portal.Reports.record/3` in the same transaction as the report, and only
  for a new report with such a line; a duplicate enqueues nothing.

  `:reports` is a queue only releases with this worker configure
  (`config/runtime.exs`), so during a blue/green switch the old release never
  claims one of these jobs. If Hex cannot be asked, the job snoozes ten
  minutes with nothing decided.
  """

  use Oban.Worker,
    queue: :reports,
    max_attempts: 5,
    unique: [keys: [:report_id], period: :infinity, states: :incomplete]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"report_id" => report_id}}) do
    case Portal.Reports.Requeue.run_report(report_id) do
      :ok -> :ok
      {:error, :hex_unavailable} -> {:snooze, 600}
    end
  end
end
