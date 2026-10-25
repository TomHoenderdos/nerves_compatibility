# Remote builders over mTLS — design (v2)

Date: 2026-10-25. Status: v1 approved in conversation, then reviewed; v2
applies the review's six amendments. Awaiting re-read. Working note,
untracked.

## Goal

Let someone else run build machines for the compatibility tracker on their
own cloud account (AWS, two years of credits) without joining the tailnet and
without ever holding the database credentials. A remote builder is a VM with
Docker and a small agent; it authenticates to the portal with a client
certificate, claims build jobs, runs the same worker container the build host
runs, and sends `result.json`, logs and the archived files to the portal,
which ingests them exactly as it ingests a local build.

**A remote builder enforces the same isolation as a local build host.** The
sandbox-isolation design (`2026-10-21-build-sandbox-isolation-design.md`)
closes two holes locally: a package poisoning the shared Nerves cache, and a
build reaching private networks. Both reopen on a remote VM unless the agent
carries the same host-side mechanisms, and egress is worse on EC2, where a
build can read the instance role's credentials from the metadata service.

Decisions from the conversation and the review:

1. No database access for remote builders; everything travels over HTTPS.
2. Enrolment covers long-lived and on-demand VMs: a one-time token exchanged
   for a certificate on first boot; leases with heartbeats so a builder that
   vanishes mid-job costs one retry, not a lost run.
3. The operator is trusted, the machines are not assumed clean. A new
   builder enrols with `publishing: false`: its runs count for the tracker
   (pass/fail, logs) but its files are not published until the admin flips
   `publishing` after inspecting first runs. Revoking a builder revokes its
   runs and re-enqueues those package versions locally.
4. Transport is a second listener in the portal release with mutual TLS and
   the portal's own CA; Apache (which terminates the public site's TLS on the
   shared web host) is not involved.
5. The worker image is published to GHCR by CI so a job's `image_digest`
   means the same thing on every builder.
6. Certificates have a lifecycle: renewal before expiry, CA rotation without
   rebuilding the agent image.

## Facts the design rests on (checked 2026-10-25)

- A build host today needs `DATABASE_URL` over the private network, an SSH
  path the web host uses to pull artifacts (`rrsync`), and an SSH path CI
  deploys through. Builds run as `Portal.Workers.Build` on the `:builds`
  queue; `Portal.Builder.build/2` runs `docker run` with `--user uid:gid`,
  `--cap-drop=ALL`, `--security-opt=no-new-privileges`, bind mounts `/work`,
  `/out`, `/files`, the Nerves cache, `/hex-cache`, the read-only
  `/build-cache`, `NCC_INPUT=/work/input.json`, a two-hour wall clock,
  `--cpus`/`--memory` from config. `Portal.Builder.worker_input/1` is pure.
- Of the isolation design, the read-only build cache with promotion has
  landed (`8b0b97e`); the Nerves-cache symlink farm with the trusted warm job
  (`mode: "warm_nerves"`, `nerves_cache.misses` in `result.json`, allowlist =
  packages owned by the `nerves` Hex account) and the egress filter with its
  fail-closed preflight have not. Locally the egress rules run with `nft`
  inside the rootless daemon's network namespace; a rootful Docker VM has the
  `DOCKER-USER` chain for the same purpose.
- `Portal.Workers.Ingest` runs on the build host's own queue, reads the
  run's scratch dir (`load_run/1` → `files_dir`, `output_dir`, `result.json`)
  and calls `Portal.Catalog.Ingestion.ingest/2`, then updates the
  `ScanRequest` and broadcasts progress.
- Staleness never compares a run's digest with the current image:
  `Backfill.eligible?/2` and `UpdateCheck` compare `Run.image_digest` only
  with `RegistryAssessment.image_digest()` (the sentinel for registry-only
  assessments). `Build.run_exists?/3` dedupes on `(package, version,
  image_digest)`. A remote run carrying a registry digest and a local run
  carrying a local image Id are two rows; no rebuild loop follows.
- Web host: Apache on 443 for several sites, Phoenix (Bandit) on 4001.
  Bandit exposes the peer certificate through `Plug.Conn.get_peer_data/1`
  (`ssl_cert`). `x509` 0.9.2 (CSR, certificate signing) is in the lock; the
  portal has no rate limiter. The precompiled signing key is a file named by
  `PRECOMPILED_SIGNING_KEY`.
- The worker image (`ncc-worker:local`, 3.1 GB) and the toolchain images are
  built on each host from `ops/builder-deploy.sh`; nothing is pushed to a
  registry today.
- `Portal.ScanRequests` enqueues `Build` with a priority per source;
  `Portal.Workers.Backfill` and `Portal.BulkRebuild` enqueue the same worker.

## Design

### 1. Identity: a portal CA and a `builders` table

- `Portal.Builders.CA`: an ECDSA P-256 root key at `NCC_BUILDER_CA_KEY`
  (file, owner `ncc`, mode 600), created by `mix portal.builder_ca.init`.
  The CA signs the mTLS listener's server certificate (`CN=<PHX_HOST>`,
  `subjectAltName: DNS:<PHX_HOST>`, since OTP's hostname check needs the
  SAN; renewed by `mix portal.builder_ca.server_cert` or at boot when
  missing or expiring within 30 days) and client certificates (one year).
  The CA certificate is served unauthenticated at `GET /builder/v1/ca.pem`;
  it is **not** embedded in the agent image.
- `Portal.Builders.Builder` (Ash, table `builders`): `name`, `fingerprint`
  (sha256 of the current client certificate DER, unique), `cert_pem`,
  `cert_expires_at`, `status` (`:enrolled | :revoked`), `publishing`
  (boolean, **default false**), `slots` (concurrent jobs, default 1),
  `enrolled_at`, `last_seen_at` (refreshed by any authenticated request, at
  most once a minute), `last_version` (agent version), `revoked_at`, `note`.
  Previous fingerprints are kept in `builder_certificates` (`builder_id`,
  `fingerprint`, `issued_at`, `expires_at`, `superseded_at`) so a renewed
  builder is recognised by either certificate during the overlap.
- `Portal.Builders.EnrolmentToken` (table `builder_enrolment_tokens`):
  `token_hash`, `name`, `created_by`, `expires_at` (24 h), `used_at`,
  `builder_id`. The token the admin sees once is
  `<token id>.<32-byte secret, base64url>.<first 16 hex chars of the CA
  certificate's sha256>`; the last part lets the agent verify the CA it
  downloads before trusting it, so rotating the CA is a new token format
  and a re-enrolment, not a new agent image.
- `Run` gains a nullable `builder_id`. Revoking a builder (`:revoke` action,
  admin button): `status: :revoked`, every `Run` with this `builder_id`
  revoked (the existing `revoke_run` path, so the next batch drops their
  files), and those package versions re-enqueued on `:builds` through
  `Portal.BulkRebuild` (`names:` = the affected packages, `what: :full`,
  `created_by: "revoke builder <name>"`) so the catalogue heals from your
  own host. Revocation takes effect on the next request: the listener
  accepts any certificate the CA signed; a plug then looks the fingerprint
  up and refuses `revoked`/unknown.

### 2. Transport: `PortalWeb.BuilderEndpoint`

- A second Phoenix endpoint in the same release, `https` only, port
  `NCC_BUILDER_PORT` (default 8443), bound to all interfaces, Bandit with
  `verify: :verify_peer`, `cacertfile` = the portal CA, `certfile`/`keyfile`
  = the CA-signed server certificate, `fail_if_no_peer_cert: false` (so the
  enrolment route can be reached without a certificate; every other route
  requires one through the plug). Only the builder router is mounted; no
  sessions, no CSRF, JSON and raw bodies only. Body limits: 8 MiB for JSON,
  `max_batch_bytes` (default 512 MiB) for a tar upload.
- `PortalWeb.Plugs.BuilderCert`: reads the peer certificate
  (`Plug.Conn.get_peer_data/1`), computes the fingerprint, loads the builder
  by current or non-superseded previous fingerprint, assigns it, refuses
  `revoked`/unknown with 403, refreshes `last_seen_at`. `/builder/v1/enroll`
  and `/builder/v1/ca.pem` bypass it.
- Firewall: 8443 open to the world (the certificate is the gate). Rate
  limits with a small ETS counter: enrol 10/min per IP, claim 60/min per
  builder.

### 3. Enrolment, renewal, first boot

```
GET  /builder/v1/ca.pem                                   → the CA certificate
POST /builder/v1/enroll   {token, csr_pem, agent_version, slots}
  → 201 {certificate_pem, builder_id, name, expires_at}
  → 401 unknown/used/expired token
POST /builder/v1/renew    {csr_pem}            (client cert required)
  → 200 {certificate_pem, expires_at}   within 30 days of expiry
  → 425 too early; 403 revoked
```

The agent's first boot: fetch `ca.pem`, verify its sha256 starts with the
token's CA prefix, store it as the only trusted root, generate a P-256 key
and CSR, enrol, store `client.pem`/`client-key.pem` in its data volume. The
portal ignores the CSR's subject and sets `CN=<builder name>`,
`serialNumber=<builder id>`, one-year validity; the token is marked used in
the same transaction that creates the builder. Renewal: when the agent's
certificate expires within 30 days it posts a new CSR with the current
certificate; the portal issues a new one-year certificate for the same
builder, records the old fingerprint as superseded (accepted for 24 more
hours), and the agent rotates its files and retries the current request.

### 4. Job flow

**Routing.** `Portal.Builders.Routing.queue_for(args) :: :builds | :remote`
is consulted by every enqueuer of `Portal.Workers.Build` (`ScanRequests`,
`Backfill`, `BulkRebuild`, `UpdateCheck` through `Backfill`). Policy, in
config and on the admin page:

- `remote_enabled`: default false; auto-true while any enrolled builder's
  `last_seen_at` is within 5 min (the claim long-poll refreshes it, so an
  idle builder stays "seen"), auto-false when none was seen for 15 min; the
  admin can force either.
- jobs with `mode: "toolchain"`, `mode: "warm_nerves"` or `meta.pin_local`
  stay on `:builds`;
- otherwise `:remote` when the local `:builds` backlog (available +
  scheduled) is above `local_backlog_threshold` (default 10), else
  `:builds`.

A job already on `:builds` is never moved. A `:failed` lease can be
re-queued locally from the admin page.

**The `:remote` queue.** Runs on the web host with limit 1;
`Portal.Workers.RemoteBuild.perform/1` inserts a `Portal.Builders.Lease`
row (table `builder_leases`: `package`, `version`, `image_digest` (registry
digest), `args`, `scan_request_id`, `priority`, `state`
(`:queued | :leased | :uploading | :done | :failed`), `builder_id`,
`leased_at`, `heartbeat_at`, `phase`, `log_tail`, `attempt`, `max_attempts`
3, `run_id`, `bytes_uploaded`, `error`), broadcasts `:queued` progress to
the scan request, publishes `{:lease_queued, id}` on `Portal.PubSub` topic
`builders:leases`, and completes. The lease table is the remote queue and
is what the admin page shows.

**Claim.**

```
POST /builder/v1/jobs/claim   {agent_version, free_slots}
  → 200 {lease_id, run_id, image: {name, digest}, input: <NCC_INPUT>,
          timeout_sec, upload: {max_file_bytes, max_total_bytes, max_batch_bytes, max_files},
          min_agent_version, egress_required: true}
  → 204 nothing to do (after a long poll of up to 25 s)
```

The long poll subscribes to `builders:leases` and wakes on a broadcast, not
on a database poll. Claim is atomic: `UPDATE builder_leases SET
state='leased', builder_id=$1, leased_at=now(), heartbeat_at=now(),
attempt=attempt+1, run_id=$2 WHERE id = (SELECT id FROM builder_leases
WHERE state='queued' ORDER BY priority, inserted_at FOR UPDATE SKIP LOCKED
LIMIT 1) RETURNING *`. A builder holds at most `slots` leases. `run_id` is
`rb-<package>-<version>-<ms>`. `input` is `Portal.Builder.worker_input/1`
for the lease's args. The agent refuses to claim when its egress ruleset is
not installed (section 5).

**Heartbeat.** `POST /builder/v1/jobs/:lease_id/heartbeat {phase,
log_tail}` every 60 s **during the build and during upload**; stores
`heartbeat_at`, `phase` (`pulling | building | uploading`) and the last
4 KiB of log; broadcasts `:building` progress.

**Files.** The worker's `/files` dir is content-addressed already.

```
POST /builder/v1/jobs/:lease_id/files/missing   {shas: [...]}   → {missing: [...]}
PUT  /builder/v1/jobs/:lease_id/files           (tar stream, ≤ max_batch_bytes)
```

The agent lists its shas (≤ `max_files`, default 20 000), asks which are
missing (the portal checks `ArtifactStore.present?/1` and the lease's own
upload dir), and sends the missing ones as one or more tar streams (plain
tar, entries named by sha; `Content-Length` ≤ `max_batch_bytes`). The portal
extracts into `<upload_root>/<lease_id>/files/`, hashing each entry as it is
written and discarding any whose name does not match its content (422 for
the batch, listing the bad shas), rejects entries with path separators, and
refuses the batch when `bytes_uploaded` would exceed `max_total_bytes`
(default 2 GiB) or when free space on `upload_root` is below the portal's
`check_free_space` floor (507). 409 when the lease is not held by this
builder. Heartbeats keep flowing between batches.

**Complete.**

```
POST /builder/v1/jobs/:lease_id/complete
  multipart: result.json (≤ 8 MiB), logs.tar.gz (≤ 64 MiB), exit_code
  → 202 accepted; → 409 lease not held; → 422 result.json unparsable
```

The portal writes the parts under `<upload_root>/<lease_id>/out/`, marks
the lease `:done` (or counts a failed attempt for exit 10/20/21 and
re-queues, `:failed` after `max_attempts`; exit 11 rejects the scan request
as `Build` does), and enqueues `Portal.Workers.Ingest` on the **web host's**
`:ingest` queue with `source: "remote"`, `lease_id`, `run_id`,
`image_digest`, `scan_request_id`, `builder_id`. `Ingest` gains a remote
loader, `Portal.Builders.Upload.load_run(lease_id)`, returning the shape
`Portal.Builder.load_run/1` returns, so `Ingestion.ingest/2`, the
`ScanRequest` update and progress run unchanged; `Ingestion` records
`builder_id` on the `Run`. Publication (`precompiled_manifest*`,
`packages_with_precompiled_files/0`) joins `Run` → `Builder` and excludes
runs whose builder has `publishing: false` or is revoked; a run with no
builder is local and publishes as today. Cleanup deletes the upload dir once
the rows are committed.

**Reaper.** `Portal.Workers.LeaseReaper` (cron, every 5 min, `:maintenance`):
a `:leased` lease with `heartbeat_at` older than 10 min, or `leased_at`
older than the job timeout (2 h) plus 30 min, goes back to `:queued`
(attempt kept); an `:uploading` lease gets 60 min since its last heartbeat
before the same happens; after `max_attempts` the lease is `:failed`, the
`ScanRequest` marked errored, and the admin page lists it.

### 5. The agent: `apps/ncc_agent`

- Elixir, OTP ≥ 27, no database. HTTP through Req/Finch (streaming tar
  uploads) with mTLS: the downloaded CA as the only trusted root, the client
  certificate and key. Shipped as a **release run directly on the VM**
  (`ncc-agent` tarball for linux x86_64 and aarch64, built by CI with the
  Hex Elixir/OTP builds, as `mix release` with the ERTS included), not as a
  container: the agent drives the host's rootful Docker daemon and installs
  firewall rules, both of which are host-level jobs. Data under
  `NCC_DATA_DIR` (default `/srv/ncc`): certificates, scratch, caches.
- **Shared flag construction.** The docker argv (flags, mounts, env,
  limits) moves from `Portal.Builder` into
  `Compatibility.Builder.Argv.build/1` in `apps/compatibility`, taking a
  plain map (paths, uid:gid, cpus, memory, image, cache mode, readonly
  flags). `Portal.Builder` and the agent both call it. The argv-parity test
  fixture is the **post-isolation** argv (read-only Nerves cache mount at
  `/nerves-cache`, `--read-only` root with the tmpfs mounts, the per-run
  cache dirs), so the agent can only ever run what the local host runs.
- **Nerves cache, as the isolation design specifies.** The agent keeps
  `<data>/nerves-cache` and mounts it read-only; before each build it
  builds the per-run symlink farm under the run's `/work/nerves/artifacts`
  and an empty `dl`, and passes `NERVES_ARTIFACTS_DIR`/`NERVES_DL_DIR`
  through the input as the worker expects. After a run, `result.json`'s
  `nerves_cache.misses` drives a local warm: the agent runs the worker in
  `mode: "warm_nerves"` with those pairs, with the cache mounted
  read-write, applying the same allowlist rule (only packages owned by the
  `nerves` Hex account; the allowlist travels in the claim response so it
  is the portal's, not the agent's). Misses outside the allowlist are
  never warmed. The build cache (`/build-cache`) is a local read-only
  volume the agent never promotes into (section 2 of the isolation design
  stays out of scope here); it starts empty and stays empty.
- **Egress filter, fail closed.** On start and before every claim the agent
  installs `ops/builder-egress-docker-user.nft` (same policy as the local
  rules: allow DNS to the resolver, allow TCP 80/443 to the Internet, drop
  RFC1918, `100.64.0.0/10`, `169.254.0.0/16` (IMDS), `127.0.0.0/8`,
  `fc00::/7`, `fe80::/10`, `::1`, and the bridge subnet itself) into the
  `DOCKER-USER` chain of the rootful daemon (via `nft` with an `iptables`
  fallback), then verifies with `iptables -L DOCKER-USER -n` (or `nft list
  chain`) that the rules are present; if not, it refuses to claim and
  reports `egress: missing` in its next heartbeat-less status call, which
  the admin page shows. The claim response carries `egress_required: true`
  so a future portal can relax it per builder; the agent never does.
- Loop per free slot: claim (long poll); `docker pull <image@digest>` if
  missing; write `input.json`; build the farm; `docker run` with the shared
  argv; stream stdout/stderr to `runner.log`, heartbeat with the tail; on
  exit: list shas, ask which are missing, tar and upload in batches with
  heartbeats between them, complete; warm the cache from the misses; delete
  the scratch. On `min_agent_version` above its own, the agent downloads
  the release named in the claim response, verifies its sha256 (listed in
  the response, taken from the CI-published `images.json`), swaps and
  restarts.
- Config via `/etc/ncc-agent.env`: `NCC_PORTAL_URL` (`https://host:8443`),
  `NCC_ENROLMENT_TOKEN` (first boot only), `NCC_SLOTS`, `NCC_CPUS`,
  `NCC_MEMORY`, `NCC_DATA_DIR`. `docs/REMOTE_BUILDERS.md` carries the
  cloud-init: install Docker, write the env file root-only, download the
  agent release for the architecture, install its systemd unit
  (`Restart=always`), start it.

### 6. Images and releases on GHCR

- A new CI workflow `images.yml` on push to `main` (after tests): `docker
  build` and `docker push` `ghcr.io/tomhoenderdos/ncc-worker:<sha>` (+
  `:latest`) and the toolchain images; build the agent release tarballs for
  both architectures and attach them to a GitHub release tagged
  `agent-<sha>`; write `images.json` (tag → registry digest, agent version →
  tarball URL + sha256). The deploy copies it to
  `/etc/ncc-portal/images.json`, read by `Portal.Builders.Images`. GHCR
  packages are public; the images contain no secrets.
- A remote lease carries the registry digest; the local path keeps using
  local image Ids. `Run.image_digest` therefore differs between a local and
  a remote build of the same image: provenance, not identity, and nothing
  compares it with a current digest (see Facts), so no rebuild loop.
- Build-host deploys may later pull from GHCR instead of building locally;
  out of scope here.

### 7. Admin

Builders tab (`/admin/builders`): builders (name, status, slots, last seen,
agent version, publishing, certificate expiry, egress status, runs count),
"New enrolment token" (shown once), revoke (with the re-enqueue count it
will cause), toggle publishing, pin-local override; leases (queued / leased
/ uploading / failed with phase, bytes and log tail), `remote_enabled`
switch and the backlog threshold, throughput per builder over 24 h.

### 8. Security notes

- The CA key and the server key live only on the web host, mode 600, owner
  `ncc`. Losing the CA key means a new CA and re-enrolling every builder
  with new tokens (the token's CA prefix changes with it).
- A builder can: claim queued jobs, send files for its own leases, complete
  them, renew its own certificate. Nothing else.
- Uploaded files are content-addressed and verified on extraction;
  `result.json` goes through the same `Ingestion` validation as a local
  build (paths, modes, schema). A compromised builder can produce bad
  results for the packages it claims; with `publishing: false` those reach
  only the tracker's pass/fail view until the admin trusts the machine, and
  revocation removes its runs and rebuilds the versions locally.
- Isolation parity: the agent runs the post-isolation argv, keeps the
  Nerves cache read-only with per-run farms and allowlisted warming, and
  refuses to work without the egress ruleset, so a malicious package on a
  remote VM gets what it gets on your own host: nothing shared, nothing
  private.
- Resource limits: `max_file_bytes`, `max_total_bytes`, `max_batch_bytes`,
  `max_files`, per-builder concurrent leases = `slots`, rate limits on
  enrol and claim, body limits on the listener, free-space floor on
  `upload_root`.

## Testing

- Unit: CA (issue/verify, SAN present), fingerprint plug (unknown, revoked,
  current, superseded-within-24h, superseded-after), enrolment (token
  single use, expiry, CA prefix mismatch rejected by the agent), renewal
  (happy path, too early 425, revoked 403), claim atomicity (two builders,
  one lease; `slots` honoured), long-poll wake on broadcast, heartbeat and
  reaper state machine (`:leased` 10 min, `:uploading` 60 min, attempts),
  missing-shas answer, tar upload (bad sha discarded with 422, path
  separator refused, batch and total caps, free-space floor, idempotent),
  complete → `Ingest` enqueued with the remote loader → `Run` has
  `builder_id`, publication excludes non-publishing and revoked builders,
  routing policy (pinned, toolchain, warm, threshold, auto-flip on
  `last_seen_at`), revoke → runs revoked + `BulkRebuild` enqueued.
- Agent: argv built from a claim equals `Compatibility.Builder.Argv` for the
  post-isolation fixture; farm built per run; warm only for allowlisted
  misses; egress install + verify, refuse-to-claim when missing; upload
  order and skip of present shas; renewal rotation; min-version swap with
  sha check.
- Integration (tagged, Docker): a local agent against a dev portal with the
  mTLS listener on 8443: enrol → claim → build `jason` with `ncc-worker:local`
  → upload → ingest; assert the `Run`, its `builder_id`, artifacts present,
  the run **absent** from the manifest while `publishing: false`, present
  after the flip.
- Deploy rehearsal on a throwaway VM: enrol; from inside a real build,
  probe `http://169.254.169.254/latest/meta-data/` and a tailnet address
  and assert both are refused; one real job; revoke the builder and see its
  run revoked and the version re-enqueued locally.

## Rollout

1. CI publishes images and agent releases to GHCR/releases (no behaviour
   change).
2. `Compatibility.Builder.Argv` extracted from `Portal.Builder` (behaviour
   preserved; argv-parity test), together with the isolation plan's
   Nerves-cache and egress tasks, which the agent depends on.
3. Portal: CA, builders, listener, enrolment, renewal, leases,
   claim/upload/complete, remote loader in `Ingest`, publication gate,
   admin tab, `remote_enabled` false. Deploy; `NCC_BUILDER_CA_KEY` and port
   8443 configured by hand on the web host.
4. Agent release; one VM of his enrolled with `publishing: false`; a few
   pinned jobs routed remote from the admin page; the IMDS/tailnet probe;
   then `remote_enabled` on with the backlog threshold. `publishing` stays
   false until the admin has looked at the first runs and flips it per
   builder.

## Out of scope

- Reproduction (publish only when a second builder reproduces the beams).
- Build-cache promotion from remote builders (isolation design section 2).
- Moving your own build host onto the agent path (possible later: same
  agent, same mTLS).
- Windows/ARM builders.
