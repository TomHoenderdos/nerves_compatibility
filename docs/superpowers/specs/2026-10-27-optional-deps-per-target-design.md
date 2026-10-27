# Optional dependencies for firmware packages, per target

Date: 2026-10-27. Status: approved by Tom (chat, 2026-10-27) on the design in
`~/Projects/ncc-optional/.optional-deps-report.md`, section "Design note and gap".

## Problem

A real application almost always has a package's optional dependencies in its
lock (plug next to ash, vintage_net next to mdns_lite, nerves_time next to
nerves_motd). A package compiles differently when an optional module is
loadable, so the precompiled API publishes its dependency closure in
`build.deps` and the client uses a build only when its own lock matches.

Since 2026-10-24 the worker adds the package's unresolved optional
dependencies in a best-effort second pass, but only for a `pure_elixir`
package: its one set of published files is the host build. A firmware package
publishes one set of files per Nerves target, built from `_build/<target>`,
and the pass skips it (`optional_deps.reason: "firmware_build"`). So every
firmware package with optional dependencies misses for every real
application. Seen on a Pi: ash (optional plug; ash is firmware because its
closure has Erlang beams, and its toolchain build is skipped because it calls
`System.cmd/2`), mdns_lite (vintage_net), nerves_motd (nerves_time,
nerves_time_zones).

## Decision

After the firmware builds, a second pass per passing target recompiles the
package with its optional dependencies added and republishes that target's
files with them. Statuses, the classification, the host result and every
firmware image stay exactly as the first build decided. Where the pass fails
for a target, that target keeps the files and lock of the first build.

One published variant per target (the files with the optional dependencies
when the pass worked), not two. That is the same choice the pure-Elixir pass
made: an application without the optional dependency misses, which is the
rare case.

## Worker (`apps/ncc_worker`)

Order inside `NccWorker.Worker` for a firmware run (`selection == :firmware`,
scope not `argus_only`):

1. Unchanged: host compile, classification, `runtime_applications`, the
   firmware builds of every target (`build_all_systems`).
2. Read the run-level lock now: `DepsLock.read/2` and
   `DepsLock.package_checksum/2` on the project as the status build left it.
   This is `result.deps_lock` / `result.package_checksum` for a firmware run
   (today they are read at the very end, which would otherwise pick up the
   optional dependencies).
3. The per-target pass, only when `Project.optional_deps_to_add/1` leaves a
   non-empty list and at least one target has `status: :pass`:
   1. `Project.snapshot/1` of `mix.exs` and `mix.lock`.
   2. For every passing target, move `_build/<target>/lib/<package>` aside to
      `_build/<target>/lib/.<package>.status-build` (a rename on the same
      filesystem). This is the target's first build, kept byte for byte.
   3. Inject the optional dependencies into `mix.exs` once (the existing
      injection in `Project.add_optional_deps`; generalise it so the inject
      step and the per-target `deps.get` + stale-build removal can be called
      separately, keeping the host-pass behaviour and its tests unchanged).
      A failed inject drops the pass for every target.
   4. Serially, per passing target, with that target's env from
      `prepare_system/4` (`MIX_TARGET`, `MIX_BUILD_PATH`, `MIX_DEPS_PATH`,
      `MIX_ENV=prod`, `HEX_HOME`): `mix deps.get`, then `LockPolicy.validate/1`.
      Serial because they share the root `mix.lock`, as the first build's
      deps.get already is.
   5. Per target that got through 4, `mix compile` with the same env
      (concurrency `build_concurrency()`, like the firmware builds; each
      target has its own build and deps path). No `mix firmware`. Output is
      appended to `logs/<system>.log` after a header line
      `==> optional dependencies: <names>`. Bounded by the per-system timeout.
   6. Per target where 5 passed: rescan `_build/<target>/lib/<package>`
      (`analyze_beam_scan/2`), re-read `compile_env`, and replace that
      system's `beam_scan` and `compile_env`. Set the system's
      `deps_lock` to `DepsLock.read/2` of the lock after the pass and its
      `optional_deps` to `%{added: names, dropped: [], reason: nil}`. Delete
      the moved-aside first build.
   7. Per target where 4 or 5 failed: remove whatever the pass left in
      `_build/<target>/lib/<package>` and rename the moved-aside first build
      back. The system keeps its `beam_scan`, `compile_env`, has no
      per-system `deps_lock` (the run-level one applies) and gets
      `optional_deps: %{added: [], dropped: names, reason: <reason>}` with
      reason `deps_get_failed`, `lock_policy_violation`,
      `target_compile_failed`, `mix_exs_edit_failed` or `timeout`.
   8. Finally restore `mix.exs` and `mix.lock` from the snapshot, so nothing
      after the pass (argus, footprint, `put_deps_lock`) sees them.
4. A restore that fails (step 7's rename back, or step 8) is the only error
   path: `{:error, {:optional_deps_revert_failed, reason}}`, exit 10, as the
   host pass does. Publishing files nobody checked would be worse.
5. Nothing in the pass changes `status`, `firmware_size_bytes`, `log_tail`,
   `error`, `dependency_scans` or `cache_candidates` of any system. The
   pass's compile of the package is never stored in the build cache (its key
   would describe the lock without the optional dependencies).

Run-level `optional_deps` for a firmware run: `added` = names kept on at least
one target, `dropped` = names dropped on every target that tried, `skipped` as
today, `reason` = the first target's drop reason when nothing was kept, else
`nil`. Systems that were not passing get no `optional_deps` key.

`NccWorker.JsonWriter` writes the two new per-system keys `deps_lock` and
`optional_deps` (only when present). The `result` typespec documents them.

Partial runs (`systems_filter`): the pass covers the built targets only.
Toolchain and pure-Elixir runs: unchanged.

## Portal (`apps/portal`)

- `Portal.Catalog.SystemResult` gains a nullable `deps_lock` map attribute
  (same shape as `Run.deps_lock`). One additive migration; no existing index
  or constraint changes.
- `Portal.Catalog.Ingestion` maps a system's `deps_lock` through the same
  all-or-nothing `deps_lock/1` normaliser it uses for the run. Carrying a
  system forward (partial runs) copies `deps_lock` with the rest.
- `Portal.Catalog.build_inputs/2`: `"deps" => result.deps_lock || run.deps_lock`.
  Every query that feeds it selects the new attribute. Format 1 and format 2
  manifests both go through it.
- `per_system optional_deps` is not stored.

## Docs

- `CLAUDE.md` step 4 and `apps/ncc_worker/README.md`: the pass now covers
  firmware targets.
- `PRECOMPILED_API.md`: `build.deps` is per entry; the caveats list says
  entries from firmware runs before this deploy were built without optional
  dependencies; fix the "2026-10-23" dates to 2026-10-24 (the real deploy of
  the pure-Elixir pass).

## Tests

- Worker unit tests with stubbed runners (no Hex, no mix): the move-aside
  and restore of `_build/<target>/lib/<pkg>`, per-target outcomes (one target
  kept, one dropped on compile failure), restore of `mix.exs`/`mix.lock`
  after the pass, run-level `deps_lock` read before the pass, revert failure
  returns `{:error, {:optional_deps_revert_failed, _}}`, no pass when no
  target passed or nothing to add, JsonWriter keys.
- Portal: ingestion stores a system's `deps_lock`, rejects a partial one
  (nil), carries it; the manifests use a system's `deps_lock` over the run's
  and fall back to the run's when absent.
- Docker integration (`build_integration_test.exs`, `:integration`): ecto
  3.14.2 with `systems_filter: ["nerves_system_x86_64"]` (firmware because of
  telemetry, optional jason): the x86_64 system result's `deps_lock` names
  jason, the run's does not, every status is `pass`, and the v2 manifest's
  x86_64 entry lists jason in `build.deps`.

## Rollout

Normal CI deploy, then `ops/deploy-builders.sh` for the home builders. After
that, rebuild the firmware packages that have optional dependencies, starting
with ash and its family, mdns_lite, nerves_motd and the Phoenix packages
(`Portal.BulkRebuild.run/1` with `names:`). Clients pick the new entries up
with the next signed batch.

## Out of scope

- Building dependents against several versions of their dependencies, or
  loosening the strict key (ash_sql built against ash 3.37.2 misses for an
  application on 3.37.0). Tom's decision, separate.
- Publishing two variants per target.
