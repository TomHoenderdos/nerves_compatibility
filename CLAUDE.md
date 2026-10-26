# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Layout

This is a **Mix umbrella** at the repo root. It serves the Nerves Compatibility Tracker dynamically from Phoenix and uses Oban jobs to run Docker-backed package builds.

| App | Role |
| --- | --- |
| `apps/compatibility` | Core library: shared result/index types, validators, and `Compatibility.Types` status helpers. |
| `apps/ncc_worker` | Runs **inside** the Docker container. Creates a Nerves project, adds the package, builds firmware per system, enforces Hex-only deps, scans BEAM artifacts, archives precompiled files by SHA256, and writes `result.json`. Dockerfile at `apps/ncc_worker/Dockerfile`. |
| `apps/portal` | Phoenix 1.8 + Ash/Postgres + Oban web app. Owns scan intake, accounts/admin, host-side Docker invocation (`Portal.Builder`), build jobs (`Portal.Workers.Build`), Catalog persistence, dynamic browser, badges, schema-v2 JSON API, and precompiled artifact API. Also the remote-builder side: the builder CA, `builders`/`builder_leases`, `PortalWeb.BuilderEndpoint` (mTLS, port 8443), `Portal.Workers.RemoteBuild`, `Portal.Workers.LeaseReaper`, `Portal.Builders.Routing`. |
| `apps/ncc_agent` | The remote builder agent, shipped as the `ncc_agent` release and run by systemd on a builder VM (as root). Enrols over mTLS, claims leases, installs the `DOCKER-USER` egress ruleset (`priv/egress.sh`), runs the worker container with the shared `Compatibility.Builder.Argv` (the post-isolation argv the local host runs; the worker's own per-run Nerves cache farm; the cache warmed only with the pairs the portal names when the lease completes), uploads files, completes, updates itself. See `docs/REMOTE_BUILDERS.md`. |

`apps/portal/AGENTS.md` carries extensive Phoenix 1.8 / LiveView / HEEx conventions — read it before touching `apps/portal/`.

## Common Commands

```bash
make build                         # Rebuild ncc-worker:local
make dev                           # Start Phoenix portal
make test                          # Run umbrella test suite
make test-integration              # Real Docker -> Portal.Catalog integration test
make test-remote-e2e               # Real ncc_agent process + fake docker -> lease -> ingest (tag :e2e)
make test-remote-integration       # Same through the real worker container (needs Docker)
make format                        # mix format at umbrella root
```

Umbrella commands (run from repo root):

```bash
mix deps.get
mix test
mix test apps/compatibility/test/
mix format
```

**Never run a `mix deps.*` task from inside `apps/*`.** The umbrella shares one
`mix.lock` at the root, and a child app resolving deps rewrites that shared lock
against only its own dependency list — silently pruning everything it does not
declare. Root-only deps are the casualties: `mix_audit` is declared at
`mix.exs` and is invisible to the children, and a child `deps.get` has already
deleted it from the lock once. A pruned lock then audits clean because the
auditor is gone from it.

The usual way this bites is `cd apps/ncc_worker && mix test`, which fails with
"the dependency is not locked" and tempts a `mix deps.get` right there. Run the
test from the root instead: `mix test apps/ncc_worker/test/`. CI catches a
pruned lock via the "mix.lock is current" step in `.github/workflows/audit.yml`.

Portal commands:

```bash
mix deps.get                       # from the root, not `mix setup` in apps/portal
mix ecto.create && mix ecto.migrate
mix phx.server                     # http://localhost:4001
mix test apps/portal/test/
```

When finishing portal changes, run the portal `precommit` alias's checks from
the root: `mix compile --warnings-as-errors && mix format && mix test`. Do not
run `mix precommit` or `mix setup` inside `apps/portal`: `precommit` includes
`deps.unlock --unused` and `setup` includes `deps.get`, both of which rewrite
the shared lock.

The integration test is `apps/portal/test/portal/workers/build_integration_test.exs`, tagged `:integration` and excluded from default `mix test`. Run it after any change that could affect Docker invocation, the JSON contract, artifact storage, or the worker firmware-build path. The remote-builder tests (`apps/portal/test/portal/builders/agent_e2e_test.exs`, tag `:e2e`, and `remote_integration_test.exs`, tag `:integration`) are excluded too; run the e2e one after any change to the builder API, the agent, `Portal.Builders.Upload` or remote ingest.

## How a Package Gets Checked

1. A trigger creates a `Portal.ScanRequests.ScanRequest` or a maintenance job discovers a Hex release.
2. Portal enqueues `Portal.Workers.Build` on Oban's `:builds` queue with package/version/image digest and optional scan request id. Nerves tooling (`Portal.Catalog.ToolingSkip`: `nerves`, systems, toolchains, kiosk systems) never reaches Docker: the worker records a `skipped` run instead.
3. `Portal.Builder` runs `docker run ncc-worker:local` with the reproducibility mounts:
   - `/work` → per-run scratch
   - `/out` → outputs (`result.json`, logs, artifacts)
   - `/files` → content-addressed artifact staging
   - `/nerves-cache` → shared Nerves cache (`~/.ncc-nerves-cache`), **read-only** in every build and read-write only for a warm run (`NCC_NERVES_CACHE_RW=1` is the one-release rollback to read-write)
   - `/hex-cache` → shared Hex cache (`~/.ncc-hex-cache`)
   - `/build-cache` → per-image dependency build cache, **read-only**, only when `NCC_BUILD_CACHE` is set
   - `/tmp` → `<scratch>/tmp` and `/home/nerves/.cache` → `<scratch>/cache`, per-run writable dirs on an otherwise read-only root
4. `NccWorker.Worker` inside the container reads `NCC_INPUT`, creates a fresh Nerves project, enforces `NccWorker.LockPolicy`, compiles on the host, then either builds firmware per Nerves system or, for a pure-Elixir dependency closure, records an assumed-compatible `pure_elixir` result (`NccWorker.BuildSelection`). For a pure-Elixir package it then rebuilds the host beams it publishes with the package's unresolved optional dependencies added (`NccWorker.DepsLock.unresolved_optional_deps`), best effort and never changing a status; `result.json` `optional_deps` records what was added or dropped. For a firmware package the same best-effort pass runs instead per target, after every target's firmware build has already settled its status: once a passing target's recompile with the optional dependencies added succeeds, that target republishes its files and gains its own per-system `deps_lock`; one that fails keeps exactly its first build and the run's own `deps_lock`. Statuses, firmware images and every other per-system field never change because of this pass (`NccWorker.OptionalDepsTargets`; see `apps/ncc_worker/README.md` for the per-system keys, every drop reason, and its wall-clock budget). It runs the advisory argus_beam analysis over the host beams (`NccWorker.Argus`), captures status/firmware size/log tail/BEAM scan/footprint, archives files by SHA256, and writes atomic `result.json`. A partial run builds less: `NCC_INPUT.systems_filter` builds only those targets, and `NCC_INPUT.mode: "argus_only"` builds none and only runs argus. `result.json` names which in `scope` (`full`, `targets`, `argus_only`). `NCC_INPUT.mode: "toolchain"` is a different run altogether: a plain `mix new` project on a toolchain image, one host build and a `BuildSelection.portable?/3` verdict, written as `toolchain_build` with `scope: "toolchain"` and empty `systems` (see `apps/ncc_worker/README.md`). Before any `mix` call the worker points `NERVES_ARTIFACTS_DIR`/`NERVES_DL_DIR` at a per-run symlink farm over the read-only `/nerves-cache` (`NccWorker.NervesCache`) and reports what it had to extract itself as `nerves_cache.misses`; `NCC_INPUT.mode: "warm_nerves"` is the one run that writes the cache (`NccWorker.WarmNerves`).
5. On success, before enqueueing ingest, `Portal.Workers.Build` promotes the run's build-cache candidates for the package under test (`Portal.BuildCache.Promotion`) and queues a Nerves cache warm for the run's allowlisted misses (`Portal.NervesCache.request_warm/3` → `Portal.Workers.WarmNerves` on the node's `warm_nerves_<node>` queue, concurrency 1), then enqueues `Portal.Workers.Ingest` (queue `:ingest`, must run on the same host because they hand off through the scratch dir). It runs `Portal.Catalog.Ingestion` into Postgres: `Package`, `Run`, `SystemResult`, `SystemLog` (full logs of failed systems) and `Artifact` rows, with blobs moved into `Portal.ArtifactStore`. For a partial run it copies the systems the run left out from the previous run of the same version, marking each copy with `carried_from_run_id`; stats do not count the copies.
6. Both workers update the linked `ScanRequest` and broadcast progress over `Portal.PubSub` topic `request:<id>` (`Portal.Workers.Progress`).
7. **Remote builds.** Every enqueuer of `Build` goes through `Portal.Builders.Routing.build_job/2`: with remote building on (`remote_mode`, auto while a builder was seen lately), a registry image in `images.json` and the local `:builds` backlog above the threshold, the job becomes `Portal.Workers.RemoteBuild` on the `:remote` queue (web host), which writes a `queued` `Portal.Builders.Lease` instead of running Docker. An `ncc_agent` claims it over `/builder/v1/*` (port 8443, mTLS), heartbeats, uploads missing files into `NCC_UPLOAD_ROOT`, and completes; exit 0 marks it `done` and enqueues `Ingest` with `source: "remote"` on `:remote`, which records the run's `builder_id`. A builder's precompiled files publish only once its `publishing` flag is on. `Portal.Workers.LeaseReaper` (every 5 min, `:maintenance`) requeues leases whose builder went silent and fails them after 3 attempts.
8. Phoenix serves the dynamic site, badge endpoint, schema-v2 JSON API, and precompiled manifest/blob API directly from Catalog.

## Public Routes

- `/` — dashboard; `/packages` — package browser
- `/packages/:name` — package detail: latest run, per-system results, and live status of its newest build
- `/packages/:name/log/:system` — stored build log of a failed system
- `/failure_clusters`, `/stats` — failure clusters and per-system stats
- `/request-scan` — scan request form
- `/requests/:id` — redirects to the package page
- `/badge/:name.svg` — SVG badge
- `/api/packages`, `/api/packages/:name`, `/api/stats` — schema-v2 JSON API
- `/api/precompiled/manifests/:package.json` (format 1), `/api/precompiled/v2/manifests/:package.json` (format 2), `/api/precompiled/files/:sha256`, `/api/precompiled/root.json`, `/api/precompiled/batch.json`, `/api/precompiled/batches/:sequence.json` — precompiled API
- `/admin` (tabs Overview, Queue, Users, Failures, Argus, Triage at `/admin/argus/findings`, Builders at `/admin/builders`, Maintenance) and `/admin/oban` — admin UI and Oban Web dashboard. `/admin` needs a passkey sign-in; `config/dev.exs` turns that off for local dev
- `/login` — password, passkey, or password + TOTP; `/settings/security` enrols passkeys, TOTP and recovery codes
- `/auth/:provider/login`, `/auth/choose-username` — sign in with Hex.pm or GitHub
- `/settings/providers/:provider/...` — link, unlink, confirm a provider from Settings
- `/builder/v1/*` on `PortalWeb.BuilderEndpoint` (`NCC_BUILDER_PORT`, default 8443, mTLS): `ca.pem` and `enroll` open, `renew`, `status`, `jobs/claim`, `jobs/:lease_id/{heartbeat,files/missing,files,complete}` behind a client certificate. The remote-builder API, not part of the public site

## Exit Code Conventions

Worker exit codes are load-bearing and should not change casually:

- `0` ok
- `10` internal failure / retryable worker error
- `11` policy violation (non-Hex git/path dependency)

Portal maps these into Oban outcomes in `Portal.Workers.Build`: success enqueues ingest, policy violation cancels and rejects the request, retryable failures (and host-side codes `20`/`21` from `Portal.Builder`) retry and eventually mark the request errored.

## Data Contracts

- **Worker input**: `NCC_INPUT` JSON passed to the worker container, including the optional `mode` (`argus_only`, `toolchain`, `warm_nerves`), `toolchain`, `systems_filter`, for a warm run `nerves_packages`, and for the egress check `egress_probe` (`[%{"address", "port"}]`). See `apps/ncc_worker/README.md`.
- **Worker output**: `result.json` typespec at top of `apps/ncc_worker/lib/ncc_worker/worker.ex`, including `scope` (`full | targets | argus_only | toolchain | warm_nerves`), for a toolchain run `toolchain_build`, for a warm run `warm`, for a probed run `egress_probe` (`NccWorker.EgressProbe` outcomes), and for a build `nerves_cache` (`%{misses, lock}`, its Nerves cache misses and locked Nerves packages). Status enum lives in `Compatibility.Types` — `pass | fail | error | skipped | unknown`. `cache`, when present, is `%{candidates: [%{"key", "dep", "dep_lock", "target", "elixir", "otp", "closure"}]}`: build-cache candidates for the package under test only, which `Portal.BuildCache.Promotion` recomputes the key for (`Compatibility.BuildCacheKey.key/1`) and verifies against Hex before moving into the shared cache.
- **Catalog JSON API**: schema version 2, documented in `docs/INDEX_FORMAT.md`.
- **Package overrides**: `Portal.Catalog.PackageOverride` rows, documented in `docs/PACKAGE_METADATA.md`. Nothing reads them yet, so they have no effect on results.
- **Precompiled API**: manifests and content-addressed files served by portal, documented in `PRECOMPILED_API.md`.
- **Remote builders**: the builder API, lease states, `images.json`, agent layout and cloud-init, documented in `docs/REMOTE_BUILDERS.md`.
- **Build cache L2 object**: `<image-digest-slug>/<key>.tar.gz`, a gzip tar of one entry (`ebin`, `priv`, `.mix`, ...) with no symlink members (Mix's `priv`/`include` links are in `.ncc-links.json`), metadata `x-amz-meta-sha256`; `Portal.BuildCache.L2.Tarball`.

## Container / Caching Details

- The worker image is based on `ghcr.io/nerves-project/nerves_system_br`.
- `Portal.Builder` passes `--user $(id -u):$(id -g)` so bind-mounted files stay owned by the invoking host user (`NCC_BUILD_USER` overrides it, e.g. `0:0` on a rootless daemon), plus `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--read-only` and `--pids-limit 4096`. `/tmp` and `/home/nerves/.cache` are bind-mounted from the run's scratch dir (`<scratch>/tmp`, `<scratch>/cache`) because the root filesystem is read-only.
- Builds run behind an egress filter inside rootless dockerd's network namespace: `ops/builder-egress.nft` (table `inet ncc_egress`: DNS, and TCP 80/443 to public addresses, nothing else), loaded by `ops/builder-egress-load.sh` into the namespace of `$XDG_RUNTIME_DIR/dockerd-rootless/child_pid` (rootlesskit's `--detach-netns` leaves dockerd itself in the host namespace) on every daemon start and every builder deploy. `Portal.Builder.check_egress/0` refuses every build (`{:error, :egress_filter_missing}`, snoozed) where it is not loaded; `NCC_EGRESS_CHECK=0` turns that off on a host without a rootless daemon and is the rollback. See `ops/README.md`, "Egress filter".
- The docker argv is built by `Compatibility.Builder.Argv.build/1` (a pure function of paths, user, image and limits) so remote builders run the same sandbox; `apps/compatibility/test/fixtures/argv/post_isolation.exs` pins it and both `Compatibility.Builder.ArgvTest` and `Portal.BuilderTest` compare against it. Change the fixture only together with the sandbox.
- `/home/nerves` and `/app` are chmod'd `a+rX` in the Dockerfile so arbitrary uids can read the baked-in Mix archives and Elixir install; nothing in the image is writable at runtime.
- `~/.ncc-nerves-cache` and `~/.ncc-hex-cache` persist across runs and speed up repeated tests. The Nerves cache is mounted read-only at `/nerves-cache` into every build, which resolves artifacts through a per-run symlink farm (`NccWorker.NervesCache`) and reports what it had to extract itself. Its only writers are warm runs (`mode: "warm_nerves"`, `NccWorker.WarmNerves`): `Portal.Workers.WarmNerves` for misses that pass `Portal.NervesCache.warm_pairs/2` (in the run's lock, owned by the `nerves` Hex user, at most four, not warmed in the last day), and the deploy-time warm `ops/builder-deploy.sh` runs through `Portal.NervesCache.deploy_warm/1` after activating a new image, which also writes `template.json`. `Portal.Workers.Sweep` bounds it (`NCC_NERVES_CACHE_MAX_GB`, default 40) without ever evicting what `template.json` lists. `NCC_NERVES_CACHE_RW=1` is the one-release rollback to a read-write mount without the farm.
- The shared dependency build cache (`NCC_BUILD_CACHE`, mounted at `/build-cache` read-only) has exactly one writer: `Portal.BuildCache.Promotion`, which runs on the host after the container exits and before ingest. It trusts nothing a build reported without recomputing it — see `Portal.BuildCache.Promotion`'s moduledoc for the checks in order (dep/version match, recomputed key, Hex outer checksum, symlink and hardlink rules). Dependencies other than the package under test are not promoted; they live only in the worker's run-local tier for the duration of that run.
- A second, shared layer sits behind that cache: an S3 bucket (`NCC_BUILD_CACHE_S3_*`, Garage on a homelab host), read by `Portal.Builder` before every build (`Portal.BuildCache.L2.prefetch/3`, the image slug's listing synced into the local cache under a 2 GiB / 5 min budget) and written by `Portal.BuildCache.Promotion` after every local promotion (`Portal.BuildCache.L2.upload/5`). Entries travel as `<slug>/<key>.tar.gz` with `x-amz-meta-sha256`, with Mix's `priv`/`include` links carried in a `.ncc-links.json` manifest rather than as symlink members; the downloader re-checks the structure with the same `Portal.BuildCache.Tree` walk Promotion uses, and trusts the content because only holders of the read-write key can upload. Unset endpoint means off; remote builders never touch it. See `docs/BUILD_CACHE_L2.md`.
- `make build` keeps Docker's layer cache; `make build-clean` adds `--no-cache` when the apt, Elixir and Hex-archive layers need refetching.
- The image carries the argus_beam escript at `/home/nerves/.mix/escripts/argus` and, under `/opt/argus-flowlog`, the prebuilt FlowLog engines it solves its rules with (downloaded once at image build). Each run copies them into its own project, because argus only runs engines from a cache its own uid owns, and runs argus with `ARGUS_OFFLINE=1`.
- argus is configured from `/admin` (`Portal.Settings`) and passed through `NCC_INPUT.argus`. Its findings are advisory and never change a status.

## Deploy

CI deploys `main`: `.github/workflows/deploy.yml` runs the tests, waits for the audit, CodeQL, Credo and Sobelow workflows to pass on the same commit (`ops/wait-for-checks.sh`), then runs `ops/deploy.sh` on the hosts through `ops/ssh-deploy.sh`. A failing check blocks the deploy. See `DEPLOY.md` and `ops/README.md`.

## Dependency Policy

The worker rejects any project whose `mix.lock` references git or path deps. This is enforced in `NccWorker.LockPolicy` and is load-bearing for reproducibility — don't relax it without updating docs/tests and understanding the consequences.

## Generated / Ignored Paths

`_build/`, `deps/`, `tmp/`, `public/`, `*.dets`, `compat_test_results/`, and the `~/.ncc-*` caches are generated. Never commit them. `.elixir_ls/` is also ignored.
