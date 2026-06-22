defmodule PortalWeb.IndexLive do
  use PortalWeb, :live_view

  alias Portal.Catalog

  @impl true
  def mount(_params, _session, socket) do
    packages = list_packages("")

    {:ok,
     socket
     |> stream_configure(:packages, dom_id: &"package-#{&1.name}")
     |> assign(:q, "")
     |> assign(:package_count, length(packages))
     |> stream(:packages, packages)}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    packages = list_packages(q)

    {:noreply,
     socket
     |> assign(:q, q)
     |> assign(:package_count, length(packages))
     |> stream(:packages, packages, reset: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:packages}>
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
            <.icon name="hero-magnifying-glass-mini" class="pointer-events-none absolute left-4 top-1/2 size-5 -translate-y-1/2 text-base-content/40" />
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
            :for={{id, package} <- @streams.packages}
            id={id}
            name={package.name}
            description={package.description}
            version={package.latest_version && "v#{package.latest_version}"}
            href={~p"/packages/#{package.name}"}
            summary={package.last_run_at && "scanned" || "not run"}
            summary_status={(package.last_run_at && "pass") || "skipped"}
          />
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp list_packages(q) do
    q = q |> to_string() |> String.downcase()

    Catalog.latest_by_pkg_json().packages
    |> Enum.map(fn {name, data} -> Map.put(data, :name, name) end)
    |> Enum.filter(fn package -> q == "" or String.contains?(package.name, q) end)
    |> Enum.sort_by(& &1.name)
  end
end
