defmodule PortalWeb.Admin.ArgusFindingsLive do
  @moduledoc """
  Internal triage of argus findings across packages. Admin (passkey) only;
  see `Portal.Catalog.FindingTriage`. Nothing here is public or sent anywhere.

  Two views, both in the URL: by check (the default), one row per analysis,
  title and severity with a group action, and by finding (`?view=findings`),
  one row per finding with bulk selection. Both take `?sort=` and keyboard
  shortcuts (see the `.TriageKeys` hook), which push the same events as the
  forms do.
  """
  use PortalWeb, :live_view

  alias Portal.Catalog
  alias Portal.Catalog.FindingTriage

  @statuses [
    {:new, "new"},
    {:confirmed, "confirmed"},
    {:false_positive, "false positive"},
    {:reported, "reported"},
    {:ignored, "ignored"}
  ]
  @severities ~w(error warning info)

  # Explicit string-to-atom whitelists: `?sort=` and `?view=` come from the URL.
  @list_sorts [
    {"severity", :severity, "Severity"},
    {"package", :package, "Package"},
    {"analysis", :analysis, "Analysis"},
    {"confidence", :confidence, "Confidence"},
    {"newest", :newest, "Recently changed"}
  ]
  @check_sorts [{"count", :count, "Most findings"} | @list_sorts]
  @views %{"checks" => :checks, "findings" => :findings}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "argus findings",
       page_description: "Internal triage of argus findings.",
       statuses: @statuses,
       status_options: Enum.map(@statuses, fn {atom, label} -> {label, atom} end),
       severities: @severities,
       selected: MapSet.new(),
       expanded: MapSet.new(),
       shown_ids: [],
       shown: 0,
       total: 0
     )
     |> stream_configure(:checks, dom_id: &"check-#{&1.id}")
     |> stream_configure(:findings, dom_id: &"finding-#{&1.triage.id}")
     |> stream(:checks, [])
     |> stream(:findings, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    view = Map.get(@views, params["view"], :checks)
    filters = filters(params)

    {:noreply,
     socket
     |> assign(view: view, sort: sort(view, params["sort"]), filters: filters)
     |> assign(:filter_form, to_form(filter_params(filters), as: :f))
     |> assign(:counts, Catalog.triage_counts())
     |> load()}
  end

  @impl true
  def handle_event("filter", %{"f" => f}, socket) do
    filters =
      filters(%{
        "status" => f["status"],
        "severity" => f["severity"],
        "analysis" => f["analysis"],
        "package" => f["package"],
        "stale" => f["stale"]
      })

    %{view: view, sort: sort} = socket.assigns
    {:noreply, push_patch(socket, to: triage_path(filters, view, sort))}
  end

  def handle_event("sort", %{"sort" => sort}, socket) do
    %{filters: filters, view: view} = socket.assigns
    {:noreply, push_patch(socket, to: triage_path(filters, view, sort(view, sort)))}
  end

  def handle_event("toggle_check", params, socket) do
    check = check_ident(params)
    key = check_key(check)

    expanded =
      if MapSet.member?(socket.assigns.expanded, key),
        do: MapSet.delete(socket.assigns.expanded, key),
        else: MapSet.put(socket.assigns.expanded, key)

    {:noreply, socket |> assign(:expanded, expanded) |> refresh_check(check)}
  end

  def handle_event("triage_check", %{"check" => params}, socket) do
    case status_atom(params["status"]) do
      nil ->
        {:noreply, put_flash(socket, :error, "Choose a status.")}

      status ->
        changed =
          Catalog.triage_check!(
            socket.assigns.filters,
            check_ident(params),
            if(params["scope"] == "new", do: :new, else: :all),
            %{status: status, note: blank_to_nil(params["note"])},
            socket.assigns.current_user
          )

        {:noreply, socket |> reload() |> put_flash(:info, "Set #{findings(changed)}.")}
    end
  end

  def handle_event("triage", %{"finding_id" => id, "triage" => triage}, socket) do
    row =
      Catalog.triage!(
        id,
        %{status: triage["status"], note: blank_to_nil(triage["note"])},
        socket.assigns.current_user
      )

    {:noreply, socket |> row_changed(row) |> put_flash(:info, "Saved.")}
  end

  # From the keyboard: a status only, so the note is kept.
  def handle_event("set_status", %{"id" => id, "status" => status}, socket) do
    with status when not is_nil(status) <- status_atom(status),
         %{triage: row} <- Catalog.triage_row(id) do
      row = Catalog.triage!(row.id, %{status: status}, socket.assigns.current_user)
      {:noreply, row_changed(socket, row)}
    else
      _ -> {:noreply, socket}
    end
  end

  # Only rows on the page can be selected, so a stale or forged id never
  # reaches the bulk action.
  def handle_event("toggle_select", %{"id" => id}, socket) do
    if socket.assigns.view == :findings and id in socket.assigns.shown_ids do
      selected = socket.assigns.selected

      selected =
        if MapSet.member?(selected, id),
          do: MapSet.delete(selected, id),
          else: MapSet.put(selected, id)

      {:noreply, socket |> assign(:selected, selected) |> insert_row(Catalog.triage_row(id))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_all", _params, socket) do
    %{selected: selected, shown_ids: shown} = socket.assigns
    all? = shown != [] and MapSet.size(selected) == length(shown)
    selected = if all?, do: MapSet.new(), else: MapSet.new(shown)
    {:noreply, socket |> assign(:selected, selected) |> load()}
  end

  def handle_event("bulk", %{"bulk" => params}, socket) do
    case status_atom(params["status"]) do
      nil ->
        {:noreply, put_flash(socket, :error, "Choose a status.")}

      status ->
        changed =
          Catalog.triage_many!(
            MapSet.to_list(socket.assigns.selected),
            %{status: status, note: blank_to_nil(params["note"])},
            socket.assigns.current_user
          )

        {:noreply,
         socket
         |> assign(:selected, MapSet.new())
         |> reload()
         |> put_flash(:info, "Set #{findings(changed)}.")}
    end
  end

  @doc "A short stable id for a check (analysis, title and severity), used in DOM ids."
  def check_key(%{analysis: analysis, title: title, severity: severity}) do
    :sha256
    |> :crypto.hash([analysis, 0, title, 0, severity])
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp reload(socket), do: socket |> assign(:counts, Catalog.triage_counts()) |> load()

  defp load(%{assigns: %{view: :findings} = assigns} = socket) do
    {rows, total} =
      Catalog.triage_page(Map.put(assigns.filters, :sort, assigns.sort), page_limit())

    shown_ids = Enum.map(rows, & &1.triage.id)

    socket
    |> assign(shown_ids: shown_ids, shown: length(rows), total: total)
    |> assign(:selected, MapSet.intersection(assigns.selected, MapSet.new(shown_ids)))
    |> stream(:findings, rows, reset: true)
  end

  defp load(%{assigns: assigns} = socket) do
    checks =
      assigns.filters
      |> Map.put(:sort, assigns.sort)
      |> Catalog.triage_checks()
      |> Enum.map(&check_item(&1, assigns))

    socket
    |> assign(shown_ids: [], selected: MapSet.new())
    |> stream(:checks, checks, reset: true)
  end

  defp check_item(check, assigns) do
    key = check_key(check)

    rows =
      if MapSet.member?(assigns.expanded, key) do
        assigns.filters
        |> Map.merge(%{check: check_ident(check), sort: :package})
        |> Catalog.triage_page(page_limit())
      end

    %{id: key, check: check, rows: rows}
  end

  defp refresh_check(socket, check) do
    filters = Map.put(socket.assigns.filters, :check, check)

    case Catalog.triage_checks(filters) do
      [row] -> stream_insert(socket, :checks, check_item(row, socket.assigns))
      [] -> stream_delete_by_dom_id(socket, :checks, "check-#{check_key(check)}")
    end
  end

  defp row_changed(socket, row) do
    socket = assign(socket, :counts, Catalog.triage_counts())

    case socket.assigns.view do
      :findings -> insert_row(socket, %{triage: row, stale?: Catalog.triage_stale?(row)})
      :checks -> refresh_check(socket, check_ident(row))
    end
  end

  defp insert_row(socket, nil), do: socket
  defp insert_row(socket, row), do: stream_insert(socket, :findings, row)

  defp check_ident(%{analysis: analysis, title: title, severity: severity}),
    do: %{analysis: analysis, title: title, severity: severity}

  defp check_ident(params) do
    %{
      analysis: to_string(params["analysis"]),
      title: to_string(params["title"]),
      severity: to_string(params["severity"])
    }
  end

  defp triage_path(filters, view, sort),
    do: ~p"/admin/argus/findings?#{query(filters, view, sort)}"

  # The URL for the current state: a value equal to its default stays out, so
  # a shared link only says what was actually narrowed.
  defp query(filters, view, sort) do
    %{
      "status" => filters |> Map.get(:status, []) |> Enum.map(&Atom.to_string/1),
      "severity" => Map.get(filters, :severity, []),
      "analysis" => filters.analysis,
      "package" => filters.package,
      "stale" => if(filters.include_stale, do: "true"),
      "view" => if(view == :findings, do: "findings"),
      "sort" => if(sort != default_sort(view), do: Atom.to_string(sort))
    }
    |> Enum.reject(fn {key, value} -> value in [nil, "", []] or default?(key, value) end)
    |> Map.new()
  end

  defp default?("status", value), do: Enum.sort(value) == ["confirmed", "new"]
  defp default?("severity", value), do: Enum.sort(value) == Enum.sort(@severities)
  defp default?(_key, _value), do: false

  defp sorts(:checks), do: @check_sorts
  defp sorts(:findings), do: @list_sorts

  defp default_sort(view), do: view |> sorts() |> hd() |> elem(1)

  defp sort(view, value) do
    Enum.find_value(sorts(view), default_sort(view), fn {string, atom, _label} ->
      string == value && atom
    end)
  end

  # A sort carries over to the other view when that view has it.
  defp switch_path(filters, sort, view) do
    sort = if Enum.any?(sorts(view), &(elem(&1, 1) == sort)), do: sort, else: default_sort(view)
    triage_path(filters, view, sort)
  end

  # The badges count every current finding, so their links drop the other
  # narrowing -- the list then matches the number clicked. View and sort stay.
  defp status_path(view, sort, status),
    do: triage_path(Map.put(filters(%{}), :status, [status]), view, sort)

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

  defp findings(n), do: "#{n} #{noun(n)}"

  defp noun(1), do: "finding"
  defp noun(_n), do: "findings"

  # "Only new" can only touch something when the status filter lets new
  # findings through and this check has some.
  defp new_scope?(filters, check),
    do: :new in Map.get(filters, :status, [:new, :confirmed]) and check.by_status.new > 0

  defp packages(1), do: "1 package"
  defp packages(n), do: "#{n} packages"

  # A check can fire in many packages; the row names the first few and counts
  # the rest, and expanding the check lists them all.
  @shown_package_names 6
  defp package_list(names) when length(names) > @shown_package_names do
    {shown, rest} = Enum.split(names, @shown_package_names)
    Enum.join(shown, ", ") <> " +#{length(rest)} more"
  end

  defp package_list(names), do: Enum.join(names, ", ")

  defp breakdown(by_status) do
    @statuses
    |> Enum.filter(fn {status, _label} -> Map.get(by_status, status, 0) > 0 end)
    |> Enum.map_join(" · ", fn {status, label} -> "#{by_status[status]} #{label}" end)
  end

  # One quiet summary per check: what is new (or, with nothing new, where its
  # findings stand), plus the totals only where they add something.
  defp check_summary(%{by_status: by_status, count: count, packages: packages}) do
    new = Map.get(by_status, :new, 0)

    lead =
      cond do
        new > 0 and count != new -> ["#{new} new", findings(count)]
        new > 0 -> ["#{new} new"]
        true -> [breakdown(by_status)]
      end

    Enum.join(lead ++ if(packages > 1, do: [packages(packages)], else: []), " · ")
  end

  # The filters on one line, so they can stay folded away.
  defp filter_summary(filters) do
    statuses = Map.get(filters, :status, [:new, :confirmed])
    severities = Map.get(filters, :severity, @severities)

    [
      if(length(statuses) == length(@statuses),
        do: "all statuses",
        else: Enum.map_join(statuses, ", ", &status_label/1)
      ),
      if(Enum.sort(severities) == Enum.sort(@severities),
        do: "all severities",
        else: Enum.join(severities, ", ")
      ),
      filters.analysis && "analysis: #{filters.analysis}",
      filters.package && "package: #{filters.package}",
      filters.include_stale && "including no longer seen"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
    |> then(&("Showing " <> &1))
  end

  defp status_label(status), do: @statuses |> List.keyfind(status, 0) |> elem(1)

  # Inside a check the title is the check's, so a row leads with argus's
  # detail for that finding.
  defp line_text(t), do: text(t.finding["detail"]) || t.title

  defp by_package(rows), do: Enum.chunk_by(rows, & &1.triage.package_name)

  defp text(value) when is_binary(value), do: value
  defp text(value) when is_number(value), do: to_string(value)
  defp text(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp text(_), do: nil

  defp texts(value), do: value |> List.wrap() |> Enum.map(&text/1) |> Enum.filter(& &1)

  defp hints(finding), do: finding |> Map.get("help") |> List.wrap() |> Enum.filter(&is_binary/1)

  # Stored findings outlive the argus version that wrote them, so `related` is
  # narrowed to the strings and integers the template prints.
  defp related(finding) do
    for %{} = r <- List.wrap(finding["related"]) do
      %{label: text(r["label"]), file: text(r["file"]), line: text(r["line"])}
    end
  end

  defp location(%{file: file, line: line}) when is_binary(file) and is_integer(line),
    do: "#{file}:#{line}"

  defp location(%{file: file, line: line}) when is_binary(file) and is_binary(line),
    do: "#{file}:#{line}"

  defp location(%{file: file}), do: file

  defp severity_class("error"), do: "badge-error"
  defp severity_class("warning"), do: "badge-warning"
  defp severity_class(_), do: "badge-ghost"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-5">
        <PortalWeb.UI.page_header kicker="Admin" title="argus findings">
          <:subtitle>Internal triage. Nothing here is public or sent to anyone.</:subtitle>
        </PortalWeb.UI.page_header>

        <PortalWeb.PageHTML.admin_tabs section={:triage} />

        <p id="triage-counts" class="text-sm text-base-content/60">
          <%= for {{status, label}, i} <- Enum.with_index(@statuses) do %>
            <span :if={i > 0} aria-hidden="true"> · </span>
            <.link
              id={"triage-count-#{status}"}
              patch={status_path(@view, @sort, status)}
              class="transition hover:text-primary"
            >
              {Map.get(@counts, status, 0)} {label}
            </.link>
          <% end %>
        </p>

        <div class="flex flex-wrap items-center justify-between gap-3">
          <div id="triage-view" class="join">
            <.link
              id="view-checks"
              patch={switch_path(@filters, @sort, :checks)}
              class={["btn btn-xs join-item", @view == :checks && "btn-active"]}
            >
              By check
            </.link>
            <.link
              id="view-findings"
              patch={switch_path(@filters, @sort, :findings)}
              class={["btn btn-xs join-item", @view == :findings && "btn-active"]}
            >
              By finding
            </.link>
          </div>
          <div class="flex items-center gap-2">
            <form id="triage-sort" phx-change="sort" class="flex items-center gap-2 text-sm">
              <label for="triage-sort-select" class="text-base-content/60">Sort</label>
              <select id="triage-sort-select" name="sort" class="select select-xs w-40">
                <option
                  :for={{value, atom, label} <- sorts(@view)}
                  value={value}
                  selected={atom == @sort}
                >
                  {label}
                </option>
              </select>
            </form>
            <button
              type="button"
              id="triage-shortcuts-toggle"
              phx-click={JS.toggle(to: "#triage-shortcuts")}
              class="btn btn-xs btn-ghost"
            >
              Shortcuts <kbd class="kbd kbd-xs">?</kbd>
            </button>
          </div>
        </div>

        <div class="text-sm">
          <div class="flex flex-wrap items-center gap-2">
            <button
              type="button"
              id="triage-filters-toggle"
              phx-click={JS.toggle(to: "#triage-filters-panel")}
              class="btn btn-xs btn-ghost"
            >
              <.icon name="hero-funnel-mini" class="size-3.5" /> Filters
            </button>
            <span id="triage-filter-summary" class="text-base-content/60">
              {filter_summary(@filters)}
            </span>
          </div>

          <%!-- Closed by default and on every load; the summary beside the
          toggle says what is active. JS.toggle keeps it open across patches. --%>
          <div id="triage-filters-panel" class="hidden pt-3">
            <.form
              for={@filter_form}
              id="triage-filters"
              phx-change="filter"
              class="grid items-start gap-4 rounded-xl border border-base-300 p-4 sm:grid-cols-5"
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
              <.input
                field={@filter_form[:analysis]}
                type="text"
                label="Analysis"
                phx-debounce="300"
              />
              <.input
                field={@filter_form[:package]}
                type="text"
                label="Package"
                phx-debounce="300"
                data-triage-search
              />
              <.input field={@filter_form[:stale]} type="checkbox" label="Include no longer seen" />
            </.form>
          </div>
        </div>

        <div
          id="triage-shortcuts"
          class="hidden rounded-xl border border-base-300 bg-base-100 p-4 text-sm"
        >
          <dl class="grid gap-x-6 gap-y-1 sm:grid-cols-3">
            <div>
              <dt class="inline">
                <kbd class="kbd kbd-xs">j</kbd> <kbd class="kbd kbd-xs">k</kbd> / arrows
              </dt>

              <dd class="inline text-base-content/60">next / previous row</dd>
            </div>
            <div>
              <dt class="inline">
                <kbd class="kbd kbd-xs">Enter</kbd> <kbd class="kbd kbd-xs">o</kbd>
              </dt>

              <dd class="inline text-base-content/60">expand or collapse a check</dd>
            </div>
            <div>
              <dt class="inline"><kbd class="kbd kbd-xs">c</kbd></dt>

              <dd class="inline text-base-content/60">confirmed</dd>
            </div>
            <div>
              <dt class="inline"><kbd class="kbd kbd-xs">f</kbd></dt>

              <dd class="inline text-base-content/60">false positive</dd>
            </div>
            <div>
              <dt class="inline"><kbd class="kbd kbd-xs">r</kbd></dt>

              <dd class="inline text-base-content/60">reported</dd>
            </div>
            <div>
              <dt class="inline"><kbd class="kbd kbd-xs">i</kbd></dt>

              <dd class="inline text-base-content/60">ignored</dd>
            </div>
            <div>
              <dt class="inline"><kbd class="kbd kbd-xs">n</kbd></dt>

              <dd class="inline text-base-content/60">new</dd>
            </div>
            <div>
              <dt class="inline"><kbd class="kbd kbd-xs">x</kbd></dt>

              <dd class="inline text-base-content/60">select (by finding)</dd>
            </div>
            <div>
              <dt class="inline"><kbd class="kbd kbd-xs">/</kbd></dt>

              <dd class="inline text-base-content/60">search packages</dd>
            </div>
            <div>
              <dt class="inline"><kbd class="kbd kbd-xs">?</kbd></dt>

              <dd class="inline text-base-content/60">this panel</dd>
            </div>
          </dl>
          <p class="mt-2 text-xs text-base-content/50">
            On a finding, a status key sets that finding. On a check row it sets the check's
            new findings within the filters, after a confirm; it does nothing when there are none.
            Either way focus moves to the next row.
          </p>
        </div>

        <div id="triage-list" phx-hook=".TriageKeys">
          <%= if @view == :findings do %>
            <div class="mb-2 flex flex-wrap items-center gap-3 text-sm text-base-content/60">
              <label class="flex items-center gap-2">
                <input
                  type="checkbox"
                  id="select-all"
                  phx-click="select_all"
                  checked={@shown_ids != [] and MapSet.size(@selected) == length(@shown_ids)}
                  class="checkbox checkbox-xs"
                /> Select all shown
              </label>
              <span :if={@total > @shown} id="triage-shown">
                Showing {@shown} of {@total}. Narrow the filters to see the rest.
              </span>
            </div>

            <%!-- Only once something is selected: until then it is noise. --%>
            <.form
              :if={MapSet.size(@selected) > 0}
              for={to_form(%{}, as: :bulk)}
              id="bulk-form"
              phx-submit="bulk"
              class="mb-3 flex flex-wrap items-center gap-2 rounded-xl border border-primary/30 bg-primary/5 px-3 py-2 text-sm"
            >
              <span class="font-medium">{MapSet.size(@selected)} selected</span>
              <select id="bulk-status" name="bulk[status]" class="select select-xs w-36">
                <option value="">Set status…</option>
                {Phoenix.HTML.Form.options_for_select(@status_options, nil)}
              </select>
              <input
                id="bulk-note"
                name="bulk[note]"
                type="text"
                value=""
                placeholder="Note (optional)"
                class="input input-xs w-48"
              />
              <button
                type="submit"
                class="btn btn-xs btn-primary"
                data-confirm={"Set the status of #{findings(MapSet.size(@selected))}?"}
              >
                Apply to selected
              </button>
            </.form>

            <div id="findings" phx-update="stream" class="border-y border-base-200">
              <div
                id="findings-empty"
                class="hidden py-6 text-sm text-base-content/60 only:block"
              >
                No findings match these filters.
              </div>
              <.finding_row
                :for={{dom_id, %{triage: t, stale?: stale?}} <- @streams.findings}
                id={dom_id}
                t={t}
                stale?={stale?}
                selected={MapSet.member?(@selected, t.id)}
                selectable
                status_options={@status_options}
              />
            </div>
          <% else %>
            <div id="checks" phx-update="stream" class="border-t border-base-200">
              <div
                id="checks-empty"
                class="hidden py-6 text-sm text-base-content/60 only:block"
              >
                No findings match these filters.
              </div>
              <div
                :for={{dom_id, %{id: key, check: c, rows: rows}} <- @streams.checks}
                id={dom_id}
                data-check
                class="border-b border-base-200 even:bg-base-content/[0.05]"
              >
                <%!-- The check's keyboard item: `.TriageKeys` reads its identity
                and how many new findings a status key would set (0 when new is
                filtered out, so the key does nothing). --%>
                <div
                  id={"#{dom_id}-item"}
                  data-triage-row
                  data-check-key={key}
                  data-analysis={c.analysis}
                  data-title={c.title}
                  data-severity={c.severity}
                  data-new={if new_scope?(@filters, c), do: c.by_status.new, else: 0}
                  tabindex="-1"
                  class={[
                    "outline-none transition-colors hover:bg-base-200/40",
                    "focus:bg-primary/10 focus:ring-2 focus:ring-inset focus:ring-primary"
                  ]}
                >
                  <button
                    type="button"
                    id={"#{dom_id}-toggle"}
                    phx-click="toggle_check"
                    phx-value-analysis={c.analysis}
                    phx-value-title={c.title}
                    phx-value-severity={c.severity}
                    aria-expanded={to_string(rows != nil)}
                    class="flex w-full cursor-pointer items-center gap-2 px-2 py-2 text-left text-sm"
                  >
                    <.icon
                      name={if rows, do: "hero-chevron-down-mini", else: "hero-chevron-right-mini"}
                      class="size-4 shrink-0 text-base-content/40"
                    />
                    <span class={["badge badge-xs shrink-0", severity_class(c.severity)]}>
                      {c.severity}
                    </span>
                    <span class="badge badge-xs badge-outline shrink-0 font-mono">
                      {c.analysis}
                    </span>
                    <span class="min-w-0 flex-1 truncate text-base-content" title={c.title}>
                      {c.title}
                    </span>
                    <span class="hidden shrink-0 text-xs text-base-content/60 sm:inline">
                      <span data-check-summary>{check_summary(c)}</span>
                      <span aria-hidden="true"> · </span>
                      <span data-check-packages class="font-mono">
                        {package_list(c.package_names)}
                      </span>
                    </span>
                  </button>
                </div>

                <div
                  :if={rows}
                  id={"#{dom_id}-findings"}
                  class="mb-2 ml-8 border-l border-base-200 pl-3"
                >
                  <%!-- The group action lives with the findings it touches, so
                  a collapsed check is one quiet line. --%>
                  <.form
                    for={to_form(%{}, as: :check)}
                    id={"check-form-#{key}"}
                    phx-submit="triage_check"
                    class="flex flex-wrap items-center gap-2 py-2 text-xs"
                  >
                    <input type="hidden" name="check[analysis]" value={c.analysis} />
                    <input type="hidden" name="check[title]" value={c.title} />
                    <input type="hidden" name="check[severity]" value={c.severity} />
                    <span class="text-base-content/60">Set the check:</span>
                    <select
                      id={"check-status-#{key}"}
                      name="check[status]"
                      class="select select-xs w-36"
                    >
                      <option value="">Set status…</option>
                      {Phoenix.HTML.Form.options_for_select(@status_options, nil)}
                    </select>
                    <input
                      id={"check-note-#{key}"}
                      name="check[note]"
                      type="text"
                      value=""
                      placeholder="Note (optional)"
                      class="input input-xs w-40"
                    />
                    <%!-- One button per scope, so each confirm can name the
                    exact number it touches. "only new" is first, so Enter in
                    the note takes the narrower one; it is absent when the
                    filters or the check leave no new finding for it to set. --%>
                    <button
                      :if={new_scope?(@filters, c)}
                      type="submit"
                      id={"check-apply-new-#{key}"}
                      name="check[scope]"
                      value="new"
                      class="btn btn-xs btn-outline"
                      data-confirm={"Set the status of #{c.by_status.new} new #{noun(c.by_status.new)} of this check?"}
                    >
                      Apply to {c.by_status.new} new
                    </button>
                    <button
                      type="submit"
                      id={"check-apply-all-#{key}"}
                      name="check[scope]"
                      value="all"
                      class="btn btn-xs btn-ghost"
                      data-confirm={"Set the status of all #{findings(c.count)} of this check?"}
                    >
                      Apply to all {c.count}
                    </button>
                    <span :if={c.confidence} class="text-base-content/50">
                      confidence up to {text(c.confidence)}
                    </span>
                  </.form>
                  <p
                    :if={elem(rows, 1) > length(elem(rows, 0))}
                    class="pb-1 text-xs text-base-content/60"
                  >
                    Showing {length(elem(rows, 0))} of {elem(rows, 1)}.
                  </p>
                  <div
                    :for={[%{triage: first} | _] = group <- by_package(elem(rows, 0))}
                    id={"#{dom_id}-package-#{first.package_name}"}
                  >
                    <div class="pt-1 font-mono text-xs text-base-content/60">
                      <.link navigate={~p"/packages/#{first.package_name}"} class="link">
                        {first.package_name}
                      </.link>
                      <span>· {findings(length(group))}</span>
                    </div>
                    <.finding_row
                      :for={%{triage: t, stale?: stale?} <- group}
                      id={"finding-#{t.id}"}
                      t={t}
                      stale?={stale?}
                      in_check
                      status_options={@status_options}
                    />
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        </div>

        <p id="triage-export" class="text-xs text-base-content/50">
          Export NDJSON (one run per line):
          <a href={~p"/admin/argus/export.ndjson"} class="link">latest run per package</a>
          · <a href={~p"/admin/argus/export.ndjson?scope=all"} class="link">every run</a>
        </p>
      </section>
    </Layouts.app>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".TriageKeys">
      // Keyboard triage over every [data-triage-row] in the list. Each key
      // pushes the same server events the forms and checkboxes do, so this
      // holds no state beyond which row has focus -- real DOM focus, which
      // survives LiveView patches where a class set from here would not.
      const STATUS_KEYS = {c: "confirmed", f: "false_positive", r: "reported", i: "ignored", n: "new"}
      const STATUS_LABELS = {
        confirmed: "confirmed",
        false_positive: "false positive",
        reported: "reported",
        ignored: "ignored",
        new: "new"
      }

      export default {
        mounted() {
          this.focused = null
          this.index = null
          this.onKey = e => this.handleKey(e)
          this.onFocus = e => this.remember(e.target.closest && e.target.closest("[data-triage-row]"))
          // A pointer press anywhere hands focus to the user: from then on a
          // drop to <body> is theirs, not ours to take back. Pressing on a row
          // focuses it (tabindex -1), which `focusin` remembers again.
          this.onPointer = () => (this.focused = null)
          window.addEventListener("keydown", this.onKey)
          document.addEventListener("pointerdown", this.onPointer, true)
          this.el.addEventListener("focusin", this.onFocus)
          // A patch can take the focused row's focus with it to <body>: the
          // row is removed (it left the filter), replaced, or moved by the
          // DOM patch -- Chrome blurs a focused node that is moved even though
          // it stays in the page. Not every such patch reaches `updated()`, so
          // watch the subtree too.
          this.observer = new MutationObserver(() => this.restore())
          this.observer.observe(this.el, {childList: true, subtree: true})
        },
        updated() {
          this.restore()
        },
        destroyed() {
          window.removeEventListener("keydown", this.onKey)
          document.removeEventListener("pointerdown", this.onPointer, true)
          this.observer.disconnect()
        },
        rows() {
          return Array.from(this.el.querySelectorAll("[data-triage-row]"))
        },
        current() {
          const active = document.activeElement
          return active && active.closest ? active.closest("[data-triage-row]") : null
        },
        remember(row) {
          if (!row) return
          this.focused = row
          this.index = this.rows().indexOf(row)
        },
        focusAt(at) {
          const rows = this.rows()
          if (rows.length === 0) return
          const row = rows[Math.min(Math.max(at, 0), rows.length - 1)]
          row.focus()
          row.scrollIntoView({block: "nearest"})
          this.remember(row)
        },
        // Puts focus back on the row the keyboard last chose, after a patch
        // dropped it to <body>: the same node if it is still in the page, else
        // its re-rendered node by id, else whatever row now sits at its index.
        restore() {
          const active = document.activeElement
          if ((active && active !== document.body) || !this.focused) return
          const same = this.focused.isConnected ? this.focused : document.getElementById(this.focused.id)

          if (same && this.el.contains(same)) {
            same.focus({preventScroll: true})
            this.remember(same)
          } else if (this.index !== null) {
            this.focusAt(this.index)
          }
        },
        move(by) {
          const at = this.rows().indexOf(this.current())
          this.focusAt(at < 0 ? (by > 0 ? 0 : this.rows().length - 1) : at + by)
        },
        // After a status: the next row, or the previous one from the last.
        advance(row) {
          const rows = this.rows()
          const at = rows.indexOf(row)
          this.focusAt(at + 1 < rows.length ? at + 1 : at - 1)
        },
        checkIdent(row) {
          const {analysis, title, severity} = row.dataset
          return {analysis, title, severity}
        },
        // A status key on a check row sets the check's new findings within the
        // filters, through the same group action as its "Apply to N new"
        // button. `data-new` is 0 when there are none or new is filtered out.
        setCheckStatus(row, status) {
          const count = parseInt(row.dataset.new, 10) || 0
          if (count === 0) return
          const noun = count === 1 ? "finding" : "findings"
          const question = `Set the status of ${count} new ${noun} of this check to ${STATUS_LABELS[status]}?`
          if (!window.confirm(question)) return
          this.pushEvent("triage_check", {check: {...this.checkIdent(row), status, scope: "new", note: ""}})
          this.advance(row)
        },
        // Typing in a field is never a shortcut; a focused checkbox still is,
        // since clicking one to select a row moves focus onto it.
        typing(target) {
          return target.closest && target.closest(
            "textarea, select, [contenteditable], input:not([type=checkbox]):not([type=radio])"
          )
        },
        // Escape leaves a field for the list: the last row, or the first.
        leaveField(target) {
          target.blur()
          if (this.focused && this.focused.isConnected) this.focused.focus()
          else this.focusAt(this.index === null ? 0 : this.index)
        },
        handleKey(e) {
          if (e.metaKey || e.ctrlKey || e.altKey) return
          if (this.typing(e.target)) {
            if (e.key === "Escape") {
              this.leaveField(e.target)
              e.preventDefault()
            }
            return
          }
          const row = this.current()

          // Arrows scroll the page as usual unless a finding has focus.
          if (e.key === "j" || (e.key === "ArrowDown" && row)) {
            this.move(1)
          } else if (e.key === "k" || (e.key === "ArrowUp" && row)) {
            this.move(-1)
          } else if (e.key === "/") {
            const search = document.querySelector("[data-triage-search]")
            if (search) search.focus()
          } else if (e.key === "?") {
            const panel = document.getElementById("triage-shortcuts")
            if (panel) this.js().toggle(panel)
          } else if (row && row.dataset.checkKey && (e.key === "o" || (e.key === "Enter" && e.target === row))) {
            // Enter only on the row itself: on its buttons it still clicks them.
            this.pushEvent("toggle_check", this.checkIdent(row))
          } else if (STATUS_KEYS[e.key] && row && row.dataset.checkKey) {
            this.setCheckStatus(row, STATUS_KEYS[e.key])
          } else if (STATUS_KEYS[e.key] && row) {
            this.pushEvent("set_status", {id: row.dataset.id, status: STATUS_KEYS[e.key]})
            this.advance(row)
          } else if (e.key === "x" && row && row.dataset.id) {
            this.pushEvent("toggle_select", {id: row.dataset.id})
          } else {
            return
          }
          e.preventDefault()
        }
      }
    </script>
    """
  end

  attr :id, :string, required: true
  attr :t, FindingTriage, required: true
  attr :stale?, :boolean, default: false
  attr :selectable, :boolean, default: false
  attr :selected, :boolean, default: false
  attr :in_check, :boolean, default: false, doc: "inside an expanded check, which names the check"
  attr :status_options, :list, required: true

  # One line per finding: what and where, and its status. Everything else --
  # the note, the source link, versions and argus's own details -- is behind
  # "Details". The form wraps both so the note still saves with the status;
  # the selection checkbox stays outside it, as it is not a triage field.
  defp finding_row(assigns) do
    assigns = assign(assigns, :source_url, FindingTriage.source_url(assigns.t))

    ~H"""
    <div
      id={@id}
      data-triage-row
      data-id={@t.id}
      tabindex="-1"
      class={
        [
          "flex items-start gap-2 border-b border-base-200 px-2 py-1.5 text-sm outline-none transition-colors last:border-b-0",
          "hover:bg-base-200/40 focus:bg-primary/10 focus:ring-2 focus:ring-inset focus:ring-primary",
          # Alternating rows: long lists of near-identical findings are easier to
          # follow across to their status select.
          if(@selected, do: "bg-primary/5", else: "even:bg-base-content/[0.05]")
        ]
      }
    >
      <input
        :if={@selectable}
        type="checkbox"
        id={"select-#{@t.id}"}
        phx-click="toggle_select"
        phx-value-id={@t.id}
        checked={@selected}
        aria-label="Select finding"
        class="checkbox checkbox-xs mt-1"
      />
      <.form
        for={to_form(%{"status" => Atom.to_string(@t.status), "note" => @t.note}, as: :triage)}
        id={"triage-form-#{@t.id}"}
        phx-change="triage"
        class="min-w-0 flex-1"
      >
        <input type="hidden" name="finding_id" value={@t.id} />
        <div class="flex items-center gap-2">
          <div class="flex min-w-0 flex-1 items-center gap-2">
            <%= if @in_check do %>
              <span class="shrink-0 font-mono text-xs text-base-content/60">{location(@t)}</span>
              <span class="min-w-0 truncate text-base-content/80" title={line_text(@t)}>
                {line_text(@t)}
              </span>
            <% else %>
              <span class={["badge badge-xs shrink-0", severity_class(@t.severity)]}>
                {@t.severity}
              </span>
              <.link
                navigate={~p"/packages/#{@t.package_name}"}
                class="link shrink-0 font-mono text-xs"
              >
                {@t.package_name}
              </.link>
              <span class="min-w-0 truncate" title={@t.title}>{@t.title}</span>
              <%!-- The location gives way before the title does. --%>
              <span
                class="hidden min-w-0 max-w-[35%] truncate font-mono text-xs text-base-content/50 md:inline"
                title={location(@t)}
              >
                {location(@t)}
              </span>
            <% end %>
            <span :if={@stale?} class="badge badge-xs badge-ghost shrink-0">no longer seen</span>
          </div>
          <span :if={@t.note} class="hidden max-w-40 truncate text-xs text-base-content/50 sm:inline">
            {@t.note}
          </span>
          <select
            id={"triage-status-#{@t.id}"}
            name="triage[status]"
            aria-label="Status"
            class="select select-xs w-32 shrink-0"
          >
            {Phoenix.HTML.Form.options_for_select(@status_options, Atom.to_string(@t.status))}
          </select>
        </div>
        <details class="text-xs text-base-content/70">
          <summary class="cursor-pointer text-base-content/50">Details</summary>
          <div class="space-y-1 py-1">
            <div class="flex flex-wrap items-center gap-2">
              <.input
                id={"triage-note-#{@t.id}"}
                name="triage[note]"
                type="text"
                value={@t.note}
                placeholder="Note"
                phx-debounce="500"
                class="input input-xs w-64"
              />
              <a
                :if={@source_url}
                id={"source-#{@t.id}"}
                href={@source_url}
                target="_blank"
                rel="noopener noreferrer"
                class="link link-primary inline-flex items-center gap-0.5"
              >
                view source <.icon name="hero-arrow-top-right-on-square-mini" class="size-3" />
              </a>
            </div>
            <p :if={!@in_check} class="font-mono">{@t.analysis}</p>
            <p :if={@in_check}>{@t.title}</p>
            <p :if={text(@t.finding["at_label"])}>{text(@t.finding["at_label"])}</p>
            <p :if={text(@t.finding["detail"])}>{text(@t.finding["detail"])}</p>
            <ul :if={hints(@t.finding) != []} class="list-disc pl-5">
              <li :for={hint <- hints(@t.finding)}>{hint}</li>
            </ul>
            <dl class="grid grid-cols-[auto_1fr] gap-x-3">
              <dt class="text-base-content/50">versions</dt>
              <dd class="font-mono">{@t.first_seen_version} → {@t.last_seen_version}</dd>
              <dt :if={text(@t.finding["confidence"])} class="text-base-content/50">confidence</dt>
              <dd :if={text(@t.finding["confidence"])}>{text(@t.finding["confidence"])}</dd>
              <dt :if={texts(@t.finding["provenance"]) != []} class="text-base-content/50">
                provenance
              </dt>
              <dd :if={texts(@t.finding["provenance"]) != []}>
                {Enum.join(texts(@t.finding["provenance"]), ", ")}
              </dd>
              <dt :if={@t.updated_by} class="text-base-content/50">triaged by</dt>
              <dd :if={@t.updated_by}>{@t.updated_by}</dd>
            </dl>
            <ul :if={related(@t.finding) != []} class="font-mono">
              <li :for={rel <- related(@t.finding)}>
                {rel.label}<span :if={rel.label && location(rel)}> — </span>{location(rel)}
              </li>
            </ul>
          </div>
        </details>
      </.form>
    </div>
    """
  end
end
