defmodule PortalWeb.PrecompiledReportController do
  @moduledoc """
  Miss reports from the precompiled client (`Portal.Reports`). The router's
  `:precompiled_reports` pipeline has already applied the rate limits and
  parsed at most 256 KiB of JSON. The client address is used only in memory,
  for the limits and `Portal.Reports.reporter_key/2`.

  A new report is answered `201` with its id; an identical one within 24
  hours `200 {"duplicate": true}` with no id, because the id is what retracts
  a report and the second sender may not be the first.
  """
  use PortalWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Portal.Reports
  alias Portal.Reports.Payload
  alias PortalWeb.ApiSchemas
  alias PortalWeb.Plugs.RateLimit

  operation :create,
    tags: ["Precompiled"],
    operation_id: "sendPrecompiledReport",
    summary: "Send a miss report",
    description:
      "Stores what a client's build hit, missed and failed, and answers 201 with the report's " <>
        "id. An identical report within 24 hours is counted, not stored again, and answered 200 " <>
        "`{\"duplicate\": true}` without an id: the id is what retracts a report, and the first " <>
        "one may have come from someone else with the same project. At most 256 KiB of " <>
        "`application/json` (utf-8). 10 requests an hour per client; a shared limit of 300 " <>
        "accepted reports an hour and 2000 a day, which refused requests do not use up.",
    request_body: {"The report", "application/json", ApiSchemas.ReportRequest},
    responses: [
      created: {"Stored", "application/json", ApiSchemas.ReportCreated},
      ok: {"Already received", "application/json", ApiSchemas.ReportDuplicate},
      unprocessable_entity: {"Refused", "application/json", ApiSchemas.ReportRejected},
      bad_request: %OpenApiSpex.Response{description: "Body is not well-formed JSON"},
      request_entity_too_large: %OpenApiSpex.Response{description: "Body over 256 KiB"},
      unsupported_media_type:
        {"Not JSON, or a charset other than utf-8", "application/json", ApiSchemas.Error},
      too_many_requests: {"Rate limited; see retry-after", "application/json", ApiSchemas.Error}
    ]

  def create(conn, _params) do
    case Payload.validate(conn.body_params) do
      {:ok, payload} ->
        key = Reports.reporter_key(RateLimit.client_key(conn), conn.secret_key_base)

        case Reports.record(payload, key) do
          {:created, id} -> conn |> spend_global() |> put_status(:created) |> json(%{id: id})
          :duplicate -> conn |> spend_global() |> json(%{duplicate: true})
        end

      {:error, details} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid report", details: Enum.take(details, 20)})
    end
  end

  # The router only peeks at the global buckets; an accepted report spends
  # them, so refused requests cannot use up everyone's budget.
  defp spend_global(conn) do
    for bucket <- [:precompiled_report_global, :precompiled_report_global_day] do
      RateLimit.spend(conn, bucket: bucket, by: :global)
    end

    conn
  end

  operation :delete,
    tags: ["Precompiled"],
    operation_id: "retractPrecompiledReport",
    summary: "Retract a miss report",
    description:
      "Deletes a report and its lines. The id the report was answered with is all it takes. " <>
        "Counts against the same per-client rate limit as sending.",
    parameters: [id: [in: :path, type: :string, description: "The report id.", required: true]],
    responses: [
      no_content: %OpenApiSpex.Response{description: "Removed"},
      not_found: {"No such report", "application/json", ApiSchemas.Error},
      too_many_requests: {"Rate limited; see retry-after", "application/json", ApiSchemas.Error}
    ]

  def delete(conn, %{"id" => id}) do
    case Reports.retract(id) do
      :ok -> send_resp(conn, :no_content, "")
      :not_found -> conn |> put_status(:not_found) |> json(%{error: "report not found"})
    end
  end
end
