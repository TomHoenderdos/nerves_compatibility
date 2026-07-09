# Request Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show approved in-flight scan requests as placeholder cards on `/packages`, and show a post-submit confirmation panel on `/request-scan` linking to each requested package's `/requests/:id` progress page.

**Architecture:** `IndexLive` merges `ScanRequests.queue_requests/0` (status `[:accepted,:queued]`) into its list as placeholder entries (deduped against the catalog), rendered by the existing `PortalWeb.UI.package_card` with a `/requests/:id` href. The three request-submit branches in `page_controller.ex` pass the created request structs to a new `submitted_requests` assign that `request_scan.html.heex` renders as a confirmation panel.

**Tech Stack:** Phoenix 1.8 LiveView, Ash, Beacon components (`PortalWeb.UI`), Tailwind/daisyUI.

## Global Constraints

- All work under `apps/portal/`. Run `mix` from the **repo root** (`/Users/tomhoenderdos/Projects/nerves_compatibility`).
- No accounts/users, no new route, no batch id, no combined live page. No worker/`result.json`, JSON API, badge, Oban, or `Catalog`/`ScanRequests` public-API changes (reuse `queue_requests/0` only).
- Placeholders show ONLY `status in [:accepted, :queued]` (approved). `:pending` unapproved requests stay hidden.
- Placeholder cards link to `~p"/requests/#{id}"` (NOT `/packages/:name`, which 404s until ingest).
- Preserve regression hooks: real package stream dom id stays `package-<name>`; `phx-change="search"` with param `q`; text `Nerves Compatibility`. Placeholders use dom id `placeholder-<name>`.
- Preserve request-scan copy/hooks: `Request scans for packages`, `data-package-picker`, the inline `<script>`, all `data-*`.
- COMMIT POLICY (user-approved): the branch has pre-existing uncommitted WIP; some target files (`index_live.ex` is clean at HEAD, `request_scan.html.heex` clean, `page_controller.ex` is WIP) may carry WIP — commit related files wholesale. Stage the EXPLICIT per-task file list; NEVER `git add -A`/`.`/`commit -a` (other unrelated files — app.css, deleted orchestrator/ — must not be swept). After each commit run `git show --stat HEAD` and confirm only intended files.
- `mix precommit` + umbrella `mix test` green at the end.

---

### Task 1: Placeholders on /packages (IndexLive)

**Files:**
- Modify: `apps/portal/lib/portal_web/live/index_live.ex` (mount, handle_event, render, list logic)
- Test: `apps/portal/test/portal_web/index_placeholders_test.exs`

**Interfaces:**
- Consumes: `Portal.ScanRequests.queue_requests/0` (returns `ScanRequest` structs with `id`, `package_name`, `status in [:accepted,:queued]`); `Portal.Catalog.latest_by_pkg_json/0`; `PortalWeb.UI.package_card`.
- Produces: `/packages` renders real package cards (`#package-<name>`, href `/packages/<name>`) and placeholder cards (`#placeholder-<name>`, href `/requests/<id>`, "in queue" pill), deduped by name, filtered by search `q`.

- [ ] **Step 1: Write the failing test**

```elixir
# apps/portal/test/portal_web/index_placeholders_test.exs
defmodule PortalWeb.IndexPlaceholdersTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Portal.Catalog.Ingestion
  alias Portal.ScanRequests.ScanRequest

  defp seed_request(name, status) do
    {:ok, req} =
      ScanRequest
      |> Ash.Changeset.for_create(:create, %{
        package_name: name,
        source: :anonymous_manual,
        status: status
      })
      |> Ash.create(domain: Portal.ScanRequests)

    req
  end

  defp ingest(name) do
    dir = Path.join(System.tmp_dir!(), "idx-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => name, "version" => "1.0.0"},
          "finished_at" => "2026-07-05T10:00:00Z",
          "systems" => %{"nerves_system_rpi0" => %{"status" => "pass"}}
        },
        %{run_id: "#{name}-1", image_digest: "sha256:x", files_dir: dir, log: "l"}
      )
  end

  test "accepted request not in catalog shows a placeholder linking to its progress", %{conn: conn} do
    req = seed_request("queuedpkg", :accepted)

    {:ok, _view, html} = live(conn, ~p"/packages")
    assert html =~ ~s(id="placeholder-queuedpkg")
    assert html =~ "in queue"
    assert html =~ ~p"/requests/#{req.id}"
  end

  test "pending (unapproved) request is not shown", %{conn: conn} do
    seed_request("pendingpkg", :pending)

    {:ok, _view, html} = live(conn, ~p"/packages")
    refute html =~ "pendingpkg"
  end

  test "a queued package already in the catalog shows only the catalog card, no placeholder", %{conn: conn} do
    ingest("dualpkg")
    seed_request("dualpkg", :accepted)

    {:ok, _view, html} = live(conn, ~p"/packages")
    assert html =~ ~s(id="package-dualpkg")
    refute html =~ ~s(id="placeholder-dualpkg")
  end

  test "search filters placeholders", %{conn: conn} do
    seed_request("findme", :accepted)
    seed_request("otherpkg", :accepted)

    {:ok, view, _html} = live(conn, ~p"/packages")
    html = render_change(view, :search, %{"q" => "findme"})
    assert html =~ "placeholder-findme"
    refute html =~ "placeholder-otherpkg"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run (from repo root): `mix test apps/portal/test/portal_web/index_placeholders_test.exs`
Expected: FAIL — no placeholder cards rendered.

- [ ] **Step 3: Rewrite IndexLive to merge placeholders**

Replace the whole body of `apps/portal/lib/portal_web/live/index_live.ex` with:

```elixir
defmodule PortalWeb.IndexLive do
  use PortalWeb, :live_view

  alias Portal.Catalog
  alias Portal.ScanRequests

  @impl true
  def mount(_params, _session, socket) do
    entries = entries("")

    {:ok,
     socket
     |> stream_configure(:packages,
       dom_id: fn entry ->
         if entry.placeholder?, do: "placeholder-#{entry.name}", else: "package-#{entry.name}"
       end
     )
     |> assign(:q, "")
     |> assign(:package_count, length(entries))
     |> stream(:packages, entries)}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    entries = entries(q)

    {:noreply,
     socket
     |> assign(:q, q)
     |> assign(:package_count, length(entries))
     |> stream(:packages, entries, reset: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:packages} current_user={@current_user}>
      <section class="space-y-8">
        <PortalWeb.UI.page_header kicker="Catalog" title="Nerves Compatibility">
          <:subtitle>
            Reproducible, per-system firmware build results for Hex packages — straight from the catalog.
          </:subtitle>
          <:actions>
            <a
              href={~p"/request-scan"}
              class="inline-flex items-center gap-2 rounded-xl bg-primary px-5 py-3 text-sm font-semibold text-primary-content shadow-sm transition hover:brightness-95"
            >
              <.icon name="hero-plus-mini" class="size-4" /> Request scan
            </a>
          </:actions>
        </PortalWeb.UI.page_header>

        <form id="package-search" phx-change="search" class="space-y-2">
          <label for="q" class="sr-only">Search packages</label>
          <div class="relative">
            <.icon
              name="hero-magnifying-glass-mini"
              class="pointer-events-none absolute left-4 top-1/2 size-5 -translate-y-1/2 text-base-content/40"
            />
            <input
              id="q"
              name="q"
              value={@q}
              type="search"
              placeholder="Search packages — jason, vintage_net, circuits_gpio…"
              class="w-full rounded-2xl border border-base-300 bg-base-100 py-4 pl-12 pr-4 text-base-content shadow-sm outline-none transition placeholder:text-base-content/40 focus:border-primary focus:ring-4 focus:ring-primary/10"
            />
          </div>
        </form>

        <div class="text-sm text-base-content/60">
          Showing <span class="font-medium text-base-content/80">{@package_count}</span> packages
        </div>

        <div id="packages" phx-update="stream" class="grid gap-3 sm:grid-cols-2">
          <PortalWeb.UI.package_card
            :for={{id, item} <- @streams.packages}
            id={id}
            name={item.name}
            description={item.description}
            version={item.version}
            href={item.href}
            summary={item.summary}
            summary_status={item.summary_status}
            statuses={item.statuses}
          />
        </div>
      </section>
    </Layouts.app>
    """
  end

  # -- entries ---------------------------------------------------------------

  defp entries(q) do
    q = q |> to_string() |> String.downcase()
    catalog = catalog_entries(q)
    names = MapSet.new(catalog, & &1.name)

    (catalog ++ placeholder_entries(q, names))
    |> Enum.sort_by(& &1.name)
  end

  defp catalog_entries(q) do
    Catalog.latest_by_pkg_json().packages
    |> Enum.map(fn {name, data} -> Map.put(data, :name, name) end)
    |> Enum.filter(fn package -> q == "" or String.contains?(package.name, q) end)
    |> Enum.map(fn package ->
      statuses = system_statuses(package)
      {summary, summary_status} = summarize(statuses)

      %{
        name: package.name,
        description: package.description,
        version: package.latest_version && "v#{package.latest_version}",
        href: ~p"/packages/#{package.name}",
        summary: summary,
        summary_status: summary_status,
        statuses: statuses,
        placeholder?: false
      }
    end)
  end

  defp placeholder_entries(q, catalog_names) do
    ScanRequests.queue_requests()
    |> Enum.reject(&MapSet.member?(catalog_names, &1.package_name))
    |> Enum.filter(fn req -> q == "" or String.contains?(req.package_name, q) end)
    |> Enum.uniq_by(& &1.package_name)
    |> Enum.map(fn req ->
      %{
        name: req.package_name,
        description: "Awaiting first scan.",
        version: nil,
        href: ~p"/requests/#{req.id}",
        summary: "in queue",
        summary_status: "queued",
        statuses: [],
        placeholder?: true
      }
    end)
  end

  defp system_statuses(package) do
    package |> Map.get(:systems, %{}) |> Map.values() |> Enum.map(&to_string(&1.status))
  end

  defp summarize(statuses) do
    cond do
      statuses == [] -> {"not run", "skipped"}
      "error" in statuses -> {tally(statuses), "error"}
      "fail" in statuses -> {tally(statuses), "fail"}
      Enum.all?(statuses, &(&1 == "pass")) -> {tally(statuses), "pass"}
      true -> {tally(statuses), "skipped"}
    end
  end

  defp tally(statuses) do
    pass = Enum.count(statuses, &(&1 == "pass"))
    "#{pass}/#{length(statuses)} pass"
  end
end
```

Note: `status_pill_class/1` in `PortalWeb.UI` already returns an amber pill for any unrecognized status (like `"queued"`), so the placeholder "in queue" pill needs no change to `PortalWeb.UI`.

- [ ] **Step 4: Run the new test + the existing catalog test**

Run (from repo root): `mix test apps/portal/test/portal_web/index_placeholders_test.exs apps/portal/test/portal_web/catalog_live_test.exs`
Expected: PASS — placeholders render/link/hide/dedup/search correctly; the moved browser test (`#package-jason`, search, "Nerves Compatibility") still passes.

- [ ] **Step 5: Commit**

```bash
git add apps/portal/lib/portal_web/live/index_live.ex apps/portal/test/portal_web/index_placeholders_test.exs
git commit -m "feat(portal): show queued scan requests as placeholders on /packages"
```

---

### Task 2: Confirmation panel on /request-scan

**Files:**
- Modify: `apps/portal/lib/portal_web/controllers/page_controller.ex` (the 3 submit success branches + `render_request_scan/2`)
- Modify: `apps/portal/lib/portal_web/controllers/page_html/request_scan.html.heex` (add panel above the form card)
- Test: `apps/portal/test/portal_web/controllers/page_controller_test.exs` (add a panel assertion to the anonymous-submit test, or a new test)

**Interfaces:**
- Consumes: the created `ScanRequest` structs already returned by `create_anonymous_requests/2`, `HexPm.complete_owner_requests/2`, and the GitHub completion path (each `{:ok, requests}` where a request has `.id` and `.package_name`).
- Produces: `@submitted_requests` assign (list of structs, default `[]`) rendered as a "track progress" panel with a `~p"/requests/#{id}"` link per package.

- [ ] **Step 1: Write the failing test**

Add to `apps/portal/test/portal_web/controllers/page_controller_test.exs` (a new test in the existing module):

```elixir
  test "submitting an anonymous request shows a confirmation panel linking to each request", %{
    conn: conn
  } do
    conn =
      post(conn, ~p"/requests/anonymous", %{
        "packages" => "coolpkg",
        "verification_method" => "anonymous"
      })

    body = html_response(conn, 200)
    assert body =~ "track progress"
    assert body =~ "coolpkg"

    # a /requests/<uuid> link is present
    assert body =~ ~r{/requests/[0-9a-f-]{36}}
  end
```

(If the anonymous submit action path/param names differ, mirror the existing anonymous-request test in the same file — grep it for the exact `post` path and params — and add the three assertions above.)

- [ ] **Step 2: Run test to verify it fails**

Run (from repo root): `mix test apps/portal/test/portal_web/controllers/page_controller_test.exs -o "confirmation panel"`
Expected: FAIL — no "track progress" panel yet. (If the `-o` filter is unsupported, run the whole file; the new test fails.)

- [ ] **Step 3: Pass submitted_requests from the 3 submit branches**

In `page_controller.ex`:

1. `render_request_scan/2` — add the assign. In the `render(conn, :request_scan, ...)` keyword list, add:

```elixir
      submitted_requests: Keyword.get(assigns, :submitted_requests, []),
```

2. The **anonymous** success branch currently calls
   `render_request_scan(packages: Enum.map(requests, & &1.package_name))`. Change it to:

```elixir
        |> render_request_scan(
          packages: Enum.map(requests, & &1.package_name),
          submitted_requests: requests
        )
```

3. The **hex_complete** success branch (same `render_request_scan(packages: Enum.map(requests, & &1.package_name))`) — apply the same change (add `submitted_requests: requests`).

4. The **github_complete** success branch (same shape) — apply the same change.

(There are exactly three `render_request_scan(packages: Enum.map(requests, & &1.package_name))` call sites — one per verified/anonymous submit path. Add `submitted_requests: requests` to each. Leave the non-success `render_request_scan(packages: ...)` calls untouched.)

- [ ] **Step 4: Render the panel in the template**

In `apps/portal/lib/portal_web/controllers/page_html/request_scan.html.heex`, insert this block immediately after the `<PortalWeb.UI.page_header ...>...</PortalWeb.UI.page_header>` closing tag and before the `<section class="card ...">` form card:

```heex
      <div
        :if={@submitted_requests != []}
        class="rounded-2xl border border-primary/30 bg-primary/5 p-6 shadow-sm"
      >
        <h2 class="text-sm font-semibold uppercase tracking-wider text-primary">
          Requested {length(@submitted_requests)} {ngettext("package", "packages", length(@submitted_requests))} — track progress
        </h2>
        <ul class="mt-4 divide-y divide-base-200">
          <li
            :for={request <- @submitted_requests}
            class="flex items-center justify-between py-3"
          >
            <span class="font-mono text-base-content">{request.package_name}</span>
            <a
              href={~p"/requests/#{request.id}"}
              class="inline-flex items-center gap-1 text-sm font-semibold text-primary hover:underline"
            >
              View progress <span aria-hidden="true">→</span>
            </a>
          </li>
        </ul>
      </div>
```

If `ngettext/3` is not available in this template context, replace the heading interpolation with `Requested {length(@submitted_requests)} package(s) — track progress`.

- [ ] **Step 5: Run the new test + the existing request-scan controller tests**

Run (from repo root): `mix test apps/portal/test/portal_web/controllers/page_controller_test.exs`
Expected: PASS — the new panel test passes; existing request-scan assertions (`Request scans for packages`, `Verify with Hex.pm`, `data-package-picker`, admin, auth-menu) still pass.

- [ ] **Step 6: Commit**

```bash
git add apps/portal/lib/portal_web/controllers/page_controller.ex apps/portal/lib/portal_web/controllers/page_html/request_scan.html.heex apps/portal/test/portal_web/controllers/page_controller_test.exs
git commit -m "feat(portal): post-submit confirmation panel linking to each request's progress"
```

---

### Task 3: Verification

- [ ] **Step 1: Umbrella tests**

Run (from repo root): `mix test`
Expected: PASS (integration excluded).

- [ ] **Step 2: Warnings-as-errors + format**

Run (from repo root): `mix compile --warnings-as-errors` and `mix format --check-formatted apps/portal/lib/portal_web/live/index_live.ex apps/portal/lib/portal_web/controllers/page_controller.ex`
Expected: clean.

- [ ] **Step 3: Manual check (light + dark)**

Run `mix phx.server` on a free port. Seed an accepted request for a package not in the catalog (e.g. via `iex`: `Portal.ScanRequests.ScanRequest |> Ash.Changeset.for_create(:create, %{package_name: "demoqueue", source: :anonymous_manual, status: :accepted}) |> Ash.create(domain: Portal.ScanRequests)`). Visit `/packages` — a "demoqueue" card shows an amber "in queue" pill and links to `/requests/<id>`; searching filters it. Submit a package on `/request-scan` — the confirmation panel appears with a "View progress →" link. Toggle theme — panel + placeholder legible in light and dark.

---

## Self-Review

**Spec coverage:**
- Placeholders from `queue_requests/0` (approved-only), deduped vs catalog, `/requests/:id` link, amber pill, search + count → Task 1. ✓
- `:pending` hidden → Task 1 (uses `queue_requests/0`, which excludes pending) + test. ✓
- Confirmation panel on `/request-scan` for all 3 submit paths, single + batch → Task 2. ✓
- Regression hooks (`package-<name>`, search, request-scan copy) preserved + tested → Tasks 1-2. ✓
- Verification → Task 3. ✓
- Non-goals: no users/route/batch-id/worker/API change. ✓

**Placeholder scan:** Two conditional fallbacks (Task 2 `-o` filter and `ngettext` availability) each name a concrete alternative — not vague TODOs. Acceptable.

**Type consistency:** `entries/1` returns maps with keys `name, description, version, href, summary, summary_status, statuses, placeholder?` consumed uniformly by `package_card` and by the `dom_id` fn (`entry.placeholder?`, `entry.name`). `submitted_requests` items are `ScanRequest` structs read as `request.package_name` / `request.id`. Consistent. ✓
