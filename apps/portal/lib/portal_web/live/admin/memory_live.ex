defmodule PortalWeb.Admin.MemoryLive do
  @moduledoc """
  Admin Memory tab: per package and kind, how much memory its worker
  containers used over the last 30 days and how often the OOM killer ended
  one (`Portal.Catalog.RunMemoryStats`), with the warm runs as one line.

  Read-only. `?kind=` and `?sort=` select the view, so a link to it is
  shareable; an unknown value falls back to the default.
  """
  use PortalWeb, :live_view

  import PortalWeb.AdminComponents

  alias Portal.Catalog.RunMemoryStats
  alias PortalWeb.MemoryFormat

  @kinds %{"all" => :all, "firmware" => :firmware, "toolchain" => :toolchain}
  @sorts Map.new(RunMemoryStats.sorts(), &{Atom.to_string(&1), &1})

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Admin", page_description: "Administration.")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    kind = Map.get(@kinds, params["kind"], :all)
    sort = Map.get(@sorts, params["sort"], :peak)

    {:noreply,
     assign(socket,
       kind: kind,
       sort: sort,
       rows: RunMemoryStats.per_package(kind: kind, sort: sort),
       warm: RunMemoryStats.warm_summary()
     )}
  end

  defp view_path(kind, sort), do: ~p"/admin/memory?#{[kind: kind, sort: sort]}"

  attr :sort, :atom, required: true
  attr :current, :atom, required: true
  attr :kind, :atom, required: true
  slot :inner_block, required: true

  defp sort_link(assigns) do
    ~H"""
    <.link
      id={"memory-sort-#{@sort}"}
      patch={view_path(@kind, @sort)}
      class={["link link-hover", @sort == @current && "font-semibold text-base-content"]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_layout flash={@flash} current_user={@current_user} section={:memory} title="Memory">
      <:subtitle>Peak memory and OOM kills of the worker containers, last 30 days.</:subtitle>

      <section id="admin-memory" class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <div class="flex flex-wrap gap-2" role="group" aria-label="Kind">
            <.link
              :for={
                {label, kind} <- [{"All", :all}, {"Firmware", :firmware}, {"Toolchain", :toolchain}]
              }
              id={"memory-kind-#{kind}"}
              patch={view_path(kind, @sort)}
              class={["btn btn-xs", if(kind == @kind, do: "btn-primary", else: "btn-ghost")]}
            >
              {label}
            </.link>
          </div>

          <div class="overflow-x-auto">
            <table id="memory" class="table table-sm">
              <thead>
                <tr>
                  <th><.sort_link sort={:name} current={@sort} kind={@kind}>Package</.sort_link></th>
                  <th>Kind</th>
                  <th><.sort_link sort={:runs} current={@sort} kind={@kind}>Runs</.sort_link></th>
                  <th><.sort_link sort={:oom} current={@sort} kind={@kind}>OOM kills</.sort_link></th>
                  <th>Last peak</th>
                  <th>p90 peak</th>
                  <th><.sort_link sort={:peak} current={@sort} kind={@kind}>Max peak</.sort_link></th>
                  <th>Last limit</th>
                  <th>Last run</th>
                </tr>
              </thead>
              <tbody id="memory-rows">
                <tr :if={@rows == []}>
                  <td colspan="9" class="text-sm text-base-content/60">
                    No container runs in the last 30 days.
                  </td>
                </tr>
                <tr :for={row <- @rows} id={"memory-#{row.package}-#{row.kind}"}>
                  <td class="font-medium">
                    <.link navigate={~p"/packages/#{row.package}"} class="link link-hover">
                      {row.package}
                    </.link>
                  </td>
                  <td>{row.kind}</td>
                  <td>{row.runs}</td>
                  <td>
                    <span class={row.oom_kills > 0 && "font-semibold text-error"}>
                      {row.oom_kills}
                    </span>
                  </td>
                  <td class="whitespace-nowrap">{MemoryFormat.size(row.last_peak_used_bytes)}</td>
                  <td class="whitespace-nowrap">{MemoryFormat.size(row.p90_peak_used_bytes)}</td>
                  <td class="whitespace-nowrap">{MemoryFormat.size(row.max_peak_used_bytes)}</td>
                  <td class="whitespace-nowrap">{MemoryFormat.size(row.last_limit_bytes)}</td>
                  <td class="whitespace-nowrap">{format_datetime(row.last_finished_at)}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <p id="memory-warm" class="text-sm text-base-content/70">
            warm runs: {@warm.runs}, max peak {MemoryFormat.size(@warm.max_peak_used_bytes)}
          </p>
          <p class="text-xs text-base-content/60">
            "Peak used" is the guest's used memory, sampled every 5 s from inside the container;
            OOM-killed runs show the limit they died at.
          </p>
        </div>
      </section>
    </.admin_layout>
    """
  end
end
