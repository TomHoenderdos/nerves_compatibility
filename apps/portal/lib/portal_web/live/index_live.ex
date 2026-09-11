defmodule PortalWeb.IndexLive do
  use PortalWeb, :live_view

  alias Portal.Catalog
  alias Portal.ScanRequests

  # The catalog is ~2,500 packages. Streaming all of them rendered a 3.6 MB
  # document, and because the search form is `phx-change`, every keystroke sent
  # a full stream reset of the same 3.6 MB back down the socket. A page at a
  # time keeps both the first paint and each search cheap.
  @page_size 60

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:packages,
       dom_id: fn entry ->
         if entry.placeholder?, do: "placeholder-#{entry.name}", else: "package-#{entry.name}"
       end
     )
     |> search("")}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, search(socket, q)}
  end

  # `entries/1` is re-derived rather than carried in the socket: the whole list
  # is megabytes, and holding it would cost that much per connected browser.
  # The catalog read behind it is memoized, so re-deriving is cheap.
  #
  # Slicing by offset means a package added between two clicks can shift the
  # window by one. The list is name-sorted and the memo has a 60s TTL, so the
  # worst case is one entry arriving a page late; a repeat is idempotent,
  # because the stream keys on the package name.
  def handle_event("load_more", _params, socket) do
    shown = socket.assigns.shown_count

    next =
      socket.assigns.q
      |> entries()
      |> Enum.slice(shown, @page_size)

    {:noreply,
     socket
     |> assign(:shown_count, shown + length(next))
     |> stream(:packages, next)}
  end

  defp search(socket, q) do
    entries = entries(q)
    page = Enum.take(entries, @page_size)

    socket
    |> assign(:q, q)
    |> assign(:package_count, length(entries))
    |> assign(:shown_count, length(page))
    |> stream(:packages, page, reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:packages} current_user={@current_user}>
      <section class="space-y-8">
        <PortalWeb.UI.page_header kicker="Catalog" title="Nerves Compatibility">
          <:subtitle>
            Reproducible, per-system firmware build results for Hex packages — straight from the catalog.
          </:subtitle>
          <:actions>
            <a
              href={~p"/request-scan"}
              class="inline-flex items-center gap-2 rounded-xl bg-primary px-5 py-3 text-sm font-semibold text-primary-content shadow-sm transition hover:brightness-95"
            >
              <.icon name="hero-plus-mini" class="size-4" /> Request scan
            </a>
          </:actions>
        </PortalWeb.UI.page_header>

        <form id="package-search" phx-change="search" class="space-y-2">
          <label for="q" class="sr-only">Search packages</label>
          <div class="relative">
            <.icon
              name="hero-magnifying-glass-mini"
              class="pointer-events-none absolute left-4 top-1/2 size-5 -translate-y-1/2 text-base-content/40"
            />
            <input
              id="q"
              name="q"
              value={@q}
              type="search"
              phx-debounce="200"
              placeholder="Search packages — jason, vintage_net, circuits_gpio…"
              class="w-full rounded-2xl border border-base-300 bg-base-100 py-4 pl-12 pr-4 text-base-content shadow-sm outline-none transition placeholder:text-base-content/40 focus:border-primary focus:ring-4 focus:ring-primary/10"
            />
          </div>
        </form>

        <div class="text-sm text-base-content/60">
          Showing <span class="font-medium text-base-content/80">{@shown_count}</span>
          of <span class="font-medium text-base-content/80">{@package_count}</span>
          packages
        </div>

        <%!--
        Scrolling to the bottom of the grid loads the next page. The button
        below is not redundant: `phx-viewport-bottom` never fires when the whole
        grid already fits on screen with more to come (a tall window, a short
        page), and it needs JS, so the button is what keyboard and no-JS users
        get. Throttled because the binding re-fires while the bottom stays in
        view.
        --%>
        <div
          id="packages"
          phx-update="stream"
          phx-viewport-bottom={@shown_count < @package_count && "load_more"}
          phx-throttle="300"
          class="grid gap-3 sm:grid-cols-2"
        >
          <PortalWeb.UI.package_card
            :for={{id, item} <- @streams.packages}
            id={id}
            name={item.name}
            description={item.description}
            version={item.version}
            href={item.href}
            summary={item.summary}
            summary_status={item.summary_status}
            statuses={item.statuses}
          />
        </div>

        <div :if={@shown_count < @package_count} class="flex justify-center">
          <button
            type="button"
            phx-click="load_more"
            class="inline-flex items-center gap-2 rounded-xl border border-base-300 bg-base-100 px-5 py-3 text-sm font-semibold text-base-content shadow-sm transition hover:border-primary hover:text-primary"
          >
            Load more
            <span class="text-base-content/50">
              ({@package_count - @shown_count} left)
            </span>
          </button>
        </div>
      </section>
    </Layouts.app>
    """
  end

  # -- entries ---------------------------------------------------------------

  defp entries(q) do
    q = q |> to_string() |> String.downcase()
    catalog = catalog_entries(q)
    names = MapSet.new(catalog, & &1.name)

    (catalog ++ placeholder_entries(q, names))
    |> Enum.sort_by(& &1.name)
  end

  defp catalog_entries(q) do
    Catalog.latest_by_pkg_json().packages
    |> Enum.map(fn {name, data} -> Map.put(data, :name, name) end)
    |> Enum.filter(fn package -> q == "" or String.contains?(package.name, q) end)
    |> Enum.map(fn package ->
      statuses = system_statuses(package)
      {summary, summary_status} = summarize(statuses)

      %{
        name: package.name,
        description: package.description,
        version: package.latest_version && "v#{package.latest_version}",
        href: ~p"/packages/#{package.name}",
        summary: summary,
        summary_status: summary_status,
        statuses: statuses,
        placeholder?: false
      }
    end)
  end

  defp placeholder_entries(q, catalog_names) do
    ScanRequests.queue_requests()
    |> Enum.reject(&MapSet.member?(catalog_names, &1.package_name))
    |> Enum.filter(fn req -> q == "" or String.contains?(req.package_name, q) end)
    |> Enum.uniq_by(& &1.package_name)
    |> Enum.map(fn req ->
      %{
        name: req.package_name,
        description: "Awaiting first scan.",
        version: nil,
        href: ~p"/requests/#{req.id}",
        summary: "in queue",
        summary_status: "queued",
        statuses: [],
        placeholder?: true
      }
    end)
  end

  defp system_statuses(package) do
    package |> Map.get(:systems, %{}) |> Map.values() |> Enum.map(&to_string(&1.status))
  end

  defp summarize(statuses) do
    cond do
      statuses == [] -> {"not run", "skipped"}
      "error" in statuses -> {tally(statuses), "error"}
      "fail" in statuses -> {tally(statuses), "fail"}
      Enum.all?(statuses, &(&1 == "pass")) -> {tally(statuses), "pass"}
      true -> {tally(statuses), "skipped"}
    end
  end

  defp tally(statuses) do
    pass = Enum.count(statuses, &(&1 == "pass"))
    "#{pass}/#{length(statuses)} pass"
  end
end
