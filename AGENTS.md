# Repository Guidelines

## Project Structure & Module Organization

This repository is a **Mix umbrella** (top-level `mix.exs`) with three umbrella apps and three legacy standalone projects (pending removal in Phase 2).

Umbrella apps under `apps/`:

- `apps/compatibility`: shared types (`Compatibility.Types`), JSON index loaders, and validators.
- `apps/ncc_worker`: Docker-side Nerves project setup, firmware builds, result JSON, and BEAM file inspection (beam_scanner folded in). Dockerfile at `apps/ncc_worker/Dockerfile`.
- `apps/portal`: Phoenix 1.8 + SQLite web app for admin UI, accounts, and scan-request intake.

Legacy standalone projects at repo root (depend on `apps/compatibility` via `path:`):

- `runner/`: host-side Docker invocation and output collection.
- `orchestrator/`: Hex.pm polling, queue management, runner invocation, and site regeneration.
- `site/`: static HTML and JSON generation.

Other:

- `docs/`, `PRECOMPILED_API.md`, and `package_metadata.json`: contracts and package overrides.
- `functions/`: Cloudflare Pages Functions (JS) for public scan-request intake.

Do not commit generated paths such as `_build/`, `deps/`, `public/`, `runner/tmp/`, `compat_test_results/`, or `*.dets`.

## Build, Test, and Development Commands

Use the root `Makefile` for full workflows:

- `make build` builds the local worker image `ncc-worker:local`.
- `make run PACKAGE=jason:1.4.1` checks one package end to end.
- `make site` collects results and generates `public/site/`.
- `make test-all` runs the configured sample package set.
- `make test-integration` runs the Docker-backed runner integration test.
- `make format` runs `mix format` across the Mix projects.

For umbrella-level work (run from repo root):

```bash
mix deps.get
mix test
mix test apps/ncc_worker/test/ncc_worker/scanner_test.exs
mix format
```

For standalone project work (run from the project's subdir):

```bash
cd runner    # or site, orchestrator
mix deps.get
mix test
mix escript.build
```

Site-only iteration:

```bash
cd site
mix site.gen --in ../example_data --out ../public
mix site.serve --dir ../public --port 4000
```

## Coding Style & Naming Conventions

Use standard Elixir formatting via `mix format`; do not hand-align code. Module names should match directory structure, for example `NccWorker.Scanner` in `worker/lib/ncc_worker/scanner.ex`. Tests use `_test.exs` filenames under each project’s `test/` directory. Keep boundaries explicit: runner owns Docker invocation; worker owns Mix/Nerves setup.

## Testing Guidelines

Each Mix project has its own ExUnit suite. Run focused tests in the project you changed, then broaden when touching shared contracts such as result JSON, index formats, Docker mounts, or exit codes. Run integration tests after worker image, runner Docker, or runner-worker JSON changes.

## Commit & Pull Request Guidelines

History uses short imperative commits such as `Bump all dependencies` and scoped messages like `Site: add experimental banner and per-package report link`. Use concise subjects, optional subsystem prefixes, and no generated-file noise.

Pull requests should summarize behavior changes, list commands run, and call out Docker, Cloudflare, contract, or cache implications. Include screenshots only for visible `site/` changes.

## Agent-Specific Instructions

Prefer existing Makefile and Mix tasks over ad hoc scripts. Do not relax the worker dependency policy for git/path deps or change documented exit codes without updating the relevant docs and tests.
