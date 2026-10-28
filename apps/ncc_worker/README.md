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
   retrying the same `mix.exs` three times a day would ever change the outcome.
3. Rejects the run if `mix.lock` contains any non-Hex deps (exit 11).
4. Compiles the package on the host. If that passes and the whole dependency closure is pure Elixir
   (`NccWorker.BuildSelection`), records an assumed-compatible `pure_elixir` result instead of building firmware.
   Otherwise builds firmware for each Nerves system (`NccWorker.Systems`), capturing status, size, and a log tail.
   When the host compile failed, rpi4 builds alone first; if it fails too, the rest are recorded as
   `skipped` ("host and <system> failed to compile") without being built (`NccWorker.SeedGate`).
   A `systems_filter` in `NCC_INPUT` builds only those systems and reports `"scope": "targets"` in `result.json`;
   otherwise the scope is `"full"`.
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
   picks one of (`picosat_elixir`, `simple_sat`); the list is `@optional_deps_never_added` in `NccWorker.Project`.
   `host.log` carries the same lines. The key is absent for argus-only runs.

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
   then carries that build's status, e.g. `"host status: fail"`), or `"no_beams"` (the package's host `ebin` has
   no `.beam` to analyze, e.g. a pure-metadata package like `nerves_pack`). `nil` otherwise.
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

## Toolchain mode

With `"mode": "toolchain"` (and an informational `"toolchain": {"elixir": "1.19", "otp": "28"}`, echoed back as
`requested_toolchain`) the worker answers one question on a toolchain image: are the package's own beams, built by
this Elixir and OTP, the same on every OS and architecture? Such an image has no nerves_bootstrap and possibly an
OTP Nerves 2 does not accept, so the run uses a plain `mix new` project (`NccWorker.Project.create_plain/2`), adds
the package, applies the lock policy (exit 11), runs the same optional-dependency pass as a pure-Elixir full run,
compiles once on the host in `prod` and judges `_build/host/lib/<package>` with
`NccWorker.BuildSelection.portable?/3`. No firmware, no argus (`argus.status` is `"skipped"`), no Nerves systems,
no Hex metadata fetch; `toolchain.nerves_bootstrap` is `"absent"`. `result.json` has `"scope": "toolchain"`,
`"systems": {}`, the usual top-level `deps_lock`, `package_checksum` and `optional_deps`, and:

```json
"toolchain_build": {
  "status": "pass | skipped | error",
  "reason": "portable?'s reason when skipped, what failed when error, null when pass",
  "elixir": "1.19.1", "otp": "28",
  "deps_lock": {"jason": {"version": "1.4.4", "checksum": "<outer>"}},
  "package_checksum": "<outer>",
  "compile_env": [{"app": "...", "path": ["..."], "value": "<base64url term>"}],
  "file_manifest": {"ebin": [{"path": "ebin/x.beam", "sha256": "...", "size": 1234, "mode": 33188}], "priv": []}
}
```

`deps_lock`, `package_checksum` and `compile_env` are present for `pass` and `skipped` and `null` for `error`;
`file_manifest` only for `pass`, and those files are archived by SHA256 from `_build/host/lib/<package>`. A failed
host compile is `status: "error"`: `result.json` is still written and the exit code is `0`, so the portal ingests the
verdict (as a `fail` row). A compile failure is deterministic for that package, version and toolchain, so it is
recorded, not retried. A `deps.get` failure here always exits `10` without a result and is retried — toolchain
mode does not run it through `NccWorker.DepsGetClassifier`; only a full, targets or argus-only run does (see
"What it does" above).

See `examples/input.json` and `examples/result.json` for the wire format; the full `result.json` typespec is at the top of `lib/ncc_worker/worker.ex`.

## Egress probe

With `"egress_probe": [{"address": "192.0.2.1", "port": 1234}, {"address": "2001:db8::1", "port": 1234}]`
in `NCC_INPUT`, the worker tries a TCP connect to each target before any `mix` runs and writes
`result.json` `egress_probe`: one `{"address", "port", "family", "outcome"}` per target, `outcome` one of
`connected` or `refused` (both mean the packet got through), `timeout` (dropped),
`unreachable` (no route), `invalid_target`, or the socket error's name. Advisory: it never changes a status or fails
the run. Only `Portal.EgressCheck` sends it (see the operator runbook); otherwise the key is absent.

## Exit codes

- `0` — success (some systems may still have failed; check `result.json`) — a toolchain run whose compile failed
  exits `0`, and so does a full/targets/argus-only run whose own `deps.get` failed deterministically
  (`NccWorker.DepsGetClassifier`)
- `10` — internal failure: no `result.json` was written (includes a `deps.get` failure classified transient, and
  always a toolchain run's own `deps.get` failure)
- `11` — policy violation (non-Hex dependency in `mix.lock`)

## Develop

From the umbrella root (never run `mix deps.*` in this directory; it rewrites the shared `mix.lock`):

```bash
mix test apps/ncc_worker/test/
make build          # builds the escript into the ncc-worker:local image
```

## Dependency policy

All deps must come from Hex. This is enforced in `NccWorker.LockPolicy` and is load-bearing for reproducibility — don't relax it.
