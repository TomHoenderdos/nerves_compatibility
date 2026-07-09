defmodule PortalWeb.SiteNav do
  @moduledoc false

  use Phoenix.Component

  import Phoenix.Controller, only: [get_csrf_token: 0]
  import PortalWeb.CoreComponents, only: [icon: 1]
  alias PortalWeb.Layouts

  attr :active, :atom, default: nil
  attr :current_user, :any, default: nil

  def site_nav(assigns) do
    ~H"""
    <nav class="site-nav">
      <div class="site-nav-inner">
        <a class="site-nav-brand" href="/">Nerves Compatibility</a>
        <div class="site-nav-links">
          <.nav_link href="/" active={@active == :home}>Dashboard</.nav_link>
          <.nav_link href="/packages" active={@active == :packages}>Packages</.nav_link>
          <.nav_link href="/failure_clusters" active={@active == :clusters}>
            Failure clusters
          </.nav_link>
          <.nav_link href="/warnings" active={@active == :warnings}>Warnings</.nav_link>
          <.nav_link href="/stats" active={@active == :stats}>Stats</.nav_link>
          <a
            href="/request-scan"
            class="rounded-md bg-primary px-3 py-1.5 text-sm font-semibold text-primary-content transition hover:brightness-95"
          >
            Request scan
          </a>
          |
          <.nav_link
            :if={Portal.Accounts.admin?(@current_user)}
            href="/admin"
            active={@active == :admin}
          >
            Admin
          </.nav_link>
          <.nav_link
            :if={Portal.Accounts.admin?(@current_user)}
            href="/admin/monitor"
            active={@active == :oban}
          >
            Oban
          </.nav_link>
          <div class="site-nav-auth">
            <%= if @current_user do %>
              |
              <form method="post" action="/logout">
                <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
                <button type="submit" class="nav-link nav-button">Logout</button>
              </form>
            <% else %>
              <details class="site-auth-menu">
                <summary class="site-avatar" aria-label="Account menu">
                  <.icon name="hero-user-mini" class="size-4" />
                </summary>
                <div class="site-auth-menu-panel">
                  <a class="site-auth-menu-item" href="/login">Login</a>
                  <a class="site-auth-menu-item" href="/register">Register</a>
                </div>
              </details>
            <% end %>
          </div>
          <div class="site-nav-theme">
            <Layouts.theme_toggle />
          </div>
        </div>
      </div>
    </nav>
    """
  end

  attr :href, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <a class={["nav-link", @active && "nav-active"]} href={@href}>{render_slot(@inner_block)}</a>
    """
  end
end
