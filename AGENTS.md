# Repository Guidelines

## Project Structure & Module Organization

This repository is a monorepo of independent Elixir Mix projects; there is no top-level `mix.exs`.

- `compat/`: shared types, JSON index loaders, and validators.
- `beam_scanner/`: compiled BEAM inspection.
- `worker/`: Docker-side Nerves project setup, firmware builds, and result JSON.
- `runner/`: host-side Docker invocation and output collection.
- `orchestrator/`: Hex.pm polling, queue management, runner invocation, and site regeneration.
- `site/`: static HTML and JSON generation.
- `docs/`, `PRECOMPILED_API.md`, and `package_metadata.json`: contracts and package overrides.

Do not commit generated paths such as `_build/`, `deps/`, `public/`, `runner/tmp/`, `compat_test_results/`, or `*.dets`.

## Build, Test, and Development Commands

Use the root `Makefile` for full workflows:

- `make build` builds the local worker image `ncc-worker:local`.
- `make run PACKAGE=jason:1.4.1` checks one package end to end.
- `make site` collects results and generates `public/site/`.
- `make test-all` runs the configured sample package set.
- `make test-integration` runs the Docker-backed runner integration test.
- `make format` runs `mix format` across the Mix projects.

For project-local work:

```bash
cd worker
mix deps.get
mix test
mix test test/ncc_worker/scanner_test.exs
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
