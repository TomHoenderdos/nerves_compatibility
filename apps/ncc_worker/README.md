# NCC Worker

Container-side program that evaluates one Hex package against the official Nerves systems.

The worker runs inside the Docker container — it never invokes Docker itself. On the host, `Portal.Builder` mounts the directories and starts it.

## What it does

1. Reads a job from `NCC_INPUT` (default `/work/input.json`).
2. Generates a fresh Nerves project and adds the target package. If that package's own `mix deps.get` fails,
   `NccWorker.DepsGetClassifier` names the failure transient (DNS, a refused or dropped connection, a timeout, a
   TLS error, or an HTTP 5xx/429 from `hex.pm`/`repo.hex.pm`: a retry could succeed, so the run stays an internal
   failure and exits `10` as before) or deterministic (everything else, defaulting to deterministic when nothing
   matches: a dependency's own `mix.exs` raising, a version resolution conflict, a package that does not exist).
   A deterministic failure is recorded as a normal verdict instead of retried: every system this run would have
   built (`systems_filter` respected, so a `targets` run only records those) gets `"status": "error"`,
   `"error": "deps_get_failed"`, and the `deps.get` output as its `log_tail` and stored log, `result.json` is
   written and the exit code is `0`, same reasoning as a toolchain run's failed host compile below — nothing about
   retrying the same `mix.exs` three times a day would ever change the outcome. An `argus_only` run is the one
   exception: it reports `"systems": {}` — not even `"host"` — instead, so `Portal.Catalog.Ingestion`'s
   carry-forward for a partial run copies every system of the package's previous run untouched rather than
   overwriting their real statuses with `"error"` from what is meant to be an advisory sweep; `"argus"` is marked
   skipped with `"reason": "deps_get_failed"`. This can only run on top of a same-version previous run —
   `Portal.Workers.Build.scope_args/3` picks `argus_only` only when one already exists — so there is always
   something to carry.
3. Rejects the run if `mix.lock` contains any non-Hex deps (exit 11).
4. Compiles the package on the host. If that passes and the whole dependency closure is pure Elixir
   (`NccWorker.BuildSelection`), records an assumed-compatible `pure_elixir` result instead of building firmware.
   Otherwise builds firmware for each Nerves system (`NccWorker.Systems`), capturing status, size, and a log tail.
   When the host compile failed, rpi4 builds alone first; if it fails too, the rest are recorded as
   `skipped` ("host and <system> failed to compile") without being built (`NccWorker.SeedGate`).
   A `systems_filter` in `NCC_INPUT` builds only those systems and reports `"scope": "targets"` in `result.json`;
   otherwise the scope is `"full"`. Each passing firmware target then records its system release's `toolchain`,
   `otp_full` and, unless `NCC_INPUT.known_system_abi` names the release, `system_libs` (see "System ABI" below).
   For a `pure_elixir` package, a best-effort second pass then adds the package's optional dependencies that the
   project left unresolved (`NccWorker.DepsLock.unresolved_optional_deps/2`, from the package's own `mix.lock` entry)
   and recompiles the package on the host with them loadable. A real application almost always has them in its lock
   (decimal next to jason), and the package compiles differently with them, so files built without them match no
   such application in the precompiled API. The pass never changes a status or the classification, which both come
   from the build without them. If `mix deps.get`, the lock policy or the host compile fails with them, the worker
   restores `mix.exs` and `mix.lock`, removes `_build/host/lib/<package>` and rebuilds without them. Both ways
   (after the `deps.get` that adds them, and after the restore) it also removes the build of every dependency whose
   closure in the lock changed (`NccWorker.DepsLock.changed_closures/2`): Mix rebuilds a dependency whose optional
   dependency appeared only when that `deps.get` fetched it, and never one whose optional dependency went away, so
   ecto built with jason would otherwise stay that way in the rebuild without jason. A firmware
   package is not given the pass: its published files come from every target's build, which it would have to
   repeat. `result.json` records the outcome as `optional_deps`:
   `{"added": ["decimal"], "dropped": [], "skipped": [], "reason": null}`, where `dropped` lists what was left out
   and `reason` is one of `deps_get_failed`, `lock_policy_violation`, `host_compile_failed`,
   `stale_build_not_removed`, `mix_exs_edit_failed` or `firmware_build`. `skipped` lists optional dependencies never
   tried because most applications do not lock them: dev tooling (`igniter`, `sourceror`, `rewrite`, `ex_doc`,
   `credo`, `dialyxir`, `stream_data`, `excoveralls`, `mix_test_watch`, `benchee`) and alternatives an application
   picks one of (`picosat_elixir`, `simple_sat`); the list is `Compatibility.OptionalDeps.never_added/0`, which the
   portal's coverage report reads too.
   `host.log` carries the same lines. The key is absent for argus-only runs.

   Its `pure_elixir` host files are published only when rule 2 passes, as for a toolchain build (see "Toolchain
   mode"): the static rules (`BuildSelection.static_rules/4`) on the beams that would be published, and the
   compile-time trace. A refusal keeps the assumed-compatible status and publishes no files, and `result.json`'s
   `host_portability` says why. The static rules run again here because the selection judged the closure before the
   optional-dependency pass recompiled it: code an optional dependency compiles in, such as a NIF load, is refused.
   A tracer that crashes or trips a cap is `"portability could not be judged"`. The trace runs after the
   optional-dependency pass and before the beam scan, so the files scanned and archived are the traced compile's; it
   is judged against
   the lock snapshot matching the build it judges, taken as in a toolchain run. Unlike a toolchain run, a full run
   keeps this dedicated traced judge compile after its host compile: its closure is compiled by nerves_bootstrap
   inside `mix deps.get`, so its host compile cannot be the traced one. A traced compile that did not finish
   (killed, timed out) may leave `_build/host/lib` half-written, so the worker rebuilds it untraced before the scan
   (`mix compile` alone, under `timeout(1)` at the per-system timeout cut to what is left of the run; no `deps.get`,
   no build cache store; skipped when no time is left). A raise anywhere on this path is "portability could not be
   judged" and never fails the run. The host status, the `pure_elixir` verdict, its beam scan and `compile_env`, argus and the log tail's first sentence
   are what they would have been without a tracer. `host_portability` is
   `{"status": "pass" | "skipped", "reason": null | "...", "portability_rule": 2, "compile_observations": {...} | null}`,
   present only for a run whose selection was `pure_elixir`.

   A firmware run gets the same idea, but after every target's firmware build has settled its status
   (`NccWorker.OptionalDepsTargets`): once `build_all_systems` returns, the worker reads the run-level `deps_lock`
   and `package_checksum` from the project's `mix.lock` as the status build left it (this is what `result.json`
   reports at the top level for a firmware run; reading it any later would pick up the optional dependencies), then,
   when there is at least one dependency to add and at least one target with `status: "pass"`, snapshots `mix.exs`
   and `mix.lock`, injects the optional dependencies once, and for every passing target moves its first build's
   `_build/<target>/lib/<package>` aside, runs `mix deps.get` and the lock policy serially (the targets share the
   root `mix.lock`), then `mix compile` (no `mix firmware`) concurrently, bounded by the per-system timeout. A
   target whose compile passes gets its `beam_scan` and `compile_env` rescanned and keeps the new build, with its
   own per-system `deps_lock` (shaped like the run's) and `optional_deps: {"added": [...], "dropped": [],
   "reason": null}`, and publishes its first build beside it: the moved-aside build is renamed to
   `_build/<target>/lib/.<package>.without` and every file its firmware-time beam scan listed is checked again
   (a plain file, same size, sha256 and mode). When they all match, the system gets
   `published_variants: [{"variant": "without", "beam_scan": {"footprint": {"file_manifest": ...}},
   "compile_env": [...], "deps_lock": {...}}]`, the first build's own file manifest and `compile_env` under the
   run's `deps_lock`, and `NccWorker.FileArchiver` archives those files from that directory, skipping one whose
   bytes no longer hash to the recorded sha256 (it hashes, then copies: the portal's digest check of each stored
   blob is what guarantees the bytes). When they do not, or the first build has no file manifest, no `compile_env` or no
   readable run lock, the first build is deleted, the target's log says why (`files_changed`,
   `no_file_manifest`, `compile_env_unreadable`, `deps_lock_unreadable`, `rename_failed`,
   `stale_variant_not_removed`), and the target publishes the new build alone, as before. The system's own keys
   always describe the build with the optional dependencies, so a reader that ignores `published_variants` sees
   what it always did. A target that fails anywhere in this gets back exactly its first build, byte for byte, no
   per-system `deps_lock`, no `published_variants`, and `optional_deps: {"added": [], "dropped": [...], "reason":
   "<reason>"}`. `mix.exs`
   and `mix.lock` are always restored from the snapshot afterwards, so nothing later (argus, the footprint scan,
   the run-level `deps_lock`) sees the optional dependencies. Nothing in this pass changes a status, a firmware
   image, `firmware_size_bytes`, `log_tail`, `error`, `dependency_scans` or `cache_candidates` of any system, and
   its compile is never stored in the build cache (the cache key would describe the lock without the optional
   dependencies). A system that was not passing when the pass ran gets no `deps_lock` or `optional_deps` key.

   A target's drop reason is one of `deps_get_failed`, `lock_policy_violation`, `target_compile_failed` (including
   a raise from any runner, or an OOM kill), `mix_exs_edit_failed` (the inject failed, which drops every target),
   `stale_build_not_removed` (the move-aside, or the pass's own cleanup, could not rename or remove the build
   directory, or the lock was unreadable around `deps.get`, so the dependencies to rebuild were unknown), `deps_lock_unreadable` (the lock could not be read after `deps.get`, so a kept target would have no
   lock of its own to publish against), `timeout` (the per-system timeout, which bounds the pass's `deps.get` as
   well as its compile, or the pass's own budget ran out before the target's `deps.get` or compile could start),
   or `run_budget_exhausted` (the run had already used too much of its time, so the pass did not start; see
   below). A target whose compile passed but whose rescan reports errors, or whose `.app` yields no
   `compile_env`, is dropped as `target_compile_failed` rather than kept, so it publishes its first build. The run-level `optional_deps` for a firmware run has
   `added` = names kept on at least one target, `dropped` = names dropped on every target that tried, and
   `reason` = the first target's drop reason, `nil` when something was kept; when no target was passing to begin
   with the run-level reason is `no_passing_target` instead, with every dependency listed in `dropped`. A target
   whatever its drop reason leaves no half-compiled lib dir behind: the pass kills anything its compile left
   running under that target's `MIX_BUILD_PATH` before putting the first build back, and a writer that survives is
   the worker's only new error path for this pass, `{:error, {:optional_deps_revert_failed, reason}}` (exit `10`,
   same as every other internal failure) — publishing files nobody checked would be worse than a retried run.

   The pass is bounded by a time budget: a target not yet started by the deadline is dropped as `timeout`, and
   each compile gets at most whatever is left. Separately, if the run itself has already used too much of its time
   by the time `build_all_systems` returns, the pass does not start at all — nothing is snapshotted, injected or
   moved — and every passing target is dropped with reason `run_budget_exhausted`, so a slow run keeps its
   statuses rather than losing the whole run.

   **Firmware world** (`NCC_INPUT.firmware_world: {"name": "nerves", "members": [...]}`, sent by the portal while
   its `firmware_world_enabled` setting is on; `NccWorker.WorldTargets`). After the pass above, on the same budget
   and deadline, each passing target can publish a third build: the package compiled with, at every depth of its
   closure, each unresolved optional dependency that is a world member (the prod set of a default `mix nerves.new`
   app, `Compatibility.Worlds.firmware_members/1`), resolved by the toolchain world's fixpoint
   (`NccWorker.WorldDeps`). It runs also when the package has no optional dependency of its own (an optional jason
   under ecto). Nothing is copied or compiled when no member is reachable from the lock. Otherwise each passing
   target's published build has its `priv`/`include` links made its own, `_build/<target>/lib` is copied
   (`cp -a`, no `.<package>.*` dirs) to `_build/<target>.world/lib`, and everything after builds under that path:
   the fixpoint once (in the first target's env), the package, every dependency whose closure changed, and every
   dependency the build with may have compiled with an optional dependency the world lacks removed from each world
   build path, `deps.get` and the lock policy for each other target serially (the lock must not
   move), then `mix compile`, the beam scan and `compile_env` concurrently. A kept target's build is renamed to
   `_build/<target>/lib/.<package>.world_nerves`, checked against its scan, and appended to the system's
   `published_variants` as `{"variant": "world_nerves", "beam_scan": {"footprint": {"file_manifest": ...}},
   "compile_env": [...], "deps_lock": {...}}`, the world closure. Every passing target's published build and its
   build without are checked again afterwards; a changed byte is `{:error, {:optional_deps_revert_failed, _}}`
   (exit `10`). The world build paths are removed and `mix.exs`/`mix.lock` restored on every path. A target is
   dropped, with the reason in its log, as `same_closure_as_without` (the world closure is the run lock's),
   `same_closure_as_with` (it is the target's own `deps_lock`), `world_extra_deps` (the fixpoint locked a package
   outside the closure that was not in the lock before), `world_lock_moved`, `world_not_converged`, `copy_failed`,
   `files_changed`, or any reason of the pass above. The run then has `firmware_world: "world:nerves"` (the echo,
   whatever was kept) and `optional_deps.firmware_world: {"name", "added", "rounds", "kept": [systems], "reason"}`.
   An image before this ignores the key and publishes no world, and so does this one for a well-formed world it
   does not pin (`Compatibility.Worlds.firmware_variant/1`); a malformed one exits `10`. `NccWorker.FirmwareBuildRoot`
   judges the world build from its own `.<package>.world_nerves` dir, like the build without from its own.

   Partial runs (`systems_filter`) run the pass over the targets that were actually built. Toolchain and
   pure-Elixir runs are unaffected by any of this; see above for their own optional-dependency pass.

   Once the pass has settled which builds a target publishes, each passing target's own build and its
   `published_variants` are judged by the baked build path rule the host judge applies to a toolchain build's own
   beams (R2, `NccWorker.FirmwareBuildRoot` over `NccWorker.Portability.BuildRoot.program_source_paths/4`), with the
   project dir (so `deps_<target>` and `_build/<target>`), the OTP and Elixir installs, `HOME`, `MIX_HOME`, the
   target's `HEX_HOME` and the Nerves artifact and download dirs as roots. A bare source path of a dependency in
   `deps_<target>` (Ecto query metadata) is observed, unless its module runs programs or the package runs a shell;
   any other root (a `__DIR__`, a `_build` path, a directory the code reads at runtime) refuses, and an `ebin` the
   rule cannot read cannot be judged. A refused or unjudged own build loses `beam_scan.footprint.file_manifest`, so
   nothing of it is archived or published; a refused variant is dropped from `published_variants`. The status, the
   firmware image and the log tail never change. Each judged system carries `build_root`: `{"status": "pass" |
   "skipped", "reason", "observations": [{"rule", "path"}], "variants": {"without": {"status", "reason"}}}`
   (`variants` only when one was judged), and `host.log` gets a line per withheld build. The portal stores it, and a
   refusal withdraws the target's older builds of the same version (`Portal.Precompiled.FirmwareRefusal`).
5. When `NCC_INPUT` carries `argus` (`{"analyses": ["default", "exposure"], "scope": "firmware", "timeout_seconds": 300}`),
   runs the argus_beam escript over the host-compiled beams (`NccWorker.Argus`) and writes its findings to
   `result.json` as `argus`. `scope: "firmware"` limits this to packages that build firmware. Advisory: it never
   changes a status or the exit code. When `argus.status` is `"skipped"`, `argus.reason` says why: `"disabled"`
   (no `argus` key -- the admin turned it off), `"not_requested"` (scope is `"firmware"` and this package is pure
   Elixir), `"host_compile_failed"` (the host build this would have read beams from did not pass; `argus.error`
   then carries that build's status, e.g. `"host status: fail"`), `"no_beams"` (the package's host `ebin` has
   no `.beam` to analyze, e.g. a pure-metadata package like `nerves_pack`), or `"deps_get_failed"` (the package's
   own `mix deps.get` failed deterministically before a host compile ever ran -- see step 2's `argus_only`
   exception). `nil` otherwise.
   With `"mode": "argus_only"` the run stops after the host compile and this step: no firmware is built, argus
   covers every package (whatever `argus.scope` says), and `result.json` reports `"scope": "argus_only"`.
   Ingestion copies the systems a partial run left out from the previous run of the same version.
6. Records `deps_lock` in `result.json`: the package's transitive dependency closure from the project's `mix.lock`,
   the optional dependencies added in step 4 included and the package itself excluded, as `{"spark": {"version": "2.7.8", "checksum": "<outer Hex checksum>"}}`
   (`NccWorker.DepsLock`). Dependencies' macros are compiled into the package's BEAMs, so the precompiled API
   publishes this for clients to match against their own lock. The key is absent for argus-only runs, which build
   nothing, and when the lock cannot be read. It also records `package_checksum`, the package's own outer Hex checksum,
   and each system result's `compile_env` (the `.app` file's compile-time config reads, values as base64url deterministic terms).
   For a firmware run, the run-level `deps_lock` and `package_checksum` are the status build's, read before the
   per-target optional pass in step 4; a system that pass kept its optional dependencies for carries its own
   `deps_lock` instead (same shape), which the precompiled API prefers over the run's for that system's entries;
   its `published_variants` entry, the first build, carries the run's `deps_lock` and is a second format-2 build
   of that system.
   - `declared` — the package's declared dependencies from its own lock entry,
     `[{"app", "name", "requirement", "optional"}]` sorted by app, optional ones
     included whether or not the build resolved them. Absent when the lock could
     not be read. `toolchain_build.declared` is the same for a toolchain run.
7. Writes atomic `/out/result.json` plus per-system logs under `/out/logs/`, and archives compiled files by SHA256 under `/files`.
   The package's own files are its `ebin/` and `priv/` from `_build/<target>/lib/<package>/`, the target's compile
   output with `debug_info` intact, not the release copy, whose BEAMs are stripped (`NccWorker.BeamScan`,
   `NccWorker.Footprint`, `NccWorker.FileArchiver`). Dependencies' files are still archived from the release.
8. The shared dependency build cache at `/build-cache` is mounted read-only — the container can restore from it
   (`NccWorker.BuildCache.restore/1`) but cannot write it. A passing build of the package under test (a failed one
   can leave a half-compiled tree, so it stores nothing) is instead stored to `/out/build-cache/<key>/`
   (`NccWorker.BuildCache.store/2`) and reported in `result.json` as `cache.candidates`, one entry per system:
   `%{"key", "dep", "dep_lock", "target", "elixir", "otp", "closure"}`, where `closure` is `[%{"name", "lock"}]`
   and `"key"` is `Compatibility.BuildCacheKey.key/1` of the rest. The host (`Portal.BuildCache.Promotion`) caps the
   candidates at one per reported system plus one, requires each `target` and toolchain to be one the run built
   with, recomputes the key with `dep` forced to the package under test, requires it to equal the reported one, ties
   the lock's outer checksum to the one Hex publishes for the release, and only then moves the candidate into the
   shared cache — the worker never decides which key its own output lands under.
   Dependencies other than the package under test still get stored, but to a run-local tier under the container's
   own `/tmp` rather than the shared cache, so a multi-target run still compiles a shared dependency once and
   restores it for the other targets without trusting the container to fill the shared cache itself.

## System ABI

Once the firmware builds have settled their statuses, and before the per-target optional pass, every passing
firmware target records what its Nerves system release offers a precompiled NIF (`NccWorker.SystemAbi`), so the
portal can match a build made on one release of a system against another:

```json
"nerves_system_rpi4": {
  "status": "pass",
  "system_version": "2.2.2",
  "toolchain": {"package": "nerves_toolchain_aarch64_nerves_linux_gnu", "version": "15.3.1"},
  "otp_full": "29.1.2",
  "system_libs": {"libz.so": ["ZLIB_1.2.0", "..."], "libz.so.1": ["..."], "libc.so.6": ["GLIBC_2.17", "..."]}
}
```

- `toolchain`: the system's `nerves_toolchain_*` dependency from its `mix.lock` entry, at the version the lock
  resolved it to.
- `otp_full`: the trimmed `staging/usr/lib/erlang/releases/*/OTP_VERSION` of the release's artifact directory,
  `<NERVES_ARTIFACTS_DIR>/<system>-<version>` (`NccWorker.NervesCache`).
- `system_libs`: `unsquashfs -n -d <tmp> images/rootfs.squashfs lib usr/lib` (no shell, at most 120 s), then the
  `*.so` and `*.so.*` entries directly in `lib` and `usr/lib`, the dynamic linker's default search path, read with
  `Compatibility.Elf`; subdirectories (`priv/lib`, `engines-3`, `gconv`) give no keys. A merged `/usr`'s `lib` link
  is scanned once, as `usr/lib`; at most 5000 library names. A regular file's DT_SONAME and file name, and a link's
  own name (its target may be anywhere in the tree), map to the symbol versions the file defines. A table without
  `libc.so.6` or `libc.so`, or with `lib` or `usr/lib` unlistable, is a failed or partial extraction and is left
  out. The extraction directory is removed afterwards.

The library tables of one run share a wall-clock budget, `NCC_SYSTEM_ABI_BUDGET_SEC` (default 300): each extraction
gets at most what is left of it, and once it is spent the remaining targets record no `system_libs` (one stderr line
names them) while still recording `toolchain` and `otp_full`.

`NCC_INPUT.known_system_abi` (`["nerves_system_rpi4@2.2.2", ...]`, default `[]`) names the releases the portal already
has a library table for; a target on one of them records `toolchain` and `otp_full` but no `system_libs`.

All three are advisory: each is absent, never `null`, when it cannot be read (a missing artifact directory or
squashfs, no `unsquashfs`, a failed or timed-out extraction, an unreadable lock), the reason goes to stderr, and no
status or exit code ever changes because of them. Failed, skipped and `pure_elixir` systems never carry them.

## Process sweep

Before the compiled files are archived and `result.json` is written, `NccWorker.ProcessSweep` stops every process in
the container except the worker's own BEAM and that BEAM's `erl_child_setup` helper: every program the worker
launched has returned by then, so nothing else belongs. It scans `/proc`, sends `SIGKILL` to each other pid by number
(never to a process group or `-1`), and scans again, for up to 20 rounds. Zombies are already dead and are neither
killed nor counted, except one with a live thread under `/proc/<pid>/task` (a process whose first thread exited on
its own runs on as a "zombie"), which is killed like any other. `erl_child_setup` is a direct child of the BEAM named `erl_child_setup`; of several such, only
the one that started first is kept, since the real helper starts with the BEAM, before any package code runs.

The worker resolves names with Erlang's own resolver (`/etc/hosts`, then DNS as `/etc/resolv.conf` sets it), never
the native `inet_gethost` port program, which the BEAM would start under `erl_child_setup` and restart whenever it is
killed: the sweep would always find it.

If anything other than those two is still running after the last round, the result passes nothing: every system is
reported `"status": "error"` with an `error` naming the processes (`"processes survived the sweep and could not be stopped: …"`, a start the portal stores as its own `"worker: …"` reason rather than a failed compile), no build cache candidates are reported, and a
toolchain run's `toolchain_build` is `"error"` with no `file_manifest`. `result.json` is still written and the exit
code is still `0`, so the portal records that verdict instead of retrying.

The sweep can only run as the container's worker: on Linux, with a `/proc`, and with the BEAM as pid 1, which it is
as the container's entrypoint. A portal build, one with `NCC_INPUT` set (the image sets it, and so do the portal's
runners), does not fail open when it cannot: the result is made non-pass exactly as for survivors, with the reason
`"process sweep could not run: <why>"`, which the portal also stores under `"worker: …"`, as an error it retries
rather than a verdict on the package. A run without `NCC_INPUT`,
such as the escript on a developer machine, is not swept and says so on stderr (`Process sweep skipped: …`). The proc
root, the kill function, the environment check and the portal-build check are options of
`NccWorker.ProcessSweep.enforce_and_report/2`, for its tests.

The same sweep (`NccWorker.ProcessSweep.clear/1`) runs around every traced compile: a toolchain or host-native
run's host compile, a full run's judge compile, a firmware target's input trace and `PrivRepro`'s second build.
`NccWorker.Portability.run/3` sweeps before it reads anything for the judge (the trees, the native split, the hook
scripts) and `NccWorker.Tracer.run/3` again once the compile is over. The untraced steps before a trace (`mix
deps.get`, a host or firmware build, `mix ncc.nerves_env`) run package code, and a process one of them leaves behind
could otherwise rewrite a dependency's source for the traced compile to read and put the tarball's bytes back before
the window closes, which neither the tree check nor the window-close digest would see. A sweep that leaves survivors,
or cannot run in a portal build, is never judged: before the compile it runs nothing (`judge_compile: "not_run"`,
`tracer_error` `"presweep_survived"` or `"presweep_unavailable"`), after it the trace fails (`"sweep_survived"`,
`"sweep_unavailable"`), and the verdict is the transient "portability could not be judged". Survivors are processes
left running (`NccWorker.Tracer.left_running/0`): a toolchain or host-native run's host compile is then a worker
error and a firmware target's trace fails the run, as when the tracer's own cleanup leaves one.

Inside the traced compile the driver sweeps too, before each dependency's window closes (`:ncc_tracer_sweep`, run by
the tracer's collector, which is not traced): a natively built dependency's `make`, cmake, cargo or rebar3 port
compiler is not traced, and a process it leaves behind must not live on into a later window. It kills every process
that started after the traced VM except that VM's own `erl_child_setup`; everything older is the launch chain (the
worker, `timeout`, `fakeroot` and its `faked`). The worker asks for it with its own start time as pid 1
(`NCC_TRACE_SWEEP`), and only where its own sweep runs: the driver sweeps only on Linux, where `/proc/1` started then
and the traced VM after it, so a trace elsewhere never kills anything. It kills through `/bin/kill` or
`/usr/bin/kill` (else `/bin/sh`'s builtin) with an empty environment, never by `PATH`: package code can set the traced
VM's environment (`os:putenv/2` is observed, not refused), and a `kill` or `LD_PRELOAD` of its choosing would
otherwise run untraced between a window's compile and its digest. Each sweep writes a `sweep` line to the trace;
one that leaves survivors or cannot run ends the compile with exit 87 (`tracer_error` `"window_sweep_failed"`), and
the report reader refuses a `sweep` line that is not `"ok"` and, when the start line says sweeps were asked for
(`window_sweep: true`), a window without one. A collector that died has already cost the trace its judgement, so the
compile goes on without sweeps and the host status stays the package's own.

Dependency sources are not made read-only after `mix deps.get`: the compile runs as the same uid as anything that
would rewrite them, which could make them writable again, and Mix itself writes into a dependency's source dir (leex
and yecc output in `src/`, rebar3's `_build`, a native build's objects).

`result.json` records how the sweep went as a top-level `"process_sweep"`: `"ok"` (swept, nothing else left),
`"skipped"` (could not run, and not a portal build) or `"tainted"` (survivors, or a portal build where it could not
run). The field is informational: it is the container's own account of itself, for monitoring. The portal does not
trust it or act on it; what it records comes from the per-system statuses and the toolchain build's verdict.

## Nerves cache

`/nerves-cache` is the build host's shared Nerves cache, mounted read-only into a build. Before any `mix` runs, the
worker (`NccWorker.NervesCache`) sets `NERVES_ARTIFACTS_DIR=/work/nerves/artifacts` and `NERVES_DL_DIR=/work/nerves/dl`
in every mode: the first holds one symlink per entry of `/nerves-cache/artifacts/` (`<app>-<version>`), the second
starts empty. It also sets `XDG_DATA_HOME=/work/nerves/data`, so nerves_bootstrap's update check writes there and not
to `~/.nerves` on the read-only root, which would stop its application and with it every cross-compile. A cached artifact resolves through its link; one the cache lacks, or whose `.fingerprint` does not match,
Nerves downloads and extracts into the run dir (removing a link never touches its target), and the build passes either
way. At the end of the run every farm entry that is a real directory is a miss, and `result.json` carries
`"nerves_cache": {"misses": [{"name": "nerves_system_rpi4", "version": "2.0.0"}], "lock": [...]}`, where `lock` lists
the run's `mix.lock` entries whose name starts with `nerves_system_` or `nerves_toolchain_`. The key is absent when
both lists are empty and for toolchain runs. Nothing refers to `/home/nerves/.nerves`.

## Hex cache

`/hex-cache` is the host's shared Hex cache, mounted read-only into every build; the container's `HEX_HOME` names
it. Before any `mix` runs (every mode but `warm_nerves`, which uses an empty `HEX_HOME` of its own), the worker
(`NccWorker.HexCache`) points `HEX_HOME` at `/work/hex-home` instead: a real `packages/hexpm/` with one symlink per
tarball in `/hex-cache/packages/hexpm/`, and nothing else. Hex keeps three things under `HEX_HOME`: the tarballs,
which it uses only when their outer checksum matches its signed registry (one that does not is removed, which removes
the link, and fetched again); its registry cache `cache.bin` (`cache.ets` before Hex 2.6), which it reads back without
verifying it; and `hex.config`, which can name a mirror or switch registry verification off. So only the tarballs are
seeded, and every run fetches the registry itself. Whatever Hex downloads lands in the run dir, never the shared one.
Within a run each target gets its own `HEX_HOME` seeded from the run's (`NccWorker.HexHome`), and the registry cache
one target fetched is copied back for the next, under its own name: `cache.bin` for the Hex the images pin
(`HEX_VERSION` in both Dockerfiles, 2.6.0), `cache.ets` for an older one, never one under the other's name.

At the end of the run `result.json` carries

```json
"hex_cache": {
  "misses": [{"name": "plug", "version": "1.16.0", "outer_checksum": "<sha256 of the file>",
              "path": "hex-home/packages/hexpm/plug-1.16.0.tar"}],
  "hits": [{"name": "jason", "version": "1.4.4"}]
}
```

where `misses` are the tarballs the run downloaded (`path` is relative to `/work`) and `hits` the run's `mix.lock`
entries whose cached tarball it used. The key is absent when both lists are empty. After the container exits and
before ingest, the host (`Portal.HexCache`, and `NccAgent.HexCache` on a remote builder, both through
`Compatibility.HexCache`) moves each miss into the shared cache only when every directory from the run's work dir down
is a real directory and the file is a regular, unlinked file within 16 MiB whose bytes hash to the outer checksum the
signed Hex registry (`repo.hex.pm/packages/<name>`, the same check Hex makes) lists for that release; it rebuilds the
source path from the validated name and version and ignores the reported checksum and path. Registry answers are kept
per package for an hour; a rate limit or outage skips the rest of that promotion. A hit's times are refreshed, since a
read-only mount no longer moves a file's atime and the hex sweep evicts by last use, but only for a release the run's
own `package`, `deps_lock` or a system's `deps_lock` names. Those are written by the container too, so this narrows what
a run can keep warm rather than guaranteeing it; it never changes what the cache holds.

The read-only mount is only for an image that says its worker does this: both Dockerfiles set
`LABEL ncc.hex-cache=seeded`, and the host (`Portal.Builder`, and the remote agent) reads that label off the exact
image it is about to run. An image without it, such as a lease created before the deploy that introduced it, keeps
the old read-write mount, without `NCC_HEX_CACHE_RW` (`Compatibility.Builder.Argv.hex_cache_mode/2`), because its
worker writes `/hex-cache/packages` itself and would fail every `deps.get` on a read-only mount.

`NCC_HEX_CACHE_RW=1` on the host (the portal's environment, or a remote agent's) is the one-release rollback: the cache
is mounted read-write, the worker is told so (`-e NCC_HEX_CACHE_RW=1`) and keeps `/hex-cache` as its `HEX_HOME`, and no
`hex_cache` is reported. Nothing needs wiping afterwards: the worker never seeds the registry cache or `hex.config`, and
Hex checks every seeded tarball. Rolling back only the worker image, to one whose worker writes `/hex-cache` itself,
needs `NCC_HEX_CACHE_RW=1` set too: the missing label already keeps such an image on the read-write mount, but the
variable makes that hold whatever the image's labels say. On a builder whose docker daemon enforces the builders'
authorization policy, that rollback is not available: the policy refuses a build container with the Hex cache mounted
read-write, so every build there fails until the variable is unset again.

## Warm mode

With `"mode": "warm_nerves"` and `"nerves_packages": [{"name": "nerves_system_rpi4", "version": "2.0.0"}]` (and no
`package`) the worker fills the shared Nerves cache, which only this mode gets read-write (`NccWorker.WarmNerves`).
Nerves points at `/nerves-cache/staging/<run_id>/`, a farm over the cache like a build's. The worker creates the
template project, pins each requested system that it builds to `== version` (toolchains are never pinned; they resolve
through their system), and runs `mix deps.get` and `mix nerves.artifact.get` for every default target (only the pinned
systems' targets when the request names systems and no toolchain). If all of them succeed, every artifact Nerves
extracted is moved into `/nerves-cache/artifacts/`: renamed in when absent, left alone when the existing entry has the
same `.fingerprint`, and otherwise swapped in after the old entry is renamed to `<entry>.stale.<run_id>`. If any target
fails, nothing is installed and the run exits `10`. The staging dir and this run's `.stale.` entries are removed either
way. `result.json` has `"scope": "warm_nerves"`, `"package": null`, `"systems": {}` and
`"warm": {"requested", "rejected", "targets", "installed", "kept", "replaced", "incomplete", "resolved", "not_warmed"}`,
where `resolved` lists the project's locked `nerves_system_*`/`nerves_toolchain_*` as `<name>-<version>`. With no pairs
it warms whatever the template resolves; `ops/builder-deploy.sh` runs that after every builder deploy.

## System ABI mode

With `"mode": "system_abi"` and `"system_abi": [{"system": "nerves_system_rpi4", "version": "2.1.0"}]` (and no
`package`) the worker builds nothing and reports the "System ABI" facts above for each listed release, for releases
no current build covers (`NccWorker.SystemAbiRun`). At most 8 pairs; more, or a list that is not one of
`{"system", "version"}` string maps, is an input error and the run exits `10` before anything is prepared.

Each pair gets its own template project with only that system's target, the system pinned to `== version`, and runs
`mix deps.get` and `mix nerves.artifact.get` with `MIX_TARGET` set to that target. Unlike a warm, and like a build,
Nerves resolves through the per-run farm over the read-only `/nerves-cache` (also under `NCC_NERVES_CACHE_RW=1`): the
run never writes the cache, and what it lacks is extracted into the run's own dir. A pair failing never stops the next.

`result.json` has `"scope": "system_abi"`, `"package": null`, `"systems": {}` and one `system_abi` entry per pair, in
input order:

```json
"system_abi": [
  {"system": "nerves_system_rpi4", "version": "2.1.0",
   "toolchain": {"package": "nerves_toolchain_aarch64_nerves_linux_gnu", "version": "15.3.0"},
   "otp_full": "28.0.2", "system_libs": {"libc.so.6": ["GLIBC_2.17", "..."], "...": []}},
  {"system": "nerves_system_bbb", "version": "2.0.0", "error": "deps.get failed"}
]
```

An entry has all three facts or none: a pair any of them could not be read for has only `system`, `version` and one
of these `error`s: `unknown system`, `invalid version`, `project failed`, `deps.get failed`,
`nerves.artifact.get failed`, `no artifact`, `no toolchain`, `no OTP version`, `no rootfs`, `no libc in rootfs` (an
extraction with no libc, failed or timed out: never an empty table), `requires nerves 1`, `timeout` or
`internal error`. Details go to stderr and `logs/system_abi.log`, never into the entry.

`requires nerves 1` is a `deps.get` that Hex could not resolve because the release does not accept the template's
pinned nerves (`Failed to use "nerves"`, or `depends on nerves ~> 1...`), a permanent failure for that release; any
other `deps.get` failure, a network one included, is `deps.get failed`.

Each pair has a deadline over all of its work, `NCC_SYSTEM_ABI_PAIR_TIMEOUT_SEC` (default 600). Every `mix` runs
under `timeout(1)` with what is left of it, which kills mix and what it started, and the extraction gets at most
what is left too (and at most 120 s, as in a build). The pair's work is also killed 30 s past the deadline, for an
image without `timeout(1)`. A pair past its deadline is `timeout`, and the run goes on to the next pair and writes
`result.json` as usual.

## Toolchain mode

With `"mode": "toolchain"` (and an informational `"toolchain": {"elixir": "1.19", "otp": "28"}`, echoed back as
`requested_toolchain`) the worker answers one question on a toolchain image: are the package's own beams, built by
this Elixir and OTP, the same on every OS and architecture? Such an image has no nerves_bootstrap and possibly an
OTP Nerves 2 does not accept, so the run uses a plain `mix new` project (`NccWorker.Project.create_plain/2`), adds
the package, applies the lock policy (exit 11), adds the package's optional dependencies, compiles once on the host
in `prod`, traced, and judges `_build/host/lib/<package>` with `NccWorker.BuildSelection.static_rules/4` **and**
the compile-time trace (`NccWorker.Portability`).

`"judge": {"makefile_rule2": true}` in `NCC_INPUT` turns on item 1 of the judge refinements: a dependency whose
`Makefile` (or another native build file) Mix never runs, because its checksum-verified Hex tarball's
`build_tools` name `mix` or `rebar3` (never `mix.lock`, which an untraced `deps.get` can rewrite), is not native
under rule 2, when the trace's closure line agrees on the manager (`manager mismatch: ` otherwise). Such a build
records `judge_revision` one higher. `toolchain_build.manager` is the manager the trace says Mix built the package
with. Any value other than `true` leaves item 1 off; with it on, a `deps/` the judge cannot list is "portability
could not be judged". Revision 3 records compile-time env reads and config values the snapshot cannot give as
inputs (`compile_inputs`, including `config_order` items for reads whose value depends on the consumer's compile
order) instead of refusing; every skipped row below it is reopened once. Revision 5 drops rebar3's own log and colour
config reads (`{rebar, log}` from `rebar_log`, `{cf, colour_term}` from `cf`), refuses a baked source path only in a
module that itself runs programs, allows a call into a module the trace loaded from installed OTP code whose `.app`
lists that module's application (public_key into `asn1rt_nif`), and judges a dependency's `rebar.config.script` by
what its evaluation read and the `mix.rebar.config` Mix wrote from it. Revision 9 lets quic's reviewed `build_nif.sh`
compile hook through, records a `platform_define` regex the OTP major does not decide as a compile input instead of
refusing, and for the package itself leaves its own name out of the native-tool grep and counts a target read only
where it can run at compile time (elixir_make), and drops rule 2's "nerves-specific source" refusal. Revision 11 accepts, at the trace's
final sentinel only, Mix's reload of a natively built dependency's protocol from the project's consolidated dir (same
md5 as that file), and lets toolshed 0.5.0's reviewed `System.version/0` read through (only the release with the
reviewed outer checksum whose tree matched its verified tarball). Revision 13 records a compile-time read of the
byte order (`:erlang.system_info(:endian)`, so `System.endianness/0`: nx's float layouts, and every package with nx
in its closure) as an `endian` compile input valued from the tracer's start line, instead of refusing it as a host
read; a read whose byte order the trace does not record (no `endian` on a start line, or two VMs disagreeing) is
"portability could not be judged". Revision 15 allows a compile-time read in a natively built closure dependency's
`ebin` (Elixir 1.20's type checker reads the beam of a module the package calls, as bumblebee's compile reads
`Tokenizers.Tokenizer.beam`) when, and only when, it comes from the Mix VM after that dependency's window closed and
the dependency is clean: no taint of its own, built by Mix (manager `mix` or `rebar3`), no new mapped library and no
call into another natively built dependency in its window, and its source tree, checked again after the compile, still
exactly its verified Hex tarball's. Anything else is the host read it always was. A natively built dependency whose
compile observed the host (tokenizers' `use RustlerPrecompiled`) still taints every package that depends on it: a host
value can reach a later compile through a persistent term, an ETS table or a process without a traced event, so the
taint stays per dependency, not per module. Revision 15 also leaves out of rule 2's native-tool grep of the package
itself a tool its `mix.exs` names only as an optional dependency (`{:rustler, "~> 0.28", optional: true}` in
rustler_precompiled), counted on the parsed file; any other mention still counts. A closure dependency whose compile
calls a natively built dependency (a `native_calls` observation in its window) is tainted from revision 15 on: the
callee's NIF returns what the trace cannot see, and the caller's beams may carry it into the package. Revision 17
records a compile-time read of the OS type (`:os.type/0`, `system_info(os_type)`, outside the path internals that read
it themselves: kino's `File.rm_rf!/1` in `Kino.JS.__before_compile__/1`, and every package whose compile runs that
hook) as an `os_type` compile input valued from the tracer's start line (`os_type`, `[family, name]`), instead of
refusing it as a host read. It names `family` alone only when every read was the toolchain's own `File.rm_rf/1`
(`{major, _} = :os.type()`, by the event's `caller` and the tracer's `caller_kind` verdict on that module's loaded
code), or OTP's `os:type/0` reading `system_info(os_type)` for such a call; any other read keeps `name` as well. A
read whose OS type the trace does not record is "portability could not be judged". `os:version/0` still refuses.
Every module whose frames are trusted by name (the path internals' `Path`, `filename` and `erl_prim_loader`, `File`,
the stack wrappers, the code-loading shapes' modules, `epp`, `erlang`) carries a trace pattern on `module_info/0`
that never fires: loading other code under such a name during the trace, even with the toolchain's put back before
the collector looks (`erlang:load_module/2` passes a sticky directory), drops it and fails the integrity check.
Every other frame's kind (toolchain or package, `first_kind`, the extent) is the verdict on the code loaded for its
module when the collector reaches the event, so the tracer also traces every code load, its prepare
(`erts_internal:prepare_loading/2`) and its finish (`erlang:finish_loading/1`, which can come any time later), and keeps
each module's versions with when each was prepared or finished: a module's toolchain code (an md5 the verdict passed)
prepared or finished at or after the first load of other code under its name fails every integrity check from then on,
whichever of the two the collector sees first. Protocol consolidation loads other code after the toolchain's, never
before it. Code with an on_load function runs it before it is made current, and is never made current when it fails,
so the toolchain's code is not loaded again: other code under a toolchain module's name that a finish returns as
`{on_load, Modules}` fails the check the same way, and so does a process that dies inside `erlang:finish_loading/1`.

Before the traced compile every locked dependency's source tree is checked against its checksum-verified Hex
tarball (`NccWorker.Portability.Trees`, item 5e): the regular files under `deps/<d>` must be exactly the tarball's
`contents.tar.gz` members, byte for byte, apart from the root files Hex writes (`.hex`, `hex_metadata.config`) and a
root `_build` the tarball does not carry (rebar3's own state when Mix built the dependency). A closure dependency whose
tree differs refuses with `dependency tree differs from its tarball: <app> (extra|missing|modified file <path> | link
<path>)`, which withdraws nothing. The check is taken right after the `deps.get` that fetched the closure, before its first compile (Mix's leex and
yecc compilers write the `.erl` they generate into the dependency's `src/`): on a full run before the host compile,
on a toolchain run before the traced host compile, and for optional dependencies before the compile that builds
them, a dependency locked as before keeping its earlier check. A traced compile given no such check over a build dir
that already holds the closure is "portability could not be judged". At judge time each file, probed directory and
directory listing (a wildcard, `list_dir`, one level deep) the compile read in such a dependency is re-checked; one
that changed since the check is "portability could not be judged", not a refusal. A natively built dependency, one without a verified tarball, a tarball with links or over the 64 MiB
inflate cap, a tree over 64 MiB, and anything left once the check's 60 s budget is spent are not checked and keep
today's verdict. `compile_observations.tree_check` says, per closure dependency, `ok`, `differs: ...` or
`unverified: ...`; `trace_stats.trees_ms` is the check's time.

Revision 21, with item 1 on: a target read in a doc file of the package under
test (`*.md`, `*.markdown`, `*.txt`, `LICENSE*`; fledex's README naming `MIX_TARGET`) no longer makes the package
natively built in the trace (`NccWorker.NativeBuild.split/4`), as it does not in the static rules. Elixir 1.20's
parallel checker reading the package's own protocol beam back from its `ebin` (fledex's `Fledex.Color.beam`) was
refused for it as a read in a native `ebin`. Every other native check of the package stays whole (its own name in the
native-tool grep, so zigler stays native, and a target read anywhere in its code), and as a dependency the same
package keeps its doc files.

Fleet hazard: every node running the `:toolchain` queue must run the same worker image and the same
`NCC_JUDGE_MAKEFILE_RULE2` value. A node at a lower judge revision than the fleet's newest leaves its toolchain rows
at that lower revision, and the portal's judge-revision reopen requeues their `skipped` rows against the fleet's
newest revision on every sweep instead of once.

The host compile is the traced one (`NccWorker.HostTrace`, `mode: :host`): after its own `mix deps.get` it runs
`timeout --kill-after=10 <sec> elixir -pa <work>/trace/ebin -S mix ncc.trace_compile`, which compiles every
dependency of the package's closure, one at a time, each in its own trace window, and then the project. Nothing is
restored from the build cache and nothing is stored for it: a dependency the trace did not see compiled cannot be
judged. The closure is compiled once, and those are the files judged and archived.

Unless the input says `"optional_deps": "exclude"`, the package's unresolved optional dependencies (the same list,
and the same `skipped` tooling, as a pure-Elixir full run's pass) are added and fetched **before** that compile, so
the closure is built with them the way an application that locks them builds it. When they cannot be added, their
`deps.get` fails, they bring in a dependency the lock policy rejects, or the compile with them fails, `mix.exs` and
`mix.lock` are put back, `_build/host` is removed, and the traced compile runs again without them; `optional_deps`
names what was dropped and why, and is absent when that compile fails too. When the compile with them used up the
run, so that the one without them finds no time left or times out, the run is a worker failure (exit `10`, no
result) and is retried; a run's only compile that runs out of time is the package's verdict, as before.

The host status never depends on the tracer. A traced compile that did not finish, or whose report is not a
host-mode one, is not the build: the processes still writing `_build/host` are killed, `_build/host` is removed,
and an untraced `mix compile`, bounded only by what is left of the run, gives the status. Such a build is "portability
could not be judged" (transient) and publishes nothing. A traced compile that fails is rebuilt untraced the same way,
because a package failure cannot be told from a tracer fault, and the untraced failure is the status. A host compile
that leaves processes running that cannot be killed, or a `_build/host` that cannot be removed, is a worker failure
(exit `10`, no result): one of those processes may still be writing `_build`.

An Erlang trace
session records every read of the host (OS type and version, environment, programs, files outside the closure, host
names, install locations, the crypto build, native loading, tracing itself) and every write outside the dependency's
own `ebin`, with the stack it came from. rebar3 dependencies are traced in their own VM through `ERL_AFLAGS`. Any
of these skips the build:

- a host read or write in the package's compile window or outside every window;
- one in a closure dependency's window (that dependency is then host-tainted);
- a read of the Mix target that the static grep cannot see (`Mix.target/0,1` through a computed module name,
  `Mix.State.get`/`fetch` of `:target`, or `:ets.lookup`/`lookup_element` of `Mix.State`'s `:target` by the table's
  name or id), anywhere, a dependency's `mix.exs` included. Only the Mix functions that read the target for Mix's own
  work count as Mix's; a package fun that Mix runs (`Mix.ProjectStack.recur/1`, `Mix.Project.in_project/4`, a
  package task) is the package's. Reading `Mix.State`'s table other ways (`:ets.match_object`, `select`, `match`,
  `tab2list`, `first`/`next`) is a known gap. `Mix.Project.build_path`, `app_path` and `compile_path` are recorded as
  `mix_project_paths` observations and refuse nothing;
- a build path baked into the beams outside diagnostic metadata;
- a call into a natively built dependency while the package compiles, or while a closure dependency compiles (that
  dependency's taint);
- a rebar3 build with hooks, plugins, or a `platform_define` whose regex is not a string, in its `rebar.config` or in
  the `mix.rebar.config` Mix wrote for rebar3 (a regex string the OTP major does not decide is a `platform_define`
  compile input instead, for the client to evaluate against its own arch string; precompiled judge refinements,
  item 3, and judge round 2). A dependency's own `rebar.config.script` is judged by what its evaluation read (Mix evaluates it in the
  traced VM, outside every window) and by that `mix.rebar.config`, which holds its result; a rebar3 parent's script
  could not be judged. One reviewed compile hook is let through: quic's `sh c_src/build_nif.sh` (a no-op unless
  `QUIC_BUILD_NIF=1`), only when that script in the verified tarball and on disk before the compile has a reviewed
  sha256 and the build env left `QUIC_BUILD_NIF` unset, with no traced write of it (`Rebar.reviewed_hooks/0`);
- a trace that did not finish.

One write is let through (judge revision 21): the package's own compile (never its `mix.exs`, never a dependency's,
never another package's) writing into its own build `priv` when that is a directory of its own, not Mix's link to
`deps/<package>/priv`, together with the probes Elixir 1.20's `File.mkdir_p/1` makes of the directories above it (the
toolchain's `File.do_mkdir_p/1` calling `:file.make_dir/1`, and `elixir_utils:read_file_type/2`, which returns the
file type alone). kino's `Kino.JS.__before_compile__/1` packing each module's assets into `priv/assets` is the case.
No file in that `priv` may hold one of the roots R2 searches beams for (the project dir, so every source path and the
build path, the OTP root, the Elixir install, `HOME`, `MIX_HOME`, `HEX_HOME`), searched as it is and, for a file with
the gzip magic, inflated (`NccWorker.Portability.PrivRoots`): a source path a `__before_compile__/1` hook writes from
`env.file` is in no beam and no read, and is the same in both builds below, so it refuses as `bakes the build path:
priv/<path>` before any second build. The trace cannot see the clock, a random number or the path it was built at, so
the package's closure is built a second time, traced, in judge mode, into a fresh build path under the system temp dir (which shares no directory with
`/work` but `/`), at least a second later (`NccWorker.Portability.PrivRepro`). That trace, judged on the tree snapshot the first one was (a snapshot taken then would refuse the leex and yecc output
the first compile wrote into `deps/<d>/src`), must pass on its own, so a
path the package named itself (the first build's `priv`, a directory above it) refuses there; both `priv` trees must
hold the same paths, only directories and regular files, with the same permission bits and bytes; and the first
build must be unchanged. One difference is let through: a `.tar` or `.tar.gz` whose two copies differ only in their
members' times (the ustar `mtime`, pax `mtime`/`atime`/`ctime` records) and the gzip header's `MTIME` and `OS`
(`NccWorker.Portability.TarTimes`: one gzip member and nothing after it, every other header byte, the member order and
every data byte the same; anything it cannot parse differs). `:erl_tar` stamps the members it packs from binaries
with the wall clock, so two users' own compiles differ the same way, and the first build's bytes are published;
`priv_tar_times` names such files. Any other difference refuses as `compile-time priv write not reproducible:
priv/<path> differs between two builds` (or `a second build refused (...)`). On a pass the verdict's `built_priv`
names the files, which the static priv rules then take without a tarball entry (below). kino 0.19.1 passes so, with
its ten asset archives under `priv/assets`; a dependent that packs its own assets into kino's `priv` (kino_db,
kino_vega_lite) still refuses.

One read is let through too (judge revision 23): a closure dependency's own compile (its window, never its
`mix.exs`, never another dependency's) reading the bytes of a file in its own source `priv` (`file:read_file`, an
`open` for reading, `file:consult/1`, `erl_prim_loader:get_file/1`; never a stat, a probe or a listing) through the
link Mix makes from its build `priv` when its tarball ships one: `_build/<env>/lib/<d>/priv` must resolve to exactly
`deps/<d>/priv`, and the file, after every link, must lie under it. That is rustler's `Mix.Tasks.Rustler.New`
embedding its templates (`compile-time host read: file:read_file/2 .../_build/host/lib/rustler/priv/templates/...`);
a natively built dependency's `priv` is otherwise unreadable, since its build may write there. The read is allowed
only when that dependency's whole source tree, checked after the compile, is still exactly its verified Hex
tarball's and the tarball holds the file (the check revision 15 makes, since a natively built dependency's tree is
not checked before the compile): every user's compile then reads the same bytes. A tree a compile wrote into keeps
the refusal, Mix's own leex and yecc output in `src/` included (localize). Anything else is the host read it always
was, in that dependency's window, so a refused one taints it. Another
package reading that `priv` (a dependent embedding rustler's templates), a build `priv` of the package's own (a
directory, which revision 21 lets its compile write first) and a link out of the package's tree keep their refusal.
A firmware target's trace and a host-native build judge it the same: the same tree check is what they already ask
of every natively built closure dependency, so rustler in tokenizers' closure no longer refuses there. A read in a
window the native build tool ran in keeps its refusal there: the `make` it runs is no traced process, and may rewrite
the file (or relink the build `priv`) and put the tarball's bytes back before the window closes, which neither the tree
check nor the digest at window close sees. The allowed reads are listed as `own_priv_reads`. A non-native dependency's own `priv` read through the link was already a
read of its Hex-listed sources, re-checked against the tree snapshot taken before the compile (item 5e), and is
unchanged.

One copy is let through as well (judge revision 27): a Mix alias of a closure dependency's own project copying one
file of its own source tree onto another, and the source's mode `File.cp/3` then writes onto the copy. That is
phoenix's `compile: [&copy_core_components/1, "compile"]`, which copies
`installer/templates/phx_web/components/core_components.ex.eex` onto
`priv/templates/phx.gen.live/core_components.ex.eex` (`compile-time write outside ebin: file:copy/2
.../deps/phoenix/priv/templates/phx.gen.live/core_components.ex.eex`), and which refused phoenix 1.8 and every
package with it in its closure (phoenix_live_view and phoenix_live_dashboard among them). Only
the calls `File.cp/3` (and `File.cp_r/3`) make count, the toolchain's `File.do_cp_file/4` the frame right below each:
the trace keeps neither a copy's byte count nor the modes it opens either file with, so a package's own `File.copy/3`
or `:file.copy/3` (cutting a file short, appending, writing it compressed) or `File.write_stat/3` (any mode) keeps its
refusal. The
call must be made in the process `elixir -S mix` runs its tasks in (`Kernel.CLI`'s exec fun at the bottom of a stack
seen whole, and the very process the window's sentinel fired in: `Kernel.CLI.run/1` is public, so package code can start
another process with that bottom frame), by a fun of the aliases Mix's alias runner called: one that tail-called the copy (`Mix.Task.run_alias/6`
the first frame) or one whose own frame is in that dependency's own `mix.exs`, and in that dependency's own window,
where Mix runs it in that dependency's source dir (a fun of another dependency's `mix.exs` that its alias runs copies by
a relative path in its tree, not the other's). So the copy never runs beside the compiler's workers, though it may run
after them (an alias step after `"compile"`, a compiler the `mix.exs` defines): every allowed step writes the bytes
already there, so none changes what a read sees. One the alias spawns, or the dependency's compiled code makes, keeps
its refusal. Both paths must resolve, after every link (Mix's from the build `priv` included), under the dependency's
own source dir, the source must be a readable source file and another file than the destination (not the same one
through Mix's link, which `File.cp/3` would empty, nor, at judge time, a hard link of it), and the dependency must not
be natively built (its untraced build tool may write the tree). The judge then allows the copy only when the verified tarball holds both files with the same bytes and the
dependency's whole source tree, checked after the compile, is still exactly that tarball's, so the copy wrote the
bytes that were already there and every user's compile reads the same; the mode write only onto the destination of
such a copy in the same window. Anything else is the write it always was, in that dependency's window, so a refused
one taints it: a copy that changes a file or adds one, into another package's tree, or with no verified tarball. The
allowed copies are listed as `own_tree_copies`. Nothing is published for them: the files are the tarball's, which
every user's `deps/<d>` holds already.

A host-read reason names the `system_info` key or environment variable, the path, and with `via` the function that
made the call when it is not the package's own (`compile-time host read: erlang:system_info/1 (system_architecture)
via CCPrecompiler.current_target/0 in ...`). `erlang:system_info/1` of `otp_release`, `machine`, `smp_support`, `threads` or
`heap_type` is allowed: each is constant within an OTP major (item 5d), which the client checks; `version`,
`nif_version`, `driver_version`, `endian` and every other key still refuse. A `Path.wildcard/2` (or
`filelib:wildcard/2,3`) is judged as a read of the literal directory it starts from, relative to the working
directory when its second argument is a module (`Path.Wildcard`, `file`) rather than a directory (item 5b); a
wildcard through any other module refuses as a host read (its file calls are not traced).

The files judged and archived are the traced compile's own. The traced compile runs with the host env
(`MIX_BUILD_PATH=_build/host`, `MIX_ENV=prod`) and the run's own `HEX_HOME`, is bounded by what is left of the run,
keeps its trace files under `<work>/trace` and logs to `logs/host.log`. It judges dependency sources against a
snapshot of the Hex releases in `mix.lock`. Two snapshots are taken. The first is taken right after the project's
`deps.get`, before any compile ran. The second is taken right after the `deps.get` that fetched the optional
dependencies, before they are compiled. A build compiled with optional dependencies added is judged against the
second; every other build, a build whose optional dependencies were dropped included, against the first.
`MIX_OS_DEPS_COMPILE_PARTITION_COUNT` is removed from the worker's environment at start.

No firmware, no argus (`argus.status` is `"skipped"`), no Nerves systems,
no Hex metadata fetch; `toolchain.nerves_bootstrap` is `"absent"`.

`"optional_deps"` in `NCC_INPUT` picks the build: `"include"` (the default, also when absent) adds the optional
dependencies before the compile, `"exclude"` adds none, so the package is built and published without its optional
dependencies, and `result.json`'s `optional_deps` is `{"added": [], "dropped": [], "skipped": [], "reason":
"not_requested"}`, whether the compile passed or not. Any other value (`"maybe"`, `""`, `"INCLUDE"`, a number, a
boolean, a list) is refused when the input is read (`{:error, {:invalid_optional_deps, value}}`, exit `10` with no result), as
malformed input is, rather than run as the default and recorded as the wrong variant. The request is echoed as `result.json`'s `"requested_optional_deps"`, which the
portal checks against the variant it queued the build as. The portal queues a version `"include"` first and
`"exclude"` only when that build added one.

`"optional_deps": "world"` is a world build (`NccWorker.WorldDeps`): the package compiled with exactly the optional
dependencies a common real application has. The input names the world and carries its members, which the image does
not pin:

```json
{"optional_deps": "world", "world": "phx", "world_members": ["bandit", "decimal", "jason", "..."]}
```

`"world": {"name": "phx", "members": [...]}` is accepted too and read as the same two keys. The members are checked
when the input is read: the name and each member match `^[a-z][a-z0-9_]*$` and are at most 64 bytes, there are 1 to
200 members, no duplicates, and none on `Compatibility.OptionalDeps.never_added/0`. A list that fails, a world build
without a world, or a `world` / `world_members` key on any other request is refused (`{:error, {:invalid_world,
why}}`, exit `10` with no result).

After the package's `deps.get` and the lock policy, the worker runs a fixpoint. Each round reads the lock and collects
every optional dependency declared by the package or by any member of its closure that the lock did not resolve, comes
from the public Hex repo and is a world member (`DepsLock.unresolved_optional_deps_in_closure/2`). It adds them to
`mix.exs`, runs `deps.get` and checks the lock policy again, then starts the next round. It stops when a round finds
nothing to add. A round is one read of the lock: esbuild converges in 2 (decimal under jason) and phoenix in 3
(bandit, jason and phoenix_html, then decimal; never cowboy or phoenix_view, which are not members). A round that
still finds something to add at the cap of 6 is `world_not_converged`. After the last `deps.get` the lock may hold
nothing but the package and its closure; anything else would be loadable while the package compiles and is
`world_extra_deps`. The lock and tree snapshots the trace judges against are taken again after that last `deps.get`,
and then the one traced compile runs and is judged like any other build.

There is no fallback to a build without the members. When a round's `deps.get` fails, the lock policy rejects the
lock, the fixpoint does not converge, a stray dependency is found or the host compile fails, the run still writes a
result: `toolchain_build.status` is `"skipped"`, its `reason` is `"world closure not built: <reason>"` (the stray or
unconverged names in parentheses), it has no `file_manifest` and no lock-derived fields, and the top-level `deps_lock`,
`package_checksum` and `declared` are left out. A host compile that is a worker error, or a project that cannot be put
back after a failed round, is still exit `10`.

`requested_optional_deps` is `"world:<name>"`, and `optional_deps` carries the world:

```json
"optional_deps": {"added": ["bandit", "jason", "phoenix_html", "decimal"], "dropped": [],
                  "skipped": ["phoenix_view", "plug_cowboy"], "reason": null, "world": "phx", "rounds": 3}
```

`added` lists the members it added, in the order it added them. `skipped` lists the closure's unresolved optional
dependencies that are not members. When the closure was not built, `added` is `[]`, `dropped` lists what earlier
rounds had added, and `reason` is one of `deps_get_failed`, `mix_exs_edit_failed`, `stale_build_not_removed`,
`lock_policy_violation`, `world_not_converged`, `world_extra_deps`, `deps_lock_unreadable` or `host_compile_failed`.

`"optional_deps": "pinned"` with `"pins"` (toolchain mode, or a firmware run of one system, below) is a pinned build
(`NccWorker.Pins`): the package compiled against exactly one closure from a project's lock.

```json
{"mode": "toolchain", "optional_deps": "pinned",
 "pins": {"hash": "<64 hex>", "package_checksum": "<64 hex>",
          "deps": [{"name": "decimal", "hex": "decimal", "version": "2.3.0", "checksum": "<64 hex>"}]}}
```

`deps` is the closure without the package, `hash` is `Compatibility.Pins.hash/1`, and the set is checked by
`Compatibility.Pins.validate/3` (at most 200 deps, names, versions, lowercase checksums, no duplicates, no Nerves
tooling, not the package itself, the hash recomputed) when the input is read; `pins` without `"pinned"`, `"pinned"`
without `pins`, a world, or any mode but `toolchain` or none is refused (exit 10, no result). The package (`== version`) and
every pin (`== v`, `hex:` when the names differ, never `override: true`) are written into `mix.exs` before the one
`deps.get`; the lock policy is checked as always (exit 11); then `NccWorker.DepsLock.read/2`, the package's checksum
and the lock outside the closure must be exactly the set. A set Mix does not reproduce compiles nothing: the result's
`toolchain_build` is `skipped` ("pins not reproduced: pins_closure_mismatch (+extra -missing ~differing)"), exit 0. A
deterministic `deps.get` failure is `pins_unresolvable`, a transient one exit 10. A reproduced set runs the toolchain
run's own compile, judge and deterministic sibling with nothing added (`optional_deps.reason` `"pinned"`). The result
echoes `requested_optional_deps: "pinned"` and carries `pins`: `{"hash", "status": "reproduced" | "refused",
"reason", "extra", "missing", "differing"}`.

The firmware path (no `mode`) builds a native set on one system's exact release: `systems_filter` must name exactly
one system `NccWorker.Systems` builds, `systems_override` must pin that system and no other to `"== X.Y.Z"`, and there
is no `firmware_world`; anything else is refused (exit 10, no result).

```json
{"optional_deps": "pinned", "pins": {...},
 "systems_filter": ["nerves_system_rpi4"], "systems_override": {"nerves_system_rpi4": "== 2.1.2"}}
```

The project is `Project.create/3`'s, with that one target at that release; the package and pins are injected into the
template as on the toolchain path (a pin the template declares is repinned in place, keeping its options). After the
`deps.get` and the lock policy comes the template round: when every dependency the closure holds beyond the set is a
template dependency, not Nerves tooling, that the closure reaches only through optional edges (`logger_backends`
through ring_logger's optional edge, say), those are taken out of `mix.exs` and `mix.lock` and `deps.get` runs once
more. The exact check is the toolchain path's without the lock outside the closure, which a Nerves template always
fills. A refused set builds nothing: its target is `skipped` with `error` `"pins_not_reproduced"` and the refusal in
its `log_tail`, exit 0. A reproduced set is built as any firmware run of one target (host compile, `BuildSelection`,
the firmware build, ABI facts, the baked build path rule, compile inputs) with no optional-deps pass and no world
(`optional_deps.reason` `"pinned"`); a retired release is built too. The result is `scope: "targets"` and carries
`requested_optional_deps: "pinned"`, `pins`, and the run's `deps_lock`, which the target's files were built against.

`"config_variant"` in `NCC_INPUT` (toolchain mode) is a `Compatibility.ConfigVariants` name; its overlay is written as
`config/config.exs` before the compile (`NccWorker.ConfigOverlay`). Absent is `"default"`, no overlay. The overlay
is written after the project's `deps.get` and before the lock snapshot and the traced compile, so the traced
compile's own `deps.get`, the compile and any untraced fallback all load it, and the trace's config reads record its
values; it never enters `mix.exs` or the `.app`. A name this image does not pin is refused when the input is read
(`{:error, {:invalid_config_variant, value}}`, exit `10` with no result), and a `config/config.exs` already in the
project is never overwritten (`{:error, {:config_overlay_failed, :config_exists}}`, exit `10`): building without
the overlay would record the build as the wrong variant. Other modes accept the key and ignore it.
`toolchain_build.config_variant` is the config variant the build was made in, echoed for the portal to check
against the job; it is always set in a toolchain run, `"default"` without an input value.

`"deterministic": true` in `NCC_INPUT` (toolchain mode and firmware runs; anything but exactly `true` is off, and
other modes ignore it; see "Firmware targets" below for a firmware target's sibling) also builds the build's
deterministic sibling (`NccWorker.Deterministic`, judge revision 29), recorded as
`result.json`'s `deterministic_build`: the package's closure compiled again with `ERL_COMPILER_OPTIONS=deterministic`
in its own traced judge compile, never a second window of the build's (Elixir reads the variable once per VM, on
its first module), at `_build/deterministic` (the build's `_build/host` is not touched), with the build's env and
`HEX_HOME`, and judged by `NccWorker.Portability.run/3` on the lock and tree snapshots the build's passing trace was
judged on, then by the static rules on its own `ebin` and `priv`. It is tried only after a build that passed and
whose compile neither read nor set `ERL_COMPILER_OPTIONS` (nor read the whole environment); otherwise it is
`"skipped"` with `"the build without the option did not pass"` or `"the build's compile reads or sets
ERL_COMPILER_OPTIONS"`. It passes only when it is the build but for what the option changes: the same `deps_lock`,
`package_checksum`, `declared`, `manager`, `compile_env`, `compile_env_rule`, `compile_inputs` and `built_priv`, the
same `priv` files (bytes too, but for `built_priv`), and an `ebin` `Compatibility.DeterministicBeams.compare_ebin/2`
takes (every beam compiled with the option; an Elixir module's code and md5 the build's, only `CInf`, `Dbgi`, `Docs`
and `ExCk` differing; an Erlang module's only `CInf`, `Dbgi`, `Docs`, `Line`, `LitT`, `Attr` and its funs'
`old_uniq` in `FunT`, which the compiler takes from the md5). Else it is
`"skipped"`, its reason the judge's or `"differs from the build: ..."`. Its fields are a toolchain build's plus
`erl_compiler_options: ["deterministic"]`; a sibling that was not tried carries only `status`, `reason`,
`erl_compiler_options`, `elixir`, `otp`, `judge_revision` and a nil `file_manifest`. Its files are archived from
`_build/deterministic/lib/<package>`, each only while it still hashes to its entry. A sibling trace that left
processes running that could not be killed, or a build whose files no longer hash to its manifest after the sibling,
fails the run (exit `10`). Nothing about the build itself changes either way.

A package that ships `priv` files is portable only when they are static data (`NccWorker.StaticPriv`): every file
under `_build/host/lib/<package>/priv` (or `deps/<package>/priv`, the only link target followed there) is a regular file with one link, executable neither there nor in the
tarball, carried byte for byte at `priv/<path>` in the `contents.tar.gz` of the package's own Hex tarball, and not
native code by name (`.so`, `.dylib`, `.dll`, `.a`, `.o`, `.node`) or magic (ELF, Mach-O, PE, `ar`), with at most
500 files and 10 MiB in all; the beam rules and the native-source check (`c_src`, `native`, `zig_src`, `go_src`
and the rest) still apply first and after. The tarball is the one `deps.get` left in the run's Hex cache, used only
while its SHA-256 is the outer checksum the lock names; the source dir is never the reference, since a compile hook
can write there too. It is read once, and the bytes hashed are the bytes judged. A file that fails names itself in
the skip reason, and a tarball that is missing or cannot be read skips the package as `"ships priv files that could
not be checked against its Hex tarball"`. The rules are `Compatibility.StaticPriv`, shared with the portal, which
applies them again on the host at ingest to the files the build hands over, against a tarball it fetches itself and
the outer checksum the signed registry lists: a pass here is the container's word, and a build the host refuses
publishes nothing. The tarball is bounded before it is unpacked: at most 8 MiB, a `contents.tar.gz` that inflates to
at most 64 MiB, counted on the bytes inflated, and at most 20,000 entries.

One kind of priv file passes without being in the tarball: one the package's own compile wrote into its own build
`priv` (kino's asset archives under `priv/assets`, say), when the trace's pass lists it in its `built_priv` because
the package's own compile alone wrote it and a second traced build wrote it the same (byte for byte, or a tar archive but for its times; judge revision
21). `BuildSelection.static_rules/4` takes that list as `built_priv:`; rule 1 never does. Such a file is static only
when the tarball does not carry its path at all (one the compile wrote over a file the release ships skips as
`"ships a priv file its compile wrote over one its Hex tarball carries (priv/<path>)"`), and the caps, the native name
and magic and the execute bit hold for it as for any other. A file not on the list is judged against the tarball as
before, and the tarball is still needed: only the tarball can say a file is not in it.

`result.json` has `"scope": "toolchain"`, `"systems": {}`, the usual top-level `deps_lock`, `package_checksum`, `declared` and
`optional_deps`, and:

```json
"toolchain_build": {
  "status": "pass | skipped | error",
  "reason": "the skip reason (see below), what failed when error, null when pass",
  "elixir": "1.19.1", "otp": "28",
  "deps_lock": {"jason": {"version": "1.4.4", "checksum": "<outer>"}},
  "package_checksum": "<outer>",
  "declared": [{"app": "decimal", "name": "decimal", "requirement": "~> 1.0 or ~> 2.0", "optional": true}],
  "compile_env": [{"app": "...", "path": ["..."], "value": "<base64url term>"}],
  "compile_env_rule": 1,
  "compile_inputs": [{"kind": "env", "name": "...", "value": "<base64url term>", "set_by": "host"}],
  "config_variant": "default",
  "portability_rule": 2,
  "rule1_reason": "rule 1's reason when it would have skipped, else null",
  "judge_revision": 5,
  "manager": "rebar3",
  "compile_observations": {"trace_stats": {"windows": 14, "wall_ms": 9100, "host_compile_sec": 31.2}, "config_reads": [], "refusals": [], "taint": {}, "problems": []},
  "file_manifest": {"ebin": [{"path": "ebin/x.beam", "sha256": "...", "size": 1234, "mode": 33188}], "priv": []},
  "built_priv": []
}
```

`deps_lock`, `package_checksum`, `declared` and `compile_env` are present for `pass` and `skipped` and `null` for
`error` (`declared` is also `null` when the lock could not be read);
`file_manifest` only for `pass`, and those files are archived by SHA256 from `_build/host/lib/<package>`.
`built_priv` is, for `pass`, the `file_manifest` paths (`"priv/<path>"`, sorted) of the priv files the trace's pass
listed as written by the package's own compile and that the manifest ships, `[]` for none, and `null` for every other
status; the portal judges exactly those files against this list instead of the tarball at ingest. A failed
host compile is `status: "error"`: `result.json` is still written and the exit code is `0`, so the portal ingests the
verdict (as a `fail` row). A compile failure is deterministic for that package, version and toolchain, so it is
recorded, not retried. A `deps.get` failure here always exits `10` without a result and is retried — toolchain
mode does not run it through `NccWorker.DepsGetClassifier`; only a full, targets or argus-only run does (see
"What it does" above).

`portability_rule`, `rule1_reason` and `compile_observations` are present for `pass` and `skipped` and `null` for
`error`. `portability_rule` is `2`: the static rules (`BuildSelection.static_rules/4`: compiled beams in Elixir or
Erlang, no NIF or driver load, static priv only, no native sources, native
build dependencies, target reads or `nerves*` name; for the package itself its own name is not a native build
dependency, and a target read counts only where it can run while it compiles, not in a `def`/`defp` body, a literal
doc, a comment or a doc file: `NccWorker.TargetScan`) AND the compile-time trace. A mention of Nerves in the
sources no longer refuses under rule 2 (revision 9); rule 1 keeps its "nerves-specific source" grep. A program call, an executable lookup
or an `:os.type()` in the sources no longer refuses a build; the trace refuses one made at compile time, and a
module that holds a source path and itself runs programs. `rule1_reason` is what rule 1 (`portable?/4`, the
verdict before rule 2) would have said, `null` when it passes: a `pass` with a `rule1_reason` is a build only rule 2
publishes. `judge_revision` is the worker's judge revision (`NccWorker.Portability.judge_revision/1`), present for
`pass` and `skipped` and `null` for `error`; the portal reopens skipped rows below the newest revision once. `manager`
is the manager the trace says Mix built the package with (`"mix"`, `"rebar3"`, `"make"`), `null` when the trace's
closure line names none and for `error`. A skip
reason from the trace starts with one of the prefixes in
`Compatibility.Portability.refusal_prefixes/0` and wins over a static one; "portability could not be judged" means
the trace itself failed and is never held against the package (the worker reports it as `skipped`, and the portal
retries the transient ones, below); when the trace could not judge and a static rule also skipped, the reason is the
static rule's. When the traced compile itself did not finish (a crash, a timeout, a
non-zero exit; `compile_observations.trace_stats.judge_compile` is `"not_finished"`), `_build` may be half-written,
so neither the static rules (`static_rules/4`) nor `portable?/4` judge it: the reason is
"portability could not be judged", `rule1_reason` and `compile_env` are
`null`. `compile_observations.trace_stats` carries the traced compile's `wall_ms`, `judge_compile` (`"finished"`,
`"not_finished"` or `"not_run"`), `report_over_budget` (the trace files exceeded the report reader's shared 64 MiB /
500 000-line budget), `transient`, the phase times `trees_ms`, `compile_ms`, `report_ms` and `judge_ms`, `tracer_error` (why
the traced compile did not finish, `null` when it did), `trace_mode` (`"host"` for a toolchain run's report),
`host_build` (`"traced"`, `"untraced"` or `"none"`: which build the host status is) and `host_compile_sec`, the
host compile's own time, its `deps.get` and any untraced fallback included, and the collector's own counts
(`calls`, `user_events`, `path_os_reads`: the OS-family reads path functions make, which the judge ignores and the
tracer counts without writing). OTP's own code loading in a rebar3 VM (`erl_prim_loader` resolving a beam's
path for `code:ensure_loaded/1`, which an archive escript makes the calling process do) is not held against the
package: its `erlang:system_info(os_type)` reads are path handling (`erl_prim_loader:pathtype/1`, `normalize/2`,
`real_path/4`), and its `prim_file:read_link/1` reads carry an `arg.code_loading` flag the tracer sets only on the
stack shape pinned for that read per toolchain (`src/ncc_code_loading_shapes.hrl`, recorded by
`test/fixtures/code_loading/code_loading_repro.erl` in each image). The beam read that follows is judged as a read,
and the same reads from package frames, an `on_load`, or a direct `erl_prim_loader` call still refuse.
`transient` is `true` when a
could-not-judge says nothing about the package: the traced compile did not finish (a timeout, a kill, an exhausted run
budget, processes that survived the cleanup, a crash) or its report was over budget. The portal stores such a
`skipped` build as an `error`, which its backlog retries after a day; a could-not-judge the package causes on every
run (a missing or unverified tarball, a rebar3 parent's `rebar.config.script`, a beam it cannot read, a missing
`ebin`) has `transient: false` and stays `skipped`.

`compile_env` is the package's `.app` `compile_env` list, and for a build whose trace passed also the
compile-time config reads the trace records while the package's dependency closure compiles
(`NccWorker.Portability.ConfigReads`): one `{app, [key], value}` item per read key, valued with what the project's
config gives in a Mix VM before any dependency loads (`:error` when unset), the same lookup a client makes; such a
build has `"compile_env_rule": 1`, every other build `null`. The items never enter the published `.app`. Reads the
toolchain's own code makes are recorded only when they are reviewed as changing generated code (Logger's compile-time
keys), dropped when reviewed as not changing it, and refused when reviewed as reaching the host (OTP's CA store, TLS
version and socket option reads: `compile-time config read: ...`); a toolchain read not yet reviewed makes the build "portability
could not be judged" and is listed in `compile_observations.config_unreviewed`. A read of Hex's config (`:hex`, any key:
the builder's API and mirror URLs, repos, proxies and keys) is never recorded and makes the build "portability could not
be judged" too. `get_all_env` from package code, a read naming a non-atom key, and a compile-time Elixir version read
that differs between patches of the minor (`compile-time Elixir patch dependence: ...`) are refusals. A trace pass that does not name its config reads at all
is judged "portability could not be judged" and publishes nothing. A `pure_elixir` system result whose files are
published carries the same list and `"compile_env_rule": 1`; one whose `.app` cannot be read (`compile_env` `null`,
which no client matches) publishes nothing either, as "portability could not be judged".

`compile_inputs` (on `pass`, `null` otherwise; also on a published `pure_elixir` system result) lists the compile-time
environment reads of the package's closure, which no longer refuse a build (`NccWorker.Portability.CompileInputs`):
`{"kind": "env", "name", "value", "set_by": "host"}` for a value from the builder's environment,
`{"kind": "env", "name", "value", "set_by": "build", "inputs": "recorded" | "unknown"}` for a value an earlier
`System.put_env` in the same build set, `{"kind": "env_all"}` for a read of the whole environment, and
`{"kind": "config_unrecorded"}` when the config reads could not all be recorded, and
`{"kind": "config_order", "app", "path", "reader", "default", "seen"}`: an unset key read outside the reader's tree;
`default` is the app's `.app` env default at the locked version, `seen` what the read returned, and
`{"kind": "platform_define", "regex", "matched"}`: a rebar3 `platform_define` regex in the closure that the OTP major
does not decide, with whether it matched the builder's `rebar_utils:get_arch/0` string (`Rebar.arch/0`; one `re`
cannot compile, or not ASCII, records `config_unrecorded`), `{"kind": "endian", "value": "little" | "big"}`: the
closure read the byte order at compile time, with the byte order the traced compile ran with (judge revision 13; the
client compares its own `System.endianness/0`), and `{"kind": "os_type", "family": "unix" | "win32", "name"}`: the
closure read the OS type at compile time, with the traced compile's `:os.type/0` (judge revision 17; `name` left out
only when no read could reach it; the client compares its own). A value the trace could not
capture, over 64 KiB, under a private-looking name (`NCC_*`, `*TOKEN*`, `*SECRET*`, `*_KEY`, `*_PASS`, `*_PROXY`,
...) or holding a URL with userinfo (`scheme://user:pass@`) is `"unrecordable"`.
Each kind has its own cap inside the list's 256 items: more than 128 `env` items record `env_all` instead, more
than 96 `config_order` items or 32 of any other kind record `config_unrecorded`; a cap never drops the build. A
`config_order` item whose app, key or reader no item may name (an empty atom, one with `=` or NUL, or over 256 bytes)
records `config_unrecorded` too.
Other host reads (`os:version`, `system_info` keys other than `endian`, `os_type` and the ones constant within an OTP
major, files, the network, programs, init arguments) still refuse.

A `System.put_env/2` that a package fun Mix runs as an alias tail-calls (circuits_i2c's
`compile: [&set_make_env/1, "compile"]`) is the package's own write; a write that leaves no source file of its own has
`"inputs": "recorded"` only when every earlier env read in its VM is recorded (judge revision 19).

### Firmware targets

`mix firmware` is not traced, so a firmware target's build carries no `compile_inputs` and a client refuses it when
the package's own `lib/` reads the environment at module level (circuits_i2c reads `CIRCUITS_I2C_I2CDEV`, which its
`mix.exs` sets from the Nerves target and its `:default_backend` config just before it compiles). For such a package
`NccWorker.FirmwareInputs` records them (judge revision 19), once every other pass is over and one target at a time,
only on a passing target that publishes its own first build (no optional dependencies kept, no variants):

1. `mix ncc.nerves_env` in the target's deps and build dirs: the variables Nerves's Mix integration sets up before
   a compile (`CROSSCOMPILE`, `NERVES_TOOLCHAIN`, `NERVES_SYSTEM`, ...);
2. the traced judge compile of the package's closure for the target as the firmware build compiled it, so a package
   cannot tell the two apart and read otherwise only in the build (`FirmwareInputs.in_build_layout/4`): the run's
   `deps/` renamed to the target's `deps_<target>` and the trace built into `_build/<target>` (the build's own dirs
   moved aside meanwhile, then put back; one that cannot be put back stops the run), so `__DIR__` and every Mix path
   are the build's; the target's build env as it is, its `HEX_HOME` included; the build's own command
   (`FirmwareInputs.firmware_command/0`: `fakeroot` when present, `System.argv/0` `["firmware"]`); and Nerves's
   variables exported only once every dependency's `mix.exs` is evaluated, as `nerves_bootstrap.init` does, and the
   dependencies loaded again after it, as the compile's own `deps.loadpaths` does. The
   moduledoc lists what still differs (the tracer's own variables, which no client matches; a few VM signals the
   tracer does not pattern). The toolchain and system dirs are moved to links whose paths share nothing with theirs,
   their names and versions included (`FirmwareInputs.move/4`; `NccWorker.Portability.target_inputs/3`): it passes only when the trace is whole, the trees
   are their tarballs' and nothing in it refuses, except what the reviewed native build tool's own code did
   (elixir_make, `Portability.native_tools/0`: `native_build`, never an input; a tracer integrity call or a write to the
   environment or the application env from its frame is a package fun it ran, and still refuses) and `Mix.target/0` reads, which record
   `{"kind": "mix_target", "value"}`. A host read whose value holds the builder's `NERVES_TOOLCHAIN` or
   `NERVES_SYSTEM` is `{"kind": "env", "name", "set_by": "nerves", "value": [segments]}`: the value cut at those
   paths (`Compatibility.CompileInputs.split/2`), which a client compares with its own value cut at its own paths;
   the published files never hold such a path (`NccWorker.FirmwareBuildRoot`). `make` is no traced process, so
   nothing the native build wrote may reach the package's beams: every natively built closure dependency's source tree
   must still be its verified tarball's after the compile, and every beam in the package's ebin compiled from a file
   in its own source dir;
3. the binding: the traced beams of the package carry the code (`beam_lib:md5/1`) and the attributes chunk (persisted
   attributes) of the published ones, module for module, and the `.app` is the published one byte for byte.

The target then carries the trace's `compile_inputs` and its `compile_env`; anything that does not hold leaves it
without, as before. Past the tracer's run ceiling (105 minutes into the run) no further target is tried, its Nerves env
included. The portal's `NCC_FIRMWARE_INPUTS=0` turns it off with no image change: firmware builds, local and remote,
get `NCC_INPUT.firmware_inputs: false`; an input without the key (an older portal) is on.

With `"deterministic": true` in `NCC_INPUT`, each passing target that publishes its own build then gets that build's
deterministic sibling (`NccWorker.FirmwareDeterministic`), last, once the optional pass, the world, R2 and the compile
inputs have settled what the target publishes: the package alone compiled again for the target with
`ERL_COMPILER_OPTIONS=deterministic` in a `mix compile` of its own (Elixir reads the variable once per VM), in the
target's build env and build tree, over the closure its firmware build already compiled. The published build is
renamed to `.<package>.det-build` with its `priv`/`include` links made its own, the compile (under `timeout(1)`,
targets concurrently as `NCC_BUILD_CONCURRENCY` allows) builds the one app missing from `_build/<target>`, its output
is renamed to `.<package>.deterministic`, its links owned and scanned there, and the published build goes back and
is checked file by file against its manifest. It is recorded as the system's `deterministic_build`: `{"status":
"pass" | "skipped", "reason", "erl_compiler_options": ["deterministic"], "judge_revision", "file_manifest",
"build_root"}`. It passes only when it lists the build's `ebin` and `priv` paths with the build's modes, its `priv`
files are the build's bytes, its `ebin` passes `Compatibility.DeterministicBeams.compare_ebin/2` against the build's,
and R2 passes on its own dir (`build_root`; the option changes an Erlang module's `?FILE` literals). It is
`"skipped"` with its reason otherwise, and also for a target that kept its optional dependencies (its build was made
against a closure the project no longer holds) or that the optional pass tried and dropped (it left the closure's builds
rebuilt with them), one whose recorded `compile_inputs` read `ERL_COMPILER_OPTIONS` or the
whole environment, after a compile failure or timeout, past the pass's budget (`NCC_FIRMWARE_DETERMINISTIC_BUDGET_SEC`,
default 600) or 75 minutes into the run, and when the compile changed `mix.lock` (put back). A target that did not
pass or publishes nothing gets no key. Its files are archived from `.<package>.deterministic`, each only while it
still hashes to its entry. A published build that cannot be put back or no longer hashes to its manifest, and
writers of a build path that survive the reap, fail the run (exit `10`). The target's status, firmware, log tail and
files never change.

See `examples/input.json` and `examples/result.json` for the wire format; the full `result.json` typespec is at the top of `lib/ncc_worker/worker.ex`.

## Host-native mode

With `"mode": "host_native"` (and optionally `"triple": "x86_64-linux-gnu"`, the triple the job asks for) the worker
builds a NIF package on a toolchain image for its own glibc Linux triple (`Compatibility.HostTriple`: x86_64 or
aarch64, `-linux-gnu` only), so a client on the same triple that opted in can install its beams and priv native files
(design addendum for board #85). A builder of another triple, or of none (musl, darwin), fails the run before any
`mix` (exit 10). The run is the toolchain run's (plain project, lock policy, no optional dependency added, as
`optional_deps: "exclude"`, one traced host compile in `prod`), judged by `NccWorker.HostNative` instead of rule 2.
No optional dependency because a client takes a build only where its env's closure of the package is exactly the
build's `deps`, and a NIF package's optional dependency is rustler, which almost no application locks:

- the trace in target mode (`target: "host"`, `host_native: true`, `NccWorker.Portability`): every compile-time read
  must be a recorded input (env, config, `mix_target` "host", byte order, OS type), as for a firmware target. The
  reviewed native tools' own activity is set apart: elixir_make (but a program it runs, `make` included, and an OS
  identity read rustler_precompiled's frame would refuse refuse from its frame too, since which pinned archive lands in
  priv must not be up to an untraced process; and an application config read its own code makes, such as
  `config :elixir_make, :force_build`, is a `compile_env` item), and rustler_precompiled (its target triple, NIF
  version, OTP release and OS type reads, its download and its writes into the package's priv; any other OS identity
  read or program run from its frame still refuses, and so does the package's own code, `use RustlerPrecompiled` and
  its `__using__/2` call excepted, including a read a variant fun of the package's tail-calls, which leaves the tool's
  `variant_suffix/2` frame first: an env read is a `compile_inputs` item, a host read refuses; its own reads of
  `TARGET_ARCH`, `TARGET_VENDOR`, `TARGET_OS` and `TARGET_ABI`, which override the triple it picks the NIF by, are
  `compile_inputs` too). Two more of its normal
  path's events pass (judge revision 25, tokenizers 0.5.2):
  the expander calling `Rustler.MACRO-__using__/2` with no package frame, once per `RustlerPrecompiled` macro before
  it in the same window and process (the tool's quote holds `use Rustler` in its force-build branch whenever the
  optional rustler is loaded; Rustler's macro is a `bind_quoted` quote that reads and runs nothing, and the branch
  that would run its code, `Rustler.Compiler.compile_crate/3` and `__before_compile__/2`, keeps their refusal, as
  does a `use Rustler` of the package's own), and the port to OTP's in-memory ram_file driver that
  `:erl_tar.extract({:binary, tar_gz}, ...)` opens through `ram_file:ll_open/3` right under the tool's
  `download_or_reuse_nif_file/2` (any other port, or that one from elsewhere, still refuses; unpacking a cached
  archive reads it in a `raw_file_io_inflate` process no tool frame owns and still refuses). What picks the
  force-build branch is recorded: the package's env read (`TOKENIZERS_BUILD`) and
  `RUSTLER_PRECOMPILED_FORCE_BUILD_ALL` are `compile_inputs`, `:rustler_precompiled`'s `force_build` and
  `force_build_all` are `compile_env`. The package's own priv libraries may be mapped (rustler's `@on_load` runs in the
  compiler VM) while the file each was mapped from is still there when the judge runs (one removed or replaced since,
  `<path> (deleted)` in the map, refuses), and so may the libraries the loader maps with one (judge revision 25): first
  seen in the same snapshot, and let through in that snapshot only,
  named by its `DT_NEEDED` by `DT_SONAME` (or through another so named), from the directory the VM's own C library was
  mapped from (tokenizers' NIF needs glibc's `libdl.so.2` and `libpthread.so.0`); a client resolves the same sonames
  (`elf.needs`). R2 (a baked build path) applies to the package's ebin, as do the tree, rebar3, closure-taint and
  built checks;
- the beams: at least one, Elixir or Erlang;
- the priv (at most 500 files and 128 MiB, one link to the package's own source priv): every non-ELF file is static
  data its verified Hex tarball carries; every ELF file a 64-bit `ET_DYN` object of the triple's machine, at most
  64 MiB; at least one ELF file;
- a downloader (its tarball ships `checksum-*.exs` or `checksum.exs`, read as data, never evaluated,
  `Compatibility.NifOrigin`): every ELF file must be, byte for byte, a member of an archive in the run's cache dirs
  (`HostNative.cache_dirs/0`) whose bytes have the sum a checksum file lists for its name, else
  `native file not verified against the package's checksum file: <path>`. The archive is archived by SHA-256 too.
- no file outside priv is ELF (`ships a native file outside priv (<path>)`): a beam can `load_nif` from ebin, and
  only priv's files are judged above;
- a package whose tarball ships no checksum file compiled its ELF files in the run, and those are refused:
  `native file compiled in the run, not a checksum-pinned download: <path>`. Nothing checks what its build assumed of
  the builder's CPU (`-march=native`, `-mavx2`, `-mcpu=native` give SIGILL on an older CPU), its run paths, or what it
  downloaded without a checksum.

`result.json` carries `host_native_build`: a toolchain build's fields (status, reason, elixir, otp, `deps_lock`,
`package_checksum`, `declared`, `compile_env`, `compile_env_rule`, `compile_inputs`, `portability_rule`,
`judge_revision`, `manager`, `compile_observations`, `file_manifest`) plus `triple`, `libc` ("glibc"), `glibc` (the
builder's, informational), `otp_full`, `nif_version`, `native_files` (each ELF file's `path`, `sha256`, `size`,
`class`, `machine`, `soname`, `needed`, `needs`) and `origins` (`path`, `checksum_file`, `archive`,
`archive_sha256`). `scope` is `host_native` and `systems` is empty.

## Egress probe

With `"egress_probe": [{"address": "192.0.2.1", "port": 1234}, {"address": "2001:db8::1", "port": 1234}]`
in `NCC_INPUT`, the worker tries a TCP connect to each target before any `mix` runs and writes
`result.json` `egress_probe`: one `{"address", "port", "family", "outcome"}` per target, `outcome` one of
`connected` or `refused` (both mean the packet got through), `timeout` (dropped),
`unreachable` (no route), `invalid_target`, or the socket error's name. Advisory: it never changes a status or fails
the run. Only `Portal.EgressCheck` sends it (see the operator runbook); otherwise the key is absent.

## Resources

Every run, whatever its mode, samples the container's memory from `/proc/meminfo` every 5 seconds
(`NccWorker.Resources`), from just after the output directories exist until just before `run/1` returns.
`limit_bytes` is `MemTotal`, what the guest sees: advisory only, since gVisor may floor it (at 2 GiB for a small
`--memory`) and the container that writes it runs package code. The portal records its own configured limit and
falls back to `limit_bytes` only when none is configured. Each sample computes used as
`MemTotal - MemFree - Buffers - Cached` and total as `MemTotal - MemFree`, in bytes, and keeps their peaks.

After every sample the worker atomically rewrites `/out/resources.json`:

```json
{"peak_used_bytes": 1610612736, "peak_total_bytes": 2147483648, "limit_bytes": 4294967296,
 "samples": 42, "read_errors": 0, "interval_ms": 5000,
 "started_at": "2026-11-12T10:00:00Z", "sampled_at": "2026-11-12T10:03:25Z"}
```

so a run the kernel OOM-kills, which writes no `result.json`, still leaves its last record. A finished run takes one
last sample and puts the same object into `result.json` as top-level `resources`. A meminfo that cannot be read or
parsed counts in `read_errors` and never fails the run; until a sample succeeds the peaks, `limit_bytes` and
`sampled_at` are `null`. Informational: it changes no status.

## Exit codes

- `0` — success (some systems may still have failed; check `result.json`) — a toolchain run whose compile failed
  exits `0`, and so does a full/targets/argus-only run whose own `deps.get` failed deterministically
  (`NccWorker.DepsGetClassifier`)
- `10` — internal failure: no `result.json` was written (includes a `deps.get` failure classified transient, and
  always a toolchain run's own `deps.get` failure, or a toolchain host compile that left processes running or a
  `_build/host` that could not be removed, or one without optional dependencies that ran out of time after the
  compile with them failed)
- `11` — policy violation (non-Hex dependency in `mix.lock`)

## Develop

From the umbrella root (never run `mix deps.*` in this directory; it rewrites the shared `mix.lock`):

```bash
mix test apps/ncc_worker/test/
make build          # builds the escript into the ncc-worker:local image
```

The image builds only under BuildKit. Under the legacy builder (what
`docker build` falls back to when the buildx component is missing, as with
Ubuntu's `docker.io` package alone) the build has been seen to fail at the
archives step with `mix: command not found`. The Dockerfile uses no
BuildKit-only syntax (no `# syntax=` line, heredocs, `--mount` or `--link`),
so the exact cause of that failure is not known. Install the buildx plugin
(Ubuntu: `docker-buildx`; Docker's own packages: `docker-buildx-plugin`).
`make build` sets `DOCKER_BUILDKIT=1`, so without buildx it stops at once
with "BuildKit is enabled but the buildx component is missing".

CI builds the image for `linux/amd64` and `linux/arm64` on native runners
(the `worker-image`/`worker-manifest` jobs in `.github/workflows/deploy.yml`,
which start as soon as `test` passes). The `nerves_system_br` base is pinned by
its multi-arch index digest, so both architectures build on the same base.
To build the other architecture locally, run `docker build --platform
linux/arm64 ...` (or `linux/amd64`). Under emulation that is slow.

## Dependency policy

All deps must come from Hex. This is enforced in `NccWorker.LockPolicy` and is load-bearing for reproducibility — don't relax it.
