defmodule PortalWeb.FailureClustersLive do
  use PortalWeb, :live_view

  alias Portal.Catalog

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :clusters, Catalog.failure_clusters(50))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:clusters} current_user={@current_user}>
      <section class="space-y-6">
        <PortalWeb.UI.page_header kicker="Diagnostics" title="Failure clusters">
          <:subtitle>Failing builds grouped by likely root cause.</:subtitle>
        </PortalWeb.UI.page_header>

        <p
          :if={@clusters == []}
          class="rounded-2xl border border-base-300 bg-base-100 p-8 text-center text-base-content/60"
        >
          No failure clusters — everything is passing.
        </p>

        <div
          :for={c <- @clusters}
          class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm"
        >
          <div class="flex flex-col gap-1 sm:flex-row sm:items-center sm:justify-between">
            <h2 class="text-lg font-semibold text-base-content">{c.title}</h2>
            <span class="font-mono text-sm text-base-content/50">
              {c.systems} failures · {c.packages} package(s)
            </span>
          </div>
          <p class="mt-2 text-sm leading-6 text-base-content/70">{c.hint}</p>

          <details class="mt-4">
            <summary class="cursor-pointer text-sm font-medium text-primary">
              Show {length(c.entries)} affected package(s)
            </summary>
            <ul class="mt-3 grid gap-2 sm:grid-cols-2">
              <li :for={e <- c.entries} class="text-sm">
                <a
                  href={~p"/packages/#{e.package}"}
                  class="font-medium text-base-content hover:text-primary"
                >
                  {e.package}<span :if={e.version} class="font-mono text-xs text-base-content/50">@{e.version}</span>
                </a>
                <span class="text-base-content/50">· {e.arch_label}</span>
              </li>
            </ul>
          </details>

          <div :if={c.sample_log} class="mt-4">
            <div class="mb-1 text-xs font-semibold uppercase tracking-wider text-base-content/50">
              Representative log
            </div>
            <pre class="overflow-auto rounded-xl border border-base-300 bg-base-300/30 p-4 font-mono text-xs leading-relaxed text-base-content/80">{c.sample_log}</pre>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
