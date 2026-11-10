defmodule Portal.Reports do
  @moduledoc """
  Miss reports from the `precompiled` client: what a tester's build hit, missed
  and failed, sent with `mix precompiled.report` to
  `POST /api/precompiled/reports` (`PortalWeb.PrecompiledReportController`).

  A report is anonymous. The only trace of who sent it is `reporter_key`, an
  HMAC of the client's address (`reporter_key/2`), kept 90 days for the
  per-reporter requeue cap. Only MISS and FAIL lines are stored as rows; HIT
  lines only raise `hit_count`.
  """

  use Ash.Domain

  resources do
    resource(Portal.Reports.Report)
    resource(Portal.Reports.Line)
    resource(Portal.Reports.Quota)
  end
end
