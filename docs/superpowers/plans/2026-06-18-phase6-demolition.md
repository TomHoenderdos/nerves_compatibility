# Phase 6 — Demolition + cutover finish (executable brief)

> Self-contained task brief for an agent (e.g. hermes) with repo access but no chat context. Umbrella-consolidation effort; stays on branch `dynamic_site` (do NOT merge to main until the user decides). Phases 1–5 are already committed — the dynamic Phoenix site, native intake, Oban builds, and Catalog are all live.

## Read first (in-repo, authoritative)
- `docs/superpowers/specs/2026-06-18-portal-consolidation-design.md` — the whole design; this phase removes everything its **Section 1** marks as deleted and finishes the cutover.
- `docs/superpowers/plans/2026-06-18-phase{3,4,5}-*.md` — confirm the functionality being deleted has truly been re-homed in portal before deleting.
- `apps/portal/AGENTS.md`.

## Pre-condition (verify before deleting anything)
The standalone projects are only safe to delete once portal fully supersedes them:
- Builds run via `Portal.Workers.Build` + `Portal.Builder` (Phase 3) — `runner/` + `orchestrator/processor` logic re-homed.
- All four triggers enqueue in portal (Phase 4) — `orchestrator/hex_poller` + `scan_request*` + `hex_auth` re-homed; `functions/` already deleted.
- The site is Phoenix-served (Phase 5) — `site/generator`, `badge`, `precompiled_manifest` re-homed.
If any of these is NOT done, STOP and report — do not delete.

## Goal
Remove the now-dead standalone projects and static-site machinery, import the package overrides into the DB, and slim the Makefile/docs so the repo is just the umbrella (`apps/compatibility`, `apps/ncc_worker`, `apps/portal`) plus its deploy/config.

## Scope (do all of it)

### 1. Import overrides into the DB, then retire the file
- Write a one-time importer (a `mix` task, e.g. `Mix.Tasks.Portal.ImportOverrides`, or a seed) that reads `package_metadata.json` (root) and creates `Portal.Catalog.PackageOverride` rows: map `forced_status`, allow/deny systems, `notes`, and the top-level `skip_if_depends_on` list. Run it; verify rows exist.
- After import, `git rm package_metadata.json` and update `docs/PACKAGE_METADATA.md` to say overrides are now admin-managed (DB / `/admin`).

### 2. Delete the standalone projects + static-site machinery
- `git rm -r runner/ site/ orchestrator/`.
- `git rm -r public/site public/data` (generated static artifact — already gitignored, but remove any tracked remnants) and `git rm wrangler.toml`.
- Remove the dead `apps/portal/config/runtime.exs` (its content lives in the umbrella root `config/runtime.exs`; the file has a comment saying so).
- Search-and-destroy references: `grep -rn` for `runner`, `orchestrator`, `Site\.`, `NccRunner`, `Orchestrator\.`, `wrangler`, `public/site` across `Makefile`, `config/`, `apps/`, and docs — fix or remove each.

### 3. Slim the Makefile
- Remove targets that drove the deleted pipeline: `run`, `test-all`, `collect`, `site`, `deploy-site`, `shell` (and any `realclean`/`clean` bits referencing `runner/tmp`, `public/site`, `compat_test_results`, the orchestrator). Keep:
  - `build` (worker image — `-f apps/ncc_worker/Dockerfile`).
  - `test-integration` — repoint to the **portal** integration test (the Phase 3 `:integration` test that drives `ncc-worker:local`), since `runner/test/.../integration_test.exs` is gone.
  - `format` → `mix format` at the umbrella root.
- Add portal dev convenience if useful (`cd apps/portal && mix phx.server`), or document it.

### 4. Docs + deploy
- `CLAUDE.md` + `AGENTS.md`: drop the "legacy standalone projects" section; describe the final umbrella + the dynamic Phoenix site + Oban. Update the "How a Package Gets Checked" flow to the Oban path. Remove the static-site/Cloudflare instructions.
- `DEPLOY.md`: replace Cloudflare-Pages deploy with the portal deploy (Phoenix release + Postgres). Note `make build` still produces the worker image the portal shells out to.
- `PRECOMPILED_API.md`: update endpoints to the portal `/api/precompiled/*` routes (Phase 5).

## Constraints
- Do not delete a project until its functionality is confirmed re-homed (see Pre-condition).
- No behavior change to the live portal — this is removal + docs + one importer.
- Frequent commits on `dynamic_site`. Follow `apps/portal/AGENTS.md` (`mix precommit`).

## Verification gate (all must pass)
1. Postgres running; worker image built (`make build`).
2. `grep -rn` shows NO remaining references to `runner/`, `site/`, `orchestrator/`, `functions/`, `wrangler`, or `public/site` in `Makefile`, `config/`, `apps/`, or docs (except historical mentions in `docs/superpowers/`).
3. From repo root: `mix deps.get && mix compile` clean; full `mix test` green (only the three umbrella apps remain).
4. `make build` + `make test-integration` (now the portal integration test) pass.
5. `PackageOverride` rows imported from `package_metadata.json`; the file is removed.
6. `mix format --check-formatted` clean.
7. The portal still boots and serves the dynamic site (`/`, `/packages/:name`, `/admin`, `/admin/oban`, `/badge/*.svg`, `/api/*`).

Report what was deleted, the override import counts, the final Makefile targets, all test counts, and confirmation of each gate item. After this phase the consolidation is complete — summarize the final repo shape and flag anything left for the user to decide (e.g. merging `dynamic_site` to main).
