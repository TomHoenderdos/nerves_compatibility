defmodule PortalWeb.DashboardLive do
  use PortalWeb, :live_view

  alias Portal.Catalog

  @impl true
  def mount(_params, _session, socket) do
    data = Catalog.dashboard(3, 10)

    {:ok,
     socket
     |> assign(:counts, data.counts)
     |> assign(:clusters, data.clusters)
     |> assign(:native, data.native)
     |> assign(:rates, data.rates)
     |> assign(:recent_pass, data.recent_pass)
     |> assign(:recent_fail, data.recent_fail)
     |> assign(:last_run, data.last_run)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:home} current_user={@current_user}>
      <section class="space-y-10">
        <PortalWeb.UI.page_header kicker="Dashboard" title="Nerves Compatibility">
          <:subtitle>Compatibility results generated automatically across Nerves systems.</:subtitle>
        </PortalWeb.UI.page_header>

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <PortalWeb.UI.stat_card label="Unique Packages" value={to_string(@counts.unique)} />
          <PortalWeb.UI.stat_card label="Passing" value={to_string(@counts.pass)} accent="pass" />
          <a href={~p"/packages"} class="block">
            <PortalWeb.UI.stat_card label="Failing" value={to_string(@counts.fail)} />
          </a>
        </div>

        <div class="grid grid-cols-1 gap-4 lg:grid-cols-3">
          <.tile title="Top failure clusters" href={~p"/failure_clusters"}>
            <p :if={@clusters == []} class="text-sm text-base-content/50">
              No failures recorded yet.
            </p>
            <ul :if={@clusters != []} class="space-y-2">
              <li :for={c <- @clusters} class="flex items-center justify-between text-sm">
                <span class="truncate text-base-content">{c.title}</span>
                <span class="font-mono text-base-content/50">{c.systems} / {c.packages} pkg</span>
              </li>
            </ul>
          </.tile>

          <.tile title="Native code">
            <p :if={@native == []} class="text-sm text-base-content/50">No packages yet.</p>
            <ul :if={@native != []} class="space-y-2">
              <li :for={n <- @native} class="flex items-center justify-between text-sm">
                <span class="text-base-content">{n.language}</span>
                <span class="font-mono text-base-content/50">{n.packages}</span>
              </li>
            </ul>
          </.tile>

          <.tile title="Pass rate per system">
            <p :if={@rates == []} class="text-sm text-base-content/50">No system results yet.</p>
            <ul :if={@rates != []} class="space-y-2">
              <li :for={r <- @rates} class="space-y-1">
                <div class="flex justify-between text-xs">
                  <span class="font-mono text-base-content">{r.system_pkg}</span>
                  <span class="text-base-content/50">
                    {r.pass}/{r.total} · {round(r.rate * 100)}%
                  </span>
                </div>
                <div class="h-1.5 w-full overflow-hidden rounded-full bg-base-200">
                  <div
                    class="h-full rounded-full bg-emerald-400 dark:bg-emerald-500"
                    style={"width: #{round(r.rate * 100)}%"}
                  >
                  </div>
                </div>
              </li>
            </ul>
          </.tile>
        </div>

        <div class="grid grid-cols-1 gap-6 sm:grid-cols-2">
          <.recent title="Recently checked passing" rows={@recent_pass} status="pass" />
          <.recent title="Recently checked failing" rows={@recent_fail} status="fail" />
        </div>

        <p class="text-xs text-base-content/40">Last test run: {@last_run || "n/a"}</p>
      </section>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :href, :string, default: nil
  slot :inner_block, required: true

  defp tile(assigns) do
    ~H"""
    <div class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm">
      <div class="mb-3 flex items-center justify-between">
        <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content/60">{@title}</h2>
        <a :if={@href} href={@href} class="text-xs font-medium text-primary hover:underline">
          see all →
        </a>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :title, :string, required: true
  attr :rows, :list, required: true
  attr :status, :string, required: true

  defp recent(assigns) do
    ~H"""
    <div class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm">
      <h2 class="mb-3 text-sm font-semibold uppercase tracking-wider text-base-content/60">
        {@title}
      </h2>
      <p :if={@rows == []} class="text-sm text-base-content/50">Nothing yet.</p>
      <ul :if={@rows != []} class="divide-y divide-base-200">
        <li :for={row <- @rows} class="flex items-center justify-between py-2">
          <a
            href={~p"/packages/#{row.package}"}
            class="font-medium text-base-content hover:text-primary"
          >
            {row.package} <span class="font-mono text-xs text-base-content/50">v{row.version}</span>
          </a>
          <PortalWeb.UI.status_badge status={to_string(row.overall_status)} />
        </li>
      </ul>
    </div>
    """
  end
end
