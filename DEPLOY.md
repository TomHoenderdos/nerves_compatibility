# Deploying

## Overview

The tracker now deploys as one Phoenix service plus Postgres and Docker on the host. Phoenix serves the public compatibility site, admin UI, Oban dashboard, schema-v2 JSON API, badges, and precompiled artifact API.

The worker still runs in Docker as `ncc-worker:local`; the portal shells out to that image from `Portal.Builder` when Oban executes build jobs.

## Required services

- PostgreSQL 14+
- Docker daemon
- Phoenix release for `apps/portal`
- Worker image built as `ncc-worker:local`

## Build the worker image

From the repo root:

```bash
make build
```

Run this whenever `apps/ncc_worker/`, `apps/compatibility/`, or `apps/ncc_worker/Dockerfile` changes.

## Portal configuration

Configure these environment variables for the Phoenix service:

| Env var | Purpose |
| --- | --- |
| `PHX_SERVER` | Set to `true` in releases so the endpoint starts |
| `PORT` | HTTP port, default `4001` |
| `SECRET_KEY_BASE` | Phoenix secret key base |
| `DATABASE_URL` | Postgres URL for `Portal.Repo` |
| `POOL_SIZE` | Optional DB pool size |
| `ECTO_IPV6` | Set to `true` when the DB needs IPv6 socket options |
| `GITHUB_CLIENT_ID` | Optional GitHub OAuth App client ID with device flow enabled |
| `PORTAL_SEED_ADMINS` | Optional seed list, e.g. `alice,bob:temporary-password` |
| `PORTAL_SEED_ADMIN_PASSWORD` | Optional shared password for seeded admins without `:password` |
| `TURNSTILE_SECRET_KEY` | Optional server-side Turnstile verification secret |
| `NCC_ARTIFACT_STORE` | Optional artifact blob store path; defaults to `~/.ncc-artifacts` |

The root `config/runtime.exs` owns runtime config. Do not add child-app `runtime.exs` files under `apps/portal/config/`; they are not loaded in an umbrella.

## Database setup

Create and migrate the database before starting the release:

```bash
DATABASE_URL=ecto://USER:PASS@HOST/DB \
bin/portal eval 'Ecto.Migrator.with_repo(Portal.Repo, &Ecto.Migrator.run(&1, :up, all: true))'
```

Seed admin users after migrations:

```bash
DATABASE_URL=ecto://USER:PASS@HOST/DB \
PORTAL_SEED_ADMINS='alice,bob:change-this-temporary-password' \
bin/portal eval 'Portal.Seeds.seed_admins_from_env!()'
```

## Import package overrides

`package_metadata.json` was imported during the Phase 6 cutover and removed from the repo. Future overrides are admin-managed in `Portal.Catalog.PackageOverride` rows.

For one-time imports in another environment, run before removing the source file:

```bash
mix portal.import_overrides /path/to/package_metadata.json
```

## Systemd example

```ini
[Service]
User=nerves-compat
WorkingDirectory=/opt/nerves_compatibility/portal
Environment=PHX_SERVER=true
Environment=PORT=4001
Environment=DATABASE_URL=ecto://portal:secret@127.0.0.1/portal_prod
Environment=SECRET_KEY_BASE=...
ExecStart=/opt/nerves_compatibility/portal/bin/portal start
```

Ensure the service user can talk to Docker and can read/write the artifact store and the shared caches (`~/.ncc-nerves-cache`, `~/.ncc-hex-cache`, or the configured equivalents).

## Public endpoints

- `/` — package browser
- `/packages/:name` — package details
- `/requests/:id` — live request/build status
- `/badge/:name.svg` — SVG badge
- `/api/packages`, `/api/packages/:name`, `/api/stats` — schema-v2 JSON API
- `/api/precompiled/manifests/:package.json` — precompiled package manifest
- `/api/precompiled/files/:sha256` — content-addressed artifact blob
- `/admin/oban` — Oban Web dashboard behind admin auth

## Verification after deploy

```bash
make build
mix test
make test-integration
```

Then boot the portal and check:

- `/`
- `/request-scan`
- `/admin`
- `/admin/oban`
- `/badge/jason.svg` after catalog data exists
- `/api/packages`
- `/api/precompiled/manifests/<package>.json` after artifact data exists
