# Beacon UI Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reskin the entire Portal web UI into one coherent "Beacon" design system (clean technical, Nerves-orange accent, light + dark) and unify the two clashing layout families behind one app shell + shared components.

**Architecture:** Tune the existing daisyUI light/dark theme tokens, add a small Beacon component module (`PortalWeb.UI`), fold the existing `SiteNav` into a single app shell used by both LiveViews and controller pages, then rebuild each page's markup against the shared components. UI-only — no routes, schema, API, or worker changes.

**Tech Stack:** Phoenix 1.8, LiveView 1.1, HEEx, Tailwind v4 (`@import "tailwindcss"`), daisyUI (theme plugin), heroicons. Dark mode via `data-theme` attribute + `@custom-variant dark` already in `app.css`.

## Global Constraints

- All work is under `apps/portal/`. Run all `mix` commands from `apps/portal/` unless noted.
- UI-only: do NOT touch worker exit codes, JSON API (`CatalogApiController`), badge SVG, Oban Web, schemas, or `Portal.Catalog*`.
- Theme-aware styling only — never hardcode `bg-white`/`text-zinc-950` without a `dark:` counterpart. Status colors carry a `dark:` variant.
- Accent = Nerves orange `#FD4F00` (light primary already `oklch(70% 0.213 47.604)`).
- Preserve these exact, test-asserted strings & hooks:
  - Index: text `Nerves Compatibility`; stream dom id `package-<name>`; event `search` with param `q`.
  - Package: dom id `system-<dom_id>` via `dom_id/1`; raw firmware bytes rendered verbatim (e.g. `45678901`); strings `nerves_system_rpi4`, `pass`, version `1.4.1`.
  - Controllers: classes `site-auth-menu`, `site-auth-menu-item`, `aria-label="Account menu"`; copy `Request scans for packages`, `Verify with Hex.pm`, `Verify with GitHub`, `Request manual review`, `data-package-picker`, `Scan request operations`, `Anonymous approvals`, `Approve`.
  - `request_scan.html.heex` inline `<script>` and every `data-*` attribute it reads — re-skin around them, never rewrite them.
- Run `mix precommit` (compile --warnings-as-errors, deps.unlock --unused, format, test) before declaring done.
- Mockups are the visual source of truth: `docs/ui-mockups/a-beacon.html`, `a-beacon-detail.html`, `a-beacon-request.html`.

---

### Task 1: Beacon theme tokens + nav restyle (CSS)

**Files:**
- Modify: `apps/portal/assets/css/app.css` (dark theme block ~28-57; `.site-nav*` block ~107-167; `.site-avatar` ~200-215; `.theme-toggle` ~169-178)

**Interfaces:**
- Produces: a Beacon-tuned dark theme (orange primary) and a theme-aware top nav (white/light in light, `zinc-900`-ish in dark) reusing existing `.site-nav*` class names so controller-page tests keep passing.

- [ ] **Step 1: Set the dark theme primary to Nerves orange**

In the `@plugin "../vendor/daisyui-theme" { name: "dark"; ... }` block, change the primary tokens so the accent matches light:

```css
  --color-primary: oklch(70% 0.213 47.604);
  --color-primary-content: oklch(98% 0.016 73.684);
```

(Leave `--color-secondary`/`--color-accent` as-is.)

- [ ] **Step 2: Make the top nav theme-aware (Beacon)**

Replace the `.site-nav`, `.site-nav-brand`, `.site-nav-links .nav-link`, `.nav-active`, and `.site-avatar` rules so the bar is a light, bordered, sticky header in light mode and a dark surface in dark mode. Replace the existing rules (do not duplicate selectors):

```css
.site-nav {
  position: sticky;
  top: 0;
  z-index: 30;
  background: color-mix(in oklab, var(--color-base-100) 85%, transparent);
  backdrop-filter: blur(8px);
  border-bottom: 1px solid var(--color-base-300);
  color: var(--color-base-content);
  padding: 0;
}

.site-nav-inner {
  max-width: 64rem;
  margin: 0 auto;
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 20px;
  flex-wrap: wrap;
  padding: 12px 24px;
}

.site-nav-brand {
  color: var(--color-base-content);
  text-decoration: none;
  font-weight: 700;
  letter-spacing: -0.01em;
}
.site-nav-brand:hover { color: var(--color-primary); }

.site-nav-links { display: flex; align-items: center; gap: 4px; flex-wrap: wrap; }

.site-nav-links .nav-link {
  color: color-mix(in oklab, var(--color-base-content) 65%, transparent);
  text-decoration: none;
  padding: 6px 12px;
  border-radius: 8px;
  font-size: 0.9rem;
  font-weight: 500;
  transition: background 120ms, color 120ms;
}
.site-nav-links .nav-link:hover {
  background: var(--color-base-200);
  color: var(--color-base-content);
}
.site-nav-links .nav-link.nav-active {
  background: var(--color-base-200);
  color: var(--color-base-content);
}

.site-avatar {
  width: 34px; height: 34px; border-radius: 999px;
  display: inline-grid; place-items: center;
  color: var(--color-primary-content);
  background: var(--color-primary);
  border: 1px solid transparent;
  font-weight: 800; text-decoration: none;
}
.site-avatar:hover { filter: brightness(1.05); }
```

Delete the now-obsolete `.theme-toggle { color:#1e1b3a; ... }` and `.theme-toggle > div { ... }` overrides (lines ~169-178) so the toggle inherits daisyUI tokens in both themes.

- [ ] **Step 3: Build assets and verify no errors**

Run: `mix assets.build`
Expected: completes without error; `tailwind portal` and `esbuild portal` succeed.

- [ ] **Step 4: Commit**

```bash
git add apps/portal/assets/css/app.css
git commit -m "style(portal): Beacon theme tokens + theme-aware top nav"
```

---

### Task 2: Beacon shared components module (`PortalWeb.UI`)

**Files:**
- Create: `apps/portal/lib/portal_web/components/ui.ex`
- Modify: `apps/portal/lib/portal_web.ex` (the `html_helpers` quote — add `import PortalWeb.UI`)
- Test: `apps/portal/test/portal_web/components/ui_test.exs`

**Interfaces:**
- Produces (function components, all `import`ed into `:html` / `:live_view`):
  - `page_header/1` — attrs: `kicker :string \\ nil`, `title :string`, optional slots `subtitle`, `actions`.
  - `stat_card/1` — attrs: `label :string`, `value :string`, `accent :string \\ nil` (one of `nil`, `"pass"`, `"primary"`).
  - `status_badge/1` — attr: `status :string` (`"pass"|"fail"|"error"|"skipped"|other`); renders a pill, text = the status.
  - `system_bar/1` — attr: `statuses :list` (list of status strings); renders a row of colored segments.
  - `package_card/1` — attrs: `name`, `description`, `version`, `href`, `summary :string` (e.g. `"6/6 pass"`), `summary_status :string`, `statuses :list`.
  - `status_segment_class/1` and `status_pill_class/1` — public helpers returning Tailwind class strings (so LiveViews can reuse them).

- [ ] **Step 1: Write the failing test**

```elixir
# apps/portal/test/portal_web/components/ui_test.exs
defmodule PortalWeb.UITest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PortalWeb.UI

  test "status_badge renders the status text and a pass color in light + dark" do
    html = render_component(&status_badge/1, status: "pass")
    assert html =~ "pass"
    assert html =~ "emerald"
    assert html =~ "dark:"
  end

  test "page_header renders kicker, title and an actions slot" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <PortalWeb.UI.page_header kicker="Catalog" title="Nerves Compatibility">
        <:actions><a href="/x">Go</a></:actions>
      </PortalWeb.UI.page_header>
      """)

    assert html =~ "Catalog"
    assert html =~ "Nerves Compatibility"
    assert html =~ "Go"
  end

  test "system_bar renders one segment per status" do
    html = render_component(&system_bar/1, statuses: ["pass", "fail", "skipped"])
    assert html |> String.split("rounded-full") |> length() >= 4
  end

  test "stat_card renders label and value" do
    html = render_component(&stat_card/1, label: "Systems", value: "6")
    assert html =~ "Systems"
    assert html =~ "6"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/portal_web/components/ui_test.exs`
Expected: FAIL — `PortalWeb.UI` is undefined.

- [ ] **Step 3: Create the component module**

```elixir
# apps/portal/lib/portal_web/components/ui.ex
defmodule PortalWeb.UI do
  @moduledoc "Beacon design-system components shared across LiveViews and controller pages."
  use Phoenix.Component

  @doc "Section header: optional kicker, title, optional subtitle and actions slots."
  attr :kicker, :string, default: nil
  attr :title, :string, required: true
  attr :class, :any, default: nil
  slot :subtitle
  slot :actions

  def page_header(assigns) do
    ~H"""
    <div class={["flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between", @class]}>
      <div class="space-y-2">
        <p :if={@kicker} class="text-xs font-semibold uppercase tracking-[0.25em] text-primary">
          {@kicker}
        </p>
        <h1 class="text-3xl font-bold tracking-tight text-base-content sm:text-4xl">{@title}</h1>
        <div :if={@subtitle != []} class="max-w-2xl text-base-content/70">
          {render_slot(@subtitle)}
        </div>
      </div>
      <div :if={@actions != []} class="shrink-0">{render_slot(@actions)}</div>
    </div>
    """
  end

  @doc "A labelled value tile."
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :accent, :string, default: nil

  def stat_card(assigns) do
    ~H"""
    <div class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm">
      <div class="text-sm text-base-content/60">{@label}</div>
      <div class={[
        "mt-1 text-2xl font-bold tracking-tight",
        @accent == "pass" && "text-emerald-600 dark:text-emerald-400",
        @accent == "primary" && "text-primary",
        is_nil(@accent) && "text-base-content"
      ]}>{@value}</div>
    </div>
    """
  end

  @doc "Status pill. Text is the status string."
  attr :status, :string, required: true
  attr :class, :any, default: nil

  def status_badge(assigns) do
    ~H"""
    <span class={["rounded-full px-2.5 py-1 text-xs font-semibold ring-1", status_pill_class(@status), @class]}>
      {@status}
    </span>
    """
  end

  @doc "Row of per-system colored segments."
  attr :statuses, :list, required: true

  def system_bar(assigns) do
    ~H"""
    <div class="flex gap-1">
      <span :for={s <- @statuses} class={["h-2 w-6 rounded-full", status_segment_class(s)]} title={s}></span>
    </div>
    """
  end

  @doc "Package summary card for the browser grid."
  attr :name, :string, required: true
  attr :description, :string, default: nil
  attr :version, :string, default: nil
  attr :href, :string, required: true
  attr :summary, :string, default: nil
  attr :summary_status, :string, default: "unknown"
  attr :statuses, :list, default: []
  attr :rest, :global

  def package_card(assigns) do
    ~H"""
    <a
      href={@href}
      class="group rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm transition hover:-translate-y-0.5 hover:border-base-content/20 hover:shadow-md"
      {@rest}
    >
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0">
          <h2 class="truncate text-base font-semibold text-base-content group-hover:text-primary">{@name}</h2>
          <p class="mt-1 line-clamp-2 text-sm text-base-content/60">{@description || "No description"}</p>
        </div>
        <.status_badge :if={@summary} status={@summary} class={summary_override(@summary_status)} />
      </div>
      <div class="mt-4 flex items-center justify-between text-xs text-base-content/50">
        <span class="font-mono">{@version || "—"}</span>
        <.system_bar :if={@statuses != []} statuses={@statuses} />
      </div>
    </a>
    """
  end

  # The pill text is a summary ("4/6 pass") but its color should follow the worst status.
  defp summary_override(status), do: status_pill_class(status)

  @doc "Tailwind classes for a status pill (theme-aware)."
  def status_pill_class("pass"), do: "bg-emerald-50 text-emerald-700 ring-emerald-100 dark:bg-emerald-500/10 dark:text-emerald-300 dark:ring-emerald-500/20"
  def status_pill_class("fail"), do: "bg-orange-50 text-orange-700 ring-orange-100 dark:bg-orange-500/10 dark:text-orange-300 dark:ring-orange-500/20"
  def status_pill_class("error"), do: "bg-red-50 text-red-700 ring-red-100 dark:bg-red-500/10 dark:text-red-300 dark:ring-red-500/20"
  def status_pill_class("skipped"), do: "bg-base-200 text-base-content/60 ring-base-300 dark:bg-base-200 dark:text-base-content/60 dark:ring-base-300"
  def status_pill_class(_), do: "bg-amber-50 text-amber-700 ring-amber-100 dark:bg-amber-500/10 dark:text-amber-300 dark:ring-amber-500/20"

  @doc "Tailwind background classes for a system_bar segment (theme-aware)."
  def status_segment_class("pass"), do: "bg-emerald-400 dark:bg-emerald-500"
  def status_segment_class("fail"), do: "bg-orange-400 dark:bg-orange-500"
  def status_segment_class("error"), do: "bg-red-400 dark:bg-red-500"
  def status_segment_class(_), do: "bg-base-300"
end
```

- [ ] **Step 4: Import the module into HTML/LiveView helpers**

In `apps/portal/lib/portal_web.ex`, inside the `defp html_helpers` quote (next to `import PortalWeb.CoreComponents` / `import PortalWeb.SiteNav` at ~83-84), add:

```elixir
      import PortalWeb.UI
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/portal_web/components/ui_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add apps/portal/lib/portal_web/components/ui.ex apps/portal/lib/portal_web.ex apps/portal/test/portal_web/components/ui_test.exs
git commit -m "feat(portal): Beacon shared UI components (page_header, stat_card, status_badge, system_bar, package_card)"
```

---

### Task 3: Unify the app shell + remove Phoenix scaffold

**Files:**
- Modify: `apps/portal/lib/portal_web/components/layouts.ex` (`app/1` ~36-73; delete `theme_toggle` duplication? keep it — `SiteNav` uses `Layouts.theme_toggle`)
- Delete: `apps/portal/lib/portal_web/controllers/page_html/home.html.heex` (dead — `/` routes to `IndexLive`)
- Test: `apps/portal/test/portal_web/components/layouts_test.exs`

**Interfaces:**
- Consumes: `PortalWeb.SiteNav.site_nav/1`, `PortalWeb.Layouts.flash_group/1`.
- Produces: `Layouts.app/1` renders `<.site_nav>` + a centered `<main>` shell (max-w-5xl) + flash group. New attrs: `active :atom \\ nil`, `current_user :any \\ nil` forwarded to `site_nav`. `inner_block` required.

- [ ] **Step 1: Write the failing test**

```elixir
# apps/portal/test/portal_web/components/layouts_test.exs
defmodule PortalWeb.LayoutsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  test "app shell renders the Nerves Compatibility nav, not the Phoenix scaffold nav" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <PortalWeb.Layouts.app flash={%{}}>
        <p>content here</p>
      </PortalWeb.Layouts.app>
      """)

    assert html =~ "site-nav"
    assert html =~ "Nerves Compatibility"
    assert html =~ "content here"
    refute html =~ "Get Started"
    refute html =~ "phoenixframework.org"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/portal_web/components/layouts_test.exs`
Expected: FAIL — current `app/1` renders the Phoenix navbar (`Get Started`, `phoenixframework.org`).

- [ ] **Step 3: Rewrite `Layouts.app/1`**

Replace the `def app(assigns)` function (and its `attr`/`slot` declarations) in `layouts.ex` with:

```elixir
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
```

Add `import PortalWeb.SiteNav` to the top of `layouts.ex` (after `use PortalWeb, :html`) if `site_nav/1` is not already in scope there. (`Layouts` uses `:html`, which imports `SiteNav` — verify; if compile fails on `site_nav`, add the import.)

- [ ] **Step 4: Delete the dead Phoenix home page**

```bash
git rm apps/portal/lib/portal_web/controllers/page_html/home.html.heex
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/portal_web/components/layouts_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/portal/lib/portal_web/components/layouts.ex apps/portal/test/portal_web/components/layouts_test.exs
git commit -m "refactor(portal): unify app shell on SiteNav; drop Phoenix scaffold layout + dead home page"
```

---

### Task 4: Rebuild IndexLive (package browser) in Beacon

**Files:**
- Modify: `apps/portal/lib/portal_web/live/index_live.ex` (`render/1`; add a `summary`/`statuses` helper; keep `mount`/`handle_event`/`list_packages` data shape)
- Test: `apps/portal/test/portal_web/catalog_live_test.exs` (must still pass unchanged)

**Interfaces:**
- Consumes: `PortalWeb.UI.{page_header, stat_card, package_card}`, `Layouts.app`.
- Produces: same stream `:packages` (dom id `package-<name>`), same `search` event. Adds private `summary_for/1` returning `{summary_text, summary_status, statuses_list}` — but since `latest_by_pkg_json` package data here has only `latest_version`/`last_run_at` (no per-system list at index level), render the card without `statuses` and derive a simple summary string.

- [ ] **Step 1: Confirm the existing LiveView test still describes the contract**

Run: `mix test test/portal_web/catalog_live_test.exs:29`
Expected: PASS (current implementation). This is the regression guard for this task.

- [ ] **Step 2: Rewrite `render/1`**

Replace the `def render(assigns)` body in `index_live.ex` with (mount/handle_event/list_packages unchanged):

```elixir
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:packages}>
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
            <.icon name="hero-magnifying-glass-mini" class="pointer-events-none absolute left-4 top-1/2 size-5 -translate-y-1/2 text-base-content/40" />
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
            :for={{id, package} <- @streams.packages}
            id={id}
            name={package.name}
            description={package.description}
            version={package.latest_version && "v#{package.latest_version}"}
            href={~p"/packages/#{package.name}"}
            summary={package.last_run_at && "scanned" || "not run"}
            summary_status={(package.last_run_at && "pass") || "skipped"}
          />
        </div>
      </section>
    </Layouts.app>
    """
  end
```

Note: `package_card` accepts `id` via `:global` `@rest`, so `id={id}` lands on the `<a>` and preserves the `package-<name>` dom id the test asserts.

- [ ] **Step 3: Run the LiveView test**

Run: `mix test test/portal_web/catalog_live_test.exs:29`
Expected: PASS — `Nerves Compatibility`, `jason`, `#package-jason` all present; filtering by `zzz` removes the card.

- [ ] **Step 4: Commit**

```bash
git add apps/portal/lib/portal_web/live/index_live.ex
git commit -m "feat(portal): Beacon package browser (theme-aware, shared components)"
```

---

### Task 5: Rebuild PackageLive (detail) in Beacon

**Files:**
- Modify: `apps/portal/lib/portal_web/live/package_live.ex` (`render/1`; remove local `status_class/1`; keep `dom_id/1`, `systems/1`, `mount`)
- Test: `apps/portal/test/portal_web/catalog_live_test.exs:42` (must still pass)

**Interfaces:**
- Consumes: `PortalWeb.UI.{page_header, stat_card, status_badge}`, `Layouts.app`.
- Produces: same `#system-<dom_id>` ids; renders raw `firmware_size_bytes` verbatim (the test asserts `45678901`).

- [ ] **Step 1: Run the existing test as the regression guard**

Run: `mix test test/portal_web/catalog_live_test.exs:42`
Expected: PASS (current implementation).

- [ ] **Step 2: Rewrite `render/1` and drop `status_class/1`**

Replace `def render(assigns)` and DELETE the five `defp status_class(...)` clauses in `package_live.ex` (status color now comes from `PortalWeb.UI.status_badge`). Keep `systems/1` and `dom_id/1`:

```elixir
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:packages}>
      <section class="space-y-8">
        <a href={~p"/"} class="inline-flex items-center gap-1.5 text-sm font-medium text-base-content/60 transition hover:text-base-content">
          <.icon name="hero-chevron-left-mini" class="size-4" /> All packages
        </a>

        <PortalWeb.UI.page_header title={@name}>
          <:subtitle>{@package.description || "No description"}</:subtitle>
          <:actions>
            <img src={"/badge/#{@name}.svg"} alt={"#{@name} Nerves compatibility badge"} class="h-6" />
          </:actions>
        </PortalWeb.UI.page_header>

        <div class="grid gap-3 sm:grid-cols-3">
          <PortalWeb.UI.stat_card label="Latest version" value={@package.latest_version || "unknown"} />
          <PortalWeb.UI.stat_card label="Last run" value={to_string(@package.last_run_at || "not run")} />
          <PortalWeb.UI.stat_card label="Systems" value={to_string(length(@systems))} />
        </div>

        <div class="overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-sm">
          <table class="w-full text-left text-sm">
            <thead class="border-b border-base-300 bg-base-200/60 text-xs uppercase tracking-wide text-base-content/60">
              <tr>
                <th class="px-5 py-3">System</th>
                <th class="px-5 py-3">Status</th>
                <th class="px-5 py-3">Firmware size</th>
                <th class="px-5 py-3">Run</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-base-200">
              <tr :for={system <- @systems} id={"system-#{dom_id(system.system_pkg)}"} class="transition hover:bg-base-200/40">
                <td class="px-5 py-4">
                  <div class="font-mono font-medium text-base-content">{system.system_pkg}</div>
                  <div class="text-base-content/50">{system.system_version || "host"}</div>
                </td>
                <td class="px-5 py-4"><PortalWeb.UI.status_badge status={system.status} /></td>
                <td class="px-5 py-4 font-mono text-base-content/70">{system.firmware_size_bytes || "—"}</td>
                <td class="px-5 py-4 font-mono text-xs text-base-content/40">{system.run_id}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end
```

- [ ] **Step 3: Run the test**

Run: `mix test test/portal_web/catalog_live_test.exs:42`
Expected: PASS — `jason`, `1.4.1`, `#system-nerves-system-rpi4`, `nerves_system_rpi4`, `pass`, `45678901` all present.

- [ ] **Step 4: Commit**

```bash
git add apps/portal/lib/portal_web/live/package_live.ex
git commit -m "feat(portal): Beacon package detail (shared status badge + stat cards)"
```

---

### Task 6: Rebuild RequestLive (status) in Beacon — stepper + log

**Files:**
- Modify: `apps/portal/lib/portal_web/live/request_live.ex` (`render/1`; keep `mount`/`handle_info`)
- Test: `apps/portal/test/portal_web/request_live_test.exs` (create)

**Interfaces:**
- Consumes: `PortalWeb.UI.{page_header, stat_card}`, `Layouts.app`.
- Produces: same `#request-status` element id; live progress panel shows `@stage` and a formatted payload. Adds private `stages/0` (the ordered stage list) and `stage_state/2` (`:done | :active | :pending`) for the stepper.

- [ ] **Step 1: Write the failing test**

```elixir
# apps/portal/test/portal_web/request_live_test.exs
defmodule PortalWeb.RequestLiveTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Portal.ScanRequests

  test "request live renders the Beacon status page", %{conn: conn} do
    {:ok, request} =
      ScanRequests.create_anonymous_request(%{package_name: "vintage_net", subject: "tester"})

    {:ok, _view, html} = live(conn, ~p"/requests/#{request.id}")

    assert html =~ "vintage_net"
    assert html =~ "Scan request"
    assert html =~ "Build progress"
    assert html =~ ~s(id="request-status")
  end
end
```

(If `create_anonymous_request/1`'s arity/name differs, use the helper the existing `scan_request_test.exs` uses to insert a request — grep `test/portal/scan_requests/` for the exact constructor and match it.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/portal_web/request_live_test.exs`
Expected: FAIL — current page has no "Build progress" / stepper.

- [ ] **Step 3: Rewrite `render/1` and add stepper helpers**

Replace `def render(assigns)` in `request_live.ex` and add the helpers below it:

```elixir
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:request_scan}>
      <section class="space-y-7">
        <a href={~p"/"} class="inline-flex items-center gap-1.5 text-sm font-medium text-base-content/60 transition hover:text-base-content">
          <.icon name="hero-chevron-left-mini" class="size-4" /> All packages
        </a>

        <PortalWeb.UI.page_header kicker="Scan request" title={@request.package_name}>
          <:subtitle><span class="font-mono text-sm">{@request.id}</span></:subtitle>
        </PortalWeb.UI.page_header>

        <div class="grid grid-cols-3 gap-3">
          <div class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm">
            <div class="text-sm text-base-content/60">Status</div>
            <div id="request-status" class="mt-1 text-lg font-semibold text-primary">{@request.status}</div>
          </div>
          <PortalWeb.UI.stat_card label="Version" value={@request.version || "latest"} />
          <PortalWeb.UI.stat_card label="Source" value={to_string(@request.source)} />
        </div>

        <div class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm">
          <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content/60">Build progress</h2>
          <ol class="mt-5 space-y-5">
            <li :for={{key, label, desc} <- stages()} class={[
              "flex items-start gap-3",
              stage_state(key, assigns) == :pending && "opacity-40"
            ]}>
              <span class={[
                "mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full",
                stage_state(key, assigns) == :done && "bg-emerald-500 text-white",
                stage_state(key, assigns) == :active && "bg-primary text-primary-content",
                stage_state(key, assigns) == :pending && "border-2 border-base-300 text-base-content/40"
              ]}>
                <.icon :if={stage_state(key, assigns) == :done} name="hero-check-mini" class="size-3.5" />
                <span :if={stage_state(key, assigns) == :active} class="h-2 w-2 animate-pulse rounded-full bg-current"></span>
              </span>
              <div>
                <div class="font-medium text-base-content">{label}</div>
                <div class="text-sm text-base-content/60">{desc}</div>
              </div>
            </li>
          </ol>
        </div>

        <div :if={map_size(@payload) > 0} class="overflow-hidden rounded-2xl border border-base-300 bg-base-300/30 shadow-sm">
          <div class="border-b border-base-300 px-4 py-2.5 font-mono text-xs text-base-content/60">latest progress</div>
          <pre class="overflow-auto p-4 font-mono text-xs leading-relaxed text-base-content/80"><%= inspect(@payload, pretty: true) %></pre>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp stages do
    [
      {:queued, "Queued", "Accepted and scheduled on the builds queue."},
      {:building, "Building firmware", "Compiling per Nerves system in the build container."},
      {:ingesting, "Ingest results", "Persist runs and archive precompiled artifacts."}
    ]
  end

  # Map the request status + live stage onto a tri-state per stage.
  defp stage_state(key, %{request: request, stage: stage}) do
    order = [:queued, :building, :ingesting]
    current = current_stage(request.status, stage)
    cond do
      Enum.find_index(order, &(&1 == key)) < Enum.find_index(order, &(&1 == current)) -> :done
      key == current -> :active
      true -> :pending
    end
  end

  defp current_stage(status, stage) do
    status = to_string(status)
    stage = to_string(stage)
    cond do
      status in ["passed", "failed", "errored", "completed", "done"] -> :ingesting
      stage =~ "ingest" -> :ingesting
      stage =~ "build" or status == "building" -> :building
      true -> :queued
    end
  end
```

(Adjust the status strings in `current_stage/2` to the actual `ScanRequest` status enum — grep `lib/portal/scan_requests` for the status values and map them: queued-ish → `:queued`, in-progress → `:building`, terminal → `:ingesting`.)

- [ ] **Step 4: Run the test**

Run: `mix test test/portal_web/request_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/portal/lib/portal_web/live/request_live.ex apps/portal/test/portal_web/request_live_test.exs
git commit -m "feat(portal): Beacon request status with build stepper + live log"
```

---

### Task 7: Re-skin request_scan page

**Files:**
- Modify: `apps/portal/lib/portal_web/controllers/page_html/request_scan.html.heex` (the page wrapper + intro `<section>`; lines ~3-17 and the `max-w-4xl` container; do NOT touch the `<form data-package-picker>` internals, the device-code blocks, or the `<script>`)
- Test: `apps/portal/test/portal_web/controllers/page_controller_test.exs:14-20` (must still pass)

**Interfaces:**
- Consumes: `PortalWeb.UI.page_header`.
- Produces: identical strings/hooks; only the heading block + container width change to Beacon.

- [ ] **Step 1: Run the regression guard**

Run: `mix test test/portal_web/controllers/page_controller_test.exs:14`
Expected: PASS (current implementation).

- [ ] **Step 2: Replace the page wrapper + intro header**

Change the top of `request_scan.html.heex` from the bespoke `<main>` + intro block to the shared shell + header. Replace lines from `<main ...>` through the closing of the intro `<div class="max-w-3xl">...</div>` (the block containing the `<p class="text-sm font-semibold text-primary">Queue priority requests</p>` heading) with:

```heex
<Layouts.flash_group flash={@flash} />

<main class="min-h-screen bg-base-100 text-base-content">
  <.site_nav active={:request_scan} current_user={@current_user} />

  <div class="mx-auto max-w-4xl px-4 py-10 sm:px-6 lg:px-8">
    <section class="space-y-8">
      <PortalWeb.UI.page_header kicker="Queue priority requests" title="Request scans for packages">
        <:subtitle>
          Add one or more Hex.pm packages, choose how ownership should be verified, and move accepted requests near the top of the compatibility scan queue.
        </:subtitle>
      </PortalWeb.UI.page_header>
```

Then ensure the existing `<section class="card ...">` (the form card) and everything after it remain unchanged, and that the original `<section class="py-8">` opening tag this replaced is removed so tags still balance. Keep the closing `</section>`, `</div>`, `</main>` at the end intact.

- [ ] **Step 3: Run the full page_controller test + format check**

Run: `mix test test/portal_web/controllers/page_controller_test.exs`
Expected: PASS — all `request_scan` assertions (`Request scans for packages`, `Verify with Hex.pm`, `data-package-picker`, etc.) still hold.

- [ ] **Step 4: Commit**

```bash
git add apps/portal/lib/portal_web/controllers/page_html/request_scan.html.heex
git commit -m "style(portal): Beacon header + shell on request-scan (hooks untouched)"
```

---

### Task 8: Re-skin login + register pages

**Files:**
- Modify: `apps/portal/lib/portal_web/controllers/page_html/login.html.heex`
- Modify: `apps/portal/lib/portal_web/controllers/page_html/register.html.heex`
- Test: covered by existing `page_controller_test.exs` auth-menu assertions + a manual check.

**Interfaces:**
- Consumes: `PortalWeb.UI.page_header`. Keep daisyUI form classes (`input input-bordered`, `btn btn-primary`) — they are already theme-aware.

- [ ] **Step 1: Re-skin login.html.heex header + card**

Replace the intro `<h1 class="card-title text-2xl">Login</h1>` block with a Beacon header and keep the `<form method="post" action={~p"/login"}>` exactly as-is. Concretely, change the `<section class="card ...">`/`<div class="card-body ...">` wrapper to:

```heex
<Layouts.flash_group flash={@flash} />

<main class="min-h-screen bg-base-100 text-base-content">
  <.site_nav current_user={@current_user} />

  <div class="mx-auto max-w-md px-4 py-12 sm:px-6 lg:px-8">
    <div class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm">
      <PortalWeb.UI.page_header title="Sign in">
        <:subtitle>
          Use your portal account. Hex.pm owner verification still happens separately per package.
        </:subtitle>
      </PortalWeb.UI.page_header>

      <form method="post" action={~p"/login"} class="mt-6 space-y-4">
```

Keep the CSRF input, the two `label`/`input` fields, the submit button, and the "No account yet?" footer line unchanged; close the wrapper `</div></div></main>` correctly. Drop the now-unused `<div class="site-banner">...</div>` only if it remains visually redundant — otherwise leave it (it carries no test assertion).

- [ ] **Step 2: Apply the same treatment to register.html.heex**

Read `register.html.heex`, then mirror the Step 1 change: shared shell + `<.page_header title="Create account">` with its existing subtitle copy, keep the form + fields + CSRF + links verbatim.

- [ ] **Step 3: Verify auth-menu assertions + compile**

Run: `mix test test/portal_web/controllers/page_controller_test.exs:24`
Expected: PASS — `site-auth-menu`, `aria-label="Account menu"`, `site-auth-menu-item href="/login"`/`/register` still present (they live in `SiteNav`, untouched).

- [ ] **Step 4: Commit**

```bash
git add apps/portal/lib/portal_web/controllers/page_html/login.html.heex apps/portal/lib/portal_web/controllers/page_html/register.html.heex
git commit -m "style(portal): Beacon login + register"
```

---

### Task 9: Re-skin admin page

**Files:**
- Modify: `apps/portal/lib/portal_web/controllers/page_html/admin.html.heex` (intro header + the two stat tiles; keep both tables + forms + copy)
- Test: `apps/portal/test/portal_web/controllers/page_controller_test.exs` admin assertions (must still pass)

**Interfaces:**
- Consumes: `PortalWeb.UI.{page_header, stat_card, status_badge}`.

- [ ] **Step 1: Run the regression guard**

Run: `mix test test/portal_web/controllers/page_controller_test.exs:100`
Expected: PASS.

- [ ] **Step 2: Replace the intro header + stat tiles**

Replace the `<section class="py-8">` intro block (the `<p>Admin</p>` + `<h1>Scan request operations</h1>` + description) with the shared shell wrapper + header, and swap the two bespoke `rounded-box` count tiles for `stat_card`:

```heex
<Layouts.flash_group flash={@flash} />

<main class="min-h-screen bg-base-100 text-base-content">
  <.site_nav active={:admin} current_user={@current_user} />

  <div class="mx-auto max-w-5xl px-4 py-10 sm:px-6 lg:px-8">
    <section class="space-y-8">
      <PortalWeb.UI.page_header kicker="Admin" title="Scan request operations">
        <:subtitle>
          Review anonymous submissions and inspect accepted requests waiting for scanner processing.
        </:subtitle>
      </PortalWeb.UI.page_header>

      <div class="grid gap-3 sm:grid-cols-2">
        <PortalWeb.UI.stat_card label="Needs review" value={to_string(length(@pending_anonymous_requests))} />
        <PortalWeb.UI.stat_card label="Current queue" value={to_string(length(@queue_requests))} />
      </div>
```

Keep both `<section class="card ...">` table blocks (Anonymous approvals + Current queue), their copy, forms, and buttons unchanged. Optionally replace the `<span class="badge badge-outline">{request_status_label(...)}</span>` cells with `<PortalWeb.UI.status_badge status={request_status_label(request.status)} />` only if `request_status_label/1` returns one of pass/fail/error/skipped; otherwise leave the daisyUI badge.

- [ ] **Step 3: Run admin tests + format**

Run: `mix test test/portal_web/controllers/page_controller_test.exs`
Expected: PASS — `Scan request operations`, `Anonymous approvals`, `Approve`, counts all present.

- [ ] **Step 4: Commit**

```bash
git add apps/portal/lib/portal_web/controllers/page_html/admin.html.heex
git commit -m "style(portal): Beacon admin dashboard"
```

---

### Task 10: Full verification (light + dark) + precommit

**Files:** none (verification only).

- [ ] **Step 1: Run the whole portal test suite**

Run: `mix test`
Expected: PASS, no warnings about undefined components.

- [ ] **Step 2: Run precommit**

Run: `mix precommit`
Expected: compile with `--warnings-as-errors` clean, `deps.unlock --unused` no-op, `format` clean, tests pass.

- [ ] **Step 3: Manual visual check (both themes)**

Run: `mix phx.server`, then visit each route and toggle the theme (system/light/dark) via the nav toggle:
- `/` (browser), `/packages/<name>` (detail), `/requests/<id>` (status), `/request-scan`, `/login`, `/register`, `/admin`.
Expected: consistent Beacon look; no hardcoded-white panels in dark mode; nav, cards, badges, tables, the stepper, and the log panel all legible in light AND dark. The theme toggle now works on the LiveViews (previously broken).

- [ ] **Step 4: Confirm Oban Web still readable**

Visit `/admin/oban`. Expected: dashboard unaffected (daisyUI token tweaks shouldn't break it). If the orange primary harms contrast there, it is third-party styling — note it, don't fix in this pass.

- [ ] **Step 5: Run umbrella-wide tests from repo root**

Run (from repo root): `mix test`
Expected: PASS across the umbrella. The Docker integration test stays excluded (it is `:integration`, no worker/contract change here).

- [ ] **Step 6: Final commit (if any formatting changed)**

```bash
git add -A apps/portal
git commit -m "chore(portal): finalize Beacon UI pass"
```

---

## Self-Review

**Spec coverage:**
- Tokens (light+dark, status palette) → Task 1 + status classes in Task 2. ✓
- App shell unification + delete Phoenix navbar + dead home → Task 3. ✓
- Shared components (page_header, stat_card, status_badge, system_bar, package_card) → Task 2. ✓
- Rebuild index/package/request → Tasks 4/5/6. ✓
- Re-skin request_scan/login/register/admin → Tasks 7/8/9. ✓
- Verify light+dark + precommit → Task 10. ✓
- Non-goals respected: no API/badge/schema/worker edits in any task. ✓

**Placeholder scan:** Two intentional "match the real value" notes remain (RequestLive status enum in Task 6; `request_status_label` branch in Task 9) — these are explicit lookups against existing code, not vague TODOs; each names the exact file to grep and the mapping rule. Acceptable.

**Type consistency:** `status_pill_class/1` and `status_segment_class/1` defined in Task 2 are the only color sources, reused in Tasks 4/5. `Layouts.app/1` attrs `active`/`current_user` defined in Task 3 are consumed in Tasks 4/5/6. `page_header` slots `subtitle`/`actions` consistent across all consumers. `system_bar` attr is `statuses` everywhere. ✓
