# Nerves Compatibility Tracker

A Phoenix-served compatibility tracker for Hex.pm packages on Nerves target systems.

## Layout

This repository is a Mix umbrella with three apps:

- `apps/compatibility` — shared result/index types, validators, and status helpers.
- `apps/ncc_worker` — the Docker-side worker escript. It creates a temporary Nerves project, builds firmware per system, scans BEAM artifacts, and emits `result.json` plus content-addressed artifacts.
- `apps/portal` — Phoenix 1.8 + Ash/Postgres + Oban web app. It owns scan intake, accounts and admin UI, the build queue, Catalog persistence, the package browser, badges, the schema-v2 JSON API, and the precompiled artifact API.

## Common commands

```bash
make build                     # build ncc-worker:local (layer cache on)
make build-clean               # same, with --no-cache
make dev                       # start the Phoenix portal on http://localhost:4001
make test                      # run umbrella tests
make test-integration          # real Docker -> Portal.Catalog integration test
make format                    # mix format
```

Run Mix from the repo root, never from inside `apps/*`: the umbrella shares one
`mix.lock`, and a `mix deps.*` task run in a child app rewrites it.

```bash
mix deps.get
mix test
mix test apps/ncc_worker/test/
mix format
```

## Public routes

- `/` — dashboard
- `/packages` — package browser
- `/packages/:name` — package details and latest system results
- `/packages/:name/log/:system` — stored build log of a failed system
- `/failure_clusters`, `/stats` — failure clusters and per-system statistics
- `/request-scan` — request a scan of a Hex package
- `/requests/:id` — redirects to the package page
- `/badge/:name.svg` — SVG compatibility badge
- `/api/packages`, `/api/packages/:name`, `/api/stats` — schema-v2 JSON API
- `/api/precompiled/manifests/:package.json`, `/api/precompiled/files/:sha256` — precompiled artifact API

## Docs

- `docs/INDEX_FORMAT.md` — schema-v2 JSON API shapes
- `docs/PACKAGE_METADATA.md` — package overrides
- `PRECOMPILED_API.md` — precompiled package API
- `DEPLOY.md` — running the portal and build worker
- `SECURITY.md` — reporting vulnerabilities
- `TODO.md` — known gaps

## License

TBD
