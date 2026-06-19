# Phase 4 — Triggers + intake consolidation (executable brief)

> Self-contained task brief for an agent (e.g. hermes) with repo access but no chat context. Umbrella-consolidation effort; stays on branch `dynamic_site` (do NOT merge to main). Phases 1 (umbrella), 2 (Postgres + Catalog + Oban), 3 (Builder + Build worker) are already committed.

## Read first (in-repo, authoritative)
- `docs/superpowers/specs/2026-06-18-portal-consolidation-design.md` — **Section 3** (the four triggers → one `builds` queue, priority map) and the **On-Demand Scan Requests** / **Decisions** blocks.
- `docs/superpowers/plans/2026-06-18-phase3-builder.md` — the `Portal.Workers.Build` worker + args you enqueue.
- `apps/portal/AGENTS.md` — Ash / Phoenix / Oban conventions.
- Code you port FROM (standalone projects + Cloudflare functions; deleted in Phase 6 — copy logic into portal, do NOT add deps on them):
  - `orchestrator/lib/orchestrator/hex_poller.ex` — polls Hex.pm (`req_hex`) for new releases. Port into an Oban cron worker.
  - `orchestrator/lib/orchestrator/scan_request.ex` — `submit/1` validation + the `:source` → queue-priority mapping (`:hex_owner`/`:github_repo`/`:anonymous_turnstile`/`:anonymous_manual`).
  - `functions/api/scan-requests.js` — Cloudflare Turnstile siteverify + the anonymous forward payload. Port the Turnstile check into Phoenix.
  - `functions/api/auth/hex/{start,complete}.js` — Hex OAuth device-flow proxy (already duplicated by `Portal.HexPm`; functions get deleted).
- Portal code you MODIFY:
  - `apps/portal/lib/portal/scan_requests.ex` — `forward_to_orchestrator/2` (replace with local enqueue).
  - `apps/portal/lib/portal_web/controllers/page_controller.ex` — intake actions `hex_complete/2`, `github_complete/2`, `anonymous_request/2`.
  - `apps/portal/lib/portal/hex_pm.ex`, `apps/portal/lib/portal/github.ex` — existing device-flow + ownership verification (reuse as-is).

## Current state you must respect
- Umbrella; run mix from repo root. Portal is on Postgres + Oban (queues `builds`, `intake`, `maintenance`); `Portal.Catalog` holds `Package`/`Run`/`SystemResult`/`Artifact`/`PackageOverride`; `Portal.Workers.Build` (Phase 3) runs a container and ingests results. `Portal.ScanRequests.ScanRequest` has `source` ∈ `[:hex_owner, :github_repo, :anonymous_turnstile, :anonymous_manual]` and a status flow.
- The worker image `ncc-worker:local` and its JSON/exit-code contract are unchanged. Keep root `config/*.exs` `File.exists?` guards intact (worker image must still build).
- Do NOT touch site rendering / badges / API (Phase 5) or delete the standalone projects (Phase 6).

## Goal
Make all four scan triggers converge on the Phase-3 `Portal.Workers.Build` queue, natively in portal — removing the orchestrator HTTP hop and the Cloudflare functions. After this phase: a Hex-owner / GitHub-repo / anonymous-Turnstile request, and the Hex firehose poller, all enqueue `Build` jobs with the correct Oban priority. `functions/` is deleted.

## Scope (do all of it)

### 1. Hex firehose poller → Oban cron
- `Portal.Workers.DiscoverReleases` (queue `:maintenance`). Port `orchestrator/lib/orchestrator/hex_poller.ex`: fetch new Hex.pm releases (use `req`/`req_hex`; reuse the existing poll interval + the `priority_users` notion if present). For each new `{package, version}` not already built (dedupe: no `Run` for `(package, version, current_image_digest)` and not already enqueued), enqueue `Portal.Workers.Build` at **normal** priority (Oban `priority: 6`), source `hex_poll`, no `ScanRequest`.
- Schedule via `Oban.Plugins.Cron` in the portal Oban config (e.g. hourly). Make the interval config-driven.

### 2. Intake → enqueue Build (replace the orchestrator hop)
- Replace `Portal.ScanRequests.forward_to_orchestrator/2` with a local path: create/`replace_open_request` the `ScanRequest`, then enqueue `Portal.Workers.Build` with `scan_request_id` and the source-derived priority. Drop the `Req.post` to the orchestrator and the `:orchestrator_scan_request_url` / `:scan_request_shared_secret` config use.
- **Source → Oban priority** (from spec Section 3): `:hex_owner` → 0, `:github_repo` → 1, `:anonymous_turnstile` → 3. (`pending_review`/admin-held → not enqueued until approved.)
- Wire the controller actions:
  - `hex_complete/2`: after `Portal.HexPm` verifies device-flow + package ownership → create `ScanRequest{source: :hex_owner, subject: hex_username}` → enqueue Build (priority 0).
  - `github_complete/2`: after `Portal.GitHub` verifies repo access → `ScanRequest{source: :github_repo}` → enqueue Build (priority 1).
  - `anonymous_request/2`: see step 3.
- The existing admin approve/reject flow (`approve_anonymous_request`/`reject_anonymous_request`) should enqueue a Build on approval.

### 3. Cloudflare Turnstile, server-side in Phoenix
- Port `functions/api/scan-requests.js`'s Turnstile verification into `anonymous_request/2`: POST the token to `https://challenges.cloudflare.com/turnstile/v0/siteverify` via `Req`, with `CF-Connecting-IP` as `remoteip`. On success → `ScanRequest{source: :anonymous_turnstile, verified?: true}` → enqueue Build (priority 3). On failure → reject.
- Add `TURNSTILE_SECRET_KEY` (and the site key for the widget) to config/runtime. Embed the Turnstile widget in the `request_scan` form/template. Keep the `:anonymous_manual` path for admin-entered requests.

### 4. Delete the Cloudflare functions
- `git rm -r functions/`. Remove any references to it in docs (`CLAUDE.md`, `AGENTS.md`, `DEPLOY.md`) — note the intake is now native Phoenix. (Do NOT yet remove `wrangler.toml`/`public/site` — that is Phase 6, tied to the static-site removal.)

## Constraints
- TDD: test the source→priority mapping; test that each intake action enqueues a `Build` with the right args/priority (`Oban.Testing.assert_enqueued`); test Turnstile success/failure (stub the `Req` call). Use `Ecto.Adapters.SQL.Sandbox` + `testing: :manual`.
- No behavior change to auth/account flows themselves — only what happens AFTER identity is verified (enqueue instead of forward).
- Do NOT add site rendering (Phase 5) or delete standalone projects (Phase 6).
- Frequent green commits on `dynamic_site`. Follow `apps/portal/AGENTS.md` (`mix precommit`).

## Verification gate (all must pass)
1. Postgres running; worker image built (`make build`).
2. From repo root: `mix deps.get && mix compile` clean; `mix test` green — existing suites + new trigger/intake/Turnstile tests.
3. The poller cron is registered (visible in Oban config) and a manual `perform`/trigger enqueues `Build` jobs for new releases with priority 6 and proper dedupe.
4. Each intake action (hex_complete, github_complete, anonymous_request) creates a `ScanRequest` and enqueues a `Build` with the correct priority; Turnstile is verified server-side for anonymous.
5. `functions/` is deleted; no code references it.
6. The worker image still builds and `make test-integration` (Phase 3 portal integration test) still passes.
7. `mix format --check-formatted` clean.

Report changes, the priority mapping, all test counts, and confirmation of each gate item. Flag any deviation with reasoning.
