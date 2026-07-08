defmodule PortalWeb.FailureClustersLive do
  use PortalWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:clusters} current_user={@current_user}>
      <PortalWeb.UI.page_header kicker="Failure clusters" title="Failure clusters" />
    </Layouts.app>
    """
  end
end
