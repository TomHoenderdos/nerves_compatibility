# Phase 2 — Postgres swap + Catalog domain + Oban (executable brief)

> Self-contained task brief for an agent (e.g. hermes) with repo access but no chat context. Part of the umbrella-consolidation effort; stays on branch `dynamic_site` (do NOT merge to main). Phase 1 (umbrella conversion) is already committed.

## Read first (in-repo, authoritative)
- `docs/superpowers/specs/2026-06-18-portal-consolidation-design.md` — the full design. **Section 2** (Ash domain model) and the **Decisions** block define exactly what this phase builds.
- `docs/superpowers/plans/2026-06-18-phase1-umbrella-scaffold.md` — what Phase 1 already did.
- `apps/portal/AGENTS.md` — Phoenix 1.8 / Ash / LiveView conventions you MUST follow.

## Current state you must respect
- Umbrella apps: `apps/compatibility` (`:compatibility`, lib), `apps/ncc_worker` (`:ncc_worker`, in-container escript), `apps/portal` (`:portal`, Phoenix 1.8 + Ash 3.0). Run mix from the **repo root**.
- `apps/portal` is on **ash_sqlite** today: `Portal.Repo` is `use AshSqlite.Repo, otp_app: :portal`. Existing Ash resources: `Portal.Accounts.User` (table `portal_users`) and `Portal.ScanRequests.ScanRequest` (table `portal_scan_requests`), both `data_layer: AshSqlite.DataLayer`. Domains configured in `apps/portal/config/config.exs`: `ash_domains: [Portal.Accounts, Portal.ScanRequests]`, `ecto_repos: [Portal.Repo]`.
- Existing sqlite migrations in `apps/portal/priv/repo/migrations/`. Portal has ~no real data — you may regenerate migrations for Postgres rather than preserving the sqlite ones.
- Supervision tree (`apps/portal/lib/portal/application.ex`) currently: `PortalWeb.Telemetry`, `DNSCluster`, `Portal.Repo`, `Phoenix.PubSub`, `PortalWeb.Endpoint`. Add Oban after `Portal.Repo`.
- **CRITICAL config gotcha:** runtime config is in the **umbrella root `config/runtime.exs`**, NOT `apps/portal/config/runtime.exs` (that file is dead under the umbrella — it has a comment saying so). `import_config` is forbidden in runtime.exs, so portal's runtime config was inlined into root `config/runtime.exs` inside an `if File.exists?(Path.expand("../apps/portal", __DIR__))` guard. Put Postgres runtime config (and `DATABASE_URL` handling) THERE, inside that guard. Compile-time portal config stays in `apps/portal/config/{config,dev,test}.exs`.
- **Do not break the worker Docker image.** It copies only `mix.exs mix.lock config apps/compatibility apps/ncc_worker` (never `apps/portal`), so it never fetches portal's deps. The root `config/config.exs` and `config/runtime.exs` already guard the portal config with `File.exists?` — keep those guards intact so `make build` still works without `apps/portal` on disk.

## Goal
Swap portal from SQLite to **Postgres** and stand up the **Oban** job infrastructure + **Oban Web** dashboard and the new **`Portal.Catalog`** Ash domain that will hold compatibility results. This phase adds schema + infrastructure ONLY — **no scan-execution logic, no workers that run builds** (those are Phase 3). No behavior change to existing portal features.

## Scope (do all of it)

### 1. Postgres data-layer swap
- Add deps to `apps/portal/mix.exs`: `{:ash_postgres, "~> 2.0"}`; remove `{:ash_sqlite, ...}`.
- Change `Portal.Repo` to `use AshPostgres.Repo, otp_app: :portal`. Add the `installed_extensions/0` callback if AshPostgres requires it (e.g. `["ash-functions"]`).
- Switch `Portal.Accounts.User` and `Portal.ScanRequests.ScanRequest` from `AshSqlite.DataLayer` to `AshPostgres.DataLayer` (the `postgres do ... end` block replaces `sqlite do ... end`; keep the same table names and indexes).
- Update DB config:
  - `apps/portal/config/dev.exs` + `test.exs`: replace the sqlite `Portal.Repo` config with Postgres (`username`, `password`, `hostname`, `database: "portal_dev"`/`"portal_test#{System.get_env("MIX_TEST_PARTITION")}"`, `pool: Ecto.Adapters.SQL.Sandbox` for test, `pool_size`).
  - Root `config/runtime.exs` (inside the existing `File.exists?("../apps/portal")` guard): prod Postgres config via `DATABASE_URL` (`url:` + `pool_size` + `socket_options` for IPv6), replacing the inlined sqlite `database:` block.
- Regenerate migrations for Postgres: delete the old sqlite migrations + any `priv/resource_snapshots`, then use Ash codegen (`mix ash.codegen initial_postgres` or `mix ash_postgres.generate_migrations`) so the User/ScanRequest tables (and the new Catalog resources from step 2) get fresh Postgres migrations + snapshots.

### 2. `Portal.Catalog` domain (new Ash resources, AshPostgres)
Create domain `Portal.Catalog` and add it to `ash_domains`. Resources per spec Section 2 (read it for the exact attribute list):
- `Package` — `name` (unique), `description`, `latest_version`, `last_run_at`.
- `Run` — `run_id`, `version_tested`, `image_digest`, `overall_status`, `footprint` (map/jsonb), `log`, `started_at`, `finished_at`; belongs_to `Package`; belongs_to `ScanRequest` (nullable).
- `SystemResult` — `system_pkg`, `system_version`, `status` (use the `Compatibility.Types` status enum: `pass|fail|error|skipped|unknown`), `firmware_size_bytes`, `hex_version_tested`, `beam_scan` (jsonb), `dependency_scans` (jsonb), `log_path`; belongs_to `Run`.
- `Artifact` — `sha256` (unique), `byte_size`, `disk_path`; belongs_to `SystemResult`. (Blobs live on disk; DB stores metadata only.)
- `PackageOverride` — `package_name`, `forced_status`, `allow_systems`, `deny_systems`, `notes` (replaces the `package_metadata.json` override file; admin-editable later).
Add minimal Ash actions (defaults `[:read, :create, :update, :destroy]` + an upsert for `Package` by name). `apps/compatibility` is available as `{:compatibility, in_umbrella: true}` if you reference `Compatibility.Types` — add that dep to portal if needed.

### 3. Oban + Oban Web
- Add deps: `{:oban, "~> 2.18"}` and `{:oban_web, "~> 2.11"}` (resolve current compatible versions).
- Configure Oban in `apps/portal/config/config.exs`: `config :portal, Oban, repo: Portal.Repo, queues: [builds: 1, intake: 5, maintenance: 1], plugins: [Oban.Plugins.Pruner]` (cron/workers come later — just infra now). In `test.exs`: `config :portal, Oban, testing: :manual`.
- Add `{Oban, Application.fetch_env!(:portal, Oban)}` to the supervision tree in `apps/portal/lib/portal/application.ex`, after `Portal.Repo`.
- Generate the Oban migration (`mix ecto.gen.migration add_oban_jobs` calling `Oban.Migration.up/down`, or Oban's installer) so `oban_jobs`/`oban_peers` tables exist.
- Mount **Oban Web** in `apps/portal/lib/portal_web/router.ex` behind admin auth: `import Oban.Web.Router` and `oban_dashboard "/oban"` inside an admin-scoped pipeline. There's already an `/admin` area gated in `PageController`; add a router pipeline/plug that enforces the same admin check (current user must be admin) before the Oban dashboard. Do not expose it unauthenticated.

## Constraints
- No behavior change to existing portal features (auth, scan-request intake, admin). Existing portal tests must still pass.
- TDD: write/extend ExUnit tests for the new Catalog resources (create/read, the `Package` unique-name upsert, a `SystemResult` status round-trips through the `Compatibility.Types` enum). Use `Ecto.Adapters.SQL.Sandbox`.
- Keep commits small and frequent, each green, on `dynamic_site`.
- Do NOT add scan build/execution workers or the Hex poller — Phase 3 / Phase 4.
- Follow `apps/portal/AGENTS.md` (Ash/Phoenix idioms, `mix precommit`).

## Verification gate (all must pass)
1. A local Postgres is available (e.g. `docker run -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:16`); note connection settings used.
2. From repo root: `mix deps.get && mix compile` clean; `cd apps/portal && mix ecto.create && mix ecto.migrate` runs clean on Postgres (User, ScanRequest, Catalog tables + `oban_jobs` created).
3. `mix test` at repo root green — existing portal suite (was 22 tests) + new Catalog resource tests; compatibility (4) and ncc_worker (18) unaffected.
4. Oban Web dashboard loads at `/admin/oban` and is rejected when not authenticated as admin.
5. The worker image still builds and the integration gate still passes: `make build` (no Phoenix/Ash/Oban pulled into the image) and `make test-integration`.
6. `mix format --check-formatted` clean.

Report what you changed, the migrations generated, all test counts, and confirmation of each gate item. Flag any deviation from the spec with reasoning.
