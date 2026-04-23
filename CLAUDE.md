# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Layout

This is a **monorepo of five independent Mix projects** that together produce a static site tracking Hex.pm package compatibility with Nerves target systems. The projects depend on each other via `path:` dependencies — there is no top-level `mix.exs`. Each project has its own `deps/`, `_build/`, and `mix.lock`.

| Project | Role | Produces |
| --- | --- | --- |
| `compat/` | Core library: JSON index loaders, validators, shared types (`Compat.Types`, `Compat.Index.*`) | Library (used as path dep) |
| `beam_scanner/` | Scans compiled BEAM files for NIF loads, ports, Application env use, etc. | Library |
| `worker/` | Runs **inside** the Docker container. Creates a Nerves project, adds the package, builds firmware per system, enforces Hex-only deps. | `ncc_worker` escript |
| `runner/` | Runs **on the host**. Takes a job JSON, invokes Docker with the right mounts, collects `result.json` + logs. | `ncc_runner` escript |
| `orchestrator/` | Long-running service: polls Hex.pm, maintains DETS queue, invokes runner, regenerates site. Depends on `runner` and `site`. | `ncc_orchestrator` escript |
| `site/` | Static site generator (Mix tasks `site.gen`, `site.serve`, `convert_results`). | HTML + JSON in `public/` |

The worker/runner split is deliberate: the worker never touches Docker, the runner never touches Mix projects. They communicate only via the JSON input/output contract described in `worker/README.md` and `docs/INDEX_FORMAT.md`.

## Common Commands

The top-level `Makefile` orchestrates the full pipeline. Most day-to-day work goes through it.

```bash
make build                         # Rebuild the ncc-worker:local Docker image (needed when Dockerfile or worker/ changes)
make run PACKAGE=jason:1.4.1       # Run one package through the full pipeline
make test-all                      # Run the hardcoded TEST_PACKAGES list
make test-integration              # End-to-end runner test: jason → real container → assert pass (needs docker + built image)
make collect                       # Gather runner/tmp/*-results into compat_test_results/
make site                          # collect + generate public/site/
make shell                         # Interactive shell in the worker container (add PACKAGE=x:y to pre-stage a job)
make clean                         # Remove runner/tmp, public/data, public/site, compat_test_results
make realclean                     # clean + purge ~/.ncc-nerves-cache and ~/.ncc-hex-cache
make format                        # mix format in all four Elixir projects
```

The integration test (`runner/test/ncc_runner/integration_test.exs`) is the regression gate for the worker+runner boundary. It's tagged `:integration` and excluded from `mix test` by default; run it after any change that could affect Docker invocation, the JSON contract, or the worker's firmware-build path.

Per-project work (run from each subdir):

```bash
mix deps.get
mix test                           # compat, worker, runner, orchestrator, site all have their own suites
mix test path/to/file_test.exs:42  # single test
mix escript.build                  # worker, runner, orchestrator produce escripts
mix format
```

Site-only loop (no Docker needed when iterating on templates/generator):

```bash
cd site
mix site.gen --in ../example_data --out ../public
mix site.serve --dir ../public --port 4000    # http://localhost:4000/site/index.html
```

## How a Package Gets Checked (End-to-End)

1. **Orchestrator** (`orchestrator/lib/orchestrator/hex_poller.ex`) polls Hex.pm, pushes new `{pkg, ver}` into a DETS-backed queue (`queue.dets`). Already-checked entries live in `checked.dets`.
2. **Processor** (`orchestrator/lib/orchestrator/processor.ex`) pulls from the queue and shells out to the runner escript with a job JSON.
3. **Runner** (`runner/lib/ncc_runner/docker.ex`) validates Docker, creates `work_dir` / `output_dir` / `files_dir`, and `docker run`s `ncc-worker:local` with the mounts:
   - `/work` → per-run scratch
   - `/out` → outputs (result.json, logs, runner_metadata.json)
   - `/home/nerves/.nerves` → shared Nerves cache (`~/.ncc-nerves-cache`)
   - `/hex-cache` → shared Hex cache (`~/.ncc-hex-cache`)
4. **Worker** (`worker/lib/ncc_worker/worker.ex`) inside the container:
   - Reads `NCC_INPUT` (default `/work/input.json`).
   - `NccWorker.Project.create/3` generates a fresh Nerves project and adds the target package.
   - `NccWorker.LockPolicy` aborts with exit 11 if `mix.lock` contains any non-Hex (git/path) deps.
   - Builds firmware for each Nerves system; captures status, firmware size, log tail, BEAM scan, footprint.
   - `NccWorker.FileArchiver` content-addresses compiled artifacts by SHA256 into `files_dir` for the precompiled API.
   - Writes atomic `result.json`.
5. **Site generator** (`site/lib/site/generator.ex`) reads the three index JSONs and emits HTML pages, per-package SVG badges, a precompiled-package manifest (`site/lib/site/precompiled_manifest.ex`), and copies logs.

## Exit Code Conventions

Worker and runner use numeric exit codes that propagate meaning up the stack — don't change these casually:

- **Worker**: `0` ok, `10` internal failure, `11` policy violation (non-Hex dep).
- **Runner**: `0` ok, `20` runner error (bad input, Docker missing, no result.json), `21` worker container exited non-zero.

## Data Contracts

- **Job input** (runner → worker): see `runner/examples/` and `worker/examples/input.json`. Key fields: `run_id`, `image.name`, `image.digest`, `package.{name,version}`, optional `systems_override`, `systems_filter`, `paths`, `limits`.
- **Worker output** (`result.json`): typespec at top of `worker/lib/ncc_worker/worker.ex`. Status enum lives in `Compat.Types` — `pass | fail | error | skipped | unknown`.
- **Site indexes**: `latest_by_pkg.json`, `latest_by_pkg_system.json`, `stats.json`. Schema version 2. Documented in `docs/INDEX_FORMAT.md`.
- **Package overrides**: `package_metadata.json` at repo root lets you force status / add notes / allow-list or deny-list systems without running tests. Documented in `docs/PACKAGE_METADATA.md`.
- **Precompiled API**: manifests and content-addressed files served by the site. Full spec in `PRECOMPILED_API.md`.

## Container / Caching Details Worth Knowing

- The worker image is based on `ghcr.io/nerves-project/nerves_system_br`. The runner passes `--user $(id -u):$(id -g)` so the container runs as the invoking host user — this keeps bind-mounted files owned by the user on Linux. `/home/nerves` and `/app` are chmod'd `a+rwX` in the Dockerfile so arbitrary uids can use the baked-in Mix archives and Elixir install. `HOME=/home/nerves` is set at run time.
- `~/.ncc-nerves-cache` and `~/.ncc-hex-cache` persist across runs and dramatically speed up repeated tests. `make realclean` wipes them.
- `make build` uses `--no-cache`. For a faster rebuild during Dockerfile iteration, run `docker build` manually without `--no-cache`.

## Dependency Policy (Worker)

The worker **rejects any project whose `mix.lock` references git or path deps**. This is enforced in `NccWorker.LockPolicy` and is load-bearing for reproducibility — don't relax it without understanding why it exists (see `worker/README.md`).

## Generated / Ignored Paths

`_build/`, `deps/`, `tmp/`, `public/`, `*.dets`, `compat_test_results/`, `runner/tmp/`, and the `~/.ncc-*` caches are all generated. Never commit them. `.elixir_ls/` is also ignored.
