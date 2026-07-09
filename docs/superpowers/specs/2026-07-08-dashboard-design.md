# Dashboard (dynamic app) — Design

**Date:** 2026-07-08
**Status:** Approved (direction + scope)
**Scope:** Portal dynamic app — new Dashboard at `/` with 5 summary sections, backed by new Catalog queries, a failure classifier, and native-code persistence.

## Goal

Give the dynamic Phoenix app a Dashboard matching (and modernizing) the prod static
site's landing page: **Top failure clusters**, **Pass rate per system**, **Native
code**, **Recently Checked Passing Packages**, **Recently Checked Failing Packages**.

## Context

- Prod (`compatibility.embedded-elixir.com`) is a **static** site whose dashboard
  already shows failure clusters, summary stats, etc. Its classification logic lived
  in the now-removed static generator.
- This branch (`dynamic_site`) is the Phoenix rewrite. Its `/` is currently just the
  package browser (`IndexLive`, Beacon-styled). No dashboard, no failure
  classification, no persisted native-code data.
- The worker (`apps/ncc_worker`) already produces the raw inputs we need:
  - per-system `log_tail` (String) and `error` (String|nil) in `result.json`
  - `NccWorker.NativeLang` writes `result.package.native_components`
    (`nif_language`, `port_languages`).
  Ingestion currently **ignores** all three.
- Catalog data model: `Package` (name, description, latest_version, last_run_at),
  `Run` (overall_status, finished_at [indexed], version_tested, footprint),
  `SystemResult` (system_pkg, status, firmware_size_bytes, beam_scan,
  dependency_scans, log_path; indexed on `[system_pkg, status]`).

## Decisions (locked)

- **Placement:** `/` becomes the Dashboard; the package browser moves to `/packages`.
- **Failure clusters:** full log-based classification, **portal-side at ingestion**,
  storing a category on each non-pass `SystemResult`.
- **Native code:** persist the worker's `native_components` into `Package`; render a
  breakdown section.
- **Backfill:** classify new runs at ingestion; a `mix portal.reclassify` task
  re-derives categories for already-stored runs (works because we persist `log_tail`).

## Architecture

### 1. Schema (Ash resources + generated migrations)

- `Portal.Catalog.SystemResult`:
  - add `failure_category :string` (nullable; set for non-pass systems)
  - add `log_tail :string` (nullable; persisted so classification is reproducible and
    `mix portal.reclassify` can re-derive without re-running builds)
- `Portal.Catalog.Package`:
  - add `native_components :map` (nullable; `%{"nif_language" => ..., "port_languages" => [...]}`)

Migrations generated via the project's Ash migration workflow (`mix ash.codegen` /
`mix ecto.migrate`).

### 2. Failure classifier (`Portal.Catalog.FailureClassifier`)

- `classify(sys_map) :: String.t() | nil` — returns `nil` when status is pass/skipped,
  otherwise a category string. Input: the per-system map (`status`, `log_tail`,
  `error`, `beam_scan`).
- Ordered rule list (first match wins), each rule a `{category, matcher}` where matcher
  is a regex/substring over `log_tail <> "\n" <> (error || "")`:
  1. `"NIF built for wrong architecture"` — e.g. `wrong ELF class`, `cannot execute binary file`, arch-mismatch signatures
  2. `"Precompiled NIF missing for target"` — `could not find` / `no precompiled` NIF/artifact signatures
  3. `"Dependency resolution failed"` — Hex/`mix deps.get`/lock resolution errors
  4. `"Compilation error"` — `(CompileError)` / `** (` / `error: ` compile signatures
  5. `"Other / unclassified"` — fallback for any non-pass with no rule match
- Pure module, no DB. Fully unit-testable with representative log snippets.
- Rules are data (a module attribute list) so new signatures are cheap to add.

### 3. Ingestion changes (`Portal.Catalog.Ingestion`)

- `create_system_result/*`: store `log_tail` from `sys["log_tail"]` and set
  `failure_category = FailureClassifier.classify(sys)`.
- `upsert_package/*`: persist `native_components` from
  `result["package"]["native_components"]` (nil-safe).
- No change to run/artifact handling, exit-code mapping, or the worker contract.

### 4. Catalog query API (`Portal.Catalog`)

New read functions, each returning plain maps/lists (no Ash structs leaking to the web
layer), each independently testable:

- `pass_rate_per_system() :: [%{system_pkg, pass, total, rate}]`
  — from latest `SystemResult` per package/system, grouped by `system_pkg`.
- `recent_runs(status, limit) :: [%{package, version, finished_at, overall_status}]`
  — `status` in `[:pass, :fail]` (fail groups fail+error); order by `finished_at` desc.
- `failure_clusters(limit) :: [%{category, systems, packages}]`
  — non-pass `SystemResult` grouped by `failure_category`; counts of occurrences and
    distinct packages; ordered desc.
- `native_breakdown() :: [%{language, packages}]`
  — packages grouped by `native_components.nif_language` (+ port languages), plus a
    "pure Elixir / none" bucket.

"Latest per package" reuses the same run-selection logic `latest_by_pkg_json/1`
already applies, factored into a shared private helper if needed (targeted improvement,
not a broad refactor).

### 5. Web layer

- `PortalWeb.DashboardLive` at `/` — renders the 5 sections using Beacon components
  (`page_header`, `stat_card`, `status_badge`, tables). Each section is a small
  function component fed by one Catalog query. Empty-state per section when no data.
- Move `PortalWeb.IndexLive` (package browser) to `/packages`. Keep its behavior and
  the regression-critical test hooks (`package-<name>` dom id, `search` event); only
  the route changes.
- `PortalWeb.SiteNav`: Dashboard (`/`) + Packages (`/packages`) links, active states.
- `PortalWeb.Router`: `/` → DashboardLive, `/packages` → IndexLive, both inside the
  existing `:public` `live_session`.

### 6. Reclassify task (`mix portal.reclassify`)

- Loads every `SystemResult` with a stored `log_tail`, re-runs
  `FailureClassifier.classify/1` over a reconstructed per-system map, and updates
  `failure_category`. Idempotent. Reports counts per category.

## Testing

- `FailureClassifier` — unit tests: one representative `log_tail` per category maps to
  the right string; pass/skipped → `nil`; unknown → `"Other / unclassified"`.
- Ingestion — a fixture result with a failing system + `native_components` produces a
  `failure_category`, a persisted `log_tail`, and `Package.native_components`.
- Catalog queries — seed a few runs, assert each of the 4 functions returns the
  expected shape/order.
- DashboardLive — renders all 5 section headings; renders empty states with no data;
  renders a cluster row + a recent-pass row with seeded data.
- IndexLive move — existing `catalog_live_test` retargeted to `/packages`, hooks intact.
- `mix precommit` (compile --warnings-as-errors, format, test) green; umbrella `mix test` green.

## Non-goals (YAGNI)

- No worker/Docker/`result.json` contract change (classification is portal-side).
- No change to the static prod site, JSON API schema, badge, precompiled API, or Oban.
- No auto-backfill migration (the mix task covers reclassification on demand).
- No new charting library — sections are tables/bars with Beacon/Tailwind.

## Risks / notes

- Classifier rules start coarse; `"Other / unclassified"` is expected to be sizable
  until rules mature. The ordered ruleset + reclassify task make refinement cheap.
- Persisting `log_tail` (~4 KB/system) is a deliberate storage cost for reproducible
  classification and the reclassify path.
- Moving `/` → `/packages` changes an existing route; update every internal link
  (`~p"/"` that meant the browser) and the retargeted test.
