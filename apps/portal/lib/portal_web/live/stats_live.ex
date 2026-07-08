defmodule PortalWeb.StatsLive do
  use PortalWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:stats} current_user={@current_user}>
      <PortalWeb.UI.page_header kicker="Stats" title="Stats" />
    </Layouts.app>
    """
  end
end
