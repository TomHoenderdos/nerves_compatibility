# Phase 1 — Umbrella Scaffold + Rename — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the repo from 6 standalone Mix projects into a Mix **umbrella** holding `apps/compatibility` (renamed from `compat`), `apps/ncc_worker` (with `beam_scanner` folded in), and `apps/portal`, while keeping the soon-to-be-deleted `runner`/`site`/`orchestrator` compiling standalone — and keep the Docker worker image building.

**Architecture:** A new umbrella root (`mix.exs` with `apps_path: "apps"`, root `config/`) builds the three keeper apps as one project. `compat`→`compatibility` is a directory + app-name + module rename (`Compat.*`→`Compatibility.*`). `beam_scanner` collapses into `apps/ncc_worker` (same `BeamScanner.*` namespace, now in-app). The trio `runner`/`site`/`orchestrator` stay at repo root as standalone projects; only their `compat` path-dep + `Compat.*` references are repointed so they still compile. The `apps/ncc_worker/Dockerfile` is rewritten for the umbrella layout, copying **only** `compatibility` + `worker` so Phoenix/Ash never enter the container image.

**Tech Stack:** Elixir/Mix umbrella, ExUnit, Docker (worker image `ncc-worker:local`).

## Global Constraints

- **No behavior changes.** This phase is purely structural. Every existing test must still pass; no test logic is rewritten.
- **Worker reproducibility boundary is untouched:** worker reads `NCC_INPUT`, writes `result.json`, exit codes `0`/`10`/`11`, `LockPolicy` — none change.
- **Worker container image must NOT contain Phoenix/Ash/Oban.** The `apps/ncc_worker/Dockerfile` copies only `apps/compatibility` + `apps/ncc_worker`.
- **App names stay the same except `:compat`→`:compatibility`.** `worker` keeps OTP app `:ncc_worker`; `runner`/`site`/`orchestrator` keep theirs.
- **The Docker integration test is the invariant gate.** Do not consider Phase 1 done until `make build` succeeds and the runner integration test passes.
- **Never commit generated paths:** `_build/`, `deps/`, `*.dets`, `runner/tmp/`, `public/`. (Each app's `.gitignore` already covers these.)

---

## File Structure (created / moved in this phase)

| Path | Responsibility |
| --- | --- |
| `mix.exs` (new, root) | Umbrella project definition (`apps_path: "apps"`) |
| `.formatter.exs` (new, root) | Umbrella formatter, delegates to `apps/*` |
| `config/config.exs` (new, root) | Umbrella compile-time config; imports portal config if present |
| `config/runtime.exs` (new, root) | Umbrella runtime config; imports portal runtime if present |
| `apps/compatibility/` (moved from `compat/`) | Shared contract; modules renamed `Compat.*`→`Compatibility.*` |
| `apps/ncc_worker/` (moved from `worker/`) | In-container escript; `beam_scanner` folded in |
| `apps/portal/` (moved from `portal/`) | Phoenix app; config now imported from root |
| `apps/ncc_worker/Dockerfile` (rewritten) | Builds worker escript from the umbrella layout |
| `runner/`, `site/`, `orchestrator/` (stay) | Standalone; `compat` dep + `Compat.*` refs repointed only |

---

## Task 1: Umbrella skeleton + move `compat` → `apps/compatibility` (renamed)

**Files:**
- Create: `mix.exs`, `.formatter.exs`, `config/config.exs`, `config/runtime.exs`
- Move: `compat/` → `apps/compatibility/` (incl. `lib/compat`→`lib/compatibility`, `test/compat`→`test/compatibility`)
- Modify: `apps/compatibility/mix.exs` (app name), all `apps/compatibility/**/*.ex(s)` (module rename)

**Interfaces:**
- Produces: OTP app `:compatibility`; modules `Compatibility`, `Compatibility.Types`, `Compatibility.Index.LatestByPackage`, `Compatibility.Index.LatestByPackageSystem`, `Compatibility.Index.Stats`, `Compatibility.PackageMetadata`. Public funcs unchanged (e.g. `Compatibility.Types.parse_status/1`, `Compatibility.Types.status_to_string/1`).

- [ ] **Step 1: Create the umbrella root `mix.exs`**

```elixir
defmodule NervesCompatibility.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Dependencies listed here are available only for this umbrella root project
  # and cannot be accessed from applications inside the apps/ folder.
  defp deps do
    []
  end
end
```

- [ ] **Step 2: Create the umbrella root `.formatter.exs`**

```elixir
[
  inputs: ["mix.exs", "config/*.exs"],
  subdirectories: ["apps/*"]
]
```

- [ ] **Step 3: Create the umbrella root `config/config.exs`**

Portal is not moved until Task 3, and the worker Docker image never copies portal, so the portal import is guarded by `File.exists?`.

```elixir
import Config

# Portal (Phoenix) config lives with the app and is imported here when present.
# Guarded so the worker Docker image (which copies only compatibility + worker)
# still builds without apps/portal on disk.
if File.exists?(Path.expand("../apps/portal/config/config.exs", __DIR__)) do
  import_config "../apps/portal/config/config.exs"
end
```

- [ ] **Step 4: Create the umbrella root `config/runtime.exs`**

```elixir
import Config

if File.exists?(Path.expand("../apps/portal/config/runtime.exs", __DIR__)) do
  import_config "../apps/portal/config/runtime.exs"
end
```

- [ ] **Step 5: Move `compat` into `apps/` and rename its lib/test dirs**

```bash
mkdir -p apps
git mv compat apps/compatibility
git mv apps/compatibility/lib/compat apps/compatibility/lib/compatibility
git mv apps/compatibility/lib/compat.ex apps/compatibility/lib/compatibility.ex
git mv apps/compatibility/test/compat apps/compatibility/test/compatibility
```

- [ ] **Step 6: Rename the app name in `apps/compatibility/mix.exs`**

Change line `app: :compat,` to `app: :compatibility,`. Leave version/deps as-is.

- [ ] **Step 7: Rename modules `Compat` → `Compatibility` across the app**

```bash
grep -rl 'Compat' apps/compatibility/lib apps/compatibility/test \
  | xargs perl -pi -e 's/\bCompat\b/Compatibility/g'
```

This rewrites `defmodule Compat`, `Compat.Types`, `Compat.Index.*`, `Compat.PackageMetadata` to the `Compatibility.*` forms. The `\b` word boundary leaves the lowercase OTP atom `:compat` (handled in Step 6) and file paths untouched.

- [ ] **Step 8: Verify compile + existing compatibility tests pass from the umbrella root**

Run: `mix deps.get && mix compile && mix test`
Expected: compiles with no `Compat`-undefined errors; only `compatibility` is in the umbrella so far, and its existing `latest_by_package_test.exs` (and siblings) PASS.

- [ ] **Step 9: Commit**

```bash
git add mix.exs .formatter.exs config apps/compatibility
git commit -m "refactor: scaffold umbrella, move compat -> apps/compatibility (Compat -> Compatibility)"
```

---

## Task 2: Move `worker` → `apps/ncc_worker` and fold in `beam_scanner`

**Files:**
- Move: `worker/` → `apps/ncc_worker/`; `beam_scanner/lib/*` → `apps/ncc_worker/lib/`; `beam_scanner/test/*` → `apps/ncc_worker/test/`
- Modify: `apps/ncc_worker/mix.exs` (deps), `apps/ncc_worker/lib/ncc_worker/worker.ex`, `apps/ncc_worker/lib/ncc_worker/json_writer.ex` (module refs)
- Delete: `beam_scanner/`

**Interfaces:**
- Consumes: `Compatibility.*` (from Task 1) as an in-umbrella dep.
- Produces: OTP app `:ncc_worker` containing both `NccWorker.*` and `BeamScanner.*` (`BeamScanner`, `BeamScanner.Analyzer`). The `ncc_worker` escript still builds.

- [ ] **Step 1: Move `worker` into `apps/`**

```bash
git mv worker apps/ncc_worker
```

- [ ] **Step 2: Fold `beam_scanner` source + tests into `apps/ncc_worker`**

```bash
git mv beam_scanner/lib/beam_scanner apps/ncc_worker/lib/beam_scanner
git mv beam_scanner/lib/beam_scanner.ex apps/ncc_worker/lib/beam_scanner.ex
# move beam_scanner tests if any exist
[ -d beam_scanner/test ] && git mv beam_scanner/test/* apps/ncc_worker/test/ 2>/dev/null || true
git rm -r beam_scanner
```

- [ ] **Step 3: Update `apps/ncc_worker/mix.exs` deps**

Replace the deps list (was `{:beam_scanner, path: "../beam_scanner"}, {:compat, path: "../compat"}, {:req, "~> 0.5.0"}`) with:

```elixir
defp deps() do
  [
    {:compatibility, in_umbrella: true},
    {:req, "~> 0.5.0"}
  ]
end
```

`beam_scanner` is gone (its modules are now in this app); `compat` becomes the in-umbrella `compatibility`. If `beam_scanner/mix.exs` declared any hex deps, add them here — verify with `cat beam_scanner/mix.exs` before deletion in Step 2 (the audit showed it had none beyond commented examples).

- [ ] **Step 4: Rename `Compat` → `Compatibility` references in worker source**

```bash
grep -rl 'Compat' apps/ncc_worker/lib apps/ncc_worker/test \
  | xargs perl -pi -e 's/\bCompat\b/Compatibility/g'
```

(Affects `worker.ex` and `json_writer.ex`, which reference `Compat.Types`.)

- [ ] **Step 5: Verify compile + worker and compatibility tests pass**

Run: `mix deps.get && mix compile && mix test`
Expected: PASS (umbrella now holds `compatibility` + `worker`). No `BeamScanner`-undefined and no `Compat`-undefined errors.

- [ ] **Step 6: Verify the escript still builds**

Run: `cd apps/ncc_worker && mix escript.build && ls ncc_worker && cd ../..`
Expected: `ncc_worker` escript produced, no errors.

- [ ] **Step 7: Commit**

```bash
git add apps/ncc_worker
git rm -r --cached beam_scanner 2>/dev/null || true
git commit -m "refactor: move worker -> apps/ncc_worker, fold beam_scanner in"
```

---

## Task 3: Move `portal` → `apps/portal` (config imported from root)

**Files:**
- Move: `portal/` → `apps/portal/`
- Verify: root `config/config.exs` + `config/runtime.exs` (created in Task 1) now import portal's config because the file exists.

**Interfaces:**
- Consumes: nothing new (portal keeps its current deps + `ash_sqlite`; the Postgres swap is Phase 2).
- Produces: OTP app `:portal` as an umbrella app. `PortalWeb.Endpoint` boots under the umbrella.

- [ ] **Step 1: Move `portal` into `apps/`**

```bash
git mv portal apps/portal
```

Portal's `config/` dir moves with it. The root `config/config.exs` from Task 1 already does `import_config "../apps/portal/config/config.exs"` guarded by `File.exists?`, which is now true. Portal's `config/config.exs` ends with `import_config "#{config_env()}.exs"`, resolved relative to `apps/portal/config/`, so its env files and `__DIR__`-relative asset/db paths stay correct. No config content is rewritten.

- [ ] **Step 2: Verify the umbrella compiles with all three apps**

Run: `mix deps.get && mix compile`
Expected: fetches Phoenix/Ash/etc. for portal plus worker/compatibility deps; compiles clean.

- [ ] **Step 3: Verify portal tests pass under the umbrella**

Run: `mix test apps/portal`
Expected: PASS (portal still on `ash_sqlite`; SQLite file created under `apps/portal/var/`).

- [ ] **Step 4: Verify the full umbrella test suite passes**

Run: `mix test`
Expected: compatibility + worker + portal suites all PASS.

- [ ] **Step 5: Smoke-check the Phoenix server boots**

Run: `cd apps/portal && MIX_ENV=dev mix phx.server` — confirm it boots and binds (Ctrl-C to stop), then `cd ../..`.
Expected: `Running PortalWeb.Endpoint` log line, no crash.

- [ ] **Step 6: Commit**

```bash
git add apps/portal config
git commit -m "refactor: move portal -> apps/portal, import its config from umbrella root"
```

---

## Task 4: Keep `runner` / `site` / `orchestrator` compiling standalone

These three are deleted in Phase 6. For now they stay at repo root as standalone projects; only their `compat` path-dep and `Compat.*` references need repointing. `runner` depends on `jason` only and needs no change.

**Files:**
- Modify: `site/mix.exs` (dep), `site/lib/site/generator.ex` (module refs)
- Modify: `orchestrator/lib/orchestrator.ex`, `orchestrator/lib/orchestrator/processor.ex` (module refs)

**Interfaces:**
- Consumes: `apps/compatibility` via path dep (`site`) and transitively (`orchestrator` through `site`).

- [ ] **Step 1: Repoint `site`'s compat dependency**

In `site/mix.exs`, change `{:compat, path: "../compat", override: true}` to:

```elixir
{:compatibility, path: "../apps/compatibility", override: true}
```

- [ ] **Step 2: Rename `Compat` → `Compatibility` in `site` source**

```bash
grep -rl 'Compat' site/lib site/test 2>/dev/null \
  | grep -v '_build' \
  | xargs perl -pi -e 's/\bCompat\b/Compatibility/g'
```

(Affects `site/lib/site/generator.ex`.)

- [ ] **Step 3: Verify `site` still compiles + tests pass standalone**

Run: `cd site && mix deps.get && mix test && cd ..`
Expected: PASS.

- [ ] **Step 4: Rename `Compat` → `Compatibility` in `orchestrator` source**

```bash
grep -rl 'Compat' orchestrator/lib orchestrator/test 2>/dev/null \
  | grep -v '_build' \
  | xargs perl -pi -e 's/\bCompat\b/Compatibility/g'
```

(Affects `orchestrator/lib/orchestrator.ex` and `orchestrator/lib/orchestrator/processor.ex`. `orchestrator` reaches `Compatibility.*` transitively through its `site` path dep, as it did with `compat` before.)

- [ ] **Step 5: Verify `orchestrator` still compiles + tests pass standalone**

Run: `cd orchestrator && mix deps.get && mix test && cd ..`
Expected: PASS.

- [ ] **Step 6: Verify `runner` is unaffected**

Run: `cd runner && mix deps.get && mix test && cd ..`
Expected: PASS (no `compat` dep, no changes).

- [ ] **Step 7: Commit**

```bash
git add site/mix.exs site/lib orchestrator/lib
git commit -m "refactor: repoint runner/site/orchestrator to apps/compatibility"
```

---

## Task 5: Rewrite `apps/ncc_worker/Dockerfile` for the umbrella + verify the Docker gate

**Files:**
- Modify: `apps/ncc_worker/Dockerfile`
- Modify: `Makefile` (worker build context / escript path, if it references `worker/`)

**Interfaces:**
- Produces: the `ncc-worker:local` image with the same `ENTRYPOINT` behavior; the runner integration test passes against it.

- [ ] **Step 1: Update the COPY/build section of `apps/ncc_worker/Dockerfile`**

Replace the old copy+build block (was `COPY compat ./compat`, `COPY beam_scanner ./beam_scanner`, `COPY worker ./worker`, `WORKDIR /app/worker`, build, `ENTRYPOINT ["/app/worker/ncc_worker"]`) with the umbrella layout. Copy **only** the umbrella root manifest, config, and the two apps the worker needs — never `apps/portal`:

```dockerfile
# Copy umbrella manifest + config and ONLY the apps the worker needs.
# apps/portal is intentionally NOT copied, so Phoenix/Ash never enter the image.
COPY mix.exs mix.lock ./
COPY config ./config
COPY apps/compatibility ./apps/compatibility
COPY apps/ncc_worker        ./apps/ncc_worker

RUN sudo chown -R nerves:nerves /app /work /out /hex-cache /home/nerves/.nerves

# Build the worker escript. mix only discovers compatibility + worker under apps/,
# so deps.get fetches only their deps.
WORKDIR /app
RUN mix deps.get
WORKDIR /app/apps/ncc_worker
RUN mix clean --deps
RUN mix escript.build
```

And update the entrypoint:

```dockerfile
ENTRYPOINT ["/app/apps/ncc_worker/ncc_worker"]
```

Keep all other lines (base image, Elixir install, archive installs, `mkdir`, ssh-keygen, final `chmod -R a+rwX /home/nerves /app`) unchanged. Ensure the final `chmod` line still references `/app` (it does).

- [ ] **Step 2: Confirm the umbrella root `config/config.exs` guard protects this build**

The image does not copy `apps/portal`, so `File.exists?(".../apps/portal/config/config.exs")` is false and the portal import is skipped. No action needed — this step is a read-through verification of Task 1 Step 3.

- [ ] **Step 3: Update the Makefile build target**

In Task 2 the Dockerfile moved with the worker dir — it now lives at `apps/ncc_worker/Dockerfile`. The Makefile `build` target currently reads `docker build --no-cache -f worker/Dockerfile -t ncc-worker:local .`. Update the `-f` flag to the new path (keep the `.` context — repo root is correct for the umbrella):

```make
build: apps/ncc_worker/Dockerfile
	@echo "Building worker Docker image..."
	docker build --no-cache -f apps/ncc_worker/Dockerfile -t $(WORKER_IMAGE) .
```

Also update any host-side escript recipe `cd worker && mix escript.build` → `cd apps/ncc_worker && mix escript.build`.

- [ ] **Step 4: Build the worker image (THE GATE, part 1)**

Run: `make build`
Expected: image builds; final stage produces `/app/apps/ncc_worker/ncc_worker`; no Phoenix/Ash in the dep fetch logs.

- [ ] **Step 5: Run the runner integration test (THE GATE, part 2)**

Run: `make test-integration`
Expected: jason → real container → asserts pass. This proves the worker boundary survived the restructure.

- [ ] **Step 6: Commit**

```bash
git add apps/ncc_worker/Dockerfile Makefile
git commit -m "build: rewrite worker Dockerfile for umbrella layout"
```

---

## Task 6: Update docs + format + final full-green verification

**Files:**
- Modify: `Makefile` (per-project `cd` paths for `compat`/`worker`), `CLAUDE.md`, `AGENTS.md`

**Interfaces:** none (docs + tooling only).

- [ ] **Step 1: Update Makefile per-project paths**

Anywhere the Makefile does `cd compat`, `cd worker`, or `mix format` over those dirs, change to `cd apps/compatibility` / `cd apps/ncc_worker`. The `format` target (was `cd compat && mix format`, etc.) should run `mix format` at the umbrella root instead:

```make
format:
	mix format
	@echo "Formatted all umbrella code."
```

(Standalone `runner`/`site`/`orchestrator` keep their own `cd <dir> && mix format` lines until Phase 6 deletes them.)

- [ ] **Step 2: Update CLAUDE.md + AGENTS.md project layout**

Edit the "Project Layout" sections to describe the umbrella: `apps/compatibility`, `apps/ncc_worker` (beam_scanner folded), `apps/portal`, with `runner`/`site`/`orchestrator` noted as legacy standalone projects pending removal. Replace `compat/` references with `apps/compatibility/` and `Compat.Types` with `Compatibility.Types`.

- [ ] **Step 3: Format check the umbrella**

Run: `mix format && mix format --check-formatted`
Expected: clean (no diff).

- [ ] **Step 4: Final full umbrella test run**

Run: `mix test`
Expected: all umbrella suites (compatibility, worker, portal) PASS.

- [ ] **Step 5: Final standalone trio test run**

Run: `for d in runner site orchestrator; do (cd $d && mix test) || exit 1; done`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add Makefile CLAUDE.md AGENTS.md
git commit -m "docs: update layout for umbrella; format umbrella"
```

---

## Done criteria (Phase 1)

- `mix compile` + `mix test` green at the umbrella root (compatibility + worker + portal).
- `runner`, `site`, `orchestrator` still compile + test green standalone.
- `make build` produces `ncc-worker:local` with no Phoenix/Ash in the image.
- `make test-integration` passes (the invariant gate).
- No `Compat.*` references remain in active source (`grep -rn '\bCompat\b' apps runner site orchestrator --include=*.ex --include=*.exs` returns nothing outside `_build`).
