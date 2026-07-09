# Static Site → Dynamic Portal Port Map

Source: deleted `site/` static generator, recovered from git ref `e162454`
(`git show e162454:<path>`). Read but not checked out. CSS recovered
verbatim to `docs/superpowers/static-site.css`.

Old app: `site/lib/site/{generator,nav,failure_cluster,warning_cluster,
architecture,badge}.ex` + `site/priv/templates/*.html.eex`, driven by
`Mix.Tasks.Site.Gen` reading JSON index files
(`latest_by_pkg.json`, `packages_by_version.json`, `stats.json`) and writing
static HTML into `output_dir/site/`.

Current app: `apps/portal/lib/portal/catalog.ex` (Ash domain) backed by
Postgres (`Package`, `Run`, `SystemResult`, `Artifact`, `PackageOverride`).

---

## Nav structure

`Site.Nav` (`site/lib/site/nav.ex`) rendered one shared nav bar into every
page via `Site.Nav.render(current_page_atom, prefix)`. Links (absolute
paths):

| id | Label | Href (old) | Current dynamic route |
| --- | --- | --- | --- |
| `:home` | Dashboard | `/site/index.html` | `/` (`DashboardLive`) |
| `:packages` | Packages | `/site/packages.html` | `/packages` (`IndexLive`) — simpler, no filters yet |
| `:request_scan` | Request scan | `/request-scan` | `/request-scan` (`PageController.request_scan`) — exists |
| `:clusters` | Failure clusters | `/site/failure_clusters.html` | **no route** |
| `:warnings` | Warnings | `/site/warnings.html` | **no route** |
| `:stats` | Stats | `/site/stats.html` | **no route** |

Nav also rendered: theme toggle (system/light/dark, localStorage
`phx:theme`, `data-theme` attr on `<html>`), an "Experimental" banner, and
auth links (Login/Register avatar). All of this is pure chrome — no data
dependency, straightforward to port into the current `Layouts.app`
component if not already equivalent (`apps/portal/lib/portal_web/components/site_nav.ex`
already exists and should be diffed against this for parity, but that's a
separate task from this doc).

Render mode: **all six pages were static-render** (Elixir builds one HTML
string per page, no client-side framework beyond vanilla JS). Two pages
embed non-trivial client-side JS "app" behavior that needs decision-making
when porting to LiveView vs. keeping as plain JS:

- **`packages.html`** — full client-side table: search input, Status
  filter, Native-code filter, Sort dropdown, pagination (50/page), all
  driven by a JSON blob (`@rows_json`, `@placeholders_json`) baked into the
  page and manipulated by inline `<script>`. URL query params
  (`?status=fail` etc.) sync bidirectionally. **This needs either a
  LiveView with `phx-change`/`assign`-driven filtering, or keeping the
  client-side JS approach reading from an API endpoint** — worth an
  explicit design decision, noted here rather than assumed.
- **`index.html`** — has a *dead* client-side search script (the comment
  in the code says search moved to `packages.html`; the `#package-search`
  element doesn't exist on this page anymore, so the script no-ops). Do
  not port the search JS from `index.html.eex` — it's vestigial.
- **`request_scan.html`** — form + fetch() calls to
  `/api/scan-requests`, `/api/auth/hex/start`, `/api/auth/hex/complete`,
  `/api/auth/github/*`. Current Portal already has a `RequestLive` and
  `PageController` auth actions — this template's JS is superseded by
  whatever `/request-scan` (`PageController.request_scan`) currently does;
  not a straight port target, just useful for UX parity reference (queue
  priority panel copy, Turnstile slot placeholder, status message copy).

---

## Page: Dashboard / Index (`index.html.eex`)

### Structure
1. `<section class="summary-section">` — Summary
   - 3 summary cards: Unique Packages Tested / Passing Packages / Failing
     Packages (fail+error), the failing card links to
     `packages.html?status=fail`.
   - `.tile-grid` (3 optional tiles, shown only if non-empty):
     - **Top failure clusters** tile: top 3 clusters (title, count, `count
       / unique_packages pkg`), link to `failure_clusters.html`.
     - **Native code** tile: stacked bar + legend, `language: count (pct%)`
       per bucket (rust/zig/c/language unknown/none/not scanned).
     - **Pass rate per system** tile: per-system progress bar,
       `pass/total · pct%`.
   - Two "top lists" (no table, just linked rows): **Recently Checked
     Passing Packages** (10) / **Recently Checked Failing Packages** (10),
     each row `name@version` linking to `packages/<safe_key>.html`.
2. `<footer>`: "Last test run: X · Site updated: Y".

No tables on this page (cards/lists only).

### Data needed → Backing

| Data | Backing |
| --- | --- |
| Total unique packages | **GAP**: `Catalog.stats_json().counts` counts `SystemResult` rows, not unique packages. Need a package-level aggregate (1 row per package, bucketed by *overall* status) — old semantics: package counted once under `pass`/`fail`/`error`/etc. based on `get_overall_status/1` (any fail/error among systems ⇒ fail; else pass if any pass). |
| Passing / Failing package counts | Same GAP as above — needs per-package overall-status rollup, not per-`SystemResult` counts. |
| Top 3 failure clusters (title, count, unique_packages) | `Catalog.failure_clusters/1` — **exists**, groups by `failure_category` (pre-computed at ingestion, unlike old site's regex-at-render-time `Site.FailureCluster`). Verify field names match (`title`/`count`/`unique_packages` vs whatever `failure_clusters/1` actually returns — read its impl before wiring). |
| Native code breakdown (language → count) | **GAP** — old `Site.Generator.native_code_distribution/1` (in deleted `generator.ex`) computed this from `Package.native_components` + `beam_scan.flags.nif`. `Catalog.native_breakdown/0` **exists** and looks like the direct replacement (returns `%{language:, packages:}` list) — verify bucket names match the old `native_colors` map (`rust`/`zig`/`c`/`language unknown`/`none`/`not scanned`). |
| Pass rate per system | `Catalog.pass_rate_per_system/0` — **exists**, matches shape needed (`system_pkg`, `pass`, `total`, `rate`). |
| Recently checked passing/failing (10 each, by `last_run_at` desc) | `Catalog.recent_runs(:pass, 10)` / `Catalog.recent_runs(status, 10)` for fail — **exists**, but old site sorted by *package* `last_run_at` and needed `pkg_key = name@version`; verify `recent_runs/2` returns enough (name, version, link) — from the read code it returns `package:`, `version:`, likely also status/finished_at. Confirm field names before reuse. |
| Last test run timestamp / site generated_at | `Catalog.stats_json().last_run_finished_at`; `generated_at` has no dynamic-site equivalent (was "site build time" — meaningless for a live app; drop or replace with "now"). |

### Notes
- Old computes `avg_target_footprint/1` per package (mean of per-system
  `total_bytes`, excluding host) — used elsewhere (packages list), not on
  this page directly.
- The 3 optional tiles are conditionally rendered only when their data
  list is non-empty — preserve that (no empty-state chrome on dashboard).

---

## Page: Packages list (`packages.html.eex`)

### Structure
Single table, **client-side rendered from a JSON blob** (no server-side
table markup in the `.eex` beyond containers) — columns (from
`rowHtml`/thead in the JS):

| # | Header | Source field |
| - | --- | --- |
| 1 | Package | `name` (+ `@version`), links to `packages/<filename>` |
| 2 | Overall | `overall` (pass/fail/partial/skipped/unknown) |
| 3 | Systems | `systems[]` → chips `{status, short}` |
| 4 | Native | `native` bucket (rust/zig/c/language unknown/none/not scanned) |
| 5 | Avg footprint | `avg_footprint_bytes`, right-aligned, humanized |
| 6 | Last scan | `last_run_at` (date only) |

Filters (all client-side, URL-synced via `?q=&status=&native=&sort=`):
Search (name substring), **Status** select (all/pass/fail/partial/
skipped/unknown), **Native code** select (all/any/none/rust/zig/c/language
unknown), **Sort** select (name/recent/status/footprint-desc/
footprint-asc). Pagination: 50/page, prev/next.

Placeholder packages (queued-but-unscanned deps discovered via other
packages' `dependencies`) appear as extra un-filterable-by-native rows at
the tail, `overall = "not scanned"`.

### Data needed → Backing

| Data | Backing |
| --- | --- |
| Per-package row: name, version, overall status, per-system status chips, native bucket, avg footprint, last_run_at | `Catalog.latest_by_pkg_json/1` gives name/version/native_components/last_run_at/systems map — **mostly backed**, but `overall` (pass/fail/**partial**/skipped/unknown — a 5-way bucket distinct from any single system's status) and `native` bucket string and `avg_footprint_bytes` are **GAP**: computed client-side/generator-side in old code (`get_overall_status/1`, `native_code_bucket_for_row/1`, `avg_target_footprint/1`) from raw data Catalog *does* expose (systems statuses, `native_components`, `Run.footprint`) — need equivalent Elixir helpers in Portal, not new Catalog reads. |
| Placeholder (queued, unscanned) rows | Portal has this concept already via `ScanRequests.queue_requests()` (see `IndexLive.placeholder_entries/2`) — **exists**, reuse. |
| Status/Native/Sort filtering + pagination + URL sync | **New UI work**, not a data gap — current `/packages` (`IndexLive`) only has search, no status/native/sort filters, no pagination. Decide LiveView-driven (server dispatches filtered `stream`) vs. keep client-side JSON-blob approach. |

### Notes
- `avg_footprint_bytes`: old computes mean of **per-system** `total_bytes`
  from `Run.footprint.per_system`, excluding `"host"`. `Catalog.Run` has a
  `footprint` map attribute — **verify its shape matches** `%{per_system:
  %{sys => %{total_bytes:, firmware_bytes:, file_count:}}}` before reuse;
  if so this is fully backed, just needs the averaging helper ported.
- `native` bucket logic (`native_code_bucket/1` in deleted `generator.ex`)
  is nontrivial: reads `beam_scan.flags.nif`, `native_components.nif_language`,
  `native_components.port_languages`, and has an `:excluded` case for
  packages where all systems are forced/skipped (→ displayed as "not
  scanned"). This whole function needs porting, backed by fields Catalog
  already stores (`Package.native_components`, `SystemResult.beam_scan`,
  `SystemResult.status`).

---

## Page: Package detail (`package.html.eex`)

Largest/most detailed page. Structure (top to bottom):

### 1. Header (purple banner)
- Package name @ version, hex.pm icon link, GitHub icon link (if
  `package.github_url`).
- Description.
- Overall status pill (`passing`/`partial`/`warning`/`unknown` — computed
  from pass/fail/error counts across systems) + "Report incorrect info"
  link (GitHub issue prefilled).
- "Found via dependency scan" banner if `package.is_dependency`.
- Meta pills: `nif_language`, each `port_language`, avg footprint, last
  scan date, "⚠ writes to source" if `package.source_changes`.
- System status chip strip: one chip per system (`arch_label`, status,
  optional log link), `title` = `system_pkg@system_version`.

### 2. `<details open>` "Dependencies & versions"
- **Tested Versions table** (only if >1 version): columns **Version |
  Status** (pass/fail/partial/unknown badges), current version bolded not
  linked, others link to `<safe_key>.html`.
- Version Tested (hex.pm link) / Last Test Run info row.
- **Compilation Determinism** badge (Deterministic/Non-deterministic/
  Unknown) computed from `sys.deterministic` across all systems; if any
  system non-deterministic, lists `determinism_changes` (path, change
  kind, hash_before/hash_after, system).
- **Runtime Dependencies (N) table**: columns **Package | Status |
  Requirement | Optional**, only `dep.runtime == true` deps shown; status
  looked up from `all_packages` map (pass/fail/partial/unknown/"not
  scanned"); banner if any runtime dep failed.

### 3. Package notes / admin override (conditional section)
- "⚠️ Administrative Status Override" box if `metadata.forced_status`.
- "📝 Package Notes" box if `metadata.notes`.

### 4. `<details>` "Beam scanner — runtime capability snapshot" (if
`package.beam_scan`)
- Header pills: scanned systems, languages, beam_count.
- Grid of 7 cards, one per flag: NIF usage / Shell-OS exec / Shell
  helpers / App config reads / OS env reads / Start callback / Halt
  calls — each shows Detected/Not detected chip + sample strings
  (`beam.samples[key]`) or start_modules for the start_callback card.
- Protocol chips: defined protocols, impls.
- Scan errors list (if any).

### 5. `<details>` "Dependency scans — transitive + OTP apps" (if
`dependency_scans` present)
- **Table**: columns **App | File Count | Size | Languages | NIF | OS
  exec | Shell | App env | OS env | Start callback** — one row per app in
  `dependency_scans` map (sorted by key), Yes/No badges for flag columns.

### 6. `<details>` "System compatibility — detailed table"
- **Table**: columns **System | Status | Version Tested | Footprint (this
  system) | Log**. Version Tested is a hex.pm link to
  `@package_name/sys_result.hex_version_tested`. Footprint cell shows
  `file_count` files + `total_bytes` (+ `firmware_bytes` if present) from
  `package.footprint.per_system[system_pkg]`, or "N/A" for host / non-pass.
  Log column links to `../../data/<log_path>`.
- Disclaimer box (static copy about what "passing" means) + report-issue
  link.

### Data needed → Backing

| Data | Backing |
| --- | --- |
| name/version/description | `Package.name`, `Run.version_tested`, `Package.description` — backed |
| `github_url` | **GAP** — no field on `Package`. Was in old package_metadata / Hex API enrichment. |
| `is_dependency` (synthesized-from-deps flag) | **GAP** — no equivalent flag on `Package`. |
| Overall status (passing/partial/warning/unknown) | Computable client-side from `SystemResult.status` per system (same as index/packages pages) — no new data needed, just the shared helper. |
| `native_components.nif_language`, `.port_languages` | `Package.native_components` — backed. |
| Avg footprint | Same GAP as packages-list page (needs `Run.footprint.per_system` averaging helper). |
| `last_run_at` | `Package.last_run_at` — backed. |
| `source_changes` (writes-to-source flag + sample paths) | **GAP** — no field on `Package` or `SystemResult`. Was package-level in old index (`pkg.source_changes.changed/added/modified`). |
| System status chips (per-system status, `system_pkg`, `system_version`, log link) | `SystemResult.{status, system_pkg, system_version, log_path}` — backed. Architecture label needs `Site.Architecture.label/1` ported (pure function, no data dep — trivial port). |
| All-versions-of-package list + status per version | **GAP**: needs a query for all `Run`s (or latest-per-version) of a package name, not just the latest — Catalog currently only exposes *latest* run per package (`latest_runs/1` picks one). Need a "runs by package, one per version" query. |
| Runtime dependency list + per-dep requirement/optional + resolved status | **GAP**: no `dependencies` field (name/requirement/runtime/optional) stored anywhere in `Package`/`Run`/`SystemResult`. Old data came from the worker's `result.json` `package.dependencies`. Not currently ingested into Catalog at all — needs new column + ingestion change, or confirm it's inside `dependency_scans`/`beam_scan` map and just needs extraction. |
| `sys.deterministic` + `determinism_changes` | **GAP** — no field on `SystemResult`. Was per-system in old index. Not currently captured by `Portal.Catalog.SystemResult` schema. |
| Admin override (`forced_status`, `notes`) | `Portal.Catalog.PackageOverride.{forced_status, notes}` — backed, exists already (this *is* the schema-v2 replacement for `package_metadata.json`). |
| `beam_scan` (flags, samples, languages, scanned_systems, beam_count, protocols, errors, start_modules) | `SystemResult.beam_scan` (map) — backed **if the stored shape matches** `%{flags:, samples:, languages:, scanned_systems:, beam_count:, protocols: %{defined:, impls:}, errors:, start_modules:}`. Verify shape (task note calls this out explicitly) — likely package-level in old data (one `beam_scan` per package spanning systems) vs. Catalog's per-`SystemResult` `beam_scan`; reconcile whether the old page's `@package.beam_scan` (package-level, one snapshot) needs to become "pick latest/representative SystemResult.beam_scan" or a merge across systems. |
| `dependency_scans` (per-app footprint/languages/flags table) | `SystemResult.dependency_scans` (map) — backed, same shape-verification caveat as above. |
| Per-system footprint (file_count, total_bytes, firmware_bytes) | `Run.footprint.per_system[system_pkg]` — **verify shape** (see packages-list GAP note); if present this is backed. |
| Per-system log link | **GAP**: old links to `../../data/<log_path>` (static file under generated site). Dynamic app needs an actual log-serving route/controller for `SystemResult.log_path` / `SystemResult.log_tail` — doesn't exist yet (`log_tail` is stored inline and could be rendered directly instead of linking out, `log_path` implies a full log artifact that isn't obviously served). |
| `hex_version_tested` (per-system) | `SystemResult.hex_version_tested` — backed. |

---

## Page: Failure clusters (`failure_clusters.html.eex`)

### Structure
No route currently exists for this page (`GAP: routing`).

- Intro paragraph.
- Empty state if no clusters.
- Per cluster (no `<table>`, card list): title, `count failures ·
  unique_packages package(s)`, hint text, a language-frequency mini-list
  (from `entries[].nif_language`), a collapsible `<details>` "Show N
  affected packages" listing each `{package@version, arch_label,
  nif_language, detail}` linked to `packages/<safe_key>.html`, and a
  "Representative log excerpt" `<pre>` block (`cluster.sample_log`).

### Data needed → Backing

| Data | Backing |
| --- | --- |
| Clusters (title, count, unique_packages, hint, entries, sample_log) | `Catalog.failure_clusters/1` **exists** — confirm it returns the same shape (old computed at *render time* by regex-classifying every failing `SystemResult.log_tail` against 6 ordered patterns in the now-deleted `Site.FailureCluster`; current Catalog instead reads a pre-computed `SystemResult.failure_category` column, presumably set at ingestion). **Two things to verify before reuse**: (1) does ingestion classify with the *same* (or an equivalent) pattern set as the deleted `Site.FailureCluster.@patterns`? (2) does `Catalog.failure_clusters/1` return `hint`/`sample_log`/`entries[].detail`/`entries[].nif_language`, or just counts? From the partial read, its per-cluster row includes `systems: length(rows)` — signature differs from old `cluster.count`/`entries`; read `Catalog.failure_clusters/1` fully before assuming parity. |
| `sample_log` per cluster | **Possible GAP** — old picks the shortest failing log_tail among a cluster's entries and takes its last 40 lines. If `Catalog.failure_clusters/1` doesn't return a representative log, this needs adding (data exists on `SystemResult.log_tail`, just needs the picking logic). |
| `nif_language` per entry | `Package.native_components["nif_language"]` — backed if joined in. |

### Notes
- This is the one place where the *classification logic itself*
  (regex-against-log-tail → title/hint) already migrated server-side to
  ingestion-time (`failure_category` column) instead of render-time —
  confirm the deleted `Site.FailureCluster.@patterns` list was ported
  wherever `failure_category` gets set, or the categories will silently
  diverge from what this page used to show.

---

## Page: Warnings (`warnings.html.eex`)

### Structure
No route currently exists for this page (`GAP: routing`).

- Intro paragraph.
- Empty state if no warnings.
- Per warning (no table, card list): title, `count package(s)` pill,
  hint, collapsible `<details>` "Show N affected packages" → grid of
  `{package@version linked to entry.link, evidence[] lines}`.

Four hardcoded rules (`Site.WarningCluster`, deleted, package-level, one
package may match multiple):
1. **Writes to its source directory during build** — `pkg.source_changes.changed == true`, evidence = up to 4 sample added/modified paths.
2. **Non-deterministic build** — any system with `sys.deterministic == false`, evidence = "non-deterministic on: <arch list>".
3. **Calls :erlang.halt / System.halt** — `beam_scan.flags.halt`, evidence = up to 3 `beam_scan.samples.halt`. Allow-list: elixir/iex/mix/nerves_runtime/nerves_pack/toolshed/shoehorn.
4. **Uses System.shell / :os.cmd** — `beam_scan.flags.shell`, evidence = up to 3 `beam_scan.samples.shell`. Allow-list: elixir/mix/iex/toolshed.

### Data needed → Backing

| Data | Backing |
| --- | --- |
| `source_changes` (rule 1) | **GAP** — same gap as package-detail page; not on `Package` or `SystemResult`. |
| `sys.deterministic` (rule 2) | **GAP** — same gap as package-detail page; not on `SystemResult`. |
| `beam_scan.flags.halt` / `.shell` + `beam_scan.samples.{halt,shell}` (rules 3/4) | `SystemResult.beam_scan` map — backed **if shape matches** (same verification caveat as package-detail page). Note old warning rules are **package-level** (one `beam_scan` per package, not per-system) — need to decide: run the rule across a package's *latest run's* systems, or need a package-level rollup. |
| Rule engine itself (4 rules, allow-lists, `compute/1`) | **GAP: no equivalent exists in Portal at all.** `Site.WarningCluster` was entirely deleted with no ported replacement — this is pure new logic to write (the deleted file is a clean, self-contained ~190-line module worth near-verbatim porting once the underlying fields exist). |

---

## Page: Stats (`stats.html.eex`)

### Structure
No route currently exists for this page (`GAP: routing`).

1. **Overall Statistics** section — stat cards: Unique Packages,
   Total Package/Versions, Passing (+%), Failing (+%), Errors (+%),
   Skipped (+%, only if >0).
2. **BEAM Scanner Statistics** section — stat cards: Packages Scanned,
   Packages with NIFs, Use Protocols, Start Callbacks, Shell Calls, Halt
   Calls, Average BEAM Files/Package; plus a "Languages Observed" list
   (`language: count`, sorted desc).
3. **Statistics by System** — **table**, columns: **Architecture |
   Nerves system | Total | Pass | Fail | Error | (Skipped, if any system
   has skipped>0)**. Rows exclude the synthetic `forced@...` bucket,
   labeled via `Site.Architecture.label/1`, sorted by architecture name.
4. Footer: last test run / site updated.

### Data needed → Backing

| Data | Backing |
| --- | --- |
| Overall counts (total unique packages, total_versions, pass/fail/error/skipped + %) | **GAP** (same package-level-vs-systemresult-level mismatch as dashboard). `Catalog.stats_json().counts` counts `SystemResult` rows, not "unique packages" / "total package-versions" the way the old `Stats.compute` did. Need to confirm what "total_versions" should even mean now (old index tracked *all* scanned versions per package, not just latest — verify whether Catalog retains historical `Run`s per package/version or only the latest, since several old pages depend on multi-version history). |
| By-system pass/fail/error/skipped counts | `Catalog.stats_json().by_system` — **exists**, per-system breakdown keyed like `"<system_pkg>@<system_version>"`, matches old `@by_system` shape closely (needs the `forced@` filter + `Site.Architecture.label/1` applied in the view, not the query). |
| BEAM scanner aggregate stats (`packages_with_beam_scan`, `packages_with_nif`, `packages_with_protocols`, `packages_with_start_callback`, `packages_with_shell`, `packages_with_halt`, `avg_beam_count_per_pkg`, `languages` histogram) | **GAP** — no equivalent aggregate in `Catalog`. Old `Stats.compute` (in `apps/compatibility`, not shown here but referenced) built this from `beam_scan` across the whole index at generation time; needs a new Catalog query/aggregate over `SystemResult.beam_scan`, package-level vs per-system decision same as Warnings page. |
| `last_run_finished_at` / `generated_at` | `Catalog.stats_json().last_run_finished_at` — backed. `generated_at` — no meaningful equivalent for a live app (see dashboard notes). |

---

## Page: Request scan (`request_scan.html.eex`)

Already has a live counterpart at `/request-scan`
(`PageController.request_scan`) plus `RequestLive` at `/requests/:id` for
status tracking — this template is UX/copy reference only, not a data
port target. Notable copy/UX to preserve if not already matched: package
name input (`pattern="[a-z][a-z0-9_]*"`), Hex.pm-owner vs GitHub-maintainer
vs anonymous verification lanes with the "Queue priority" explainer panel,
Turnstile placeholder slot copy.

---

## Cross-cutting GAP summary (data Catalog cannot currently answer)

1. **Package-level overall-status rollup** (pass/fail/**partial**/skipped/unknown, one bucket per package) — needed by dashboard, packages list, package detail. Distinct from `Catalog.stats_json()`'s per-`SystemResult` counts.
2. **Per-package average footprint across systems** — needs `Run.footprint.per_system` shape verified + an averaging helper; used on dashboard-adjacent packages list and package detail.
3. **Native-code bucket classification** (`native_code_bucket/1` logic: nif_language / port_languages / all-forced-or-skipped → "not scanned") — pure function, needs porting, inputs likely already available.
4. **`github_url`** on Package — not stored.
5. **`is_dependency`** (synthesized-placeholder flag) on Package — not stored; Portal has a *different* placeholder mechanism via `ScanRequests.queue_requests()` that may or may not cover the same case (old: package that appeared only as someone else's dependency; new: package that has an open scan request). Reconcile semantics, don't assume equivalence.
6. **`source_changes`** (writes-to-source-during-build flag + sample paths) — not stored anywhere in Catalog schema. Needed by package detail + Warnings rule 1.
7. **`deterministic` / `determinism_changes`** per system — not stored in `SystemResult`. Needed by package detail + Warnings rule 2.
8. **Runtime `dependencies` list** (name, requirement, optional, runtime) per package/run — not stored in Catalog schema at all. Needed by package detail's Runtime Dependencies table.
9. **Multi-version-per-package history** (all previously-scanned versions of one package, not just latest) — Catalog's `latest_runs/1` only surfaces the latest `Run` per package; package detail's "Tested Versions" table needs all versions. Verify whether historical `Run` rows are even retained/queryable this way.
10. **Log artifact serving** — old links to a static `data/<log_path>` file; dynamic app has `SystemResult.log_path` (a path string) and `SystemResult.log_tail` (inline text) but no confirmed route serving full logs.
11. **Warnings rule engine** (`Site.WarningCluster`) — zero equivalent exists in Portal; needs writing from scratch once dependent fields (6, 7, and verified `beam_scan` shape) exist.
12. **BEAM-scanner aggregate stats** (packages_with_nif, avg_beam_count_per_pkg, language histogram, etc.) — no equivalent Catalog aggregate; needed by Stats page.
13. **Routing** — `/failure_clusters`, `/warnings`, `/stats` have no LiveView/controller/route today; `Catalog.failure_clusters/1`, `Catalog.pass_rate_per_system/0`, `Catalog.native_breakdown/0`, `Catalog.recent_runs/2` already exist and are unused by any current route.
14. **`beam_scan` / `dependency_scans` shape verification** — Catalog stores these as opaque `:map` attributes on `SystemResult` (per-system), while the old site's package-detail/warnings pages sometimes treated `beam_scan` as **package-level** (one snapshot representing the package, not per-system). Before wiring any of the Beam-scanner UI, confirm (a) the stored map's internal keys match what the templates expect (`flags`, `samples`, `languages`, `scanned_systems`, `beam_count`, `protocols.defined/impls`, `errors`, `start_modules`), and (b) whether "package-level" old behavior maps to "pick one representative SystemResult" or requires a merge across a run's systems.

## Already fully replicated (safe to wire directly)

- `Catalog.pass_rate_per_system/0` → dashboard "Pass rate per system" tile.
- `Catalog.native_breakdown/0` → dashboard "Native code" tile (verify bucket-name parity with old `native_colors` keys).
- `Catalog.recent_runs/2` → dashboard "Recently Checked Passing/Failing" lists (verify returned fields).
- `Catalog.failure_clusters/1` → failure_clusters page skeleton (verify full return shape against old `Site.FailureCluster` output — count/hint/entries/sample_log — before assuming full parity; also confirm classification-pattern parity, see cross-cutting note above).
- `Catalog.stats_json().by_system` → Stats page's per-system table (minus the `forced@` filter + arch-label mapping, which stay view-side).
- `PackageOverride.{forced_status, notes}` → package detail's admin-override + notes boxes.
- `Site.Architecture.label/1` and `Site.Badge.generate/2` — pure functions, no data dependency, trivial verbatim ports (both fully recovered above/at their source paths in this doc's file list).

---

## Files written

- `docs/superpowers/static-site-port-map.md` (this file)
- `docs/superpowers/static-site.css` (full recovered CSS, verbatim, base + per-page sections)
