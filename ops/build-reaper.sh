#!/usr/bin/env bash
# Root, on a timer: kills build containers that outlived the build ceiling.
#
# A gVisor sandbox can wedge so that `docker kill`, `docker stop` and
# `runsc kill` all block on it; only SIGKILL of its runsc-sandbox and
# runsc-gofer processes ends it. Both run inside the container's scope
# cgroup, so writing 1 to the scope's cgroup.kill ends the sentry, the
# gofer and the guest at once, and docker then reaps the container.
#
# Only `docker-<64 hex id>.scope` cgroups directly under an
# `ncc-builds.slice` are considered: docker-ncc puts every build container
# there and nothing else runs in it. (Another dockerd's containers are
# `docker-<id>.scope` too, elsewhere; they are never matched.) A scope is
# killed once it has been active for longer than NCC_REAPER_MAX_AGE_SECONDS
# (default 9000, 2 h 30 min). No build runs that long: Portal.Builder's wall
# clock is 2 h, and its own stop of a timed-out container takes minutes.
# Docker is not asked anything: a wedged container can block it too.
#
# Run by the builder host's configuration, as root, for example:
#
#   ncc-build-reaper.service:
#     [Service]
#     Type=oneshot
#     ExecStart=/usr/local/libexec/ncc-build-reaper
#
#   ncc-build-reaper.timer:
#     [Timer]
#     OnBootSec=5min
#     OnUnitActiveSec=5min
#     [Install]
#     WantedBy=timers.target
#
# Install a root-owned copy (0755). Each kill is logged to the journal.

set -uo pipefail

reaper_cgroup_root=/sys/fs/cgroup

# Microseconds since boot at which systemd unit $1 became active, or nothing.
reaper_active_since() {
  systemctl show -P ActiveEnterTimestampMonotonic "$1" 2>/dev/null
}

# Microseconds since boot, now.
reaper_now() {
  local uptime
  read -r uptime _ < /proc/uptime || return 1
  printf '%s\n' "$(( ${uptime%.*} * 1000000 ))"
}

reaper_kill_scope() {
  printf '1\n' > "$1/cgroup.kill"
}

reaper_main() {
  local max_age=${NCC_REAPER_MAX_AGE_SECONDS:-9000}
  if [[ ! $max_age =~ ^[0-9]+$ ]] || (( max_age < 3600 )); then
    echo "refusing: NCC_REAPER_MAX_AGE_SECONDS must be a whole number of seconds, at least 3600" >&2
    return 2
  fi
  local now status=0 scope unit id since age
  now=$(reaper_now) || { echo 'cannot read the uptime' >&2; return 1; }
  shopt -s nullglob
  for scope in "$reaper_cgroup_root"/ncc-builds.slice/docker-*.scope \
               "$reaper_cgroup_root"/*/ncc-builds.slice/docker-*.scope; do
    unit=${scope##*/}
    id=${unit#docker-}
    id=${id%.scope}
    [[ $id =~ ^[0-9a-f]{64}$ ]] || continue
    since=$(reaper_active_since "$unit")
    if [[ ! $since =~ ^[0-9]+$ ]] || (( since == 0 )); then
      echo "skipping $unit: systemd does not say when it started" >&2
      continue
    fi
    age=$(( (now - since) / 1000000 ))
    (( age > max_age )) || continue
    if reaper_kill_scope "$scope"; then
      echo "killed build container ${id:0:12} ($unit): active for ${age}s, past ${max_age}s"
    else
      echo "could not kill build container ${id:0:12} ($unit)" >&2
      status=1
    fi
  done
  return "$status"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  reaper_main
fi
