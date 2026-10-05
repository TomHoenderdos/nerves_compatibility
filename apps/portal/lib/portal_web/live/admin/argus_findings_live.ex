defmodule PortalWeb.Admin.ArgusFindingsLive do
  @moduledoc """
  Internal triage of argus findings across packages. Admin (passkey) only;
  see `Portal.Catalog.FindingTriage`. Nothing here is public or sent anywhere.
  """
  use PortalWeb, :live_view

  alias Portal.Catalog

  @statuses [
    {:new, "new"},
    {:confirmed, "confirmed"},
    {:false_positive, "false positive"},
    {:reported, "reported"}
  ]
  @severities ~w(error warning info)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "argus findings",
       page_description: "Internal triage of argus findings.",
       statuses: @statuses,
       status_options: Enum.map(@statuses, fn {atom, label} -> {label, atom} end),
       severities: @severities
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = filters(params)
    {rows, total} = Catalog.triage_page(filters, page_limit())

    {:noreply,
     socket
     |> assign(:filter_form, to_form(filter_params(filters), as: :f))
     |> assign(:counts, Catalog.triage_counts())
     |> assign(:shown, length(rows))
     |> assign(:total, total)
     |> stream(:findings, rows, reset: true, dom_id: &"finding-#{&1.triage.id}")}
  end

  @impl true
  def handle_event("filter", %{"f" => f}, socket) do
    query =
      %{
        "status" => f |> Map.get("status") |> List.wrap() |> Enum.reject(&(&1 == "")),
        "severity" => f |> Map.get("severity") |> List.wrap() |> Enum.reject(&(&1 == "")),
        "analysis" => f["analysis"],
        "package" => f["package"],
        "stale" => if(f["stale"] == "true", do: "true")
      }
      |> Enum.reject(fn {key, value} -> value in [nil, "", []] or default?(key, value) end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/admin/argus/findings?#{query}")}
  end

  def handle_event("triage", %{"finding_id" => id, "triage" => triage}, socket) do
    row =
      Catalog.triage!(
        id,
        %{status: triage["status"], note: blank_to_nil(triage["note"])},
        socket.assigns.current_user
      )

    {:noreply,
     socket
     |> assign(:counts, Catalog.triage_counts())
     |> stream_insert(:findings, %{triage: row, stale?: Catalog.triage_stale?(row)})
     |> put_flash(:info, "Saved.")}
  end

  # A selection equal to the default stays out of the URL, so a shared link
  # only says what was actually narrowed.
  defp default?("status", value), do: Enum.sort(value) == ["confirmed", "new"]
  defp default?("severity", value), do: Enum.sort(value) == Enum.sort(@severities)
  defp default?(_key, _value), do: false

  # Rows rendered at once. Each carries two inputs, so a page of every finding
  # in the catalogue would be slow to diff; narrow the filters to see more.
  defp page_limit do
    :portal |> Application.get_env(__MODULE__, []) |> Keyword.get(:page_limit, 500)
  end

  defp filters(params) do
    %{}
    |> put_list(:status, params["status"], &status_atom/1)
    |> put_list(:severity, params["severity"], &(&1 in @severities && &1))
    |> Map.put(:analysis, blank_to_nil(params["analysis"]))
    |> Map.put(:package, blank_to_nil(params["package"]))
    |> Map.put(:include_stale, params["stale"] == "true")
  end

  defp put_list(map, key, values, cast) do
    case values |> List.wrap() |> Enum.map(cast) |> Enum.filter(& &1) do
      [] -> map
      list -> Map.put(map, key, list)
    end
  end

  defp status_atom(value) do
    Enum.find_value(@statuses, fn {atom, _label} -> Atom.to_string(atom) == value && atom end)
  end

  defp filter_params(filters) do
    %{
      "status" => filters |> Map.get(:status, [:new, :confirmed]) |> Enum.map(&Atom.to_string/1),
      "severity" => Map.get(filters, :severity, @severities),
      "analysis" => filters.analysis,
      "package" => filters.package,
      "stale" => to_string(filters.include_stale)
    }
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp text(value) when is_binary(value), do: value
  defp text(_), do: nil

  defp hints(finding), do: finding |> Map.get("help") |> List.wrap() |> Enum.filter(&is_binary/1)

  defp location(%{file: file, line: line}) when is_binary(file) and is_integer(line),
    do: "#{file}:#{line}"

  defp location(%{file: file}), do: file

  defp severity_class("error"), do: "badge-error"
  defp severity_class("warning"), do: "badge-warning"
  defp severity_class(_), do: "badge-ghost"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-6">
        <PortalWeb.UI.page_header kicker="Admin" title="argus findings">
          <:subtitle>Internal triage. Nothing here is public or sent to anyone.</:subtitle>
        </PortalWeb.UI.page_header>

        <div id="triage-counts" class="flex flex-wrap gap-2">
          <span :for={{status, label} <- @statuses} class="badge badge-lg badge-outline">
            {Map.get(@counts, status, 0)} {label}
          </span>
        </div>

        <p :if={@total > @shown} id="triage-shown" class="text-sm text-base-content/60">
          Showing {@shown} of {@total}. Narrow the filters to see the rest.
        </p>

        <.form
          for={@filter_form}
          id="triage-filters"
          phx-change="filter"
          class="grid items-start gap-4 sm:grid-cols-5"
        >
          <%!-- Checkbox groups rather than multi-selects: a select box clips its
          options, so a selected status can sit out of sight. --%>
          <fieldset>
            <legend class="label mb-1">Status</legend>
            <label :for={{atom, label} <- @statuses} class="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                id={"filter-status-#{atom}"}
                name="f[status][]"
                value={atom}
                checked={Atom.to_string(atom) in @filter_form[:status].value}
                class="checkbox checkbox-sm"
              /> {label}
            </label>
          </fieldset>
          <fieldset>
            <legend class="label mb-1">Severity</legend>
            <label :for={severity <- @severities} class="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                id={"filter-severity-#{severity}"}
                name="f[severity][]"
                value={severity}
                checked={severity in @filter_form[:severity].value}
                class="checkbox checkbox-sm"
              /> {severity}
            </label>
          </fieldset>
          <.input field={@filter_form[:analysis]} type="text" label="Analysis" phx-debounce="300" />
          <.input field={@filter_form[:package]} type="text" label="Package" phx-debounce="300" />
          <.input field={@filter_form[:stale]} type="checkbox" label="Include no longer seen" />
        </.form>

        <div class="overflow-x-auto rounded-2xl border border-base-300 bg-base-100 shadow-sm">
          <table class="w-full text-sm">
            <thead class="bg-base-200/60 text-left text-xs uppercase tracking-wide text-base-content/60">
              <tr>
                <th class="px-4 py-3">Finding</th>
                <th class="px-4 py-3">Versions</th>
                <th class="px-4 py-3">Triage</th>
              </tr>
            </thead>
            <tbody id="findings" phx-update="stream" class="divide-y divide-base-200">
              <tr :for={{dom_id, %{triage: t, stale?: stale?}} <- @streams.findings} id={dom_id}>
                <td class="px-4 py-3 align-top">
                  <div class="flex flex-wrap items-center gap-2">
                    <span class={["badge badge-sm", severity_class(t.severity)]}>{t.severity}</span>
                    <.link navigate={~p"/packages/#{t.package_name}"} class="link font-mono">
                      {t.package_name}
                    </.link>
                    <span class="badge badge-sm badge-outline font-mono">{t.analysis}</span>
                    <span :if={stale?} class="badge badge-sm badge-ghost">no longer seen</span>
                  </div>
                  <div class="mt-1 font-medium text-base-content">{t.title}</div>
                  <div :if={location(t)} class="font-mono text-xs text-base-content/60">
                    {location(t)}
                  </div>
                  <details class="mt-1 text-base-content/70">
                    <summary class="cursor-pointer text-xs">Details</summary>
                    <p :if={text(t.finding["detail"])}>{text(t.finding["detail"])}</p>
                    <ul class="list-disc pl-5">
                      <li :for={hint <- hints(t.finding)}>{hint}</li>
                    </ul>
                  </details>
                </td>
                <td class="px-4 py-3 align-top font-mono text-xs text-base-content/60">
                  {t.first_seen_version} → {t.last_seen_version}
                </td>
                <td class="w-64 px-4 py-3 align-top">
                  <.form
                    for={
                      to_form(%{"status" => Atom.to_string(t.status), "note" => t.note}, as: :triage)
                    }
                    id={"triage-form-#{t.id}"}
                    phx-change="triage"
                  >
                    <input type="hidden" name="finding_id" value={t.id} />
                    <.input
                      id={"triage-status-#{t.id}"}
                      name="triage[status]"
                      type="select"
                      value={Atom.to_string(t.status)}
                      options={@status_options}
                    />
                    <.input
                      id={"triage-note-#{t.id}"}
                      name="triage[note]"
                      type="text"
                      value={t.note}
                      placeholder="Note"
                      phx-debounce="500"
                    />
                  </.form>
                  <div :if={t.updated_by} class="text-xs text-base-content/50">
                    by {t.updated_by}
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
