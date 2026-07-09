# Beacon UI Pass — Design

**Date:** 2026-06-22
**Status:** Approved (direction + scope)
**Scope:** Portal web UI — full sweep (public + auth + admin)
**Mockups:** `docs/ui-mockups/{index,a-beacon,b-console,c-workshop}.html`

## Goal

Unify the portal's clashing UI layers into one coherent design system —
**"Beacon"**: clean technical, Hex.pm-grade, Nerves-orange accent, light + dark.

## Problem (current state)

Two disconnected layout families:

| Family | Pages | State |
| --- | --- | --- |
| `Layouts.app` (Phoenix default navbar + hardcoded `zinc-*`) | `IndexLive`, `PackageLive`, `RequestLive` | Light-only, ignores theme toggle, stock Phoenix branding ("Get Started", phoenix version, phoenix logo) |
| `SiteNav` + `bg-base-100` shell (daisyUI semantic tokens) | `request_scan`, `login`, `register`, `admin` | Theme-aware, correctly branded, decent — but visually unrelated to the LiveViews |

Consequences: dark mode broken on the highest-traffic pages; brand inconsistent;
duplicate nav concepts; `page_html/home.html.heex` is dead (not routed — `/` is `IndexLive`).

## Direction: Beacon

Selected from an A/B/C comparison. Beacon = clean technical:

- **Accent:** Nerves orange `#FD4F00`. Maps onto daisyUI `--color-primary`, which in
  the **light** theme is *already* orange (`oklch(70% 0.213 47.604)`). Dark theme accent
  decision deferred to implementation (keep Elixir purple vs. shift orange).
- **Neutrals:** zinc scale via daisyUI `base-*` tokens (already configured).
- **Status palette (theme-aware):** pass = emerald, fail = orange, error = red,
  skipped = zinc. Exposed as utility classes, never hardcoded per-page.
- **Shape language:** `rounded-2xl` cards, soft shadows, generous whitespace,
  Inter (sans) + mono for versions/IDs.

## Architecture

### 1. Theme tokens (`apps/portal/assets/css/app.css`)

Tune the existing daisyUI light + dark theme blocks to the Beacon palette. Add a small
set of theme-aware status classes (e.g. `.status-pass`, `.status-fail`, `.status-error`,
`.status-skip`) with light + dark variants, so status color lives in one place.

### 2. App shell (one layout for everything)

Replace the two families with a single shell. `SiteNav` (already the correct
"Nerves Compatibility" nav) folds into a shared `app_shell` component:

- LiveViews call it via `Layouts.app` (rewritten to render `SiteNav` + main, Phoenix
  navbar deleted).
- Controller templates keep using `SiteNav` through the same shell markup.
- Delete dead `page_html/home.html.heex`.

Boundary: the shell owns nav + flash + max-width main + theme toggle. Pages own only
their content. Changing the shell never requires touching a page.

### 3. Shared components (new module, e.g. `PortalWeb.UI` or extend `CoreComponents`)

Reusable function components — each one purpose, used across LiveViews and controllers:

| Component | Purpose | Used by |
| --- | --- | --- |
| `<.page_header>` | kicker + title + subtitle + optional action slot | all pages |
| `<.stat_card>` | label + value tile | index, package, admin |
| `<.status_badge status=>` | colored pill from a status atom/string | package, request, index, admin |
| `<.package_card>` | package name + desc + version + aggregate status + system bar | index |
| `<.system_bar systems=>` | 6-segment per-system pass/fail strip | index card, package detail |

These replace ad-hoc markup and the inline `status_class/1` in `PackageLive`.

### 4. Page rebuilds (Beacon, theme-aware)

- **`IndexLive`** — hero + `<.page_header>`, stat strip, search, package grid of
  `<.package_card>`. Drop all hardcoded `zinc-*` → semantic tokens.
- **`PackageLive`** — `<.page_header>` with badge, stat cards, per-system results table
  using `<.status_badge>`; replace local `status_class/1`.
- **`RequestLive`** — `<.page_header>`, status/version/source stat cards,
  live progress panel; theme-aware (no `bg-zinc-950` pre block — use a token surface).

### 5. Re-skin controller pages (light touch — already token-based)

- **`request_scan`**, **`login`/`register`**, **`admin`** — swap bespoke cards/headers
  for the shared `<.page_header>` / `<.stat_card>` / `<.status_badge>` so spacing,
  radius, and typography match the LiveViews. Preserve all existing JS hooks
  (package picker, hex/github device-code flow) and form actions verbatim.

## Non-goals (YAGNI)

- No new routes or features. No data/schema changes.
- No change to the JSON API, badge SVG, or Oban Web dashboard styling.
- No new font/icon dependencies beyond what ships (heroicons, daisyUI, Inter if already present).

## Testing / verification

- Existing controller/LiveView tests must still pass (`mix test`).
- Manual: every page in **light and dark**, plus the system theme. Theme toggle works
  on LiveViews (currently it doesn't).
- `cd apps/portal && mix precommit` (compile --warnings-as-errors, format, test).
- Integration test untouched (no worker/contract changes), but run `mix test` umbrella-wide.

## Risk notes

- daisyUI token edits are global — verify Oban Web at `/admin/oban` and forms still read well.
- Preserve `request_scan` inline `<script>` and all `data-*` hooks; they drive the
  device-code auth flow. Re-skin markup around them, don't rewrite them.
- Keep worker exit-code / contract code paths untouched (UI-only change).
