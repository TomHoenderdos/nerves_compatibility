# ncc_agent

The remote builder agent. It runs on a builder host next to Docker, holds an
mTLS identity issued by the portal's builder CA, claims build jobs from the
portal's `/builder/v1` API, runs the `ncc-worker` image for them and uploads
the results. It ships as the `ncc_agent` release (with its own ERTS) from the
umbrella root.

On first boot it fetches the portal CA, checks its sha256 against the prefix
in the enrolment token, and trades the token and a CSR for a client
certificate. The identity lives in the data dir (`ca.pem`, `client.pem`,
`client-key.pem` at 0600, `client.csr`) and is renewed when it is within 30
days of expiry.

## Configuration

Read from the environment (in production, populated from the file
`ncc-agent.service`'s `EnvironmentFile=` points at):

| Key | Default | Meaning |
| --- | --- | --- |
| `NCC_PORTAL_URL` | required | The portal's builder endpoint, `https://host:8443` |
| `NCC_ENROLMENT_TOKEN` | none | One-time token from `/admin` → Builders; needed only until enrolled |
| `NCC_SLOTS` | `1` | Concurrent builds, 1..16 |
| `NCC_MEMORY` | required | Per-container `docker run --memory`, a positive size such as `8g`; every build container gets it |
| `NCC_CPUS` | none | Per-container `docker run --cpus` |
| `NCC_BUILD_CONCURRENCY` | none | Passed to the worker as its build concurrency |
| `NCC_DATA_DIR` | `/srv/ncc` | Identity, scratch, Nerves/Hex caches, releases |
| `NCC_BUILD_USER` | required non-root | `docker run --user`, the `uid:gid` of the `ncc-build` user; `0:*` is refused |
| `NCC_DOCKER_BIN` | `docker` | Docker CLI to run |
| `NCC_EGRESS_SCRIPT` | `priv/egress.sh` | Installs the containers' egress ruleset |
| `NCC_HEX_CACHE_RW` | unset | `1` mounts the slot's Hex cache read-write and tells the worker so: the one-release rollback, as on the portal host (`apps/ncc_worker/README.md`, "Hex cache"). A docker daemon that enforces the builders' authorization policy refuses that read-write mount |
| `NCC_DNS_SERVERS` | none | Space-separated resolvers builds may use; unset, they come from `daemon.json`, `resolv.conf` or `resolvectl`, and the egress install fails (no slot claims) when none is usable |
| `NCC_DOCKER_DAEMON_JSON` | `/etc/docker/daemon.json` | The daemon configuration the host check reads `default-ulimits` from and `egress.sh` reads `dns` from |

A missing or invalid `NCC_PORTAL_URL`, `NCC_MEMORY`, `NCC_SLOTS` or
`NCC_BUILD_USER` stops the release at boot.

## Host requirements

Every container the agent starts runs under gVisor (`docker run
--runtime=runsc`, `Compatibility.Builder.Argv`), with no fallback. The
builder's docker daemon needs:

- **`runsc` registered as a runtime** (and best as the default runtime).
  gVisor's platform is part of that registration, never of the build argv:
  `kvm` where `/dev/kvm` exists, `systrap` otherwise (a VM without nested
  virtualisation, an arm64 VM on Apple Silicon).
- **`default-ulimits` `nofile` 65536**, soft and hard, in `daemon.json`.
  Without it a container inherits a limit of about 2^31, the BEAM sizes its
  port table from it (some 2 GB, which gVisor charges to the container's
  memory cgroup) and every build is OOM-killed with exit 137.
- **The iptables firewall backend.** The egress ruleset (`priv/egress.sh`)
  lives in docker's `DOCKER-USER` chain, which `"firewall-backend":
  "nftables"` and `"iptables": false` take away.

Before every claim each slot checks the first two (`NccAgent.HostCheck`:
`docker info` for `runsc`, `NCC_DOCKER_DAEMON_JSON` for the limit) and the
egress ruleset. A host that fails claims nothing, logs why, and shows
`host_unready` (or `missing`, for the ruleset) as its egress state on the
admin Builders tab until it is fixed.

The memory limit is mandatory because under gVisor's `kvm` platform the
container's `--pids-limit` is not enforced, so `--memory` is the only bound
on a fork bomb.

`builder-host-setup.sh`, at the root of the release, sets all of this up on
Ubuntu 24.04 (x86_64 or aarch64), as root:

```bash
bash /srv/ncc/releases/current/builder-host-setup.sh install   # idempotent
bash /srv/ncc/releases/current/builder-host-setup.sh check     # changes nothing
```

`install` installs `docker.io` and a pinned gVisor release (its tarball's
sha512 checked per architecture before anything is unpacked), merges
`runsc`, `default-runtime` and `default-ulimits` into `daemon.json` (keeping
the keys it does not own), restarts docker only when that changed, and runs
`check`: the same settings, then a busybox container under `runsc` that
must see `ulimit -n` 65536 and gVisor's kernel log. `NCC_RUNSC_PLATFORM`
(`kvm` or `systrap`) overrides the platform it picks; `NCC_DOCKER_DNS`
(space-separated addresses) writes `daemon.json`'s `dns`, for a VM whose
own resolver the egress ruleset cannot allow (see OrbStack below); it
refuses addresses the ruleset drops or will not use as a resolver.
An existing docker (`docker-ce`, or any `dockerd` on `PATH`) is kept and
configured rather than replaced with `docker.io`. A change that needs a
docker restart is refused, with nothing written, while `ncc-agent` is
active or a container runs, since the restart would kill its builds:
`systemctl stop ncc-agent` first, or pass `install --force`.
Upgrading gVisor is a change to the version and both checksums at the top
of the script.

## Setting up a builder host

The web host first: `ops/remote-builders-golive.sh`, run as root there,
checks the builder CA, the listener, `images.json` and the routing settings
and prints the remaining steps (`--init-ca` creates the CA when it is
missing; nothing else changes).

Then, per builder, an enrolment token from `/admin/builders` and a VM.

**Ubuntu 24.04 x86_64 or aarch64 only.** The release carries its own ERTS,
linked against the glibc of the runner that built it (2.39); on an older
glibc it does not start. Which worker image a builder pulls is named by the
portal's `images.json`.

The steps, as root, with `PORTAL_HOST` (the portal's `PHX_HOST`: its server
certificate names it), `TOKEN` and `COMMIT` (a 40-hex sha with a published
`agent-<sha>` release; the agent updates itself to the portal's version on
its first claim) filled in:

```bash
set -euo pipefail
commit=COMMIT
apt-get update -q && apt-get install -y -q curl python3 ca-certificates
id ncc-build >/dev/null 2>&1 ||
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin ncc-build
install -m 0600 /dev/null /etc/ncc-agent.env
cat >/etc/ncc-agent.env <<EOF
NCC_PORTAL_URL=https://PORTAL_HOST:8443
NCC_ENROLMENT_TOKEN=TOKEN
NCC_SLOTS=1
NCC_CPUS=4
NCC_MEMORY=8g
NCC_DATA_DIR=/srv/ncc
NCC_BUILD_USER=$(id -u ncc-build):$(id -g ncc-build)
EOF
mkdir -p /srv/ncc/releases
base="https://github.com/TomHoenderdos/nerves_compatibility/releases/download/agent-$commit"
curl -fsSL -o /srv/ncc/images.json "$base/images.json"
read -r version url sha < <(python3 -c 'import json,sys; a=json.load(open(sys.argv[1]))["agent"]; r=a["releases"][sys.argv[2]]; print(a["version"], r["url"], r["sha256"])' /srv/ncc/images.json "$(uname -m)")
curl -fsSL -o "/srv/ncc/releases/$version.tar.gz" "$url"
echo "$sha  /srv/ncc/releases/$version.tar.gz" | sha256sum -c -
mkdir -p "/srv/ncc/releases/$version"
# --no-same-owner: as root, tar would keep the CI runner's uid on files root runs.
tar --no-same-owner -C "/srv/ncc/releases/$version" -xzf "/srv/ncc/releases/$version.tar.gz"
rm "/srv/ncc/releases/$version.tar.gz"
ln -sfn "$version/ncc_agent" /srv/ncc/releases/current
bash /srv/ncc/releases/current/builder-host-setup.sh install
cp /srv/ncc/releases/current/ncc-agent.service /etc/systemd/system/ncc-agent.service
systemctl daemon-reload
systemctl enable --now ncc-agent
```

The builder appears on `/admin/builders` once it enrols, with
`publishing` off. Check that its egress state is `ok`, inspect its first
runs, then turn publishing on there. `journalctl -u ncc-agent` says why a
builder that shows `missing` or `host_unready` claims nothing.

### cloud-init

The same steps on a cloud VM: save the block above as a file with the
placeholders filled in and pass it as user data. cloud-init runs a user-data
file that starts with `#!` as a root shell script on first boot. Add
`#!/bin/bash` as its first line.

### OrbStack on an Apple Silicon Mac

An OrbStack machine is an arm64 Ubuntu with systemd, so the same steps
work there, under the `systrap` platform (there is no `/dev/kvm`):

```bash
orb create ubuntu:noble ncc-builder        # arm64 on Apple Silicon
orb -m ncc-builder sudo -i                 # a root shell in the machine
```

Two differences, both for the shell inside the machine:

- OrbStack's resolver (`0.250.250.200` in `/etc/resolv.conf`) is not an
  address the egress ruleset can allow, so without more the egress install
  fails and no slot claims. Give docker public resolvers before the agent
  starts, by running the setup line of the steps as
  `NCC_DOCKER_DNS="1.1.1.1 9.9.9.9" bash /srv/ncc/releases/current/builder-host-setup.sh install`.
- `NCC_MEMORY` times `NCC_SLOTS` must fit in the memory OrbStack gives its
  Linux machines (OrbStack's settings). A Mac that sleeps stops its builds:
  their leases miss their heartbeats and go back to the queue after 10
  minutes.

The agent runs as root under the machine's systemd like on any other host;
`orb -m ncc-builder sudo journalctl -u ncc-agent -f` follows it.

## Running in dev against a local portal

From the umbrella root, with the portal's builder endpoint up and a token
created in `/admin`:

```bash
NCC_PORTAL_URL=https://localhost:8443 \
NCC_ENROLMENT_TOKEN=<token> \
NCC_DATA_DIR=$PWD/tmp/agent \
iex -S mix run --no-start -e 'Application.ensure_all_started(:ncc_agent)'
```

then `NccAgent.Identity.ensure()` enrols. Tests (`mix test apps/ncc_agent/test/`,
from the root) run against a fake portal and do not read the environment.

