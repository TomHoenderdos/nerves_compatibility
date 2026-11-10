defmodule Portal.Workers.ReportRequeueTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Workers.ReportRequeue

  test "runs on the reports queue, once per report" do
    assert ReportRequeue.__opts__()[:queue] == :reports
    assert ReportRequeue.__opts__()[:unique][:keys] == [:report_id]
  end

  test "a retracted report is nothing to do" do
    assert :ok = perform_job(ReportRequeue, %{"report_id" => Ecto.UUID.generate()})
  end
end
