defmodule PortalWeb.LogLive do
  @moduledoc """
  One build log, for one system of a package's latest run.

  Deep-linkable, so a maintainer can paste the URL into an issue.

  Two rules govern this page, and both come from the content being compile
  output from an unreviewed third-party Hex package:

    * The filter is a case-insensitive substring, never a regex. A
      user-supplied pattern is a ReDoS against this LiveView process.
    * Nothing here uses `raw/1`. HEEx escapes every interpolation, and that is
      the only thing standing between a package's log and the browser.
  """

  use PortalWeb, :live_view

  alias Portal.Catalog

  @impl true
  def mount(%{"name" => name, "system" => system}, _session, socket) do
    case Catalog.system_log(name, system) do
      {:ok, log} ->
        lines = number_lines(log.body)

        {:ok,
         socket
         |> assign(:name, name)
         |> assign(:log, log)
         |> assign(:filter, "")
         |> assign(:lines, lines)
         |> assign(:visible, lines)}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "No stored build log for that system")
         |> push_navigate(to: ~p"/packages/#{name}")}
    end
  end

  @impl true
  def handle_event("filter", %{"filter" => query}, socket) do
    {:noreply,
     socket
     |> assign(:filter, query)
     |> assign(:visible, filter_lines(socket.assigns.lines, query))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:packages} current_user={@current_user}>
      <section class="space-y-6">
        <a
          href={~p"/packages/#{@name}"}
          class="inline-flex items-center gap-1.5 text-sm font-medium text-base-content/60 transition hover:text-base-content"
        >
          <.icon name="hero-chevron-left-mini" class="size-4" /> {@name}
        </a>

        <PortalWeb.UI.page_header kicker="Build log" title={@log.system_pkg}>
          <:subtitle>
            <span class="font-mono text-sm">
              {@name} {@log.version_tested} · {@log.status} · run {@log.run_id}
            </span>
          </:subtitle>
        </PortalWeb.UI.page_header>

        <div
          :if={@log.truncated}
          id="log-truncation-banner"
          class="rounded-xl border border-warning/40 bg-warning/10 px-4 py-3 text-sm"
        >
          The original log was {@log.byte_size} bytes. Showing the first and last 400 KB;
          the middle is marked where it was elided.
        </div>

        <form id="log-filter-form" phx-change="filter" class="max-w-md">
          <.input
            type="text"
            id="log-filter"
            name="filter"
            value={@filter}
            label="Filter lines"
            placeholder="substring, case-insensitive"
            phx-debounce="150"
          />
        </form>

        <div id="log-line-count" class="text-sm text-base-content/60">
          {length(@visible)} of {length(@lines)} lines
        </div>

        <div class="overflow-hidden rounded-2xl border border-base-300 bg-base-300/30 shadow-sm">
          <pre class="overflow-x-auto p-4 font-mono text-xs leading-relaxed text-base-content/80"><code id="log-body"><span :for={{text, number} <- @visible} class="block"><span class="mr-4 inline-block w-10 select-none text-right text-base-content/30">{number}</span>{text}</span></code></pre>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp number_lines(body), do: body |> String.split("\n") |> Enum.with_index(1)

  defp filter_lines(lines, ""), do: lines

  defp filter_lines(lines, query) do
    needle = String.downcase(query)

    Enum.filter(lines, fn {text, _number} -> String.contains?(String.downcase(text), needle) end)
  end
end
