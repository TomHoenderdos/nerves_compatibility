defmodule PortalWeb.AdminComponents do
  @moduledoc """
  The admin pages' chrome: title, tab bar, date format and row labels. Shared by the
  controller-rendered admin tabs and the admin LiveViews, so moving a tab
  from one to the other does not change how the page around it looks.
  """
  use Phoenix.Component
  use PortalWeb, :verified_routes

  import PortalWeb.SiteNav

  alias PortalWeb.Layouts

  @admin_tabs [
    {:overview, "Overview", "/admin"},
    {:queue, "Queue", "/admin/queue"},
    {:builders, "Builders", "/admin/builders"},
    {:users, "Users", "/admin/users"},
    {:failures, "Failures", "/admin/failures"},
    {:argus, "Argus", "/admin/argus"},
    {:triage, "Triage", "/admin/argus/findings"},
    {:maintenance, "Maintenance", "/admin/maintenance"}
  ]

  @doc """
  The frame every admin section renders in: site nav, a title, and a tab per
  section with the current one marked, so the sections read as one place.
  """
  attr :flash, :map, required: true
  attr :current_user, :any, required: true
  attr :section, :atom, required: true
  attr :title, :string, required: true
  slot :subtitle
  slot :inner_block, required: true

  def admin_layout(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="min-h-screen bg-base-100 text-base-content">
      <.site_nav active={:admin} current_user={@current_user} />

      <div class="mx-auto max-w-5xl px-4 py-10 sm:px-6 lg:px-8">
        <section class="space-y-8">
          <PortalWeb.UI.page_header kicker="Admin" title={@title}>
            <:subtitle :if={@subtitle != []}>{render_slot(@subtitle)}</:subtitle>
          </PortalWeb.UI.page_header>

          <.admin_tabs section={@section} />

          {render_slot(@inner_block)}
        </section>
      </div>
    </main>
    """
  end

  @doc """
  The tab per admin section, with `section` marked current. Shared by
  `admin_layout/1` and the admin LiveViews, which render inside
  `Layouts.app` and so place it under their own page header.
  """
  attr :section, :atom, required: true

  def admin_tabs(assigns) do
    assigns = assign(assigns, :tabs, @admin_tabs)

    ~H"""
    <nav
      id="admin-tabs"
      aria-label="Admin sections"
      class="-mt-2 flex flex-wrap gap-1 border-b border-base-300"
    >
      <.link
        :for={{key, label, path} <- @tabs}
        href={path}
        aria-current={if key == @section, do: "page"}
        class={[
          "-mb-px border-b-2 px-3 py-2 text-sm font-medium transition",
          if(key == @section,
            do: "border-primary text-base-content",
            else: "border-transparent text-base-content/60 hover:text-base-content"
          )
        ]}
      >
        {label}
      </.link>
    </nav>
    """
  end

  def format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  def format_datetime(_datetime), do: "-"

  @doc "A toolchain such as `1.19/28` as a DOM id fragment, `1.19-28`."
  def toolchain_dom_id(toolchain), do: String.replace(toolchain, "/", "-")

  def verification_label(:hex_owner), do: "Hex.pm owner"
  def verification_label(:github_repo), do: "GitHub repository"
  def verification_label(:anonymous_turnstile), do: "Anonymous"
  def verification_label(:anonymous_manual), do: "Manual review"
  def verification_label(:admin_manual), do: "Admin"
  def verification_label(source), do: source |> to_string() |> String.replace("_", " ")

  def request_status_label(:pending), do: "Pending review"
  def request_status_label(:accepted), do: "Accepted"
  def request_status_label(:queued), do: "Queued"
  def request_status_label(:rejected), do: "Rejected"
  def request_status_label(status), do: status |> to_string() |> String.replace("_", " ")
end
