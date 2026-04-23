# NCC Runner

Host-side program that invokes the worker container for a single package/version job.

## What it does

- Validates Docker and the job JSON.
- Creates per-run `work_dir`, `output_dir`, and `files_dir`.
- Runs `ncc-worker:local` with the mounts documented in the top-level `CLAUDE.md`.
- Collects `result.json`, logs, and `runner_metadata.json` for reproducibility.

See `examples/` for sample job payloads.

## Usage

```bash
mix deps.get
mix escript.build   # produces ./ncc_runner
./ncc_runner run --input examples/job.json --output-dir ./output
```

## Exit codes

- `0` — runner succeeded (builds may still have failed; check `result.json`)
- `20` — runner error (bad input, Docker missing, no `result.json`)
- `21` — worker container exited non-zero

## Integration test

`mix test --only integration` runs a real container and is the regression gate for the worker/runner boundary. Run it after any change that touches Docker invocation or the JSON contract.
