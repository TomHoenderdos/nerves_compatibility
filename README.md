# Nerves Compatibility Tracker

A static site that tracks Hex.pm package compatibility with Nerves target systems.

## Layout

Monorepo of five independent Mix projects (no top-level `mix.exs`):

- `compat/` — shared types, JSON index loaders and validators
- `beam_scanner/` — inspects compiled BEAMs for NIFs, ports, env access, etc.
- `worker/` — runs inside the Docker container; builds firmware per system
- `runner/` — runs on the host; invokes Docker and collects results
- `orchestrator/` — polls Hex.pm, queues work, invokes the runner, regenerates the site
- `site/` — static site generator (Mix tasks `site.gen`, `site.serve`)

See each subdir's README for details.

## Common commands

The top-level `Makefile` wraps the full pipeline:

```bash
make build                    # build the ncc-worker:local Docker image
make run PACKAGE=jason:1.4.1  # run one package end-to-end
make site                     # collect results and generate public/site/
make test-integration         # end-to-end regression test (needs Docker)
```

Site-only iteration (no Docker):

```bash
cd site
mix site.gen --in ../example_data --out ../public
mix site.serve --dir ../public --port 4000
```

## Docs

- `docs/INDEX_FORMAT.md` — index JSON schemas
- `docs/PACKAGE_METADATA.md` — `package_metadata.json` overrides
- `PRECOMPILED_API.md` — precompiled package API

## License

TBD
