# Phase 5 — Dynamic site (Phoenix-served) (executable brief)

> Self-contained task brief for an agent (e.g. hermes) with repo access but no chat context. Umbrella-consolidation effort; stays on branch `dynamic_site` (do NOT merge to main). Phases 1–4 are already committed.

## Read first (in-repo, authoritative)
- `docs/superpowers/specs/2026-06-18-portal-consolidation-design.md` — **Section 4** (the Phoenix surface: routes/LiveViews + badge/API) and **Section 2** (Catalog data you render).
- `docs/INDEX_FORMAT.md` — the schema-v2 JSON shapes you must keep emitting from `/api/*` so existing badge/API consumers don't break.
- `apps/portal/AGENTS.md` — Phoenix 1.8 / LiveView / HEEx conventions (REQUIRED — streams, `<.input>`, `Layouts.app`, etc.).
- Rendering logic you port FROM (standalone `site/`; deleted in Phase 6 — copy/adapt, do NOT add a dep on it):
  - `site/lib/site/generator.ex` — page generation (index, per-package, warnings, failure clusters). Reference for layout + what data each page shows.
  - `site/lib/site/badge.ex` — per-package SVG badge computation.
  - `site/lib/site/nav.ex`, `site/lib/site/architecture.ex`, `site/lib/site/failure_cluster.ex`, `site/lib/site/warning_cluster.ex` — supporting render logic.
  - `site/lib/site/precompiled_manifest.ex` — precompiled-API manifest shape + content-addressed file references.

## Current state you must respect
- Umbrella; run mix from repo root. Portal is on Postgres + Oban; `Portal.Catalog` holds `Package`/`Run`/`SystemResult`/`Artifact`/`PackageOverride`; builds ingest into it (Phase 3); triggers enqueue builds (Phase 4). `Portal.Workers.Build` broadcasts progress to PubSub topic `"request:#{scan_request_id}"`.
- Worker image + JSON/exit-code contract unchanged. Keep root `config/*.exs` `File.exists?` guards intact.
- Existing router (`apps/portal/lib/portal_web/router.ex`): `/` currently `PageController :request_scan`; `/admin`, `/auth/*`, `/requests/anonymous`, `/api/packages/hex` exist. `/admin/oban` (Oban Web) from Phase 2.
- Do NOT delete `site/` or `public/site/` (Phase 6).

## Goal
Serve the compatibility site **dynamically from Phoenix**, reading from `Portal.Catalog` (Postgres) instead of static index JSONs. Add the public browse LiveViews, the badge endpoint, and the schema-v2 JSON API + precompiled endpoints. No static generation, no Cloudflare Pages.

## Scope (do all of it)

### 1. Browse LiveViews (public)
- `IndexLive` at `/` — package list with search/filter (use LiveView streams per AGENTS.md). Replaces the static index. Move the scan-request form to `/request-scan` (it already exists as a route/action — keep it).
- `PackageLive` at `/packages/:name` — package detail: latest `Run` + its `SystemResult`s (status per system, firmware size, beam scan summary), honoring any `PackageOverride`.
- `RequestLive` at `/requests/:id` — live scan-request status. Subscribe to PubSub `"request:#{id}"` (`Portal.PubSub`) and show queued → building → per-system results streaming in.
- Port page structure/look from `site/lib/site/generator.ex` + `nav.ex` into HEEx/components. Data comes from Ash queries on `Portal.Catalog`, NOT from JSON files.

### 2. Badge + JSON API (controllers, CDN-cacheable)
- `GET /badge/:name.svg` — port `site/lib/site/badge.ex`; compute the SVG from the package's latest `SystemResult`s. Set cache headers.
- `GET /api/packages`, `GET /api/packages/:name`, `GET /api/stats` — Ash queries rendered as JSON. **Keep the schema-v2 shapes** from `docs/INDEX_FORMAT.md` (`latest_by_pkg`, `latest_by_pkg_system`, `stats`) so existing consumers/badges keep working. `stats` is computed via Ash aggregates over `SystemResult` (no stored table).
- `GET /api/precompiled/*` — port `site/lib/site/precompiled_manifest.ex`: serve the precompiled manifest and the content-addressed `Artifact` files from the artifact-store dir (the disk path on each `Artifact`).

### 3. "latest" semantics
- "Latest result for package X" = a `Run` query ordered by `finished_at` (no denormalized `latest_by_*` table — SQL provides it). Provide a context function (e.g. `Portal.Catalog.latest_run(package)`) used by both LiveViews and API.

## Constraints
- `/api/*` MUST remain schema-v2 compatible (existing badges/integrations depend on it). Add tests asserting the JSON shape.
- TDD: LiveView tests (`Phoenix.LiveViewTest`, key DOM ids per AGENTS.md), a badge snapshot test, API JSON-shape tests, and a `RequestLive` test that asserts a PubSub broadcast updates the view.
- No behavior change to auth/intake/admin from Phase 4. Do NOT delete `site/` (Phase 6).
- Frequent green commits on `dynamic_site`. Follow `apps/portal/AGENTS.md` (`mix precommit`).

## Verification gate (all must pass)
1. Postgres running; worker image built (`make build`).
2. From repo root: `mix deps.get && mix compile` clean; `mix test` green — existing suites + new LiveView/controller/API tests.
3. `/` lists packages from the DB; `/packages/:name` renders the latest run + system results; `/requests/:id` updates live when a `Build` broadcasts progress.
4. `/badge/:name.svg` returns a valid SVG computed from current data; `/api/packages`, `/api/packages/:name`, `/api/stats` return schema-v2 JSON; `/api/precompiled/*` serves the manifest + an artifact blob.
5. The worker image still builds and `make test-integration` still passes.
6. `mix format --check-formatted` clean.

Report changes, the routes added, the schema-v2 conformance evidence, all test counts, and confirmation of each gate item. Flag any deviation with reasoning.
