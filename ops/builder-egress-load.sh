#!/usr/bin/env bash
# Loads the build egress filter (ops/builder-egress.nft, and best effort
# ops/builder-egress-bridge.nft) into the network namespace rootless dockerd's
# bridge lives in. Runs as the daemon's own user: from systemd as the docker
# user unit's ExecStartPost, and from ops/builder-deploy.sh at every builder
# deploy. See the operator runbook.
#
# rootlesskit runs with --detach-netns, so dockerd itself (docker.pid) sits in
# the host's network namespace and nsenter into it fails EPERM. The bridge is
# in the namespace of rootlesskit's child, dockerd-rootless/child_pid.
set -euo pipefail

# Appended, so a caller's PATH still wins: the systemd user manager's PATH may
# leave sbin out (nft), and NixOS keeps everything in /run/current-system/sw/bin.
PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin:/run/current-system/sw/bin

ruleset=${NCC_EGRESS_RULESET:-/etc/ncc-portal/builder-egress.nft}
bridge_ruleset=${NCC_EGRESS_BRIDGE_RULESET:-/etc/ncc-portal/builder-egress-bridge.nft}
wait_seconds=${NCC_EGRESS_WAIT_SECONDS:-60}
runtime=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
child_pid_file=$runtime/dockerd-rootless/child_pid
export DOCKER_HOST=${DOCKER_HOST:-unix://$runtime/docker.sock}
# Portal.Builder's @egress_marker; the preflight looks for the same comment.
marker=ncc_egress_v1

[[ $wait_seconds =~ ^[0-9]+$ ]] || { echo 'invalid NCC_EGRESS_WAIT_SECONDS' >&2; exit 1; }

# Every docker and nsenter call is bounded at 10 s: the docker user unit has
# TimeoutSec=0, so a hang in this ExecStartPost would leave the unit
# activating forever, and a deploy holding its lock.
bounded() { timeout 10 "$@"; }

# Under Type=notify ExecStartPost already runs after readiness; the wait makes
# this right whatever the unit type and whenever child_pid appears. A hung
# `docker info` counts as not ready yet, within the same overall wait.
deadline=$((SECONDS + wait_seconds))
until bounded docker info >/dev/null 2>&1 && [[ -s $child_pid_file ]]; do
  if (( SECONDS >= deadline )); then
    echo "rootless dockerd not ready after ${wait_seconds}s; egress filter not loaded" >&2
    exit 1
  fi
  sleep 1
done

pid=$(<"$child_pid_file")
[[ $pid =~ ^[0-9]+$ ]] || { echo "unexpected child_pid: $pid" >&2; exit 1; }

bridge=$(bounded docker network inspect bridge --format '{{index .Options "com.docker.network.bridge.name"}}')
# An interface name is at most 15 bytes. Anything else must not reach nft's
# parser, which is what the define below hands it to.
[[ $bridge =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || { echo "unexpected bridge name: $bridge" >&2; exit 1; }

in_netns() { bounded nsenter -U --preserve-credentials -n -t "$pid" "$@"; }
with_bridge() { sed "s/^define ncc_bridge = .*/define ncc_bridge = \"$bridge\"/" "$1"; }

with_bridge "$ruleset" | in_netns nft -f -

listing=$(in_netns nft list table inet ncc_egress)
if [[ $listing != *"comment \"$marker\""* ]]; then
  echo "table inet ncc_egress is loaded but its final drop ($marker) is missing" >&2
  exit 1
fi

if ! with_bridge "$bridge_ruleset" | in_netns nft -f -; then
  echo 'warning: bridge-family table not loaded (no nft_meta_bridge in this kernel?);' \
    'containers on the bridge can still reach each other' >&2
fi

echo "egress filter $marker loaded on $bridge in the namespace of pid $pid"
