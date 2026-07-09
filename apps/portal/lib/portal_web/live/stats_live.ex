defmodule PortalWeb.StatsLive do
  use PortalWeb, :live_view

  alias Portal.Catalog
  alias Portal.Catalog.Architecture

  @impl true
  def mount(_params, _session, socket) do
    stats = Catalog.stats_json()

    {:ok,
     socket
     |> assign(:counts, Catalog.package_status_counts())
     |> assign(:by_system, by_system_rows(stats))
     |> assign(:last_run, stats[:last_run_finished_at])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:stats} current_user={@current_user}>
      <section class="space-y-10">
        <PortalWeb.UI.page_header kicker="Statistics" title="Statistics">
          <:subtitle>Aggregate compatibility results across the catalog.</:subtitle>
        </PortalWeb.UI.page_header>

        <div>
          <h2 class="mb-3 text-sm font-semibold uppercase tracking-wider text-base-content/60">
            Overall Statistics
          </h2>
          <div class="grid grid-cols-2 gap-4 sm:grid-cols-4">
            <PortalWeb.UI.stat_card label="Unique Packages" value={to_string(@counts.unique)} />
            <PortalWeb.UI.stat_card label="Passing" value={to_string(@counts.pass)} accent="pass" />
            <PortalWeb.UI.stat_card label="Failing" value={to_string(@counts.fail)} />
            <PortalWeb.UI.stat_card label="Partial" value={to_string(@counts.partial)} />
          </div>
        </div>

        <div>
          <h2 class="mb-3 text-sm font-semibold uppercase tracking-wider text-base-content/60">
            Statistics by System
          </h2>
          <div class="overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-sm">
            <table class="w-full text-left text-sm">
              <thead class="border-b border-base-300 bg-base-200/60 text-xs uppercase tracking-wide text-base-content/60">
                <tr>
                  <th class="px-5 py-3">Architecture</th>
                  <th class="px-5 py-3">Nerves system</th>
                  <th class="px-5 py-3">Total</th>
                  <th class="px-5 py-3">Pass</th>
                  <th class="px-5 py-3">Fail</th>
                  <th class="px-5 py-3">Error</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-base-200">
                <tr :for={row <- @by_system} class="hover:bg-base-200/40">
                  <td class="px-5 py-3 font-medium text-base-content">{row.arch}</td>
                  <td class="px-5 py-3 font-mono text-base-content/70">{row.system}</td>
                  <td class="px-5 py-3">{row.total}</td>
                  <td class="px-5 py-3 text-emerald-600 dark:text-emerald-400">{row.pass}</td>
                  <td class="px-5 py-3 text-orange-600 dark:text-orange-400">{row.fail}</td>
                  <td class="px-5 py-3 text-red-600 dark:text-red-400">{row.error}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <p class="text-xs text-base-content/40">Last test run: {@last_run || "n/a"}</p>
      </section>
    </Layouts.app>
    """
  end

  # stats_json().by_system is keyed "<system_pkg>@<system_version>" -> counts map.
  # Drop synthetic forced@ rows; label by architecture; sort by system name.
  defp by_system_rows(stats) do
    (stats[:by_system] || %{})
    |> Enum.reject(fn {key, _} -> String.starts_with?(to_string(key), "forced") end)
    |> Enum.map(fn {key, counts} ->
      system = key |> to_string() |> String.split("@") |> hd()
      c = normalize_counts(counts)

      %{
        arch: Architecture.label(system),
        system: system,
        total: c.total,
        pass: c.pass,
        fail: c.fail,
        error: c.error
      }
    end)
    |> Enum.sort_by(& &1.system)
  end

  defp normalize_counts(counts) do
    get = fn keys -> Enum.find_value(keys, 0, &Map.get(counts, &1)) end
    pass = get.([:pass, "pass"])
    fail = get.([:fail, "fail"])
    error = get.([:error, "error"])
    # Total reconciles with the visible Pass/Fail/Error columns (skipped has no column).
    %{pass: pass, fail: fail, error: error, total: pass + fail + error}
  end
end
