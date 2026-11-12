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
   restores `mix.exs` and `mix.lock`, removes `_build/host/lib/<package>` and rebuilds without them. A firmware
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
   "reason": null}`; one that fails anywhere in this gets back exactly its first build, byte for byte, no
   per-system `deps_lock`, and `optional_deps: {"added": [], "dropped": [...], "reason": "<reason>"}`. `mix.exs`
   and `mix.lock` are always restored from the snapshot afterwards, so nothing later (argus, the footprint scan,
   the run-level `deps_lock`) sees the optional dependencies. Nothing in this pass changes a status, a firmware
   image, `firmware_size_bytes`, `log_tail`, `error`, `dependency_scans` or `cache_candidates` of any system, and
   its compile is never stored in the build cache (the cache key would describe the lock without the optional
   dependencies). A system that was not passing when the pass ran gets no `deps_lock` or `optional_deps` key.

   A target's drop reason is one of `deps_get_failed`, `lock_policy_violation`, `target_compile_failed` (including
   a raise from any runner, or an OOM kill), `mix_exs_edit_failed` (the inject failed, which drops every target),
   `stale_build_not_removed` (the move-aside, or the pass's own cleanup, could not rename or remove the build
   directory), `deps_lock_unreadable` (the lock could not be read after `deps.get`, so a kept target would have no
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

   Partial runs (`systems_filter`) run the pass over the targets that were actually built. Toolchain and
   pure-Elixir runs are unaffected by any of this; see above for their own optional-dependency pass.
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
   `deps_lock` instead (same shape), which the precompiled API prefers over the run's for that system's entries.
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
killed nor counted. `erl_child_setup` is a direct child of the BEAM named `erl_child_setup`; of several such, only
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
could not be judged".

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
- a call into a natively built dependency while the package compiles;
- a rebar3 build with hooks, plugins, `rebar.config.script`, or a `platform_define` whose regex can see past the
  leading OTP major (precompiled judge refinements, item 3; `rebar_utils:get_arch/0` puts the full OTP version
  ahead of the arch and wordsize, but the client checks only the major);
- a trace that did not finish.

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
  "config_variant": "default",
  "portability_rule": 2,
  "rule1_reason": "rule 1's reason when it would have skipped, else null",
  "judge_revision": 1,
  "manager": "rebar3",
  "compile_observations": {"trace_stats": {"windows": 14, "wall_ms": 9100, "host_compile_sec": 31.2}, "config_reads": [], "refusals": [], "taint": {}, "problems": []},
  "file_manifest": {"ebin": [{"path": "ebin/x.beam", "sha256": "...", "size": 1234, "mode": 33188}], "priv": []}
}
```

`deps_lock`, `package_checksum`, `declared` and `compile_env` are present for `pass` and `skipped` and `null` for
`error` (`declared` is also `null` when the lock could not be read);
`file_manifest` only for `pass`, and those files are archived by SHA256 from `_build/host/lib/<package>`. A failed
host compile is `status: "error"`: `result.json` is still written and the exit code is `0`, so the portal ingests the
verdict (as a `fail` row). A compile failure is deterministic for that package, version and toolchain, so it is
recorded, not retried. A `deps.get` failure here always exits `10` without a result and is retried — toolchain
mode does not run it through `NccWorker.DepsGetClassifier`; only a full, targets or argus-only run does (see
"What it does" above).

`portability_rule`, `rule1_reason` and `compile_observations` are present for `pass` and `skipped` and `null` for
`error`. `portability_rule` is `2`: the static rules (`BuildSelection.static_rules/4`: compiled beams in Elixir or
Erlang, no NIF or driver load, static priv only, no mention of Nerves in the code of its sources
(`NccWorker.NervesCode`; rule 1 keeps the plain grep), no native sources, native
build dependencies, target reads or `nerves*` name) AND the compile-time trace. A program call, an executable lookup
or an `:os.type()` in the sources no longer refuses a build; the trace refuses one made at compile time, and a
module that holds a source path in a package that runs programs. `rule1_reason` is what rule 1 (`portable?/4`, the
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

See `examples/input.json` and `examples/result.json` for the wire format; the full `result.json` typespec is at the top of `lib/ncc_worker/worker.ex`.

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
