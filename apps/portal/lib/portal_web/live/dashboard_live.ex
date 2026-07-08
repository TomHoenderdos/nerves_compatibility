defmodule PortalWeb.DashboardLive do
  use PortalWeb, :live_view

  alias Portal.Catalog

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:clusters, Catalog.failure_clusters(8))
     |> assign(:rates, Catalog.pass_rate_per_system())
     |> assign(:native, Catalog.native_breakdown())
     |> assign(:recent_pass, Catalog.recent_runs(:pass, 5))
     |> assign(:recent_fail, Catalog.recent_runs(:fail, 5))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:home} current_user={@current_user}>
      <section class="space-y-10">
        <PortalWeb.UI.page_header kicker="Dashboard" title="Nerves Compatibility">
          <:subtitle>Build results across every Nerves system, summarized.</:subtitle>
          <:actions>
            <a href={~p"/packages"} class="inline-flex items-center gap-2 rounded-xl bg-primary px-5 py-3 text-sm font-semibold text-primary-content shadow-sm transition hover:brightness-95">
              Browse packages
            </a>
          </:actions>
        </PortalWeb.UI.page_header>

        <.section title="Top failure clusters">
          <.empty :if={@clusters == []}>No failures recorded yet.</.empty>
          <ul :if={@clusters != []} class="divide-y divide-base-200">
            <li :for={c <- @clusters} class="flex items-center justify-between py-3">
              <span class="font-medium text-base-content">{c.category}</span>
              <span class="font-mono text-sm text-base-content/60">{c.systems} / {c.packages} pkg</span>
            </li>
          </ul>
        </.section>

        <.section title="Pass rate per system">
          <.empty :if={@rates == []}>No system results yet.</.empty>
          <ul :if={@rates != []} class="space-y-3">
            <li :for={r <- @rates} class="space-y-1">
              <div class="flex items-center justify-between text-sm">
                <span class="font-mono text-base-content">{r.system_pkg}</span>
                <span class="text-base-content/60">{r.pass}/{r.total} · {round(r.rate * 100)}%</span>
              </div>
              <div class="h-2 w-full overflow-hidden rounded-full bg-base-200">
                <div class="h-full rounded-full bg-emerald-400 dark:bg-emerald-500" style={"width: #{round(r.rate * 100)}%"}></div>
              </div>
            </li>
          </ul>
        </.section>

        <.section title="Native code">
          <.empty :if={@native == []}>No packages yet.</.empty>
          <ul :if={@native != []} class="divide-y divide-base-200">
            <li :for={n <- @native} class="flex items-center justify-between py-3">
              <span class="font-medium text-base-content">{n.language}</span>
              <span class="font-mono text-sm text-base-content/60">{n.packages} pkg</span>
            </li>
          </ul>
        </.section>

        <div class="grid gap-6 sm:grid-cols-2">
          <.section title="Recently checked passing">
            <.empty :if={@recent_pass == []}>Nothing yet.</.empty>
            <.recent_list :if={@recent_pass != []} rows={@recent_pass} />
          </.section>
          <.section title="Recently checked failing">
            <.empty :if={@recent_fail == []}>Nothing yet.</.empty>
            <.recent_list :if={@recent_fail != []} rows={@recent_fail} />
          </.section>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <div class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm">
      <h2 class="mb-4 text-sm font-semibold uppercase tracking-wider text-base-content/60">{@title}</h2>
      {render_slot(@inner_block)}
    </div>
    """
  end

  slot :inner_block, required: true

  defp empty(assigns) do
    ~H"""
    <p class="text-sm text-base-content/50">{render_slot(@inner_block)}</p>
    """
  end

  attr :rows, :list, required: true

  defp recent_list(assigns) do
    ~H"""
    <ul class="divide-y divide-base-200">
      <li :for={row <- @rows} class="flex items-center justify-between py-3">
        <a href={~p"/packages/#{row.package}"} class="font-medium text-base-content hover:text-primary">
          {row.package} <span class="font-mono text-xs text-base-content/50">v{row.version}</span>
        </a>
        <PortalWeb.UI.status_badge status={to_string(row.overall_status)} />
      </li>
    </ul>
    """
  end
end
