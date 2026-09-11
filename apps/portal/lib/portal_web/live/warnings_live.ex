defmodule PortalWeb.WarningsLive do
  use PortalWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Warnings")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:warnings} current_user={@current_user}>
      <section class="space-y-10">
        <PortalWeb.UI.page_header kicker="Warnings" title="Warnings">
          <:subtitle>Compiler and dialyzer warnings across packages, coming soon.</:subtitle>
        </PortalWeb.UI.page_header>
      </section>
    </Layouts.app>
    """
  end
end
