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

**Never run a `mix deps.*` task from inside `apps/*`.** The umbrella shares one
`mix.lock` at the root, and a child app resolving deps rewrites that shared lock
against only its own dependency list — silently pruning everything it does not
declare. Root-only deps are the casualties: `mix_audit` is declared at
`mix.exs` and is invisible to the children, and a child `deps.get` has already
deleted it from the lock once. A pruned lock then audits clean because the
auditor is gone from it.

The usual way this bites is `cd apps/ncc_worker && mix test`, which fails with
"the dependency is not locked" and tempts a `mix deps.get` right there. Run the
test from the root instead: `mix test apps/ncc_worker/test/`. CI catches a
pruned lock via the "mix.lock is current" step in `.github/workflows/audit.yml`.

Portal commands:

```bash
mix deps.get                       # from the root, not `mix setup` in apps/portal
mix ecto.create && mix ecto.migrate
mix phx.server                     # http://localhost:4001
mix test apps/portal/test/
```

When finishing portal changes, run the portal `precommit` alias's checks from
the root: `mix compile --warnings-as-errors && mix format && mix test`. Do not
run `mix precommit` or `mix setup` inside `apps/portal`: `precommit` includes
`deps.unlock --unused` and `setup` includes `deps.get`, both of which rewrite
the shared lock.

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
   - `/build-cache` → per-image dependency build cache, only when `NCC_BUILD_CACHE` is set
4. `NccWorker.Worker` inside the container reads `NCC_INPUT`, creates a fresh Nerves project, enforces `NccWorker.LockPolicy`, compiles on the host, then either builds firmware per Nerves system or, for a pure-Elixir dependency closure, records an assumed-compatible `pure_elixir` result (`NccWorker.BuildSelection`). It runs the advisory argus_beam analysis over the host beams (`NccWorker.Argus`), captures status/firmware size/log tail/BEAM scan/footprint, archives files by SHA256, and writes atomic `result.json`.
5. On success `Portal.Workers.Build` enqueues `Portal.Workers.Ingest` (queue `:ingest`, must run on the same host because they hand off through the scratch dir). It runs `Portal.Catalog.Ingestion` into Postgres: `Package`, `Run`, `SystemResult`, `SystemLog` (full logs of failed systems) and `Artifact` rows, with blobs moved into `Portal.ArtifactStore`.
6. Both workers update the linked `ScanRequest` and broadcast progress over `Portal.PubSub` topic `request:<id>` (`Portal.Workers.Progress`).
7. Phoenix serves the dynamic site, badge endpoint, schema-v2 JSON API, and precompiled manifest/blob API directly from Catalog.

## Public Routes

- `/` — dashboard; `/packages` — package browser
- `/packages/:name` — package detail: latest run, per-system results, and live status of its newest build
- `/packages/:name/log/:system` — stored build log of a failed system
- `/failure_clusters`, `/stats` — failure clusters and per-system stats
- `/request-scan` — scan request form
- `/requests/:id` — redirects to the package page
- `/badge/:name.svg` — SVG badge
- `/api/packages`, `/api/packages/:name`, `/api/stats` — schema-v2 JSON API
- `/api/precompiled/manifests/:package.json`, `/api/precompiled/files/:sha256` — precompiled API
- `/admin` (tabs Overview, Queue, Users, Failures, Argus, Triage at `/admin/argus/findings`, Maintenance) and `/admin/oban` — admin UI and Oban Web dashboard. `/admin` needs a passkey sign-in; `config/dev.exs` turns that off for local dev
- `/login` — password, passkey, or password + TOTP; `/settings/security` enrols passkeys, TOTP and recovery codes
- `/auth/:provider/login`, `/auth/choose-username` — sign in with Hex.pm or GitHub
- `/settings/providers/:provider/...` — link, unlink, confirm a provider from Settings

## Exit Code Conventions

Worker exit codes are load-bearing and should not change casually:

- `0` ok
- `10` internal failure / retryable worker error
- `11` policy violation (non-Hex git/path dependency)

Portal maps these into Oban outcomes in `Portal.Workers.Build`: success enqueues ingest, policy violation cancels and rejects the request, retryable failures (and host-side codes `20`/`21` from `Portal.Builder`) retry and eventually mark the request errored.

## Data Contracts

- **Worker input**: `NCC_INPUT` JSON passed to the worker container. See `apps/ncc_worker/README.md`.
- **Worker output**: `result.json` typespec at top of `apps/ncc_worker/lib/ncc_worker/worker.ex`. Status enum lives in `Compatibility.Types` — `pass | fail | error | skipped | unknown`.
- **Catalog JSON API**: schema version 2, documented in `docs/INDEX_FORMAT.md`.
- **Package overrides**: `Portal.Catalog.PackageOverride` rows, documented in `docs/PACKAGE_METADATA.md`. Nothing reads them yet, so they have no effect on results.
- **Precompiled API**: manifests and content-addressed files served by portal, documented in `PRECOMPILED_API.md`.

## Container / Caching Details

- The worker image is based on `ghcr.io/nerves-project/nerves_system_br`.
- `Portal.Builder` passes `--user $(id -u):$(id -g)` so bind-mounted files stay owned by the invoking host user (`NCC_BUILD_USER` overrides it, e.g. `0:0` on a rootless daemon), plus `--cap-drop=ALL` and `--security-opt=no-new-privileges`.
- `/home/nerves` and `/app` are chmod'd `a+rwX` in the Dockerfile so arbitrary uids can use the baked-in Mix archives and Elixir install.
- `~/.ncc-nerves-cache` and `~/.ncc-hex-cache` persist across runs and speed up repeated tests.
- `make build` keeps Docker's layer cache; `make build-clean` adds `--no-cache` when the apt, Elixir and Hex-archive layers need refetching.
- The image carries Souffle 2.5 and the argus_beam escript at `/home/nerves/.mix/escripts/argus`. amd64 installs Souffle's upstream `.deb`; arm64 builds it from source, so a local `make build` on Apple silicon takes noticeably longer.
- argus is configured from `/admin` (`Portal.Settings`) and passed through `NCC_INPUT.argus`. Its findings are advisory and never change a status.

## Deploy

CI deploys `main`: `.github/workflows/deploy.yml` runs the tests, waits for the audit, CodeQL, Credo and Sobelow workflows to pass on the same commit (`ops/wait-for-checks.sh`), then runs `ops/deploy.sh` on the hosts through `ops/ssh-deploy.sh`. A failing check blocks the deploy. See `DEPLOY.md` and `ops/README.md`.

## Dependency Policy

The worker rejects any project whose `mix.lock` references git or path deps. This is enforced in `NccWorker.LockPolicy` and is load-bearing for reproducibility — don't relax it without updating docs/tests and understanding the consequences.

## Generated / Ignored Paths

`_build/`, `deps/`, `tmp/`, `public/`, `*.dets`, `compat_test_results/`, and the `~/.ncc-*` caches are generated. Never commit them. `.elixir_ls/` is also ignored.
