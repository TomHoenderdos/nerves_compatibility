defmodule PortalWeb.IndexLive do
  use PortalWeb, :live_view

  alias Portal.Catalog
  alias Portal.ScanRequests

  @impl true
  def mount(_params, _session, socket) do
    entries = entries("")

    {:ok,
     socket
     |> stream_configure(:packages,
       dom_id: fn entry ->
         if entry.placeholder?, do: "placeholder-#{entry.name}", else: "package-#{entry.name}"
       end
     )
     |> assign(:q, "")
     |> assign(:package_count, length(entries))
     |> stream(:packages, entries)}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    entries = entries(q)

    {:noreply,
     socket
     |> assign(:q, q)
     |> assign(:package_count, length(entries))
     |> stream(:packages, entries, reset: true)}
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
              placeholder="Search packages — jason, vintage_net, circuits_gpio…"
              class="w-full rounded-2xl border border-base-300 bg-base-100 py-4 pl-12 pr-4 text-base-content shadow-sm outline-none transition placeholder:text-base-content/40 focus:border-primary focus:ring-4 focus:ring-primary/10"
            />
          </div>
        </form>

        <div class="text-sm text-base-content/60">
          Showing <span class="font-medium text-base-content/80">{@package_count}</span> packages
        </div>

        <div id="packages" phx-update="stream" class="grid gap-3 sm:grid-cols-2">
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
