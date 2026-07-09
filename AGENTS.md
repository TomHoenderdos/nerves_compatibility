# Repository Guidelines

## Project Structure & Module Organization

This repository is a **Mix umbrella** (top-level `mix.exs`) with three apps under `apps/`:

- `apps/compatibility`: shared compatibility types, JSON schema structs/loaders, validators, and status helpers.
- `apps/ncc_worker`: Docker-side Nerves project setup, firmware builds, result JSON, BEAM file inspection, and content-addressed artifact archiving. Dockerfile at `apps/ncc_worker/Dockerfile`.
- `apps/portal`: Phoenix 1.8 + Ash/Postgres + Oban web app for admin UI, accounts, scan-request intake, build queue, Catalog persistence, dynamic package browser, badges, schema-v2 JSON API, and precompiled artifact serving.

Other:

- `docs/`, `PRECOMPILED_API.md`: contracts and operating docs.
- `config/`: umbrella runtime/config guarded so the worker Docker image can build without portal files copied into the image.

Do not commit generated paths such as `_build/`, `deps/`, `public/`, `compat_test_results/`, or `*.dets`.

## Build, Test, and Development Commands

Use the root `Makefile`:

- `make build` builds the local worker image `ncc-worker:local`.
- `make dev` starts the Phoenix portal server.
- `make test` runs the umbrella test suite.
- `make test-integration` runs the Docker-backed Portal build integration test.
- `make format` runs `mix format` across the umbrella.

For umbrella-level work (run from repo root):

```bash
mix deps.get
mix test
mix test apps/ncc_worker/test/ncc_worker/scanner_test.exs
mix format
```

Portal work:

```bash
cd apps/portal
mix setup
mix phx.server
mix test
mix precommit
```

## Coding Style & Naming Conventions

Use standard Elixir formatting via `mix format`; do not hand-align code. Module names should match directory structure, for example `NccWorker.Scanner` in `apps/ncc_worker/lib/ncc_worker/scanner.ex`. Tests use `_test.exs` filenames under each app's `test/` directory. Keep boundaries explicit: portal owns host-side Docker invocation and persistence; worker owns in-container Mix/Nerves setup and result generation.

## Testing Guidelines

Each umbrella app has its own ExUnit suite. Run focused tests in the app you changed, then broaden when touching shared contracts such as result JSON, index formats, Docker mounts, artifact paths, or exit codes. Run `make test-integration` after worker image, portal builder, or runner-worker JSON contract changes.

## Commit & Pull Request Guidelines

History uses short imperative commits and scoped messages. Use concise subjects, optional subsystem prefixes, and no generated-file noise.

Pull requests should summarize behavior changes, list commands run, and call out Docker, deployment, contract, or cache implications. Include screenshots only for visible portal changes.

## Agent-Specific Instructions

Prefer existing Makefile and Mix tasks over ad hoc scripts. Do not relax the worker dependency policy for git/path deps or change documented exit codes without updating the relevant docs and tests. For portal work, read `apps/portal/AGENTS.md` and run `mix precommit` when finishing.
