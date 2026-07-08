defmodule PortalWeb.PackageLive do
  use PortalWeb, :live_view

  alias Portal.Catalog

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    case Catalog.latest_by_pkg_json(name) do
      %{packages: %{^name => package}} ->
        {:ok,
         socket
         |> assign(:name, name)
         |> assign(:package, package)
         |> assign(:systems, systems(package))}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Package not found")
         |> push_navigate(to: ~p"/packages")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:packages} current_user={@current_user}>
      <section class="space-y-8">
        <a
          href={~p"/packages"}
          class="inline-flex items-center gap-1.5 text-sm font-medium text-base-content/60 transition hover:text-base-content"
        >
          <.icon name="hero-chevron-left-mini" class="size-4" /> All packages
        </a>

        <PortalWeb.UI.page_header title={@name}>
          <:subtitle>{@package.description || "No description"}</:subtitle>
          <:actions>
            <img src={"/badge/#{@name}.svg"} alt={"#{@name} Nerves compatibility badge"} class="h-6" />
          </:actions>
        </PortalWeb.UI.page_header>

        <div class="grid gap-3 sm:grid-cols-3">
          <PortalWeb.UI.stat_card label="Latest version" value={@package.latest_version || "unknown"} />
          <PortalWeb.UI.stat_card
            label="Last run"
            value={to_string(@package.last_run_at || "not run")}
          />
          <PortalWeb.UI.stat_card label="Systems" value={to_string(length(@systems))} />
        </div>

        <div class="overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-sm">
          <table class="w-full text-left text-sm">
            <thead class="border-b border-base-300 bg-base-200/60 text-xs uppercase tracking-wide text-base-content/60">
              <tr>
                <th class="px-5 py-3">System</th>
                <th class="px-5 py-3">Status</th>
                <th class="px-5 py-3">Firmware size</th>
                <th class="px-5 py-3">Run</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-base-200">
              <tr
                :for={system <- @systems}
                id={"system-#{dom_id(system.system_pkg)}"}
                class="transition hover:bg-base-200/40"
              >
                <td class="px-5 py-4">
                  <div class="font-mono font-medium text-base-content">{system.system_pkg}</div>
                  <div class="text-base-content/50">{system.system_version || "host"}</div>
                </td>
                <td class="px-5 py-4"><PortalWeb.UI.status_badge status={system.status} /></td>
                <td class="px-5 py-4 font-mono text-base-content/70">
                  {system.firmware_size_bytes || "—"}
                </td>
                <td class="px-5 py-4 font-mono text-xs text-base-content/40">{system.run_id}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp systems(package) do
    package.systems
    |> Map.values()
    |> Enum.sort_by(& &1.system_pkg)
  end

  defp dom_id(value), do: value |> String.replace("_", "-") |> String.replace("@", "-")
end
