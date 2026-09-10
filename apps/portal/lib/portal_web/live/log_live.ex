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

        <form id="log-filter-form" phx-change="filter" phx-submit="filter" class="max-w-md">
          <.input
            type="text"
            id="log-filter"
            name="filter"
            value={@filter}
            label="Filter lines"
            placeholder="substring, case-insensitive"
            phx-debounce="300"
          />
        </form>

        <div id="log-line-count" class="text-sm text-base-content/60">
          {length(@visible)} of {length(@lines)} lines
        </div>

        <div class="overflow-hidden rounded-2xl border border-base-300 bg-base-300/30 shadow-sm">
          <pre class="overflow-x-auto p-4 font-mono text-xs leading-relaxed text-base-content/80"><code id="log-body"><span :for={{text, _downcased, number} <- @visible} class="block"><span class="mr-4 inline-block w-10 select-none text-right text-base-content/30">{number}</span>{text}</span></code></pre>
        </div>
      </section>
    </Layouts.app>
    """
  end

  # Each line carries a downcased copy built once here rather than on every
  # keystroke. Re-downcasing a 16k-line log per debounced change threw away
  # ~800 KB of garbage each time to recompute a string that never changes.
  defp number_lines(body) do
    body
    |> String.split("\n")
    |> drop_trailing_blank()
    |> Enum.with_index(1)
    |> Enum.map(fn {text, number} -> {text, String.downcase(text), number} end)
  end

  # A newline-terminated log splits into a final "" that is not a line. It was
  # being counted and rendered as a blank numbered row, so a 200-line log
  # reported "201 lines".
  defp drop_trailing_blank(lines) do
    case List.last(lines) do
      "" -> Enum.drop(lines, -1)
      _ -> lines
    end
  end

  defp filter_lines(lines, ""), do: lines

  defp filter_lines(lines, query) do
    needle = String.downcase(query)

    Enum.filter(lines, fn {_text, downcased, _number} ->
      String.contains?(downcased, needle)
    end)
  end
end
