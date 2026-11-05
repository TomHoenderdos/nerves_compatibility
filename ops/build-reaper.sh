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
# `docker-<id>.scope` too, elsewhere; they are never matched.) A host whose
# systemd does not know ncc-builds.slice exits 3: the reaper would otherwise
# pass silently where it protects nothing. A known slice with no cgroup is
# idle (systemd creates it with its first scope, so after boot it is absent
# until the first build): 0 scopes, exit 0. Each run ends with one summary
# line. A scope
# is killed once it has been active for longer than NCC_REAPER_MAX_AGE_SECONDS
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
#
# It is also what stops a timed-out build container whose stop no portal
# process waits for: Portal.Builder.Stop runs in a task of the node that
# ran the build, and in a release `eval` (the deploy-time warm) in a
# process that dies with the eval.

set -uo pipefail

reaper_cgroup_root=/sys/fs/cgroup

# Unix seconds at which systemd unit $1 became active, or nothing. Wall
# clock against wall clock (reaper_now): systemd's monotonic stamps are
# CLOCK_MONOTONIC, which stops during suspend, and /proc/uptime is
# CLOCK_BOOTTIME, which does not. `--timestamp=unix` needs systemd 248.
reaper_active_since() {
  local stamp
  stamp=$(systemctl show -P ActiveEnterTimestamp --timestamp=unix "$1" 2>/dev/null) || return 0
  [[ $stamp =~ ^@([0-9]+)$ ]] && printf '%s\n' "${BASH_REMATCH[1]}"
  return 0
}

# systemd's LoadState of the build slice: `loaded` where it is declared.
reaper_slice_state() {
  systemctl show -P LoadState ncc-builds.slice 2>/dev/null
}

# Unix seconds, now.
reaper_now() {
  date +%s
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
  local now status=0 scope unit id since age scanned=0 killed=0
  now=$(reaper_now)
  if [[ ! $now =~ ^[0-9]+$ ]]; then
    echo 'cannot read the clock' >&2
    return 1
  fi
  shopt -s nullglob
  # A host whose build slice is elsewhere, or not set up, would otherwise
  # pass every run while reaping nothing; an idle declared slice is fine.
  # The first path has no glob, so nullglob keeps it whether it exists or not.
  local slices=() slice
  for slice in "$reaper_cgroup_root"/ncc-builds.slice "$reaper_cgroup_root"/*/ncc-builds.slice; do
    [[ -d $slice ]] && slices+=("$slice")
  done
  if [[ ${#slices[@]} -eq 0 ]]; then
    local state
    state=$(reaper_slice_state)
    if [[ $state != loaded ]]; then
      echo "ncc-builds.slice is not a loaded systemd unit (LoadState '${state:-unknown}'): is docker-ncc's cgroup parent set? nothing reaped" >&2
      return 3
    fi
    echo "scanned 0 build container scopes: ncc-builds.slice not active"
    return 0
  fi
  for scope in "$reaper_cgroup_root"/ncc-builds.slice/docker-*.scope \
               "$reaper_cgroup_root"/*/ncc-builds.slice/docker-*.scope; do
    unit=${scope##*/}
    id=${unit#docker-}
    id=${id%.scope}
    [[ $id =~ ^[0-9a-f]{64}$ ]] || continue
    scanned=$((scanned + 1))
    since=$(reaper_active_since "$unit")
    if [[ ! $since =~ ^[0-9]+$ ]] || (( since == 0 )); then
      echo "skipping $unit: systemd does not say when it started" >&2
      continue
    fi
    age=$(( now - since ))
    (( age > max_age )) || continue
    if reaper_kill_scope "$scope"; then
      echo "killed build container ${id:0:12} ($unit): active for ${age}s, past ${max_age}s"
      killed=$((killed + 1))
    else
      echo "could not kill build container ${id:0:12} ($unit)" >&2
      status=1
    fi
  done
  echo "scanned $scanned build container scopes in ${#slices[@]} slice(s), killed $killed"
  return "$status"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  reaper_main
fi
