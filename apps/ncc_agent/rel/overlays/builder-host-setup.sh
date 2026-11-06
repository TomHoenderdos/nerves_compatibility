#!/usr/bin/env bash
# Prepares an Ubuntu 24.04 VM (x86_64 or aarch64) to be a remote builder's
# docker host, or checks one, as root:
#
#   builder-host-setup.sh install [--force]
#                                   install docker and gVisor, configure the
#                                   daemon, restart it if anything changed,
#                                   then run `check`. A change that needs a
#                                   docker restart is refused (and nothing
#                                   written) while ncc-agent is active or a
#                                   container runs: a restart kills running
#                                   builds and spends a lease attempt. Stop
#                                   ncc-agent first, or pass --force
#                                   (NCC_FORCE_RESTART=1).
#   builder-host-setup.sh check     change nothing; exit 0 only when the host
#                                   is ready, else print why and exit 1
#
# What a builder needs from its docker daemon (and NccAgent.HostCheck
# refuses to claim without):
#
#   - runsc registered as a runtime. Every build container runs
#     `docker run --runtime=runsc` (Compatibility.Builder.Argv); this script
#     also makes it the default runtime. gVisor's platform is set here, in
#     the runtime's arguments, never in the build argv: `kvm` where
#     /dev/kvm exists, `systrap` otherwise (a VM without nested
#     virtualisation, an arm64 VM on Apple Silicon). NCC_RUNSC_PLATFORM
#     overrides the choice.
#   - default-ulimits nofile 65536, soft and hard. Without it a container
#     inherits a limit of about 2^31, the BEAM allocates a ~2 GB port table
#     from it, gVisor charges that to the container's memory cgroup, and
#     every build is OOM-killed (exit 137).
#   - the iptables firewall backend. The agent's egress ruleset
#     (priv/egress.sh) lives in docker's DOCKER-USER chain, which the
#     nftables backend does not have, and `"iptables": false` removes.
#
# gVisor is pinned below: one release, its tarball's sha512 per
# architecture, from https://storage.googleapis.com/gvisor/releases/release/
# (the `<version>/<arch>/gvisor.tar.zstd` and `.sha512` files). To upgrade,
# change GVISOR_VERSION and both checksums together, after checking the
# published .sha512 files yourself. Nothing is piped into a shell, and a
# tarball whose checksum does not match is never unpacked.
#
# The self-test runs a small pinned busybox under runsc with no network and
# expects `ulimit -n` 65536 (soft and hard) and a gVisor kernel log.
#
# Idempotent: a second run downloads nothing, rewrites nothing and does not
# restart docker. Keys of daemon.json this script does not own (dns,
# log-driver, ...) are kept.
#
# Docker itself: docker.io from Ubuntu, unless a docker is already there
# (docker-ce installed, or dockerd on PATH), which is kept and configured.
#
# Environment: NCC_RUNSC_PLATFORM (kvm or systrap), NCC_DOCKER_DAEMON_JSON
# (default /etc/docker/daemon.json, as the agent and egress.sh read it),
# NCC_DOCKER_DNS (space-separated resolver addresses written as daemon.json's
# `dns`: the resolvers build containers use and the egress ruleset lets them
# reach). Set it where the VM's own resolver is one egress.sh cannot use,
# such as OrbStack's 0.250.250.200; unset, `dns` is left as it is.
# For tests only: DOCKER, SYSTEMCTL, APT_GET, CURL name the binaries,
# NCC_RUNSC_DIR the install dir, NCC_KVM_DEVICE the device probed, and
# NCC_SETUP_TEST=1 skips the root and OS checks.
set -euo pipefail

GVISOR_VERSION=20261005.0
GVISOR_SHA512_X86_64=27fed731b432d6a39d908956623fd273979fda66b3ccf4b9c12413ea417c516e18a9dc3cced403fb28efe495d64dce4251f51cf8c4d9f4a72f9833bd96b6bb35
GVISOR_SHA512_AARCH64=cb1c1ac7616f1f0e2287d39660aa9a65f1d81b866c7fa29457f78da62373baadda2d55aa96a200743dfe56193e43d2b6256af23a23d41d0b49a49b4971982435
GVISOR_BASE=https://storage.googleapis.com/gvisor/releases/release
# busybox 1.37.0, the multi-arch index digest.
SELFTEST_IMAGE=busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec
NOFILE=65536

DOCKER="${DOCKER:-docker}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
APT_GET="${APT_GET:-apt-get}"
CURL="${CURL:-curl}"
RUNSC_DIR="${NCC_RUNSC_DIR:-/usr/local/bin}"
DAEMON_JSON="${NCC_DOCKER_DAEMON_JSON:-/etc/docker/daemon.json}"
KVM_DEVICE="${NCC_KVM_DEVICE:-/dev/kvm}"

say() { printf 'builder-host-setup: %s\n' "$*"; }
fail() { printf 'builder-host-setup: FAIL: %s\n' "$*" >&2; exit 1; }

usage() {
  echo "usage: $0 install [--force] | check" >&2
  exit 2
}

preflight() {
  [[ -n ${NCC_SETUP_TEST:-} ]] && return 0
  [[ $(id -u) -eq 0 ]] || fail "run as root (sudo $0 $1)"
  [[ $(uname -s) == Linux ]] || fail "a builder host is Linux, not $(uname -s)"
  if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 24.04 ]]; then
      say "warning: tested on Ubuntu 24.04 only, this is ${PRETTY_NAME:-unknown}"
    fi
  fi
}

gvisor_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) echo x86_64 ;;
    aarch64 | arm64) echo aarch64 ;;
    *) fail "unsupported architecture $(uname -m); x86_64 or aarch64 only" ;;
  esac
}

platform() {
  local platform=${NCC_RUNSC_PLATFORM:-}
  if [[ -z $platform ]]; then
    if [[ -c $KVM_DEVICE ]]; then platform=kvm; else platform=systrap; fi
  fi
  case "$platform" in
    kvm | systrap) echo "$platform" ;;
    *) fail "NCC_RUNSC_PLATFORM must be kvm or systrap, got '$platform'" ;;
  esac
}

install_packages() {
  local missing=() pkg packages=(iptables curl python3 zstd ca-certificates)
  # docker.io conflicts with docker-ce and containerd.io: installing it
  # would replace a docker the operator put there.
  if dpkg -s docker-ce >/dev/null 2>&1 || command -v dockerd >/dev/null 2>&1; then
    say "docker already installed; not installing docker.io"
  else
    packages=(docker.io "${packages[@]}")
  fi
  for pkg in "${packages[@]}"; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' ||
      missing+=("$pkg")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    say "packages present"
    return 0
  fi
  say "installing ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive "$APT_GET" update -q
  DEBIAN_FRONTEND=noninteractive "$APT_GET" install -y -q "${missing[@]}"
}

runsc_current() {
  local version
  [[ -x $RUNSC_DIR/runsc && -x $RUNSC_DIR/containerd-shim-runsc-v1 &&
    -x $RUNSC_DIR/gvisor-bin/gvisor_sentry ]] || return 1
  # Captured, not piped into `grep -q`: an early grep exit would fail the
  # pipe under pipefail.
  version=$("$RUNSC_DIR/runsc" --version 2>/dev/null) || return 1
  grep -qx "runsc version release-$GVISOR_VERSION" <<<"$version"
}

install_runsc() {
  if runsc_current; then
    say "runsc release-$GVISOR_VERSION present"
    return 0
  fi

  local arch sha url tmp
  arch=$(gvisor_arch)
  case "$arch" in
    x86_64) sha=$GVISOR_SHA512_X86_64 ;;
    aarch64) sha=$GVISOR_SHA512_AARCH64 ;;
  esac
  url="$GVISOR_BASE/$GVISOR_VERSION/$arch/gvisor.tar.zstd"
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064 # expand now: the trap outlives this function's locals
  trap "rm -rf '$tmp'" EXIT

  say "downloading gVisor release-$GVISOR_VERSION ($arch)"
  "$CURL" -fsSL --retry 3 -o "$tmp/gvisor.tar.zstd" "$url"
  if ! printf '%s  %s\n' "$sha" "$tmp/gvisor.tar.zstd" | sha512sum -c --status -; then
    fail "gvisor.tar.zstd from $url does not match the pinned sha512; not installing it"
  fi
  # runsc runs its sentry and helpers from gvisor-bin/ next to itself and
  # refuses to start a sandbox without them.
  mkdir "$tmp/x"
  tar -C "$tmp/x" --zstd --no-same-owner -xf "$tmp/gvisor.tar.zstd"
  [[ -f $tmp/x/runsc && -f $tmp/x/containerd-shim-runsc-v1 && -d $tmp/x/gvisor-bin ]] ||
    fail "the gVisor tarball does not hold runsc, containerd-shim-runsc-v1 and gvisor-bin/"
  install -d -m 0755 "$RUNSC_DIR" "$RUNSC_DIR/gvisor-bin"
  local file
  for file in "$tmp"/x/gvisor-bin/*; do
    install -m 0755 "$file" "$RUNSC_DIR/gvisor-bin/${file##*/}"
  done
  install -m 0755 "$tmp/x/containerd-shim-runsc-v1" "$RUNSC_DIR/containerd-shim-runsc-v1"
  # runsc last: its version is what marks the install complete.
  install -m 0755 "$tmp/x/runsc" "$RUNSC_DIR/runsc"
  rm -rf "$tmp"
  trap - EXIT
  runsc_current || fail "installed runsc does not report release-$GVISOR_VERSION"
  say "installed runsc release-$GVISOR_VERSION in $RUNSC_DIR"
}

# Merges the builder's settings into daemon.json and prints `changed` or
# `unchanged`; with mode `plan` it only prints, writing nothing. Refuses a
# daemon configured away from the iptables backend.
configure_daemon() {
  python3 - "$DAEMON_JSON" "$RUNSC_DIR/runsc" "$1" "$NOFILE" "${NCC_DOCKER_DNS:-}" "$2" <<'PY'
import ipaddress, json, os, sys, tempfile

path, runsc, platform, nofile = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
dns = sys.argv[5].split()
mode = sys.argv[6]
# What egress.sh refuses as a resolver (is_unusable), the ranges its ruleset
# drops that hold no resolver included: a DNS accept to one would be a hole
# in that drop. RFC1918 and CGNAT stay allowed, as there: a VPC's resolver.
UNUSABLE = [ipaddress.ip_network(n) for n in [
    "0.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16", "192.0.0.0/24",
    "198.18.0.0/15", "224.0.0.0/3",
    "::/127", "::ffff:0:0/96", "fe80::/10", "ff00::/8",
]]
for address in dns:
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        sys.exit(f"NCC_DOCKER_DNS: {address!r} is not an IP address")
    if any(ip.version == n.version and ip in n for n in UNUSABLE):
        sys.exit(f"NCC_DOCKER_DNS: {address} is in a range the egress ruleset drops or "
                 "will not use as a resolver; use a public resolver such as 1.1.1.1")
try:
    with open(path) as f:
        text = f.read()
    doc = json.loads(text) if text.strip() else {}
except FileNotFoundError:
    doc = {}
if not isinstance(doc, dict):
    sys.exit(f"{path} is not a JSON object")

if doc.get("firewall-backend", "iptables") != "iptables":
    sys.exit(f"{path} sets firewall-backend {doc['firewall-backend']!r}: the egress "
             "ruleset needs docker's iptables backend (DOCKER-USER); remove it")
if doc.get("iptables", True) is not True:
    sys.exit(f"{path} sets \"iptables\": false: the egress ruleset needs docker's "
             "DOCKER-USER chain; remove it")

want = json.loads(json.dumps(doc))
runtimes = want.setdefault("runtimes", {})
runtimes["runsc"] = {"path": runsc, "runtimeArgs": [f"--platform={platform}"]}
want["default-runtime"] = "runsc"
ulimits = want.setdefault("default-ulimits", {})
ulimits["nofile"] = {"Name": "nofile", "Soft": nofile, "Hard": nofile}
if dns:
    want["dns"] = dns

if want == doc:
    print("unchanged")
    sys.exit(0)
if mode == "plan":
    print("changed")
    sys.exit(0)

os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".daemon.json.")
with os.fdopen(fd, "w") as f:
    json.dump(want, f, indent=2, sort_keys=True)
    f.write("\n")
os.chmod(tmp, 0o644)
os.replace(tmp, path)
print("changed")
PY
}

# A docker restart kills every running container: refused while the agent
# is active or a container runs, unless forced.
guard_restart() {
  local force=$1 running
  [[ $force == true ]] && return 0
  "$SYSTEMCTL" is-active --quiet docker || return 0
  running=$("$DOCKER" ps -q 2>/dev/null || true)
  if "$SYSTEMCTL" is-active --quiet ncc-agent || [[ -n $running ]]; then
    fail "applying this needs a docker restart, which would kill running builds; stop ncc-agent first (systemctl stop ncc-agent, wait for its containers to end), or rerun with --force"
  fi
}

restart_docker() {
  local changed=$1
  "$SYSTEMCTL" enable docker >/dev/null 2>&1 || true
  if [[ $changed == changed ]] || ! "$SYSTEMCTL" is-active --quiet docker; then
    say "restarting docker"
    # A configuration docker rejects stops here, not at the first build.
    "$SYSTEMCTL" restart docker || fail "docker did not restart with $DAEMON_JSON; journalctl -u docker"
  else
    say "docker configuration unchanged"
  fi
}

check() {
  local problems=0 runtimes backend default_runtime out

  if ! runtimes=$("$DOCKER" info --format '{{json .Runtimes}}' 2>&1); then
    fail "docker info failed: $runtimes"
  fi
  if grep -q '"runsc"' <<<"$runtimes"; then
    say "ok: runsc runtime registered"
  else
    say "missing: runsc runtime (docker has: $runtimes)"
    problems=1
  fi

  default_runtime=$("$DOCKER" info --format '{{.DefaultRuntime}}' 2>/dev/null || true)
  [[ $default_runtime == runsc ]] || say "note: default runtime is '${default_runtime:-unknown}'; builds pass --runtime=runsc anyway"

  # Older daemons do not report the field: they only have iptables.
  backend=$("$DOCKER" info --format '{{if .FirewallBackend}}{{.FirewallBackend.Driver}}{{end}}' 2>/dev/null || true)
  if [[ -z $backend || $backend == iptables* ]]; then
    say "ok: firewall backend ${backend:-iptables}"
  else
    say "wrong: firewall backend '$backend'; the egress ruleset needs iptables (DOCKER-USER)"
    problems=1
  fi

  if python3 - "$DAEMON_JSON" "$NOFILE" <<'PY'
import json, sys
path, want = sys.argv[1], int(sys.argv[2])
try:
    with open(path) as f:
        n = (json.load(f).get("default-ulimits") or {}).get("nofile") or {}
except (OSError, ValueError, AttributeError) as e:
    sys.exit(f"cannot read default-ulimits from {path}: {e}")
if n.get("Soft") != want or n.get("Hard") != want:
    sys.exit(f"{path} default-ulimits nofile is {n.get('Soft')}/{n.get('Hard')}, want {want}/{want}")
PY
  then
    say "ok: default-ulimits nofile $NOFILE in $DAEMON_JSON"
  else
    problems=1
  fi

  if [[ $problems -ne 0 ]]; then
    fail "host not ready (run: $0 install)"
  fi

  say "self-test: $SELFTEST_IMAGE under runsc"
  if ! out=$("$DOCKER" pull -q "$SELFTEST_IMAGE" 2>&1); then
    fail "cannot pull the self-test image: $out"
  fi
  # shellcheck disable=SC2016 # expanded by the container's shell
  if ! out=$("$DOCKER" run --rm --runtime=runsc --network=none "$SELFTEST_IMAGE" \
    sh -c 'echo "nofile=$(ulimit -Sn)/$(ulimit -Hn)"; dmesg' 2>&1); then
    fail "the self-test container failed: $out"
  fi
  if ! grep -qx "nofile=$NOFILE/$NOFILE" <<<"$out"; then
    fail "the self-test container's nofile is not $NOFILE/$NOFILE: $(head -n 1 <<<"$out")"
  fi
  if ! grep -q 'gVisor' <<<"$out"; then
    fail "the self-test container's kernel log is not gVisor's; is runsc really its runtime?"
  fi
  say "ok: a runsc container sees nofile $NOFILE/$NOFILE and the gVisor kernel"
  say "host ready"
}

main() {
  local force=false
  [[ ${NCC_FORCE_RESTART:-} == 1 ]] && force=true
  if [[ $# -eq 2 && $1 == install && $2 == --force ]]; then
    force=true
    set -- install
  fi
  [[ $# -eq 1 ]] || usage
  case "$1" in
    install)
      preflight install
      local platform changed
      platform=$(platform)
      install_packages
      install_runsc
      changed=$(configure_daemon "$platform" plan) || fail "$DAEMON_JSON not updated"
      [[ $changed == changed ]] && guard_restart "$force"
      changed=$(configure_daemon "$platform" write) || fail "$DAEMON_JSON not updated"
      say "daemon.json $changed (runsc platform $platform)"
      restart_docker "$changed"
      check
      ;;
    check)
      preflight check
      check
      ;;
    *) usage ;;
  esac
}

main "$@"
