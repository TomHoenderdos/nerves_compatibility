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
| `PHX_HOST` | Public hostname used to generate URLs. Defaults to `example.com`, so it must be set |
| `PHX_BIND_IP` | Address the endpoint binds to. Defaults to every interface; set `127.0.0.1` behind a reverse proxy on the same host |
| `SECRET_KEY_BASE` | Phoenix secret key base |
| `DATABASE_URL` | Postgres URL for `Portal.Repo` |
| `PORTAL_DATABASE_POOL_SIZE` | Optional DB pool size |
| `ECTO_IPV6` | Set to `true` when the DB needs IPv6 socket options |
| `GITHUB_CLIENT_ID` | Optional GitHub OAuth App client ID with device flow enabled |
| `PORTAL_SEED_ADMINS` | Optional seed list, e.g. `alice,bob:temporary-password` |
| `PORTAL_SEED_ADMIN_PASSWORD` | Optional shared password for seeded admins without `:password` |
| `TURNSTILE_SECRET_KEY` | Optional server-side Turnstile verification secret |
| `NCC_ARTIFACT_STORE` | Optional artifact blob store path; defaults to `~/.ncc-artifacts` |

Build-host settings. Every path below is passed to `docker run --mount source=`, so it is
resolved by the host daemon and must be a path the daemon can see:

| Env var | Purpose |
| --- | --- |
| `NCC_DOCKER_IMAGE` | Worker image; defaults to `ncc-worker:local` |
| `NCC_SCRATCH_ROOT` | Per-run scratch dirs; defaults to `~/.ncc-scratch` |
| `NCC_NERVES_CACHE` | Shared Nerves cache; defaults to `~/.ncc-nerves-cache` |
| `NCC_HEX_CACHE` | Shared Hex cache; defaults to `~/.ncc-hex-cache` |
| `NCC_BUILD_CPUS` | Cap cores per build, e.g. `3`. Unset means unbounded |
| `NCC_BUILD_MEMORY` | Cap memory per build, e.g. `4g`. Unset means unbounded |
| `NCC_BUILD_USER` | `--user` for the build container. Unset means our own uid:gid. Set `0:0` on a rootless daemon, where our uid is already 0 inside the namespace |

The root `config/runtime.exs` owns runtime config. Do not add child-app `runtime.exs` files under `apps/portal/config/`; they are not loaded in an umbrella.

## Database setup

Create and migrate the database before starting the release:

```bash
DATABASE_URL=ecto://USER:PASS@HOST/DB \
bin/portal eval 'Ecto.Migrator.with_repo(Portal.Repo, &Ecto.Migrator.run(&1, :up, all: true))'
```

Seed admin users after migrations. This one runs against the *running* node,
not through `eval`: seeding goes through an Ash action, and `eval` starts a bare
VM in which `Portal.Repo` was never started, so it fails with `could not lookup
Ecto repo Portal.Repo`. Start the service first, then:

```bash
PORTAL_SEED_ADMINS='alice,bob:change-this-temporary-password' \
bin/portal rpc 'Portal.Seeds.seed_admins_from_env!()'
```

`rpc` inherits the running node's environment, so `PORTAL_SEED_ADMINS` and
`PORTAL_SEED_ADMIN_PASSWORD` belong in the service's env file, not on this
command line, unless the node already has them.

## Import package overrides

`package_metadata.json` was imported during the Phase 6 cutover and removed from the repo. Future overrides are admin-managed in `Portal.Catalog.PackageOverride` rows.

For one-time imports in another environment, run before removing the source file:

```bash
mix portal.import_overrides /path/to/package_metadata.json
```

## Building the release

There is no root-level release definition per app; the umbrella defines one
release named `portal` (see `releases/0` in the root `mix.exs`).

Run the build from the **umbrella root**, not from `apps/portal`. Assets resolve
their dependencies through the umbrella's `deps/`, and running mix from inside
`apps/portal` gives that app its own separate `deps/` tree.

```bash
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix assets.setup
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release portal
```

`assets.deploy` must come before `mix release`, or the release ships without
CSS/JS and without a digest manifest.

A release links against the glibc of the machine that built it. When building in
a container for a different host, the base image must match that host's
distribution.

## Systemd example

```ini
[Service]
Type=exec
User=nerves-compat
WorkingDirectory=/var/lib/nerves-compat
EnvironmentFile=/etc/ncc-portal/portal.env
Environment=RELEASE_TMP=/var/lib/nerves-compat/tmp
ExecStart=/opt/nerves_compatibility/portal/bin/portal start
ExecStop=/opt/nerves_compatibility/portal/bin/portal stop
Restart=on-failure
```

`WorkingDirectory` must be a directory the service user can actually read. The
release boots a VM there, and pointing it at a directory the user cannot enter
produces a kernel-level crash during boot rather than a clear error.

`RELEASE_TMP` matters when the release directory is not writable by the service
user: the release regenerates `vm.args` and `runtime.exs` output on every boot
and needs somewhere to put them.

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
