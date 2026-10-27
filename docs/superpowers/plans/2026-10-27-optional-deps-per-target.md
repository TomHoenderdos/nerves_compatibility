# Optional deps per target: implementation plan

> For agentic workers: executed subagent-driven, one task per implementer, task review after each, whole-branch review at the end.

**Goal:** firmware packages publish each passing target's files compiled with their optional dependencies, with a per-system `deps_lock`, without changing any status.

**Spec:** `docs/superpowers/specs/2026-10-27-optional-deps-per-target-design.md` (the authority; read it first).

**Worktree / branch:** `.claude/worktrees/optional-per-target`, `feat/optional-per-target` from main `00f77d6`.

## Global constraints

- Run every `mix` command from the umbrella root. Never `mix deps.*` inside `apps/*`.
- Statuses, classification, host result, firmware images, `cache_candidates` never change because of the pass.
- Exit codes unchanged: the only new error is `{:error, {:optional_deps_revert_failed, reason}}` (exit 10).
- Migrations additive only; no existing index or constraint reshaped.
- Commit trailer exactly: `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`. Commit by theme with explicit paths. Do not push.
- Gates before a task reports DONE: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo`, the tests of the touched apps. Sobelow strict for touched apps (`mix sobelow --root apps/<app> [--no-router for ncc_worker] --private --skip --strict --exit low`, check `$?`).

## Review focus

1. A target whose optional pass fails publishes exactly its first build's files (moved aside and back, byte for byte), never a half-compiled lib dir.
2. `mix.exs`/`mix.lock` after the pass equal the snapshot, so `put_deps_lock`, argus and footprint never see the optional deps.
3. Run-level `deps_lock` of a firmware run is the status build's lock, read before the pass.
4. A manifest entry for a system with its own `deps_lock` uses it; one without falls back to the run's (old rows, carried rows, pure-Elixir runs).
5. A carried system result keeps its `deps_lock`.

---

### Task 1: worker per-target pass

**Files:** `apps/ncc_worker/lib/ncc_worker/worker.ex`, `apps/ncc_worker/lib/ncc_worker/project.ex`, `apps/ncc_worker/lib/ncc_worker/json_writer.ex`, tests under `apps/ncc_worker/test/ncc_worker/` (`worker_*`/`project_test.exs`/`json_writer_test.exs`; add a focused test module for the pass, e.g. `optional_deps_targets_test.exs`).

**Produces (consumed by Task 2 through result.json):** per-system keys `deps_lock` (`%{name => %{"version", "checksum"}}`, only on systems that kept the optional deps) and `optional_deps` (`%{added, dropped, reason}`, only on systems that were passing); run-level `optional_deps` summary per the spec; run-level `deps_lock`/`package_checksum` read before the pass for firmware runs.

Steps:
1. Split `Project.add_optional_deps/5` so the inject step and the per-env `remove_stale_build` + `deps_get` step are callable separately; keep `add_optional_deps/5`'s behaviour and its existing tests green.
2. Put the pass in a small module of its own (e.g. `NccWorker.OptionalDepsTargets`) with injectable runners (deps.get, compile, scan, lock policy) so it tests offline; `Worker` calls it after `build_all_systems` for a firmware run and before `put_deps_lock` (which for firmware runs must use the lock read before the pass).
3. Write the tests listed in the spec's worker section first, then the code. Stubs only: no Hex, no `mix` in unit tests.
4. Update the `result` typespec and `JsonWriter`.
5. Gates, commit.

### Task 2: portal storage and manifests

**Files:** `apps/portal/lib/portal/catalog/system_result.ex`, a new migration via `mix ash_postgres.generate_migrations --name system_result_deps_lock` (inspect it: one `add :deps_lock, :map` column, nothing else), `apps/portal/lib/portal/catalog/ingestion.ex` (map + carry), `apps/portal/lib/portal/catalog.ex` (`build_inputs/2` and every select feeding it), tests under `apps/portal/test/portal/catalog/` and the manifest tests.

**Consumes:** result.json per-system `deps_lock` from Task 1.

Steps: tests first (ingestion stores / rejects partial / carries; manifest prefers the system's lock, falls back to the run's, both formats), then code, migrate dev and test DBs, gates, commit.

### Task 3: docs and Docker integration test

**Files:** `CLAUDE.md` (step 4), `apps/ncc_worker/README.md`, `PRECOMPILED_API.md` (per-entry `build.deps`, caveat, 2026-10-23 → 2026-10-24), `apps/portal/test/portal/workers/build_integration_test.exs` (ecto 3.14.2 on `nerves_system_x86_64` per the spec).

Steps: write docs, add the integration test, `make build`, run `mix test --include integration apps/portal/test/portal/workers/build_integration_test.exs`, report the output, commit.
