# NCC Worker

Container-side program that evaluates one Hex package against the official Nerves systems.

The worker runs inside the Docker container — it never invokes Docker itself. On the host, `Portal.Builder` mounts the directories and starts it.

## What it does

1. Reads a job from `NCC_INPUT` (default `/work/input.json`).
2. Generates a fresh Nerves project and adds the target package.
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
5. When `NCC_INPUT` carries `argus` (`{"analyses": ["default", "exposure"], "scope": "firmware", "timeout_seconds": 300}`),
   runs the argus_beam escript over the host-compiled beams (`NccWorker.Argus`) and writes its findings to
   `result.json` as `argus`. `scope: "firmware"` limits this to packages that build firmware. Advisory: it never
   changes a status or the exit code. Without the key, `argus.status` is `"skipped"`.
   With `"mode": "argus_only"` the run stops after the host compile and this step: no firmware is built, argus
   covers every package (whatever `argus.scope` says), and `result.json` reports `"scope": "argus_only"`.
   Ingestion copies the systems a partial run left out from the previous run of the same version.
6. Records `deps_lock` in `result.json`: the package's transitive dependency closure from the project's `mix.lock`,
   the optional dependencies added in step 4 included and the package itself excluded, as `{"spark": {"version": "2.7.8", "checksum": "<outer Hex checksum>"}}`
   (`NccWorker.DepsLock`). Dependencies' macros are compiled into the package's BEAMs, so the precompiled API
   publishes this for clients to match against their own lock. The key is absent for argus-only runs, which build
   nothing, and when the lock cannot be read. It also records `package_checksum`, the package's own outer Hex checksum,
   and each system result's `compile_env` (the `.app` file's compile-time config reads, values as base64url deterministic terms).
7. Writes atomic `/out/result.json` plus per-system logs under `/out/logs/`, and archives compiled files by SHA256 under `/files`.
   The package's own files are its `ebin/` and `priv/` from `_build/<target>/lib/<package>/`, the target's compile
   output with `debug_info` intact, not the release copy, whose BEAMs are stripped (`NccWorker.BeamScan`,
   `NccWorker.Footprint`, `NccWorker.FileArchiver`). Dependencies' files are still archived from the release.
8. The shared dependency build cache at `/build-cache` is mounted read-only — the container can restore from it
   (`NccWorker.BuildCache.restore/1`) but cannot write it. A pass or fail compile of the package under test is
   instead stored to `/out/build-cache/<key>/` (`NccWorker.BuildCache.store/2`) and reported in `result.json` as
   `cache.candidates`, one entry per system: `%{"key", "dep", "dep_lock", "target", "elixir", "otp", "closure"}`,
   where `closure` is `[%{"name", "lock"}]` and `"key"` is `Compatibility.BuildCacheKey.key/1` of the rest. The host
   (`Portal.BuildCache.Promotion`) recomputes that key with `dep` forced to the package under test, requires it to
   equal the reported one, ties the lock's outer checksum to the one Hex publishes for the release, and only then
   moves the candidate into the shared cache — the worker never decides which key its own output lands under.
   Dependencies other than the package under test still get stored, but to a run-local tier under the container's
   own `/tmp` rather than the shared cache, so a multi-target run still compiles a shared dependency once and
   restores it for the other targets without trusting the container to fill the shared cache itself.

See `examples/input.json` and `examples/result.json` for the wire format; the full `result.json` typespec is at the top of `lib/ncc_worker/worker.ex`.

## Exit codes

- `0` — success (some systems may still have failed; check `result.json`)
- `10` — internal failure
- `11` — policy violation (non-Hex dependency in `mix.lock`)

## Develop

From the umbrella root (never run `mix deps.*` in this directory; it rewrites the shared `mix.lock`):

```bash
mix test apps/ncc_worker/test/
make build          # builds the escript into the ncc-worker:local image
```

## Dependency policy

All deps must come from Hex. This is enforced in `NccWorker.LockPolicy` and is load-bearing for reproducibility — don't relax it.
