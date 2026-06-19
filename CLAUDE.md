# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Layout

This is a **Mix umbrella** at the repo root (top-level `mix.exs`) plus three legacy standalone projects and two non-Mix deploy targets, together producing a static site tracking Hex.pm package compatibility with Nerves target systems.

### Umbrella apps (`apps/`)

| App | Role | Produces |
| --- | --- | --- |
| `apps/compatibility` | Core library: JSON index loaders, validators, shared types (`Compatibility.Types`, `Compatibility.Index.*`) | Library (used as umbrella dep) |
| `apps/ncc_worker` | Runs **inside** the Docker container. Creates a Nerves project, adds the package, builds firmware per system, enforces Hex-only deps. Includes BEAM file scanner (formerly `beam_scanner/`). Dockerfile at `apps/ncc_worker/Dockerfile`. | `ncc_worker` escript |
| `apps/portal` | **Phoenix 1.8 + SQLite** web app: admin UI, accounts, GitHub/Hex auth, stores scan requests and forwards them to the orchestrator. | Phoenix server |

### Legacy standalone projects (pending removal in Phase 2)

| Project | Role | Produces |
| --- | --- | --- |
| `runner/` | Runs **on the host**. Takes a job JSON, invokes Docker with the right mounts, collects `result.json` + logs. Depends on `apps/compatibility` via `path:`. | `ncc_runner` escript |
| `orchestrator/` | Long-running service: polls Hex.pm, maintains a DETS **priority** queue, serves a scan-request HTTP API, invokes runner, regenerates site. Depends on `apps/compatibility`, `runner`, and `site`. | `ncc_orchestrator` escript |
| `site/` | Static site generator (Mix tasks `site.gen`, `site.serve`, `convert_results`). Depends on `apps/compatibility` via `path:`. | HTML + JSON in `public/` |

Non-Mix deploy targets:

- `functions/` — **Cloudflare Pages Functions** (JS). Public scan-request intake: `api/scan-requests.js` (anonymous, Cloudflare Turnstile-gated) and `api/auth/hex/{start,complete}.js` (Hex OAuth device flow). Each verifies the caller, then forwards to the orchestrator's HTTP API with a `Bearer` shared secret.
- `public/site/` — the generated static artifact, deployed to Cloudflare Pages (`wrangler.toml`, `make deploy-site`).

The worker/runner split is deliberate: the worker never touches Docker, the runner never touches Mix projects. They communicate only via the JSON input/output contract described in `apps/ncc_worker/README.md` and `docs/INDEX_FORMAT.md`.

`apps/portal/AGENTS.md` carries extensive Phoenix 1.8 / LiveView / HEEx conventions — read it before touching `apps/portal/`.

## Common Commands

The top-level `Makefile` orchestrates the full pipeline. Most day-to-day work goes through it.

```bash
make build                         # Rebuild the ncc-worker:local Docker image (needed when apps/ncc_worker/Dockerfile or apps/ncc_worker/ changes)
make run PACKAGE=jason:1.4.1       # Run one package through the full pipeline
make test-all                      # Run the hardcoded TEST_PACKAGES list
make test-integration              # End-to-end runner test: jason → real container → assert pass (needs docker + built image)
make collect                       # Gather runner/tmp/*-results into compat_test_results/
make site                          # collect + generate public/site/
make shell                         # Interactive shell in the worker container (add PACKAGE=x:y to pre-stage a job)
make clean                         # Remove runner/tmp, public/data, public/site, compat_test_results
make realclean                     # clean + purge ~/.ncc-nerves-cache and ~/.ncc-hex-cache
make format                        # mix format at umbrella root + runner/site/orchestrator
```

The integration test (`runner/test/ncc_runner/integration_test.exs`) is the regression gate for the worker+runner boundary. It's tagged `:integration` and excluded from `mix test` by default; run it after any change that could affect Docker invocation, the JSON contract, or the worker's firmware-build path.

Umbrella commands (run from repo root):

```bash
mix deps.get
mix test                           # runs all umbrella apps (compatibility, ncc_worker, portal)
mix test apps/compatibility/test/  # single umbrella app
mix format                         # format all umbrella apps
```

Per-project work for standalone projects (run from each subdir):

```bash
mix deps.get
mix test                           # runner, orchestrator, site each have their own suites
mix test path/to/file_test.exs:42  # single test
mix escript.build                  # runner, orchestrator produce escripts
mix format
```

Site-only loop (no Docker needed when iterating on templates/generator):

```bash
cd site
mix site.gen --in ../example_data --out ../public
mix site.serve --dir ../public --port 4000    # http://localhost:4000/site/index.html
```

Portal (Phoenix, in the umbrella — run from repo root or from apps/portal):

```bash
cd apps/portal
mix setup                          # deps + SQLite DB create/migrate + assets
mix phx.server                     # http://localhost:4001
mix test
mix precommit                      # run when finishing portal changes (see apps/portal/AGENTS.md)
```

Note: `make format` runs `mix format` at the umbrella root (covers `apps/compatibility`, `apps/ncc_worker`, `apps/portal`) and then formats `runner/`, `site/`, and `orchestrator/` individually.

## How a Package Gets Checked (End-to-End)

1. **Orchestrator** (`orchestrator/lib/orchestrator/hex_poller.ex`) polls Hex.pm, pushes new `{pkg, ver}` into a DETS-backed queue (`queue.dets`). Already-checked entries live in `checked.dets`.
2. **Processor** (`orchestrator/lib/orchestrator/processor.ex`) pulls from the queue and shells out to the runner escript with a job JSON.
3. **Runner** (`runner/lib/ncc_runner/docker.ex`) validates Docker, creates `work_dir` / `output_dir` / `files_dir`, and `docker run`s `ncc-worker:local` with the mounts:
   - `/work` → per-run scratch
   - `/out` → outputs (result.json, logs, runner_metadata.json)
   - `/home/nerves/.nerves` → shared Nerves cache (`~/.ncc-nerves-cache`)
   - `/hex-cache` → shared Hex cache (`~/.ncc-hex-cache`)
4. **Worker** (`apps/ncc_worker/lib/ncc_worker/worker.ex`) inside the container:
   - Reads `NCC_INPUT` (default `/work/input.json`).
   - `NccWorker.Project.create/3` generates a fresh Nerves project and adds the target package.
   - `NccWorker.LockPolicy` aborts with exit 11 if `mix.lock` contains any non-Hex (git/path) deps.
   - Builds firmware for each Nerves system; captures status, firmware size, log tail, BEAM scan, footprint.
   - `NccWorker.FileArchiver` content-addresses compiled artifacts by SHA256 into `files_dir` for the precompiled API.
   - Writes atomic `result.json`.
5. **Site generator** (`site/lib/site/generator.ex`) reads the three index JSONs and emits HTML pages, per-package SVG badges, a precompiled-package manifest (`site/lib/site/precompiled_manifest.ex`), and copies logs.

The orchestrator's queue is **priority-ordered** (`orchestrator/lib/orchestrator/queue.ex`): rank `hex_owner` (0) < `github_repo` (10) < `anonymous` (50) < `normal` (100, the Hex poller's default) < `pending_review` (200). Lower rank pops first; re-queuing an existing package keeps the higher-priority entry.

## On-Demand Scan Requests (Dynamic Site)

Beyond the Hex poller, users can request a specific package be scanned. Two intake fronts converge on one orchestrator endpoint:

1. **Cloudflare Pages Functions** (`functions/api/`) — anonymous requests pass Turnstile; package owners auth via Hex OAuth device flow. Both forward to the orchestrator.
2. **Portal** (`portal/`, Phoenix) — `Portal.ScanRequests.forward_to_orchestrator/2` POSTs via `Req` to the orchestrator using `:orchestrator_scan_request_url` + `:scan_request_shared_secret`.

**Orchestrator HTTP API** (`Orchestrator.ScanRequestRouter`, a `Plug.Router` served by **Bandit**): `POST /scan-requests`, `/auth/hex/start`, `/auth/hex/complete`, `GET /health`. All non-health routes require `Authorization: Bearer <shared_secret>`. The server is **off by default** — enable via `config :orchestrator, :scan_request_server, true` (port `:scan_request_port`, default 4080) and set `NCC_SCAN_REQUEST_SECRET` (`:scan_request_shared_secret`). Wired in `application.ex` (`maybe_add_scan_request_server/1`).

`Orchestrator.ScanRequest.submit/1` validates the package, authorizes by `:source` (`:hex_owner` / `:github_repo` require a verified subject; `:anonymous_turnstile` requires a human check), and maps source → queue priority. `Orchestrator.HexAuth` implements the Hex.pm OAuth device login and package-ownership check. Auth providers live **outside** `ScanRequest` — the caller (Function or portal) verifies identity first, then submits with the matching `:source`.

## Exit Code Conventions

Worker and runner use numeric exit codes that propagate meaning up the stack — don't change these casually:

- **Worker**: `0` ok, `10` internal failure, `11` policy violation (non-Hex dep).
- **Runner**: `0` ok, `20` runner error (bad input, Docker missing, no result.json), `21` worker container exited non-zero.

## Data Contracts

- **Job input** (runner → worker): see `runner/examples/` and `apps/ncc_worker/examples/input.json`. Key fields: `run_id`, `image.name`, `image.digest`, `package.{name,version}`, optional `systems_override`, `systems_filter`, `paths`, `limits`.
- **Worker output** (`result.json`): typespec at top of `apps/ncc_worker/lib/ncc_worker/worker.ex`. Status enum lives in `Compatibility.Types` — `pass | fail | error | skipped | unknown`.
- **Site indexes**: `latest_by_pkg.json`, `latest_by_pkg_system.json`, `stats.json`. Schema version 2. Documented in `docs/INDEX_FORMAT.md`.
- **Package overrides**: `package_metadata.json` at repo root lets you force status / add notes / allow-list or deny-list systems without running tests. Documented in `docs/PACKAGE_METADATA.md`.
- **Precompiled API**: manifests and content-addressed files served by the site. Full spec in `PRECOMPILED_API.md`.

## Container / Caching Details Worth Knowing

- The worker image is based on `ghcr.io/nerves-project/nerves_system_br`. The runner passes `--user $(id -u):$(id -g)` so the container runs as the invoking host user — this keeps bind-mounted files owned by the user on Linux. `/home/nerves` and `/app` are chmod'd `a+rwX` in the Dockerfile so arbitrary uids can use the baked-in Mix archives and Elixir install. `HOME=/home/nerves` is set at run time.
- `~/.ncc-nerves-cache` and `~/.ncc-hex-cache` persist across runs and dramatically speed up repeated tests. `make realclean` wipes them.
- `make build` uses `--no-cache`. For a faster rebuild during Dockerfile iteration, run `docker build` manually without `--no-cache`.

## Dependency Policy (Worker)

The worker **rejects any project whose `mix.lock` references git or path deps**. This is enforced in `NccWorker.LockPolicy` and is load-bearing for reproducibility — don't relax it without understanding why it exists (see `apps/ncc_worker/README.md`).

## Generated / Ignored Paths

`_build/`, `deps/`, `tmp/`, `public/`, `*.dets`, `compat_test_results/`, `runner/tmp/`, and the `~/.ncc-*` caches are all generated. Never commit them. `.elixir_ls/` is also ignored.
