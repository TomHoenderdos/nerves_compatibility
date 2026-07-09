# Nerves Compatibility Tracker

A Phoenix-served compatibility tracker for Hex.pm packages on Nerves target systems.

## Layout

This repository is a Mix umbrella with three apps:

- `apps/compatibility` — shared result/index types, validators, and status helpers.
- `apps/ncc_worker` — the Docker-side worker escript. It creates a temporary Nerves project, builds firmware per system, scans BEAM artifacts, and emits `result.json` plus content-addressed artifacts.
- `apps/portal` — Phoenix 1.8 + Ash/Postgres + Oban web app. It owns scan intake, admin UI, build queue, Catalog persistence, dynamic package browser, badges, schema-v2 JSON API, and precompiled artifact API.

## Common commands

```bash
make build                     # build ncc-worker:local
make dev                       # start the Phoenix portal
make test                      # run umbrella tests
make test-integration          # real Docker -> Portal.Catalog integration test
make format                    # mix format
```

Umbrella-level commands can also be run directly from the repo root:

```bash
mix deps.get
mix test
mix format
```

## Public routes

- `/` — package browser
- `/packages/:name` — package details and latest system results
- `/requests/:id` — live scan-request/build status
- `/badge/:name.svg` — SVG compatibility badge
- `/api/packages`, `/api/packages/:name`, `/api/stats` — schema-v2 JSON API
- `/api/precompiled/manifests/:package.json`, `/api/precompiled/files/:sha256` — precompiled artifact API

## Docs

- `docs/INDEX_FORMAT.md` — schema-v2 JSON API shapes
- `docs/PACKAGE_METADATA.md` — admin-managed package overrides
- `PRECOMPILED_API.md` — precompiled package API

## License

TBD
