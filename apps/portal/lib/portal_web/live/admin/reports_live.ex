defmodule PortalWeb.Admin.ReportsLive do
  @moduledoc """
  Admin Reports tab: the miss and fail reports testers send with
  `mix precompiled.report`, and the top reason codes behind them
  (`Portal.Reports.Report`, `Portal.Reports.Line`, `Portal.Reports.Summary`;
  see `Portal.Reports.Payload` for what a report may carry).

  Read-only. Nothing here mutates, so no event re-checks the admin the way a
  write would on another tab -- the `on_mount` hooks already guard every
  connect and reconnect, and that is the whole check this page needs.
  `?report=` opens one report's lines; an id nobody has, or that is not a
  UUID, renders the list with nothing selected, the same as an unmatched
  filter on the Not precompiled tab.

  `contact` and `reporter_key` never reach this page: `@report_fields` and
  `@line_fields` name everything a query here is allowed to select, and
  nothing outside that list is shown.
  """
  use PortalWeb, :live_view

  import PortalWeb.AdminComponents
  import PortalWeb.Admin.LiveAuth, only: [sane_page: 1, table_state_change: 2]

  require Ash.Query

  alias Portal.Reports.{Line, Report, Requeue, Summary}

  @report_fields [
    :id,
    :received_at,
    :client,
    :elixir,
    :otp,
    :os_family,
    :os_arch,
    :target,
    :system,
    :system_version,
    :seen_count,
    :hit_count,
    :miss_count,
    :fail_count
  ]

  @line_fields [
    :id,
    :package,
    :version,
    :status,
    :reason_code,
    :reason_args,
    :reason,
    :requeue,
    :inserted_at
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Admin",
       page_description: "Administration.",
       reports_query:
         Report
         |> Ash.Query.select(@report_fields)
         |> Ash.Query.sort(received_at: :desc)
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket = Cinder.UrlSync.handle_params(sane_page(params), uri, socket)
    selected = selected_report(params["report"])

    {:noreply,
     assign(socket,
       selected: selected,
       lines: if(selected, do: lines_of(selected.id), else: []),
       reason_summary: Summary.by_reason_code()
     )}
  end

  @impl true
  def handle_info({:table_state_change, _table_id, encoded_state}, socket),
    do: table_state_change(socket, encoded_state)

  defp selected_report(id) when is_binary(id) and id != "" do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Report
        |> Ash.Query.select(@report_fields)
        |> Ash.Query.filter(id == ^uuid)
        |> Ash.read_one!(domain: Portal.Reports)

      :error ->
        nil
    end
  end

  defp selected_report(_id), do: nil

  defp lines_of(report_id) do
    Line
    |> Ash.Query.select(@line_fields)
    |> Ash.Query.filter(report_id == ^report_id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(domain: Portal.Reports)
  end

  # Only `codes/0` are ever decided; any other code stays nil forever, which
  # would otherwise read as a report still waiting.
  defp requeue_label(nil, reason_code) do
    if reason_code in Requeue.codes(), do: "pending", else: "not eligible"
  end

  defp requeue_label(value, _reason_code), do: value

  defp system_label(%{system: nil}), do: "-"
  defp system_label(%{system: system, system_version: version}), do: "#{system} #{version}"

  defp number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_layout flash={@flash} current_user={@current_user} section={:reports} title="Reports">
      <:subtitle>
        Miss and fail reports from testers running <code>mix precompiled.report</code>, with the reason codes behind them.
      </:subtitle>

      <section id="reports-reasons" class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-base">Top reason codes</h2>
          <p class="text-xs text-base-content/60">Last 30 days, most lines first.</p>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Reason code</th>
                  <th>Lines</th>
                  <th>Reports</th>
                  <th>Reporters</th>
                  <th>First seen</th>
                  <th>Last seen</th>
                  <th>Queued</th>
                  <th>Skipped</th>
                  <th>Open</th>
                </tr>
              </thead>
              <tbody id="reason-rows">
                <tr :if={@reason_summary == []}>
                  <td colspan="9" class="text-sm text-base-content/60">
                    No reports in the last 30 days.
                  </td>
                </tr>
                <tr :for={row <- @reason_summary} id={"reason-#{row.reason_code}"}>
                  <td class="font-mono text-sm">{row.reason_code}</td>
                  <td>{number(row.count)}</td>
                  <td>{number(row.reports)}</td>
                  <td>{number(row.reporters)}</td>
                  <td class="whitespace-nowrap text-xs">{format_datetime(row.first_seen)}</td>
                  <td class="whitespace-nowrap text-xs">{format_datetime(row.last_seen)}</td>
                  <td>{number(row.queued)}</td>
                  <td>{number(row.skipped)}</td>
                  <td>{number(row.open)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <section id="reports-recent" class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-base">Recent reports</h2>
          <p class="text-xs text-base-content/60">Newest first. Open one to see its lines.</p>

          <div id="reports-table" class="mt-3">
            <Cinder.collection
              id="reports"
              query={@reports_query}
              actor={@current_user}
              url_state={@url_state}
              page_size={25}
              empty_message="No reports yet."
            >
              <:col :let={r} field="received_at" label="Received" sort>
                {format_datetime(r.received_at)}
              </:col>
              <:col :let={r} field="client" label="Client" filter sort class="font-mono">
                {r.client}
              </:col>
              <:col :let={r} label="Elixir/OTP">{r.elixir}/{r.otp}</:col>
              <:col :let={r} field="target" label="Target" filter class="font-mono">
                {r.target}
              </:col>
              <:col :let={r} label="System">{system_label(r)}</:col>
              <:col :let={r} label="OS">{r.os_family}/{r.os_arch}</:col>
              <:col :let={r} field="hit_count" label="Hits" sort>{r.hit_count}</:col>
              <:col :let={r} field="miss_count" label="Misses" sort>{r.miss_count}</:col>
              <:col :let={r} field="fail_count" label="Fails" sort>{r.fail_count}</:col>
              <:col :let={r} label="">
                <.link
                  id={"report-view-#{r.id}"}
                  patch={~p"/admin/reports?report=#{r.id}"}
                  class="link link-hover"
                >
                  View
                </.link>
              </:col>
            </Cinder.collection>
          </div>
        </div>
      </section>

      <section
        :if={@selected}
        id="report-detail"
        class="card border border-base-300 bg-base-100 shadow-sm"
      >
        <div class="card-body">
          <div class="flex items-start justify-between gap-2">
            <h2 class="card-title text-base">Report lines</h2>
            <.link patch={~p"/admin/reports"} class="link link-hover text-sm">Close</.link>
          </div>

          <dl class="grid grid-cols-2 gap-2 text-sm sm:grid-cols-4">
            <div>
              <dt class="text-base-content/60">Received</dt>
              <dd>{format_datetime(@selected.received_at)}</dd>
            </div>
            <div>
              <dt class="text-base-content/60">Client</dt>
              <dd class="font-mono">{@selected.client}</dd>
            </div>
            <div>
              <dt class="text-base-content/60">Elixir/OTP</dt>
              <dd>{@selected.elixir}/{@selected.otp}</dd>
            </div>
            <div>
              <dt class="text-base-content/60">OS</dt>
              <dd>{@selected.os_family}/{@selected.os_arch}</dd>
            </div>
            <div>
              <dt class="text-base-content/60">Target</dt>
              <dd class="font-mono">{@selected.target}</dd>
            </div>
            <div>
              <dt class="text-base-content/60">System</dt>
              <dd>{system_label(@selected)}</dd>
            </div>
            <div>
              <dt class="text-base-content/60">Hit/miss/fail</dt>
              <dd>{@selected.hit_count}/{@selected.miss_count}/{@selected.fail_count}</dd>
            </div>
            <div>
              <dt class="text-base-content/60">Seen</dt>
              <dd>{@selected.seen_count} time(s)</dd>
            </div>
          </dl>

          <div class="overflow-x-auto mt-3">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Package</th>
                  <th>Version</th>
                  <th>Status</th>
                  <th>Reason code</th>
                  <th>Reason</th>
                  <th>Requeue</th>
                </tr>
              </thead>
              <tbody id="report-lines">
                <tr :if={@lines == []}>
                  <td colspan="6" class="text-sm text-base-content/60">No miss or fail lines.</td>
                </tr>
                <tr :for={line <- @lines} id={"report-line-#{line.id}"}>
                  <td class="font-medium">
                    <.link navigate={~p"/packages/#{line.package}"} class="link link-hover">
                      {line.package}
                    </.link>
                  </td>
                  <td class="whitespace-nowrap">{line.version}</td>
                  <td>
                    <span class={[
                      "badge badge-sm",
                      if(line.status == :fail, do: "badge-error", else: "badge-warning")
                    ]}>
                      {line.status}
                    </span>
                  </td>
                  <td class="font-mono text-sm">{line.reason_code}</td>
                  <td class="text-sm">
                    {line.reason || "-"}
                    <span :if={line.reason_args != []} class="block text-xs text-base-content/60">
                      {Enum.join(line.reason_args, ", ")}
                    </span>
                  </td>
                  <td class="text-sm">{requeue_label(line.requeue, line.reason_code)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>
    </.admin_layout>
    """
  end
end
