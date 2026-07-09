# Static-Site Port — Phase 1a Design

**Date:** 2026-07-08
**Status:** Approved (direction + scope)
**Scope:** Re-implement the prod static site's **shell + three read-only pages**
(Dashboard, Failure clusters, Stats) in the dynamic Phoenix app, in **Tailwind**
(keep the current stack; match prod's *structure* — sections, cards, tables,
columns — not its raw CSS), backed by the existing Catalog plus small ported
helpers and one query extension.

**References:**
- Port map: `docs/superpowers/static-site-port-map.md`
- Recovered CSS (structure reference only, not adopted): `docs/superpowers/static-site.css`
- Old generator source (for exact pure-function bodies): git ref `e162454`,
  `git show e162454:site/lib/site/<file>.ex`.

## Goal

Move the dynamic app's look toward the prod static site, starting with the three
data-backed read-only pages, and establish the shared nav/route structure the rest
of the port hangs on. This replaces the Beacon dashboard with prod's richer index and
adds the two currently-missing pages.

## Context

- Prod is a static site; its design is prod's own structure over ~1000 lines of custom
  CSS. We keep Tailwind/daisyUI and re-create the *structure* with utilities.
- The dynamic Catalog already exposes: `latest_by_pkg_json/1`, `stats_json/0`,
  `failure_clusters/1`, `pass_rate_per_system/0`, `native_breakdown/0`,
  `recent_runs/2`, `latest_system_results/1`, `precompiled_manifest/1`.
- Routes today: `/` → `DashboardLive` (Beacon), `/packages` → `IndexLive`,
  `/request-scan`, `/requests/:id`, `/admin`. **No** `/failure_clusters`, `/warnings`,
  `/stats`.
- `Portal.Accounts.admin?/1`, `SiteNav`, `Layouts.app`, and the `:public` `live_session`
  (assigns `current_user`) all exist and are reused.

## Decisions (locked)

- **Phase 1a only:** Dashboard, Failure clusters, Stats. Packages-list-with-filters is
  Phase 1b; Warnings + BEAM-aggregate stats + package-detail are later phases.
- **Tailwind** re-implementation (no raw-CSS adoption).
- Warnings appears in the nav (parity) but links to a **stub** page ("coming soon")
  until Phase 3 — no dead link, no rule engine yet.
- Reuse existing Catalog queries; extend only `failure_clusters/1` (needs richer
  per-cluster data for its page).

## Architecture

### 1. Shared helpers (`Portal.Catalog` + a small view-helper module)

Pure functions ported from the old generator (recover exact bodies from
`e162454:site/lib/site/*.ex`), placed in a new `Portal.Catalog.Rollup` module (pure,
no DB) unless noted:

- `overall_status(system_statuses :: [atom|string]) :: :pass | :fail | :partial | :skipped | :unknown`
  — package-level rollup. Semantics from old `get_overall_status/1`: any `error`/`fail`
  ⇒ `:fail`; else if all `pass` ⇒ `:pass`; a mix of pass + skipped ⇒ `:partial`; all
  skipped ⇒ `:skipped`; else `:unknown`. (Confirm exact rule against the recovered
  source and encode it verbatim.)
- `native_bucket(package) :: String.t()` — ported `native_code_bucket/1`
  (`rust`/`zig`/`c`/`language unknown`/`none`/`not scanned`), from
  `Package.native_components` + `SystemResult.beam_scan.flags.nif` + the all-skipped
  ("not scanned") case. From `e162454:site/lib/site/generator.ex`.
- `Portal.Catalog.Architecture.label(system_pkg) :: String.t()` — verbatim port of
  `e162454:site/lib/site/architecture.ex` (its `@system_to_arch` map + the
  `nerves_system_`-strip fallback).

New Catalog aggregate:

- `Catalog.package_status_counts() :: %{unique: n, pass: n, fail: n, partial: n, skipped: n, unknown: n, total_versions: n}`
  — one bucket per package via `overall_status/1` over its latest run's systems.
  `unique` = package count; `pass`/`fail`(=fail+error at system level rolled up)/etc.
  Built from `latest_annotated_systems/0` grouped by package.

### 2. Extend `Catalog.failure_clusters/1`

Current returns `%{category, systems, packages}`. Extend to:

```
%{category, title, hint, systems, packages,
  entries: [%{package, version, arch_label, nif_language, detail}],
  sample_log: String.t() | nil}
```

- `title`/`hint`: static text per `failure_category`, ported from the old
  `Site.FailureCluster` (`e162454:site/lib/site/failure_cluster.ex`) category→hint map.
  (Our `failure_category` values were chosen to match those categories; map each to its
  title/hint, with a fallback for unknown.)
- `entries`: the affected `{package, version, arch_label, nif_language, detail}` per
  failing system in the cluster (join package + `Architecture.label` + native_components).
- `sample_log`: the shortest `log_tail` among the cluster's systems, last ~40 lines
  (ported picking logic). Requires `log_tail` (already persisted) on the annotated rows —
  extend `latest_annotated_systems/0` to carry `log_tail`, `version`, `nif_language`.

### 3. Routes + nav

- `router.ex` (inside `:public` `live_session`): add
  `live "/failure_clusters", FailureClustersLive, :index`,
  `live "/stats", StatsLive, :index`, and `live "/warnings", WarningsLive, :index`
  (stub). `/` stays `DashboardLive` (rebuilt), `/packages` stays `IndexLive`.
- `SiteNav`: links Dashboard `/` · Packages `/packages` · Failure clusters
  `/failure_clusters` · Warnings `/warnings` · Stats `/stats` · Request scan (+ admin/oban
  gated). Active-state atoms per page.

### 4. Pages (Tailwind, prod structure)

- **`DashboardLive`** (`/`, rebuilt) — prod index structure:
  - Summary: 3 cards (Unique Packages / Passing / Failing) from
    `package_status_counts/0`; Failing card links `/packages?status=fail` (query honored
    in Phase 1b).
  - Tile grid (each shown only if non-empty): Top failure clusters (top 3 from extended
    `failure_clusters/1`), Native code (stacked bar + legend from `native_breakdown/0`),
    Pass rate per system (`pass_rate_per_system/0`).
  - Two lists: Recently checked passing / failing (10 each, `recent_runs/2`), rows
    `name@version` → `/packages/:name`.
  - Footer: "Last test run: {stats_json.last_run_finished_at}".
- **`FailureClustersLive`** (`/failure_clusters`) — intro + empty-state + a card per
  cluster: title, `count · packages`, hint, language mini-list, `<details>` affected
  packages (linked), `<pre>` sample log.
- **`StatsLive`** (`/stats`) — Overall Statistics cards (from `package_status_counts/0`
  with %s) + "Statistics by System" table (Architecture | Nerves system | Total | Pass |
  Fail | Error | Skipped) from `stats_json().by_system`, `forced@` rows filtered,
  `Architecture.label` applied. (BEAM-scanner stats section deferred to Phase 3.)
- **`WarningsLive`** (`/warnings`) — stub: intro + "Warnings analysis coming soon"
  empty-state. Real rules in Phase 3.

Each page uses `Layouts.app` + `SiteNav`; sections/cards/tables are Tailwind, matching
prod's column order and grouping. Beacon `PortalWeb.UI` components reused where they fit
(stat cards, status pills), restyled toward prod density as needed.

## Testing

- `Portal.Catalog.Rollup.overall_status/1` + `native_bucket/1` + `Architecture.label/1`
  — unit tests: representative inputs → expected buckets/labels (incl. `forced`,
  all-skipped, mixed).
- `Catalog.package_status_counts/0` + extended `failure_clusters/1` — seed a couple runs
  (pass + a failing system with a known `failure_category` + `log_tail`), assert counts
  and the cluster's `entries`/`sample_log`/`title`.
- `DashboardLive` / `FailureClustersLive` / `StatsLive` — render tests: each page's
  section headings + one data row with seeded data; empty states with no data;
  `WarningsLive` renders its stub.
- Regression: `/packages` (`IndexLive`) unchanged (its tests still pass); nav renders the
  5 links; existing `catalog_live_test` + dashboard tests updated to the rebuilt dashboard
  headings.
- `mix precommit` + umbrella `mix test` green.

## Non-goals (Phase 1a)

- No packages-list filters/pagination (Phase 1b), no package-detail changes, no Warnings
  rules, no BEAM-aggregate stats.
- No worker/`result.json`/Docker change; no JSON API/badge/Oban change.
- No raw-CSS adoption; no removal of Tailwind/daisyUI.
- No new ingested fields (determinism/deps/source_changes/github_url are later phases).

## Risks / notes

- `failure_category` → title/hint parity: our ingestion categories were chosen to match
  the old `Site.FailureCluster` set; if any diverge, the mapping falls back to the raw
  category string as the title with a generic hint. Confirm the category set during the
  query extension.
- The rebuilt `DashboardLive` replaces the Beacon dashboard; its existing test assertions
  (5 Beacon headings) change to the prod-structure headings — update them, don't keep both.
- `stats_json().by_system` keys are `"<system_pkg>@<system_version>"`; the table groups by
  `system_pkg` via `Architecture.label` — apply the split view-side.
