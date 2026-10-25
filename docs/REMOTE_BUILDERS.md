# Remote builders

## What it is

A remote builder is a VM you do not otherwise trust (a cloud instance, a
spare machine) that takes build jobs from the portal over mutual TLS, runs
the same worker container with the same docker argv as the local build
host, and uploads the results. The portal ingests them exactly as it
ingests a local build, records which builder produced each run, and keeps
that builder's precompiled files out of the public manifests until an admin
turns its `publishing` flag on.

The pieces:

| Where | What |
| --- | --- |
| web host | `PortalWeb.BuilderEndpoint` on `NCC_BUILDER_PORT` (8443): `/builder/v1/*`, mTLS against the portal's own CA (`Portal.Builders.CA`) |
| web host | the `:remote` Oban queue: `Portal.Workers.RemoteBuild` writes a `builder_leases` row instead of running Docker, and the `Ingest` a completed lease enqueues runs there too |
| web host | `Portal.Workers.LeaseReaper` (cron, every 5 min, `:maintenance`) takes leases back from silent builders |
| web host | `/etc/ncc-portal/images.json` (`ops/images-sync.sh`): the registry digest of the worker image and the agent releases for the deployed commit |
| builder | `ncc_agent`, a release run by systemd as root: drives the host's rootful Docker and the `DOCKER-USER` firewall chain, builds as the unprivileged `ncc-build` user |

The job flow: an enqueuer asks `Portal.Builders.Routing` for a queue; with
remote building on and the local `:builds` backlog above the threshold the
job becomes a `RemoteBuild` on `:remote`, which writes a `queued` lease. An
agent's claim (a 25 s long poll) takes it (`leased`), heartbeats every
minute while it builds, uploads the content-addressed files the portal does
not have yet (`uploading`), and completes with the worker's exit code and
`result.json`. Exit 0 marks the lease `done` and enqueues
`Portal.Workers.Ingest` (`source: "remote"`) on `:remote` in the same
transaction; 11 fails the lease and rejects the request; anything else
requeues the lease until its third attempt, then fails it.

## Portal setup (web host)

All of this is manual, once.

1. **Create the CA.** As the service user, with the key outside the
   checkout. `bin/portal eval` evaluates `config/runtime.exs`, which raises
   without `SECRET_KEY_BASE` and the rest of the env file, so source it
   first, exactly as `ops/deploy.sh` does:

   ```bash
   install -d -o ncc -g ncc -m 0700 /etc/ncc-portal/builder-ca
   sudo -u ncc bash -c "cd /var/lib/ncc && set -a && . /etc/ncc-portal/portal.env && set +a && \
     /opt/nerves_compatibility/portal/bin/portal eval 'Portal.Builders.CA.init(\"/etc/ncc-portal/builder-ca/ca-key.pem\")'"
   ```

   (`mix portal.builder_ca.init --key PATH` from a checkout.) It writes the
   key mode 600 and `ca.pem` beside it, and refuses to overwrite. The
   listener's server certificate (`CN`/SAN = `PHX_HOST`) is issued into the
   same dir at boot and reissued when it nears expiry
   (`mix portal.builder_ca.server_cert` forces it).

2. **Env file** (`/etc/ncc-portal/portal.env` on the web host):

   ```bash
   NCC_BUILDER_CA_KEY=/etc/ncc-portal/builder-ca/ca-key.pem
   NCC_BUILDER_PORT=8443                      # the default
   NCC_UPLOAD_ROOT=/var/lib/ncc/uploads       # default ~/.ncc-uploads
   NCC_IMAGES_JSON=/etc/ncc-portal/images.json  # the default
   OBAN_QUEUES=intake:5,maintenance:1,remote:2
   ```

   The listener starts only with `PHX_SERVER` set and a CA key that loads;
   otherwise the portal logs why and serves without it. `remote:2` is
   required on the web host: remote ingests run on `:remote` because the
   uploads sit on the web host's disk. Without it leases reach `done` and
   never become runs (the admin tab shows `done` leases with no run).
   `NCC_UPLOAD_ROOT` must be on a filesystem with room for in-flight
   uploads (up to 2 GiB per lease); uploads are refused with 507 below the
   portal's free-space floor (`NCC_MIN_FREE_GB`).

3. **Firewall**: open TCP 8443 to the world. The client certificate is the
   gate; enrolment (`/builder/v1/enroll`, `/builder/v1/ca.pem`) is the only
   route reachable without one, and it needs a one-time token.

4. **images.json.** `ops/deploy.sh` runs `ops/images-sync.sh` best-effort
   after each deploy, but the images workflow publishes the file minutes
   after the deploy, so a timer retries:

   `/etc/systemd/system/ncc-images-sync.service`

   ```ini
   [Unit]
   Description=Fetch images.json for the deployed commit
   After=network-online.target
   Wants=network-online.target

   [Service]
   Type=oneshot
   ExecStart=/bin/bash -c 'exec /opt/nerves_compatibility/src/ops/images-sync.sh "$(cd /opt/nerves_compatibility/src && git rev-parse HEAD)"'
   ```

   `/etc/systemd/system/ncc-images-sync.timer`

   ```ini
   [Unit]
   Description=Fetch images.json every 10 minutes

   [Timer]
   OnBootSec=2min
   OnUnitActiveSec=10min

   [Install]
   WantedBy=timers.target
   ```

   ```bash
   systemctl daemon-reload && systemctl enable --now ncc-images-sync.timer
   ```

   Until the file exists (or while it names no `ncc-worker` digest) routing
   keeps every job local; nothing breaks.

5. Restart the portal and check the log for `builder listener on 8443`.

## Enrolling a builder

1. Admin → **Builders** (`/admin/builders`) → **New enrolment token**,
   with the builder's name. The token (`<id>.<secret>.<CA prefix>`) is
   shown once and expires in 24 h. The prefix authenticates the CA the
   agent downloads, so a token minted before a CA rotation does not work
   after it.
2. Create the VM with the cloud-init below, the token and the deployed
   commit's sha filled in.
3. The builder appears on the tab once it enrols; `publishing` starts off.

### cloud-init

Debian/Ubuntu, x86_64 or aarch64. Replace `PORTAL_HOST` (the portal's
`PHX_HOST`: the server certificate names it), `TOKEN` and `COMMIT` (the
40-hex sha the web host is on; any published commit works, the agent
updates itself to the portal's version on its first claim).

```yaml
#cloud-config
package_update: true
packages:
  - docker.io
  - iptables
  - curl
  - python3

users:
  - default
  - name: ncc-build
    system: true
    shell: /usr/sbin/nologin
    homedir: /nonexistent
    no_create_home: true

write_files:
  - path: /etc/ncc-agent.env
    owner: root:root
    permissions: "0600"
    content: |
      NCC_PORTAL_URL=https://PORTAL_HOST:8443
      NCC_ENROLMENT_TOKEN=TOKEN
      NCC_SLOTS=1
      NCC_CPUS=4
      NCC_MEMORY=8g
      NCC_DATA_DIR=/srv/ncc
      # NCC_BUILD_USER is appended by runcmd (the ncc-build uid:gid)

runcmd:
  - systemctl enable --now docker
  - echo "NCC_BUILD_USER=$(id -u ncc-build):$(id -g ncc-build)" >> /etc/ncc-agent.env
  - mkdir -p /srv/ncc/releases
  - |
    set -eu
    commit=COMMIT
    base="https://github.com/TomHoenderdos/nerves_compatibility/releases/download/agent-$commit"
    curl -fsSL -o /srv/ncc/images.json "$base/images.json"
    arch=$(uname -m)
    read -r version url sha <<EOF
    $(python3 -c 'import json,sys; a=json.load(open(sys.argv[1]))["agent"]; r=a["releases"][sys.argv[2]]; print(a["version"], r["url"], r["sha256"])' /srv/ncc/images.json "$arch")
    EOF
    curl -fsSL -o "/srv/ncc/releases/$version.tar.gz" "$url"
    echo "$sha  /srv/ncc/releases/$version.tar.gz" | sha256sum -c -
    mkdir -p "/srv/ncc/releases/$version"
    tar -C "/srv/ncc/releases/$version" -xzf "/srv/ncc/releases/$version.tar.gz"
    rm "/srv/ncc/releases/$version.tar.gz"
    cd /srv/ncc/releases && ln -sfn "$version/ncc_agent" current
    cp /srv/ncc/releases/current/ncc-agent.service /etc/systemd/system/ncc-agent.service
    systemctl daemon-reload
    systemctl enable --now ncc-agent
```

The layout the agent's updater keeps: the tarball unpacks to `ncc_agent/`,
installed as `/srv/ncc/releases/<version>/ncc_agent`, and
`/srv/ncc/releases/current` is a relative symlink to `<version>/ncc_agent`
(the updater compares that exact target). The unit and
`ncc-agent.env.example` sit at the release root
(`/srv/ncc/releases/current/ncc-agent.service`); the unit runs
`/srv/ncc/releases/current/bin/ncc_agent start` as root with
`EnvironmentFile=/etc/ncc-agent.env`, `Restart=always` and
`TimeoutStopSec=150` (each slot has 90 s to kill its container and hand its
lease back). The env keys are documented in
`apps/ncc_agent/rel/overlays/ncc-agent.env.example`.

After enrolment the token in `/etc/ncc-agent.env` is spent and harmless;
the identity lives in `/srv/ncc/{ca.pem,client.pem,client-key.pem}`.

## What the agent does

- **Boot.** Loads `/etc/ncc-agent.env` (a bad config stops the VM rather
  than spin), clears `<data>/scratch`, installs the egress ruleset, starts
  one slot per `NCC_SLOTS`. On first boot it fetches `ca.pem`, checks it
  against the token's prefix, generates a P-256 key and enrols; it renews
  its one-year certificate within 30 days of expiry.
- **Loop, per slot.** Verify the egress ruleset (reinstall once if it is
  gone; still gone: claim nothing, report `egress: missing`, retry in
  60 s), claim, and if the claim names a newer `min_agent_version`,
  download that release, verify its sha256, swap `current`, hand the lease
  back and restart. Otherwise pull `image@digest` when missing, write
  `input.json`, build the Nerves symlink farm, `docker run` the shared argv
  with a heartbeat every minute, upload the files the portal lacks in tar
  batches, complete, warm the cache from the run's misses, delete the
  scratch dir.
- **Isolation.** The argv is `Compatibility.Builder.Argv.build/1`, the
  post-isolation argv (pinned by `apps/ncc_agent/test/fixtures/post_isolation_argv.txt`
  and the portal's argv parity test): read-only root with per-run
  `tmp`/`cache` binds, `--cap-drop=ALL`, `no-new-privileges`, the
  container as `NCC_BUILD_USER`, the Nerves cache read-only at
  `/nerves-cache`, never a build cache.
  - *Nerves cache farm*: each run gets `work/nerves/artifacts/` with one
    symlink per entry of `<data>/nerves-cache/artifacts` and an empty
    `dl/`, passed as `NERVES_ARTIFACTS_DIR`/`NERVES_DL_DIR` (container env
    and `input.paths`). After a passing run, `result.json`'s
    `nerves_cache.misses` that the portal's allowlist names (official
    Nerves packages, sent in the claim) are warmed by a second container
    with the cache read-write, at most four per run.
  - *Egress*: `priv/egress.sh` writes chain `NCC-EGRESS` first in
    `DOCKER-USER` (IPv6 too when `ip6tables` has the chain): established
    replies, DNS, then drop RFC1918, `100.64.0.0/10`, `169.254.0.0/16`
    (IMDS) and loopback (`fc00::/7`, `fe80::/10`, `::1` on v6), accept TCP
    443/80, drop the rest. The agent fails closed: no ruleset, no claim.
    On a daemon using the native nftables backend (`DOCKER-USER` absent)
    the builder never claims and the tab shows `egress: missing`.
    `NCC_EGRESS_SCRIPT` replaces the script for tests only; never set it in
    production.

## Operating

- **Publishing.** A new builder's runs count for pass/fail but its
  precompiled files are not published (`publishing: false`). Inspect its
  first runs (package pages, `/admin/builders` runs count) and flip
  publishing on from the tab; flipping it off again withdraws its files
  from the next manifest.
- **Revoke.** The tab's revoke button shows how many runs it will touch.
  It marks the builder revoked (its certificate is refused from the next
  request on, 403 `builder_revoked`), revokes every run it produced, puts
  its held leases back to `queued`, and enqueues a full rebuild of those
  packages pinned to the local `:builds` queue (`BulkRebuild`,
  `pin_local`). Re-adding the machine means a new token.
- **Requeue.** A `failed` lease (three failed attempts, a non-ingestible
  upload, the reaper) can be requeued from the tab with a fresh attempt
  budget. It goes back to remote builders; to build it locally, rebuild
  the package from the admin instead.
- **Reaper timings.** Every 5 minutes: a `leased` lease without a
  heartbeat for 10 minutes or held for more than 2 h 30 min (the 2 h build
  timeout plus slack), or an `uploading` lease without a heartbeat for 60
  minutes, is requeued, or failed once its attempts are spent (its request
  is then errored). A reaped lease that the agent later completes gets 409
  `lease_not_held`.
- **Routing policy** (tab, "Remote building"): `remote_mode` is `auto`
  (default; on while an enrolled builder was seen within 5 minutes, off
  once none was seen for 15, holding its last decision in between), `on`
  or `off`. With remote on, a job goes remote only while the local
  `:builds` backlog is above `remote_backlog_threshold`. Toolchain and
  `warm_nerves` jobs, pinned jobs and everything while `images.json` names
  no registry image always stay local; a job already on `:builds` is never
  moved. A lease waiting in `queued` with no builder left is never reaped:
  requeue the package locally if no builder will return.

## Troubleshooting

| Symptom | Cause, fix |
| --- | --- |
| Agent log: 403 `unknown_builder` | The certificate is valid for the CA but no builder holds it: the CA was re-initialised (new `NCC_BUILDER_CA_KEY`), or the builder row was removed. Stop the agent, delete `/srv/ncc/{ca.pem,client.pem,client-key.pem,client.csr}`, put a fresh token in `/etc/ncc-agent.env`, start it. A TLS handshake failure instead of a 403 means the same after a CA change. |
| 403 `builder_revoked` | Revoked on purpose; re-enrol with a new token if that was a mistake. |
| 409 `egress_missing`, tab shows `egress: missing` | The ruleset did not verify (`/srv/ncc/releases/current/lib/ncc_agent-*/priv/egress.sh verify` prints why). Usually Docker restarted and rewrote its chains (the agent reinstalls on the next claim) or the daemon has no `DOCKER-USER` chain (nftables backend: switch the daemon back to iptables). |
| 507 `insufficient_disk` on upload | The web host's `NCC_UPLOAD_ROOT` is below the free-space floor. Free space; the agent's complete fails and the lease is retried or reaped. |
| 425 `too_early` on renew | The agent asked to renew more than 30 days before expiry (clock skew on the builder). Fix NTP; the current certificate keeps working. |
| Leases `done` but no runs | `remote` is missing from the web host's `OBAN_QUEUES`. |
| Nothing goes remote | `images.json` missing or stale (`systemctl status ncc-images-sync`), `remote_mode` off, no builder seen in 15 min, or the local backlog under the threshold. |
| Builder never claims, no errors | The agent is waiting to restart into a new release (`updating`), or its `NCC_SLOTS` are all busy. |

## Depends on `feat/sandbox-isolation`

The agent already runs the post-isolation argv and writes the per-run
Nerves paths; three things only take full effect once the isolation branch
lands:

- The worker reading `NERVES_ARTIFACTS_DIR`/`NERVES_DL_DIR` and
  `paths.nerves_artifacts_dir`/`paths.nerves_dl_dir` from `NCC_INPUT`.
  Until then the keys are informational (`apps/ncc_worker/README.md`) and
  the container env alone steers Nerves.
- `nerves_cache.misses` in `result.json`. Until the worker reports it, the
  agent warms nothing and every remote run fetches its Nerves artifacts
  cold.
- `Portal.Builder` switching to `Compatibility.Builder.Argv`: today the
  local host still builds its own argv, and the parity test pins the two
  (`apps/portal/test/portal/builder_argv_parity_test.exs`).

## Manual deploy steps, summarised

Web host, once:

1. Create the CA as `ncc` with `/etc/ncc-portal/portal.env` sourced:

   ```bash
   sudo -u ncc bash -c "cd /var/lib/ncc && set -a && . /etc/ncc-portal/portal.env && set +a && \
     /opt/nerves_compatibility/portal/bin/portal eval 'Portal.Builders.CA.init(\"/etc/ncc-portal/builder-ca/ca-key.pem\")'"
   ```

2. `NCC_BUILDER_CA_KEY`, `NCC_UPLOAD_ROOT`, `remote:2` in `OBAN_QUEUES`
   (and `NCC_BUILDER_PORT`/`NCC_IMAGES_JSON` if not the defaults) in
   `/etc/ncc-portal/portal.env`.
3. Open TCP 8443.
4. Install and enable `ncc-images-sync.timer`.
5. Restart the portal.

Per builder: mint a token on `/admin/builders`, boot the VM with the
cloud-init, check it appears with `egress: ok`, inspect its first runs,
turn publishing on.

## Tests

- `make test-remote-e2e`: `apps/portal/test/portal/builders/agent_e2e_test.exs`
  (tag `:e2e`) starts the builder router with the real TLS options on an
  ephemeral port, spawns the agent as an OS process with the fake docker,
  and checks enrol → claim → upload → complete → ingest → publishing gate.
  Runs anywhere the test database does.
- `make test-remote-integration`: `remote_integration_test.exs` (tag
  `:integration`), the same through the real `ncc-worker:local` image.
  Needs Docker and network; the egress script is a stub there, since a
  workstation has no `DOCKER-USER` chain.
