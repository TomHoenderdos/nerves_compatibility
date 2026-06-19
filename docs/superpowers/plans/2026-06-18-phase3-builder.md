# Phase 3 — Builder + Build worker (executable brief)

> Self-contained task brief for an agent (e.g. hermes) with repo access but no chat context. Part of the umbrella-consolidation effort; stays on branch `dynamic_site` (do NOT merge to main). Phases 1 (umbrella) and 2 (Postgres + Catalog + Oban) are already committed.

## Read first (in-repo, authoritative)
- `docs/superpowers/specs/2026-06-18-portal-consolidation-design.md` — **Section 3** (Oban topology + end-to-end flow + the exit-code→Oban table) and **Section 2** (the Catalog resources you ingest into) define this phase.
- `docs/superpowers/plans/2026-06-18-phase2-postgres-catalog-oban.md` — what Phase 2 set up (Postgres, Catalog resources, Oban infra).
- `apps/portal/AGENTS.md` — Ash / Phoenix / Oban conventions to follow.
- Code you are porting FROM (host side; do NOT add a dep on these — they get deleted in Phase 6, so copy/adapt their logic into portal):
  - `runner/lib/ncc_runner/docker.ex` — the `docker run` invocation: `NccRunner.Docker.run(%Job{}, opts)`. Mounts `/work`, `/out`, `/files`, `/home/nerves/.nerves` (nerves cache), `/hex-cache`; `--user uid:gid`; image `ncc-worker:local`; `NCC_INPUT=/work/input.json`; container naming; wall-clock timeout; exit-code capture.
  - `runner/lib/ncc_runner/job.ex`, `metadata.ex`, `cli.ex` — the Job struct, exit-code names, and the runner exit-code contract (20 = runner error, 21 = worker container non-zero).
  - `orchestrator/lib/orchestrator/processor.ex` — how the job JSON is built, how `result.json` is parsed, and how exit codes are interpreted today. Reference for the ingestion mapping; rewrite to write Ash/Postgres instead of DETS/JSON.
  - `apps/ncc_worker/lib/ncc_worker/worker.ex` — the `result.json` typespec (the `systems` map with per-system `status`, `firmware_size_bytes`, `system_version`, `beam_scan`, `dependency_scans`; plus `footprint`). This is the shape you parse.

## Current state you must respect
- Umbrella; run mix from repo root. `apps/portal` is on **Postgres** (`ash_postgres`), with Oban configured (queues `builds: 1, intake: 5, maintenance: 1`) and the `Portal.Catalog` domain holding `Package`, `Run`, `SystemResult`, `Artifact`, `PackageOverride`. `apps/compatibility` is available as `{:compatibility, in_umbrella: true}` for `Compatibility.Types`.
- The worker container image `ncc-worker:local` is built by `make build` and is unchanged. The JSON contract (job input → worker → `result.json`) and worker exit codes (`0`/`10`/`11`) are LOAD-BEARING — do not change them.
- **Do not add a path/dep on the standalone `runner`/`orchestrator` projects.** Port the logic into `apps/portal`. Those stay until Phase 6.
- **Do not break the worker Docker image:** it copies only `apps/compatibility` + `apps/ncc_worker` + root config; portal additions never leak in (it never copies `apps/portal`). Keep the root `config/*.exs` `File.exists?` guards intact.

## Goal
Make a package actually get built and its results land in Postgres, driven by an Oban job. Port the host-side Docker invocation into `Portal.Builder`, add an Oban `Portal.Workers.Build` that runs it and ingests `result.json` into the Catalog, updates the `ScanRequest`, and broadcasts live status. This phase wires **execution + ingestion**; it does NOT add intake triggers or the Hex poller (Phase 4) or any site rendering (Phase 5). A manually-enqueued `Build` job is the deliverable.

## Scope (do all of it)

### 1. `Portal.Builder` (host-side Docker invocation, ported)
- New module(s) under `apps/portal/lib/portal/builder/`. Port docker-arg building + `docker run` + exit-code capture from `runner/lib/ncc_runner/docker.ex` (and the Job struct from `job.ex`). Keep the invocation identical: same mounts (`/work`, `/out`, `/files`, `/home/nerves/.nerves` ← nerves cache, `/hex-cache` ← hex cache), `--user uid:gid`, image `ncc-worker:local`, `NCC_INPUT=/work/input.json`, container naming, wall-clock timeout.
- Public API, roughly: `Portal.Builder.build(%{package:, version:, image:, run_id:}, opts) :: {:ok, %{exit_code:, result: parsed_result_json, files_dir:, log:}} | {:error, reason}`. Creates per-run scratch dirs (`work_dir`/`output_dir`/`files_dir`), writes `input.json`, runs the container, reads `/out/result.json`.
- Config (in `apps/portal/config/config.exs`, runtime-overridable): `config :portal, Portal.Builder, docker_image: "ncc-worker:local", scratch_root: ..., nerves_cache: Path.expand("~/.ncc-nerves-cache"), hex_cache: Path.expand("~/.ncc-hex-cache")`. Reference the existing orchestrator config keys (`orchestrator/config/config.exs`: `docker_image`, `runner_tmp_dir`, caches) for the right defaults.

### 2. `Portal.Workers.Build` (Oban worker, queue `:builds`)
Args: `%{"package" =>, "version" =>, "image_digest" =>, "scan_request_id" => (nullable), "priority" =>}`. Steps:
1. **Dedupe:** if a `Run` already exists for `(package, version, image_digest)`, skip the build, mark the linked `ScanRequest` (if any) as built, return `:ok`.
2. Call `Portal.Builder.build/2`.
3. Map the outcome (table below).
4. **Ingest** on success, in ONE transaction: upsert `Package` (by name; update `latest_version`/`last_run_at`), insert `Run`, insert N×`SystemResult` (status via `Compatibility.Types`), register M×`Artifact` — move content-addressed files from `files_dir` into the artifact store on disk and store `sha256`/`byte_size`/`disk_path`.
5. Update the `ScanRequest` status (`built` / `rejected` / `error` + reason) and link `run_id`.
6. Broadcast progress to Phoenix PubSub topic `"request:#{scan_request_id}"` (queued → building → done) via `Portal.PubSub`, so a future LiveView (Phase 5) can subscribe.

**Exit-code → Oban outcome (from spec Section 3 — preserve exactly):**

| Source | Code | Oban result |
| --- | --- | --- |
| worker | `0` | success → ingest |
| worker | `11` policy (git/path dep) | `{:cancel, reason}` (no retry); `ScanRequest` → `rejected: "non-Hex dep"` |
| worker | `10` internal | error → retry (Oban backoff, `max_attempts: 3`) |
| runner-side | `20` runner / `21` container | retry; on exhaustion `ScanRequest` → `error` |
| n/a | unknown package (pre-check) | `{:cancel}`; `ScanRequest` → `rejected` |

Set `max_attempts: 3` and `unique: [keys: [:package, :version, :image_digest]]` on the worker.

### 3. Artifact store
- A disk dir (config `config :portal, :artifact_store, path: ...`) holding content-addressed blobs (`<sha256>` filenames). The `Build` worker moves the worker's `files_dir` outputs there; `Artifact.disk_path` points at them. (Serving them is Phase 5 — just store now.)

## Constraints
- TDD. Unit-test the exit-code→outcome mapping and the ingestion (a fixture `result.json` → assert `Package`/`Run`/`SystemResult`/`Artifact` rows). Use `Ecto.Adapters.SQL.Sandbox` + Oban's `testing: :manual` (`Oban.Testing` — `perform_job/2`, `assert_enqueued`).
- No behavior change to existing portal features; existing tests stay green.
- Do NOT add intake/triggers/poller (Phase 4) or LiveViews/badges/API (Phase 5). Keep `Portal.Builder` and the worker decoupled from web rendering.
- Frequent green commits on `dynamic_site`. Follow `apps/portal/AGENTS.md` (`mix precommit`).

## Verification gate (all must pass)
1. Postgres running (Phase 2 setup) and the worker image built: `make build`.
2. From repo root: `mix deps.get && mix compile` clean; `mix test` green — existing suites + new unit tests (mapping + ingestion with a fixture `result.json`).
3. **New integration test (replaces the runner's `integration_test.exs` as the boundary gate), tagged `:integration`:** `perform` a `Portal.Workers.Build` for a real small package (e.g. `jason` at a pinned version) against the real `ncc-worker:local` container, then assert a `Package` row, a `Run` row with a non-error `overall_status`, and ≥1 `SystemResult` rows in Postgres. Excluded from default `mix test`; run explicitly.
4. The `11` policy path is exercised by a unit test (a fixture/stubbed `Portal.Builder` returning exit 11 ⇒ worker returns `{:cancel, ...}` and the `ScanRequest` is marked `rejected`, no retry).
5. Artifacts: after a successful build, content-addressed files exist under the artifact-store path and `Artifact.disk_path` rows point at them.
6. `mix format --check-formatted` clean.

Report what you changed, all test counts, the integration-test outcome, and confirmation of each gate item. Flag any deviation from the spec with reasoning.
