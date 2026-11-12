defmodule PortalWeb.Admin.NotPrecompiledLive do
  @moduledoc """
  Admin Not precompiled tab: why packages have no precompiled build, from
  the current `skipped` toolchain builds grouped by root cause
  (`Portal.Catalog.NotPrecompiled`, `Portal.Catalog.SkipReasons`).

  Read-only. `?class=`, `?detail=` and `?blocker=` filter the package list,
  so a view is shareable; an unknown class is ignored.
  """
  use PortalWeb, :live_view

  import PortalWeb.AdminComponents

  alias Portal.Catalog.{NotPrecompiled, SkipReasons}

  @classes Map.new(SkipReasons.classes(), &{Atom.to_string(&1), &1})
  @list_limit 200
  @blocker_limit 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Admin", page_description: "Administration.")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    rows = NotPrecompiled.rows()
    class = Map.get(@classes, params["class"])
    detail = blank_to_nil(params["detail"])
    blocker = blank_to_nil(params["blocker"])
    all_blockers = NotPrecompiled.by_blocker(rows)
    matching = NotPrecompiled.filter(rows, class: class, detail: detail, blocker: blocker)

    {:noreply,
     assign(socket,
       class: class,
       detail: detail,
       blocker: blocker,
       classes: NotPrecompiled.by_class(rows),
       blockers: Enum.take(all_blockers, @blocker_limit),
       env_vars: NotPrecompiled.by_detail(rows, :env_read),
       details: if(class, do: NotPrecompiled.by_detail(rows, class), else: []),
       blocker_options: Enum.map(all_blockers, & &1.blocker),
       total: length(matching),
       packages: matching |> Enum.uniq_by(& &1.package) |> length(),
       list: Enum.take(matching, @list_limit),
       filter_form:
         to_form(
           %{
             "class" => class && Atom.to_string(class),
             "detail" => detail,
             "blocker" => blocker
           },
           as: :f
         )
     )}
  end

  @impl true
  def handle_event("filter", %{"f" => f}, socket) do
    class = Map.get(@classes, f["class"])
    # A detail belongs to its class: changing the class drops it.
    detail = if class == socket.assigns.class, do: blank_to_nil(f["detail"])
    {:noreply, push_patch(socket, to: view_path(class, detail, blank_to_nil(f["blocker"])))}
  end

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_value), do: nil

  # "Native code: erlang:load_nif/2 via certifi".
  defp cause(row) do
    detail = if row.detail, do: ": #{row.detail}", else: ""
    via = if row.blocker, do: " via #{row.blocker}", else: ""
    SkipReasons.label(row.class) <> detail <> via
  end

  defp view_path(class, detail, blocker) do
    query =
      [class: class, detail: detail, blocker: blocker]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    ~p"/admin/not-precompiled?#{query}"
  end

  defp number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_layout
      flash={@flash}
      current_user={@current_user}
      section={:not_precompiled}
      title="Not precompiled"
    >
      <:subtitle>
        Why packages have no precompiled build: each package's newest skipped toolchain build, by root cause.
      </:subtitle>

      <section id="np-classes" class="grid grid-cols-2 gap-3 sm:grid-cols-3">
        <p :if={@classes == []} class="text-sm text-base-content/60">No skipped builds.</p>
        <.link
          :for={c <- @classes}
          id={"np-class-#{c.class}"}
          patch={view_path(c.class, nil, nil)}
          class={[
            "card border bg-base-100 shadow-sm transition hover:border-primary",
            if(c.class == @class, do: "border-primary", else: "border-base-300")
          ]}
        >
          <div class="card-body gap-1 p-4">
            <span class="text-xs font-medium text-base-content/60">
              {SkipReasons.label(c.class)}
            </span>
            <span class="text-2xl font-semibold">{number(c.packages)}</span>
            <span class="text-xs text-base-content/60">
              packages, {number(c.downloads)} recent downloads
            </span>
          </div>
        </.link>
      </section>

      <section id="np-blockers" class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-base">Top blocking dependencies</h2>
          <p class="text-xs text-base-content/60">
            Closure dependencies whose own compile observed the host. Fixing one upstream unblocks every package here.
          </p>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Dependency</th>
                  <th>Packages blocked</th>
                  <th>Most downloaded</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@blockers == []}>
                  <td colspan="3" class="text-sm text-base-content/60">None.</td>
                </tr>
                <tr :for={b <- @blockers} id={"np-blocker-#{b.blocker}"}>
                  <td class="font-medium">
                    <.link patch={view_path(nil, nil, b.blocker)} class="link link-hover">
                      {b.blocker}
                    </.link>
                  </td>
                  <td>{number(b.packages)}</td>
                  <td class="text-sm">{Enum.join(b.sample, ", ")}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <section id="np-env" class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-base">Env vars read at compile time</h2>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Variable</th>
                  <th>Packages</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@env_vars == []}>
                  <td colspan="2" class="text-sm text-base-content/60">None.</td>
                </tr>
                <tr :for={e <- @env_vars} id={"np-env-#{e.detail || "unnamed"}"}>
                  <td class="font-mono text-sm">
                    <.link
                      :if={e.detail}
                      patch={view_path(:env_read, e.detail, nil)}
                      class="link link-hover"
                    >
                      {e.detail}
                    </.link>
                    <span :if={!e.detail} class="text-base-content/60">(unnamed)</span>
                  </td>
                  <td>{number(e.packages)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <section id="np-packages" class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-base">Packages</h2>

          <.form
            for={@filter_form}
            id="np-filter"
            phx-change="filter"
            class="grid gap-2 sm:grid-cols-3"
          >
            <.input
              field={@filter_form[:class]}
              type="select"
              label="Cause"
              prompt="Any"
              options={Enum.map(@classes, &{SkipReasons.label(&1.class), &1.class})}
            />
            <.input
              field={@filter_form[:detail]}
              type="select"
              label="Detail"
              prompt="Any"
              disabled={is_nil(@class)}
              options={for d <- @details, d.detail, do: {"#{d.detail} (#{d.packages})", d.detail}}
            />
            <.input
              field={@filter_form[:blocker]}
              type="select"
              label="Blocking dependency"
              prompt="Any"
              options={@blocker_options}
            />
          </.form>

          <p id="np-count" class="text-sm text-base-content/70">
            {number(@packages)} packages, {number(@total)} skip reasons<span :if={
              @total > length(@list)
            }>, the {length(@list)} most downloaded shown</span>.
            <.link
              :if={@class || @detail || @blocker}
              id="np-clear"
              patch={~p"/admin/not-precompiled"}
              class="link link-hover ml-2"
            >
              Clear filters
            </.link>
          </p>

          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Package</th>
                  <th>Version</th>
                  <th>Toolchains</th>
                  <th>Downloads</th>
                  <th>Cause</th>
                </tr>
              </thead>
              <tbody id="np-rows">
                <tr :if={@list == []}>
                  <td colspan="5" class="text-sm text-base-content/60">No packages match.</td>
                </tr>
                <tr :for={{row, i} <- Enum.with_index(@list)} id={"np-row-#{row.package}-#{i}"}>
                  <td class="font-medium">
                    <.link navigate={~p"/packages/#{row.package}"} class="link link-hover">
                      {row.package}
                    </.link>
                  </td>
                  <td class="whitespace-nowrap">{row.version}</td>
                  <td class="whitespace-nowrap text-xs">{Enum.join(row.toolchains, ", ")}</td>
                  <td>{number(row.downloads)}</td>
                  <td class="text-sm">
                    <details>
                      <summary class="cursor-pointer" title={row.reason}>
                        {cause(row)}
                      </summary>
                      <code class="mt-1 block whitespace-pre-wrap break-all text-xs text-base-content/70">
                        {row.reason || "(no reason)"}
                      </code>
                    </details>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>
    </.admin_layout>
    """
  end
end
