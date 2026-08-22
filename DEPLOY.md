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

Docker layer caching is on, so a source-only change reuses the apt, Elixir and
hex-archive layers above the `COPY`. Use `make build-clean` (`--no-cache`) when
those upper layers are what you want refetched, e.g. after an OTP bump.

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
| `OBAN_QUEUES` | Which queues this node runs, e.g. `builds:1,ingest:2`. Unset means all of them. See [Splitting the build host](#splitting-the-build-host) |

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
| `NCC_BUILD_CONCURRENCY` | How many Nerves targets one build may compile at once. Unset means 1 (serial). Raise it together with `NCC_BUILD_CPUS`: the targets share that cap, and the win comes from overlapping the single-threaded stretches (release assembly, squashfs, fwup). Capped at 4 in code. See the note below |

### Picking a concurrency

Targets each get their own `MIX_BUILD_PATH` and `MIX_DEPS_PATH`, so the
firmware builds do not share compiled state. They do share the project
directory and the Hex cache, so this is bounded by the host, not by
correctness: `@max_build_concurrency` in `NccWorker.Worker` caps it at 4, and
anything above that leaves a 6-core machine with nothing for the rest of its
work.

Measured on jason, warm caches, 6-core Contabo:

| config | wall clock |
|---|---|
| serial, `CPUS=3` | 15.5 min |
| `CONCURRENCY=2`, `CPUS=3` | 15.5 min |
| `CONCURRENCY=2`, `CPUS=5` | 11.9 min |
| `CONCURRENCY=3`, `CPUS=5` | 4.5 min |
| `CONCURRENCY=4`, `CPUS=5` | **3.2 min** |

Every row is jason on the same host, all four systems passing, firmware sizes
matching to within a few hundred bytes. The last two rows also carry the
`deps.clean` fix below, which is most of the drop between 11.9 and 4.5: the
cross-target clean was making every target recompile the package repeatedly
even when nothing ran in parallel.

Raising concurrency without raising `CPUS` buys nothing: the targets just split
the same cap. At `CONCURRENCY=4`/`CPUS=5` on a 6-core host, load peaked at 7.7
and the co-tenant site's slowest request was 0.64s.

One historical trap, fixed but worth knowing if it comes back. The determinism
check used to force a rebuild with `mix deps.clean --build <pkg>`, and that task
globs `Path.dirname(build_path)/*/lib/<app>` — with every target's build dir
under one `_build/`, it deleted the package from the *sibling* targets as well.
Concurrently that landed between a sibling's compile and its release step:

```
Unchecked dependencies for environment prod:
* jason (Hex package)
  could not find an app file at "_build/mangopi_mq_pro/lib/jason/ebin/jason.app"
```

The worker now removes its own `<build_path>/lib/<pkg>` directly instead.

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

The env file needs the same care, one level up. `deploy.sh` runs the migration
as the service user, and sourcing a file means traversing its directory, so both
have to be reachable by that user:

```bash
install -d -o root -g nerves-compat -m 0750 /etc/ncc-portal
install -o root -g nerves-compat -m 0640 portal.env /etc/ncc-portal/portal.env
```

A directory left at `0700 root:root` fails in a way that is easy to misread. The
service still starts, because systemd reads `EnvironmentFile` as root before it
drops privileges, so only the deploy script reports `Permission denied`, and it
does so after building the release but before restarting into it. The unit keeps
reporting `active` on the previous build.

Ensure the service user can talk to Docker and can read/write the artifact store and the shared caches (`~/.ncc-nerves-cache`, `~/.ncc-hex-cache`, or the configured equivalents).

## Build pipeline

A scan request runs as two Oban jobs, not one:

1. `Portal.Workers.Build` (queue `builds`, concurrency 1) runs the worker
   container and leaves the run's scratch directory in place.
2. `Portal.Workers.Ingest` (queue `ingest`) reads that scratch directory back
   and writes the Catalog rows, then removes it.

They are split so a database-side ingest failure retries the database write
instead of the multi-target firmware build that produced it. A scratch dir that
outlives its run therefore means an ingest that never completed: check the
`ingest` queue before deleting it by hand.

## Splitting the build host

Builds are the expensive part and they do not need to sit next to the web
server. `OBAN_QUEUES` lets one deploy run as two nodes against one database:

| | web node | build node |
| --- | --- | --- |
| `OBAN_QUEUES` | `intake:5,maintenance:1` | `builds:1,ingest:2` |
| `DATABASE_URL` | local Postgres | the same Postgres, over the private network |
| Docker daemon | not used | runs the worker image |
| Apache/TLS | yes | no, firewall it to the private interface |

Both nodes run the same release. Oban coordinates through Postgres rows, not
through BEAM distribution, so the nodes never need to see each other and no
epmd port has to be opened between them. Adding a third build box is the same
env file again.

Three things decide where a queue can live:

**`ingest` must sit with `builds`.** They hand off through the run's scratch
directory on local disk. Put `ingest` on the web node and it finds nothing to
read, then cancels the request with `build output missing`.

**Latency, not CPU, decides the rest.** A build is minutes of compilation and a
handful of queries, so a slow link to the database costs nothing. Query-chatty
work is the opposite: at 23ms round trip a job doing 50 queries spends over a
second waiting. Measure the link before moving a queue that talks to the
database more than it computes.

**Artifacts land where `ingest` runs.** `Portal.ArtifactStore` writes blobs to
local disk and the database keeps only metadata, so a build node fills its own
`NCC_ARTIFACT_STORE` while the web node serves
`/api/precompiled/files/:sha256` from a directory that never sees them. Blobs
are named by their SHA256 and therefore immutable, so a periodic pull is enough:

```bash
rsync -a --ignore-existing -e ssh root@BUILD_HOST:/ /var/lib/ncc/artifacts/
```

Run that *from* the web node, on a timer. Pulling rather than pushing keeps the
credential on the trusted side: the build node executes unreviewed package code,
so it should never hold a key into the machine serving the site.

Restrict the key it uses on the build host, in `~/.ssh/authorized_keys`:

```
command="rrsync -ro /var/lib/ncc/artifacts",restrict ssh-rsa AAAA...
```

`rrsync` ships with rsync and confines the connection to that one directory,
read-only. That is why the source path above is `:/` and not the real path: the
remote side is already chrooted to the artifact store, so an absolute path would
resolve underneath it. Verify both halves after installing the key. The pull
must work, and

```bash
ssh root@BUILD_HOST id
```

must be refused with `SSH_ORIGINAL_COMMAND does not run rsync`.

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
