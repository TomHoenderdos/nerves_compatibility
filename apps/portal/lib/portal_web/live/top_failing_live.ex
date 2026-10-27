defmodule PortalWeb.TopFailingLive do
  @moduledoc """
  `/failing`: packages whose latest run fails, ranked by hex.pm downloads, so a
  contributor can pick the fix that helps the most people. Rows come from
  `Portal.Catalog.TopFailing.list/1`; the same list is `GET /api/failing`.

  Sort and target live in the URL (`?sort=recent|all&system=<system_pkg>`) so a
  filtered view can be linked.
  """
  use PortalWeb, :live_view

  alias Portal.Catalog
  alias Portal.Catalog.TopFailing

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Top failing")
     |> assign(
       :page_description,
       "Nerves build failures ranked by hex.pm downloads: the failing packages " <>
         "whose fix would help the most projects."
     )
     |> assign(:systems, systems())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    opts = TopFailing.opts_from_params(params)

    {:noreply,
     socket
     |> assign(:sort, Keyword.fetch!(opts, :sort))
     |> assign(:system, Keyword.get(opts, :system))
     |> assign(:rows, TopFailing.list(opts))}
  end

  @impl true
  def handle_event("filter", params, socket) do
    query =
      params
      |> Map.take(["sort", "system"])
      |> Enum.reject(fn {key, value} ->
        value in [nil, ""] or {key, value} == {"sort", "recent"}
      end)

    {:noreply, push_patch(socket, to: ~p"/failing?#{query}")}
  end

  # Real Nerves systems that have results, for the target filter.
  defp systems do
    (Catalog.stats_json()[:by_system] || %{})
    |> Map.keys()
    |> Enum.map(&(&1 |> to_string() |> String.split("@") |> hd()))
    |> Enum.filter(&Catalog.real_system?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:failing} current_user={@current_user}>
      <section class="space-y-6">
        <PortalWeb.UI.page_header kicker="Diagnostics" title="Top failing">
          <:subtitle>
            Failing packages, most-downloaded first. Fixing one near the top helps the most projects.
          </:subtitle>
        </PortalWeb.UI.page_header>

        <form
          id="top-failing-filters"
          phx-change="filter"
          class="flex flex-wrap items-center gap-4 text-sm"
        >
          <label class="flex items-center gap-2">
            <span class="text-base-content/60">Rank by</span>
            <select name="sort" class="select select-bordered select-sm">
              <option value="recent" selected={@sort == :recent}>Recent downloads (90 days)</option>
              <option value="all" selected={@sort == :all}>All-time downloads</option>
            </select>
          </label>
          <label class="flex items-center gap-2">
            <span class="text-base-content/60">Target</span>
            <select name="system" class="select select-bordered select-sm">
              <option value="" selected={is_nil(@system)}>All targets</option>
              <option :for={system <- @systems} value={system} selected={system == @system}>
                {system}
              </option>
            </select>
          </label>
          <a href="/api/failing" class="link link-primary text-xs">JSON</a>
        </form>

        <p :if={@system && @rows != []} id="system-filter-note" class="text-sm text-base-content/60">
          Showing packages failing on {@system}. Counts and top failure cover every failing target of each package's latest run.
        </p>

        <p
          :if={@rows == []}
          class="rounded-2xl border border-base-300 bg-base-100 p-8 text-center text-base-content/60"
        >
          No failing packages{if @system, do: " on #{@system}"}.
        </p>

        <div
          :if={@rows != []}
          class="overflow-x-auto rounded-2xl border border-base-300 bg-base-100 shadow-sm"
        >
          <table class="w-full text-left text-sm">
            <thead class="border-b border-base-300 bg-base-200/60 text-xs uppercase tracking-wide text-base-content/60">
              <tr>
                <th class="px-5 py-3">#</th>
                <th class="px-5 py-3">Package</th>
                <th class="px-5 py-3">Recent downloads</th>
                <th class="px-5 py-3">All downloads</th>
                <th class="px-5 py-3">
                  {if @system, do: "Failing targets (all)", else: "Failing targets"}
                </th>
                <th class="px-5 py-3">
                  {if @system, do: "Top failure (all targets)", else: "Top failure"}
                </th>
                <th class="px-5 py-3">Version tested</th>
                <th class="px-5 py-3">Last run</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-base-200">
              <tr :for={{row, rank} <- Enum.with_index(@rows, 1)} class="hover:bg-base-200/40">
                <td class="px-5 py-3 font-mono text-base-content/50">{rank}</td>
                <td class="px-5 py-3">
                  <a
                    href={~p"/packages/#{row.name}"}
                    class="font-medium text-base-content hover:text-primary"
                  >
                    {row.name}
                  </a>
                </td>
                <td class="px-5 py-3 font-mono">{count(row.downloads_recent)}</td>
                <td class="px-5 py-3 font-mono text-base-content/70">{count(row.downloads_all)}</td>
                <td class={[
                  "px-5 py-3 font-mono",
                  if(row.status == :error,
                    do: "text-red-600 dark:text-red-400",
                    else: "text-orange-600 dark:text-orange-400"
                  )
                ]}>
                  {row.failing_count}/{row.total_targets}
                </td>
                <td class="px-5 py-3 text-base-content/70">{top_category(row.failing_targets)}</td>
                <td class="px-5 py-3 font-mono text-base-content/70">{row.version_tested || "-"}</td>
                <td class="px-5 py-3 text-base-content/50">{date(row.last_run_at)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp count(nil), do: "-"

  defp count(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  # The category most of the failing targets share; ties go to the one that
  # sorts first, so the column is stable between renders.
  defp top_category(targets) do
    targets
    |> Enum.map(& &1.failure_category)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {category, n} -> {-n, category} end)
    |> case do
      [{category, _n} | _] -> category
      [] -> "-"
    end
  end

  defp date(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d")
  defp date(_datetime), do: "-"
end
