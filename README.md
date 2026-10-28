# Nerves Compatibility Tracker

A Phoenix-served compatibility tracker for Hex.pm packages on Nerves target systems.

## Layout

This repository is a Mix umbrella with four apps:

- `apps/compatibility` — shared result/index types, validators, and status helpers.
- `apps/ncc_worker` — the Docker-side worker escript. It creates a temporary Nerves project, builds firmware per system, scans BEAM artifacts, and emits `result.json` plus content-addressed artifacts.
- `apps/portal` — Phoenix 1.8 + Ash/Postgres + Oban web app. It owns scan intake, accounts and admin UI, the build queue, Catalog persistence, the package browser, badges, the schema-v2 JSON API, and the precompiled artifact API.
- `apps/ncc_agent` — the remote builder agent. It claims build jobs from the portal, runs the worker image for them, and uploads the results.

[elixir_precompiled](https://github.com/TomHoenderdos/elixir_precompiled) is a client that consumes the precompiled API.

## Common commands

```bash
make build                     # build ncc-worker:local (layer cache on)
make build-clean               # same, with --no-cache
make dev                       # start the Phoenix portal on http://localhost:4001
make test                      # run umbrella tests
make test-integration          # real Docker -> Portal.Catalog integration test
make test-remote-e2e           # real ncc_agent process + fake docker -> lease -> ingest
make test-remote-integration   # same through the real worker container (needs Docker)
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
- `/failing` — "Top failing": failing packages ranked by hex.pm downloads
- `/request-scan` — request a scan of a Hex package
- `/requests/:id` — redirects to the package page
- `/badge/:name.svg` — SVG compatibility badge
- `/api/packages`, `/api/packages/:name`, `/api/stats` — schema-v2 JSON API
- `/api/failing?sort=recent|all&limit=&system=` — failing packages ranked by downloads (see `docs/INDEX_FORMAT.md`)
- `/api/packages/hex?query=` — Hex.pm package search used by the scan request form
- `/api/precompiled/manifests/:package.json` (format 1), `/api/precompiled/v2/manifests/:package.json` (format 2), `/api/precompiled/files/:sha256` — precompiled artifact API
- `/api/precompiled/root.json`, `/api/precompiled/batch.json`, `/api/precompiled/batches/:sequence.json` — signed precompiled trust root and batches
- `/api/docs` — the JSON API documented as a page; `/api/openapi.json` — the same as an OpenAPI 3 document

## Docs

- `/api/openapi.json` (and `/api/docs`) — every JSON API endpoint, its parameters and response schemas, generated from the controllers
- `docs/INDEX_FORMAT.md` — schema-v2 JSON API shapes
- `PRECOMPILED_API.md` — precompiled package API
- `docs/PRECOMPILED_DEPS_RFC.md` — RFC: precompiled dependencies for Elixir and Erlang projects
- `SECURITY.md` — reporting vulnerabilities

## License

Copyright 2026 Tom Hoenderdos. Licensed under the Apache License, Version 2.0; see
[LICENSE](LICENSE). Vendored files under `apps/portal/assets/vendor/` keep their own licenses.
