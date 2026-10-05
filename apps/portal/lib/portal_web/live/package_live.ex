defmodule PortalWeb.PackageLive do
  use PortalWeb, :live_view

  alias Portal.Catalog

  # Both snippets and the on-page <img> must agree: this is the text that ends
  # up in someone else's README, where a broken badge shows the alt and nothing
  # else.
  @badge_alt "Nerves compatibility"

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    case Catalog.latest_by_pkg_json(name) do
      %{packages: %{^name => package}} ->
        systems = systems(package)
        base = PortalWeb.Endpoint.url()
        badge_url = "#{base}/badge/#{name}.svg"
        page_url = "#{base}/packages/#{name}"

        hex_meta = Catalog.package_hex_meta(name) || %{links: %{}, owners: [], fetched_at: nil}

        {:ok,
         socket
         |> assign(:page_title, name)
         |> assign(:page_description, describe(name, package, systems))
         |> assign(:name, name)
         |> assign(:package, package)
         |> assign(:systems, systems)
         |> assign(:badge_alt, @badge_alt)
         |> assign(:hex_url, "https://hex.pm/packages/#{name}")
         |> assign(:docs_url, "https://hexdocs.pm/#{name}")
         |> assign(:github_url, github_url(hex_meta.links))
         |> assign(:owners, hex_meta.owners)
         |> assign(:argus, argus_view(Catalog.latest_argus(name)))
         |> assign(:argus_floor, Portal.Settings.get().argus_min_severity)
         |> assign(:admin?, Portal.Accounts.admin?(socket.assigns[:current_user]))
         |> assign(:badge_url, badge_url)
         |> assign(:badge_markdown, "[![#{@badge_alt}](#{badge_url})](#{page_url})")
         |> assign(
           :badge_html,
           ~s(<a href="#{page_url}"><img src="#{badge_url}" alt="#{@badge_alt}"></a>)
         )}

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
            <img src={@badge_url} alt={"#{@name} #{@badge_alt} badge"} class="h-6" />
          </:actions>
        </PortalWeb.UI.page_header>

        <%!--
        Both URLs are derived from the package name rather than stored, because
        hex.pm and hexdocs.pm both mint them that way for every published
        package. `rel="noopener"` on `target="_blank"`: without it the opened tab
        gets a live `window.opener` handle back to this one.
        --%>
        <div class="flex flex-wrap items-center gap-2">
          <.upstream_link href={@hex_url} label="Hex" />
          <.upstream_link href={@docs_url} label="Docs" />
          <.upstream_link :if={@github_url} href={@github_url} label="GitHub" />
        </div>

        <%!--
        Rendered only when hex.pm listed someone. An empty list is both "we
        have not fetched this package yet" and "hex.pm returned no owners", and
        neither is worth a line that says nobody maintains it.
        --%>
        <p :if={@owners != []} class="text-sm text-base-content/60">
          Maintained on Hex by
          <span :for={{owner, index} <- Enum.with_index(@owners)}>
            <span :if={index > 0}>, </span><a
              href={"https://hex.pm/users/#{owner}"}
              target="_blank"
              rel="noopener"
              class="font-medium text-base-content/80 hover:text-primary hover:underline"
            >{owner}</a>
          </span>
        </p>

        <div class="grid gap-3 sm:grid-cols-3">
          <PortalWeb.UI.stat_card label="Latest version" value={@package.latest_version || "unknown"} />
          <PortalWeb.UI.stat_card label="Last run" value={format_last_run(@package.last_run_at)} />
          <PortalWeb.UI.stat_card label="Checks" value={to_string(length(@systems))} />
        </div>

        <p
          :if={Enum.any?(@systems, &(&1.system_pkg == "pure_elixir"))}
          id="compatibility-assumption"
          class="rounded-xl border border-base-300 bg-base-200/50 p-4 text-sm text-base-content/80"
        >
          Assumed compatible: this package and its resolved dependencies passed host compilation
          and were identified as pure Elixir. No firmware targets were built.
        </p>

        <p
          :if={Enum.any?(@systems, &(&1.system_pkg == "registry_deps"))}
          id="compatibility-assumption"
          class="rounded-xl border border-base-300 bg-base-200/50 p-4 text-sm text-base-content/80"
        >
          Assumed compatible: no package in this release's dependency closure on hex.pm uses
          native code. Nothing was compiled.
        </p>

        <div class="overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-sm">
          <table class="w-full text-left text-sm">
            <thead class="border-b border-base-300 bg-base-200/60 text-xs uppercase tracking-wide text-base-content/60">
              <tr>
                <th class="px-5 py-3">Target / check</th>
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
                  <div class="font-mono font-medium text-base-content">
                    {system_label(system.system_pkg)}
                  </div>
                  <div :if={not assessment?(system.system_pkg)} class="text-base-content/50">
                    {system.system_version || "host"}
                  </div>
                  <.link
                    :if={system.status in ["fail", "error"]}
                    id={"log-link-#{dom_id(system.system_pkg)}"}
                    navigate={~p"/packages/#{@name}/log/#{system.system_pkg}"}
                    class="mt-1 inline-flex items-center gap-1 text-xs font-medium text-primary hover:underline"
                  >
                    <.icon name="hero-document-text-mini" class="size-3.5" /> View log
                  </.link>
                </td>
                <td class="px-5 py-4">
                  <PortalWeb.UI.status_badge status={system.status} />
                </td>
                <td class="px-5 py-4 font-mono text-base-content/70">
                  {system.firmware_size_bytes || "—"}
                </td>
                <td class="px-5 py-4 font-mono text-xs text-base-content/40">{system.run_id}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <section
          :if={@argus}
          id="argus"
          class="space-y-4 rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm"
        >
          <div>
            <h2 class="text-sm font-semibold text-base-content">OTP analysis</h2>
            <p class="mt-1 text-sm text-base-content/60">
              Static analysis of the compiled beams, advisory — by <a
                href="https://hex.pm/packages/argus_beam"
                target="_blank"
                rel="noopener"
                class="link"
              >
                argus_beam {@argus["version"]}
              </a>. It does not affect the compatibility result.
            </p>
          </div>

          <%= if @argus["status"] == "error" do %>
            <p class="text-sm text-base-content/70">Analysis could not run for this version.</p>
            <p :if={@admin?} class="font-mono text-xs text-base-content/50">{@argus["error"]}</p>
          <% else %>
            <% visible = visible_findings(@argus["findings"], @argus_floor) %>
            <p :if={visible == []} class="text-sm text-base-content/70">
              No findings at {@argus_floor} or above for: {Enum.join(
                List.wrap(@argus["analyses"]),
                ", "
              )}
            </p>
            <ul :if={visible != []} class="divide-y divide-base-200">
              <li
                :for={{finding, i} <- Enum.with_index(visible)}
                id={"argus-finding-#{i}"}
                class="py-3"
              >
                <div class="flex flex-wrap items-center gap-2">
                  <span class={["badge badge-sm", severity_class(finding["severity"])]}>
                    {finding["severity"]}
                  </span>
                  <span class="font-medium text-base-content">{finding["title"]}</span>
                  <span class="badge badge-sm badge-outline font-mono">{finding["analysis"]}</span>
                </div>
                <div
                  :if={finding_location(finding)}
                  class="mt-1 font-mono text-xs text-base-content/60"
                >
                  {finding_location(finding)}
                </div>
                <details class="mt-1 text-sm text-base-content/70">
                  <summary class="cursor-pointer text-xs">Details</summary>
                  <p :if={finding["at_label"]}>{finding["at_label"]}</p>
                  <p :if={finding["detail"]} class="mt-1">{finding["detail"]}</p>
                  <ul :if={finding["help"] not in [nil, []]} class="mt-1 list-disc pl-5">
                    <li :for={hint <- List.wrap(finding["help"])}>{hint}</li>
                  </ul>
                  <ul
                    :if={is_list(finding["related"]) and finding["related"] != []}
                    class="mt-1 font-mono text-xs"
                  >
                    <li :for={rel <- finding["related"]}>
                      {rel["label"]} — {finding_location(rel)}
                    </li>
                  </ul>
                </details>
              </li>
            </ul>
            <p :if={@argus["truncated"]} class="text-xs text-base-content/50">
              Showing the first 200 findings argus reported.
            </p>
          <% end %>
        </section>

        <div class="space-y-4 rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm">
          <div>
            <h2 class="text-sm font-semibold text-base-content">Add this badge to your README</h2>
            <p class="mt-1 text-sm text-base-content/60">
              It updates itself as {@name}'s compatibility is reassessed.
            </p>
          </div>

          <img src={@badge_url} alt={"#{@name} #{@badge_alt} badge"} class="h-6" />

          <.badge_snippet label="Markdown" snippet={@badge_markdown} />
          <.badge_snippet label="HTML" snippet={@badge_html} />
        </div>
      </section>
    </Layouts.app>
    """
  end

  # The package author's declared links arrive as a free-form label-to-URL map,
  # so the label is not dependable -- "GitHub", "Github", "Source", "Repo" and
  # "repository" all occur in the wild. The host is, so that is what is matched.
  #
  # `Portal.HexPm.package_metadata/1` has already filtered these to absolute
  # http/https URLs; this only picks one out.
  #
  # A package often declares several github.com links -- the repository, a
  # changelog, an issues page. The shallowest path wins, because that is the
  # repository root: `/owner/repo` beats `/owner/repo/blob/main/CHANGELOG.md`,
  # whatever the author happened to label either of them.
  defp github_url(links) when is_map(links) do
    links
    |> Enum.sort()
    |> Enum.flat_map(fn {_label, url} ->
      github_candidate(url)
    end)
    |> case do
      [] -> nil
      candidates -> candidates |> Enum.min() |> elem(2)
    end
  end

  defp github_url(_links), do: nil

  defp path_depth(nil), do: 0

  defp path_depth(path) do
    path |> String.split("/", trim: true) |> length()
  end

  attr :href, :string, required: true
  attr :label, :string, required: true

  defp upstream_link(assigns) do
    ~H"""
    <a
      href={@href}
      target="_blank"
      rel="noopener"
      class="inline-flex items-center gap-1.5 rounded-lg border border-base-300 bg-base-100 px-3 py-1.5 text-sm font-medium text-base-content/70 transition hover:border-primary hover:text-primary"
    >
      {@label}
      <.icon name="hero-arrow-top-right-on-square-mini" class="size-3.5" />
    </a>
    """
  end

  attr :label, :string, required: true
  attr :snippet, :string, required: true

  defp badge_snippet(assigns) do
    ~H"""
    <div class="space-y-1.5">
      <div class="flex items-center justify-between gap-3">
        <span class="text-xs font-medium uppercase tracking-wide text-base-content/50">
          {@label}
        </span>
        <button
          type="button"
          phx-hook=".CopyToClipboard"
          id={"copy-#{String.downcase(@label)}"}
          data-copy={@snippet}
          class="inline-flex items-center gap-1.5 rounded-lg border border-base-300 px-2.5 py-1 text-xs font-medium text-base-content/70 transition hover:border-primary hover:text-primary"
        >
          <span data-copy-label>Copy</span>
        </button>
      </div>
      <%!--
      `readonly` rather than a <pre>: it keeps the text selectable and
      keyboard-copyable for anyone the clipboard hook cannot serve -- no JS, an
      insecure context, or a denied clipboard permission.
      --%>
      <input
        type="text"
        readonly
        value={@snippet}
        onclick="this.select()"
        class="w-full rounded-lg border border-base-300 bg-base-200/50 px-3 py-2 font-mono text-xs text-base-content/80 outline-none focus:border-primary"
      />
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToClipboard">
      export default {
        mounted() {
          const label = this.el.querySelector("[data-copy-label]")
          const original = label.textContent

          this.el.addEventListener("click", async () => {
            try {
              await navigator.clipboard.writeText(this.el.dataset.copy)
              label.textContent = "Copied"
            } catch {
              // Insecure context, or the user denied clipboard access. The
              // input beside the button is still selectable, so say what to do
              // rather than failing silently.
              label.textContent = "Select and copy"
            }
            clearTimeout(this.resetTimer)
            this.resetTimer = setTimeout(() => (label.textContent = original), 2000)
          })
        },
        destroyed() {
          clearTimeout(this.resetTimer)
        }
      }
    </script>
    """
  end

  # This page is ~2,500 of the site's indexed URLs, so its description is the
  # one that most affects what a search result actually says. A single shared
  # sentence would make every package page look identical to a crawler; the
  # counts and the version make each one specific.
  #
  # Capped at 155 characters because that is roughly where Google truncates,
  # and a sentence cut mid-word reads worse than one that ends early.
  @description_limit 155

  defp describe(name, package, systems) do
    version = package.latest_version

    head =
      case basis(systems) do
        "registry_deps" ->
          "#{name} #{version} is assumed Nerves-compatible: no native code in its dependency closure on hex.pm; not compiled."

        "pure_elixir" ->
          "#{name} #{version} is assumed Nerves-compatible after pure-Elixir inspection and host compilation."

        nil ->
          build_summary(name, version, systems)
      end

    case package.description do
      blurb when is_binary(blurb) and blurb != "" -> truncate(head <> " " <> blurb)
      _ -> head
    end
  end

  defp build_summary(name, version, systems) do
    case {length(systems), Enum.count(systems, &(&1.status == "pass"))} do
      {0, _} -> "#{name} has not been built against any Nerves system yet."
      {total, total} -> "#{name} #{version} builds on all #{total} tracked Nerves systems."
      {total, 0} -> "#{name} #{version} fails on all #{total} tracked Nerves systems."
      {total, pass} -> "#{name} #{version} builds on #{pass} of #{total} tracked Nerves systems."
    end
  end

  defp basis(systems) do
    Enum.find_value(systems, fn system ->
      if assessment?(system.system_pkg), do: system.system_pkg
    end)
  end

  # Checks that are verdicts rather than builds: they have no system version to
  # show and read differently in the summary.
  defp assessment?(system_pkg), do: Catalog.assessment_system?(system_pkg)

  defp system_label("pure_elixir"), do: "Pure Elixir"
  defp system_label("registry_deps"), do: "Pure Elixir (dependency check)"
  defp system_label(system_pkg), do: system_pkg

  defp truncate(text) do
    if String.length(text) <= @description_limit do
      text
    else
      text
      |> String.slice(0, @description_limit)
      |> String.replace(~r/\s+\S*$/u, "")
      |> Kernel.<>("...")
    end
  end

  defp systems(package) do
    package.systems
    |> Map.values()
    |> Enum.sort_by(& &1.system_pkg)
  end

  defp dom_id(value), do: value |> String.replace("_", "-") |> String.replace("@", "-")

  defp format_last_run(nil), do: "not run"

  defp format_last_run(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> relative_time(dt)
      _ -> iso
    end
  end

  defp format_last_run(%DateTime{} = dt), do: relative_time(dt)
  defp format_last_run(other), do: to_string(other)

  defp relative_time(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 0 -> Calendar.strftime(dt, "%b %-d, %Y %H:%M UTC")
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)} min ago"
      diff < 86_400 -> "#{div(diff, 3600)} hr ago"
      diff < 2_592_000 -> "#{div(diff, 86_400)} days ago"
      true -> Calendar.strftime(dt, "%b %-d, %Y")
    end
  end

  defp github_candidate(url) do
    case URI.new(url) do
      {:ok, %URI{host: host, path: path}} when is_binary(host) ->
        if host == "github.com" or String.ends_with?(host, ".github.com"),
          do: [{path_depth(path), String.length(url), url}],
          else: []

      _ ->
        []
    end
  end

  @severity_rank %{"error" => 3, "warning" => 2, "info" => 1}

  # Only well-formed `ok` and `error` results render. Anything else -- skipped,
  # a run from before argus, a map missing its findings -- renders nothing.
  defp argus_view(%{"status" => "ok", "findings" => findings} = argus) when is_list(findings) do
    %{
      argus
      | "findings" =>
          for(%{"severity" => s} = f <- findings, Map.has_key?(@severity_rank, s), do: finding(f))
    }
    |> Map.put(
      "analyses",
      argus |> Map.get("analyses") |> List.wrap() |> Enum.filter(&is_binary/1)
    )
  end

  defp argus_view(%{"status" => "error"} = argus), do: argus
  defp argus_view(_), do: nil

  # Stored findings outlive the argus version that wrote them, so every field
  # the template prints is narrowed to the type it expects. Anything else is
  # dropped rather than allowed to raise during render.
  defp finding(f) do
    %{
      "severity" => f["severity"],
      "analysis" => text(f["analysis"]),
      "title" => text(f["title"]),
      "at_label" => text(f["at_label"]),
      "detail" => text(f["detail"]),
      "file" => text(f["file"]),
      "line" => if(is_integer(f["line"]), do: f["line"]),
      "help" => f["help"] |> List.wrap() |> Enum.filter(&is_binary/1),
      "related" =>
        for(
          %{} = r <- List.wrap(f["related"]),
          do: %{
            "label" => text(r["label"]),
            "file" => text(r["file"]),
            "line" => if(is_integer(r["line"]), do: r["line"])
          }
        )
    }
  end

  defp text(value) when is_binary(value), do: value
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(_), do: nil

  defp visible_findings(findings, floor) do
    min = Map.fetch!(@severity_rank, Atom.to_string(floor))

    findings
    |> Enum.filter(&(is_map(&1) and Map.get(@severity_rank, &1["severity"], 0) >= min))
    |> Enum.sort_by(&(-Map.get(@severity_rank, &1["severity"], 0)))
  end

  defp finding_location(%{"file" => file, "line" => line})
       when is_binary(file) and is_integer(line),
       do: "#{file}:#{line}"

  defp finding_location(%{"file" => file}) when is_binary(file), do: file
  defp finding_location(_), do: nil

  defp severity_class("error"), do: "badge-error"
  defp severity_class("warning"), do: "badge-warning"
  defp severity_class(_), do: "badge-ghost"
end
