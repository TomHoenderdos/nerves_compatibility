# NCC Worker

Container-side program that evaluates one Hex package against the official Nerves systems.

The worker runs inside the Docker container — it never invokes Docker itself. The host-side `runner` mounts directories and starts it.

## What it does

1. Reads a job from `NCC_INPUT` (default `/work/input.json`).
2. Generates a fresh Nerves project and adds the target package.
3. Rejects the run if `mix.lock` contains any non-Hex deps (exit 11).
4. Builds firmware for each Nerves system, capturing status, size, and a log tail.
5. Writes atomic `/out/result.json` plus per-system logs under `/out/logs/`.

See `examples/input.json` and `examples/result.json` for the wire format.

## Exit codes

- `0` — success (some systems may still have failed; check `result.json`)
- `10` — internal failure
- `11` — policy violation (non-Hex dependency in `mix.lock`)

## Develop

```bash
mix deps.get
mix test
mix escript.build   # produces ./ncc_worker
```

## Dependency policy

All deps must come from Hex. This is enforced in `NccWorker.LockPolicy` and is load-bearing for reproducibility — don't relax it.
