# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Layout

This is a **Mix umbrella** at the repo root. It serves the Nerves Compatibility Tracker dynamically from Phoenix and uses Oban jobs to run Docker-backed package builds.

| App | Role |
| --- | --- |
| `apps/compatibility` | Core library: shared result/index types, validators, and `Compatibility.Types` status helpers. |
| `apps/ncc_worker` | Runs **inside** the Docker container. Creates a Nerves project, adds the package, builds firmware per system, enforces Hex-only deps, scans BEAM artifacts, archives precompiled files by SHA256, and writes `result.json`. Dockerfile at `apps/ncc_worker/Dockerfile`. |
| `apps/portal` | Phoenix 1.8 + Ash/Postgres + Oban web app. Owns scan intake, accounts/admin, host-side Docker invocation (`Portal.Builder`), build jobs (`Portal.Workers.Build`), Catalog persistence, dynamic browser, badges, schema-v2 JSON API, and precompiled artifact API. |

`apps/portal/AGENTS.md` carries extensive Phoenix 1.8 / LiveView / HEEx conventions — read it before touching `apps/portal/`.

## Common Commands

```bash
make build                         # Rebuild ncc-worker:local
make dev                           # Start Phoenix portal
make test                          # Run umbrella test suite
make test-integration              # Real Docker -> Portal.Catalog integration test
make format                        # mix format at umbrella root
```

Umbrella commands (run from repo root):

```bash
mix deps.get
mix test
mix test apps/compatibility/test/
mix format
```

Portal commands:

```bash
cd apps/portal
mix setup
mix phx.server                     # http://localhost:4001
mix test
mix precommit                      # run when finishing portal changes
```

The integration test is `apps/portal/test/portal/workers/build_integration_test.exs`, tagged `:integration` and excluded from default `mix test`. Run it after any change that could affect Docker invocation, the JSON contract, artifact storage, or the worker firmware-build path.

## How a Package Gets Checked

1. A trigger creates a `Portal.ScanRequests.ScanRequest` or a maintenance job discovers a Hex release.
2. Portal enqueues `Portal.Workers.Build` on Oban's `:builds` queue with package/version/image digest and optional scan request id.
3. `Portal.Builder` runs `docker run ncc-worker:local` with the reproducibility mounts:
   - `/work` → per-run scratch
   - `/out` → outputs (`result.json`, logs, artifacts)
   - `/files` → content-addressed artifact staging
   - `/home/nerves/.nerves` → shared Nerves cache (`~/.ncc-nerves-cache`)
   - `/hex-cache` → shared Hex cache (`~/.ncc-hex-cache`)
4. `NccWorker.Worker` inside the container reads `NCC_INPUT`, creates a fresh Nerves project, enforces `NccWorker.LockPolicy`, builds firmware per Nerves system, captures status/firmware size/log tail/BEAM scan/footprint, archives files by SHA256, and writes atomic `result.json`.
5. `Portal.Catalog.Ingestion` ingests the result into Postgres: `Package`, `Run`, `SystemResult`, and `Artifact` rows, with blobs moved into `Portal.ArtifactStore`.
6. `Portal.Workers.Build` updates the linked `ScanRequest` and broadcasts progress over `Portal.PubSub` topic `request:<id>`.
7. Phoenix serves the dynamic site, badge endpoint, schema-v2 JSON API, and precompiled manifest/blob API directly from Catalog.

## Public Routes

- `/` — package browser
- `/packages/:name` — package detail: latest run and per-system results
- `/requests/:id` — live request/build status
- `/badge/:name.svg` — SVG badge
- `/api/packages`, `/api/packages/:name`, `/api/stats` — schema-v2 JSON API
- `/api/precompiled/manifests/:package.json`, `/api/precompiled/files/:sha256` — precompiled API
- `/admin`, `/admin/oban` — admin UI and Oban Web dashboard

## Exit Code Conventions

Worker exit codes are load-bearing and should not change casually:

- `0` ok
- `10` internal failure / retryable worker error
- `11` policy violation (non-Hex git/path dependency)

Portal maps these into Oban outcomes in `Portal.Workers.Build`: success ingests, policy violation discards/rejects, retryable failures retry and eventually mark the request errored.

## Data Contracts

- **Worker input**: `NCC_INPUT` JSON passed to the worker container. See `apps/ncc_worker/README.md`.
- **Worker output**: `result.json` typespec at top of `apps/ncc_worker/lib/ncc_worker/worker.ex`. Status enum lives in `Compatibility.Types` — `pass | fail | error | skipped | unknown`.
- **Catalog JSON API**: schema version 2, documented in `docs/INDEX_FORMAT.md`.
- **Package overrides**: admin-managed `Portal.Catalog.PackageOverride` rows, documented in `docs/PACKAGE_METADATA.md`.
- **Precompiled API**: manifests and content-addressed files served by portal, documented in `PRECOMPILED_API.md`.

## Container / Caching Details

- The worker image is based on `ghcr.io/nerves-project/nerves_system_br`.
- `Portal.Builder` passes `--user $(id -u):$(id -g)` so bind-mounted files stay owned by the invoking host user.
- `/home/nerves` and `/app` are chmod'd `a+rwX` in the Dockerfile so arbitrary uids can use the baked-in Mix archives and Elixir install.
- `~/.ncc-nerves-cache` and `~/.ncc-hex-cache` persist across runs and speed up repeated tests.
- `make build` uses `--no-cache`. For faster Dockerfile iteration, run `docker build` manually without `--no-cache`.

## Dependency Policy

The worker rejects any project whose `mix.lock` references git or path deps. This is enforced in `NccWorker.LockPolicy` and is load-bearing for reproducibility — don't relax it without updating docs/tests and understanding the consequences.

## Generated / Ignored Paths

`_build/`, `deps/`, `tmp/`, `public/`, `*.dets`, `compat_test_results/`, and the `~/.ncc-*` caches are generated. Never commit them. `.elixir_ls/` is also ignored.
