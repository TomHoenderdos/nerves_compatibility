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
5. When `NCC_INPUT` carries `argus` (`{"analyses": ["default", "exposure"], "scope": "firmware", "timeout_seconds": 300}`),
   runs the argus_beam escript over the host-compiled beams (`NccWorker.Argus`) and writes its findings to
   `result.json` as `argus`. `scope: "firmware"` limits this to packages that build firmware. Advisory: it never
   changes a status or the exit code. Without the key, `argus.status` is `"skipped"`.
6. Writes atomic `/out/result.json` plus per-system logs under `/out/logs/`, and archives compiled files by SHA256 under `/files`.

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
