defmodule PortalWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use PortalWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @site_name "Nerves Compatibility"
  @title_suffix " · " <> @site_name
  @default_title "Catalog"

  @default_description "Which Hex packages actually build on Nerves. Every package is " <>
                         "built as real firmware against each Nerves system, with " <>
                         "per-system results and the full build log for failures."

  @doc """
  The suffix every page title carries, and the title used when a page sets none.

  Exposed as functions because `root.html.heex` passes them to `<.live_title>`
  while `head_meta/1` needs the same strings to build `og:title`. A literal in
  both places would drift.
  """
  def title_suffix, do: @title_suffix
  def default_title, do: @default_title

  @doc """
  The `<head>` metadata that is not the title: description, canonical URL, and
  Open Graph.

  Every page here is public and listed in `sitemap.xml`, so what a crawler or a
  chat client makes of a link is decided entirely by these tags. Without them a
  search engine invents its own snippet and a Slack or Discord unfurl is blank.

  The canonical URL is built from `conn.request_path`, which drops the query
  string. That is deliberate and currently lossless: no LiveView in this app
  implements `handle_params/3` or calls `push_patch/2`, so no page state lives
  in the query string. What the query string *does* carry is tracking junk
  (`utm_*`, `fbclid`) appended by whoever shared the link, and without a
  canonical each variant is a separate, duplicate entry in the index. If a page
  ever starts encoding real state in its query string, it has to set its own
  canonical rather than inherit this one.

  No `og:image`: the only brand asset is an SVG, and the major unfurlers
  (Slack, Discord, Twitter, iMessage) either ignore SVG or fail the card
  outright. A card with a title and a description beats a card with a broken
  image.
  """
  attr :conn, Plug.Conn, required: true, doc: "the request, for the canonical URL"
  attr :page_title, :string, default: nil, doc: "title without the site suffix"
  attr :page_description, :string, default: nil, doc: "one-sentence page summary"

  def head_meta(assigns) do
    canonical = PortalWeb.Endpoint.url() <> assigns.conn.request_path

    assigns =
      assigns
      |> assign(:title, (assigns.page_title || @default_title) <> @title_suffix)
      |> assign(:description, assigns.page_description || @default_description)
      |> assign(:canonical, canonical)
      |> assign(:site_name, @site_name)

    ~H"""
    <meta name="description" content={@description} />
    <link rel="canonical" href={@canonical} />
    <meta property="og:type" content="website" />
    <meta property="og:site_name" content={@site_name} />
    <meta property="og:title" content={@title} />
    <meta property="og:description" content={@description} />
    <meta property="og:url" content={@canonical} />
    <meta name="twitter:card" content="summary" />
    """
  end

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :active, :atom, default: nil, doc: "active nav item"
  attr :current_user, :any, default: nil, doc: "the signed-in user, if any"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <.site_nav active={@active} current_user={@current_user} />

    <main class="min-h-screen bg-base-100 text-base-content">
      <div class="mx-auto max-w-5xl px-4 py-10 sm:px-6 lg:px-8">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <%!--
      `show/1` is scoped by selector, but the `JS.remove_attribute` piped onto it is
      not: without a `to:` it targets the element carrying the binding. `hidden` is
      the only thing hiding these toasts, so an unscoped removal un-hid *both* of
      them on every disconnect -- a plain reload flashed "Something went wrong!"
      alongside the connection notice. Both halves have to name the same selector.
      --%>
      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="theme-toggle card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="relative z-10 flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="relative z-10 flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="relative z-10 flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
