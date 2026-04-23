# Orchestrator

Long-running service that polls Hex.pm, queues new package versions, drives the runner, and regenerates the site.

Three supervised processes:

- **HexPoller** — polls Hex.pm (newest-updated first) and enqueues work.
- **Queue** — DETS-backed queues (`queue.dets`, `checked.dets`) that survive restarts.
- **Processor** — pulls from the queue, shells out to `ncc_runner`, and regenerates the site after each result.

## Run

```bash
mix deps.get
mix escript.build        # produces ./ncc_orchestrator

./ncc_orchestrator start       # long-running
./ncc_orchestrator status      # poll / queue / processor state
./ncc_orchestrator queue       # queue head + recent checks
./ncc_orchestrator poll        # force an immediate poll
./ncc_orchestrator pause       # stop processing (polling continues)
./ncc_orchestrator resume
./ncc_orchestrator clear-checked   # wipe dedup cache — re-checks everything
```

## Config

Defaults in `config/config.exs`; overrides in `config/dev.exs`. Key settings: `:poll_interval_ms`, `:runner_path`, `:results_dir`, `:public_dir`, `:queue_file`, `:checked_file`.
