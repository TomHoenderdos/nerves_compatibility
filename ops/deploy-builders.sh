#!/usr/bin/env bash
# Deploys one main commit to the build hosts from an operator's laptop: the
# operator's own builders (never deployed by CI) and the main builder (normally
# deployed by CI; included for a redeploy or a rescue).
#
# The hosts come from ops/builders.hosts (or $NCC_BUILDERS_FILE), which is not
# committed: one `<name> <ssh destination>` per line, in deploy order, `#`
# comments allowed. See ops/builders.hosts.example.
#
#   ops/deploy-builders.sh                  # head of main, every host
#   ops/deploy-builders.sh -s host-a host-b # one host at a time, two hosts
#   ops/deploy-builders.sh -c <sha> host-a  # a specific commit (must be main's head)
#   ops/deploy-builders.sh -f host-a        # redeploy a host already on the commit
#   ops/deploy-builders.sh -n               # dry run: preflight only, changes nothing
#
# Per host, in order:
#   1. preflight: ssh reachable, checkout on main, which commit it runs;
#      a host already on the commit with ncc-portal active is skipped (-f overrides)
#   2. installs that commit's ops/deploy.sh and ops/build-release.sh into the
#      host's fixed deploy directory (hosts run those copies, not the
#      checkout's; see the operator runbook)
#   3. starts `deploy.sh <sha> builder` detached on the host (setsid, stdin
#      closed, own log under the deploying user's home), so a dropped ssh
#      cannot kill it halfway;
#      deploy.sh holds its own flock, so a second run refuses rather than races
#   4. polls the log from here (no loop runs on the host) until deploy.sh exits
#   5. verifies the host is on the commit and ncc-portal is active
#
# A builder deploy drains its build queues first, up to ~2 h. Without -s every
# selected host deploys at once, which pauses all build capacity together.
#
# Written for the bash 3.2 macOS ships: no associative arrays.
set -euo pipefail

hosts_file=${NCC_BUILDERS_FILE:-$(dirname "$0")/builders.hosts}
[[ -r $hosts_file ]] || {
  echo "no host list at $hosts_file (copy ops/builders.hosts.example)" >&2
  exit 2
}

ORDER=()
DESTS=()
while read -r name dest _; do
  [[ -z $name || $name == \#* ]] && continue
  [[ -n $dest ]] || { echo "$hosts_file: no ssh destination for '$name'" >&2; exit 2; }
  ORDER+=("$name")
  DESTS+=("$dest")
done <"$hosts_file"
[[ ${#ORDER[@]} -gt 0 ]] || { echo "$hosts_file lists no hosts" >&2; exit 2; }

# ssh destination for a host name; empty for an unknown one.
host_of() {
  local i
  for i in "${!ORDER[@]}"; do
    if [[ ${ORDER[$i]} == "$1" ]]; then
      echo "${DESTS[$i]}"
      return
    fi
  done
}

POLL_SECONDS=60
MAX_WAIT_SECONDS=$((4 * 60 * 60))
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)

usage() {
  echo "usage: $0 [-c <40-char sha>] [-s] [-f] [-n] [host ...]" >&2
  exit 2
}

sha=""
serial=false
force=false
dry_run=false
while getopts ":c:sfnh" opt; do
  case "$opt" in
    c) sha=$OPTARG ;;
    s) serial=true ;;
    f) force=true ;;
    n) dry_run=true ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

if [[ $# -gt 0 ]]; then
  selected=("$@")
else
  selected=("${ORDER[@]}")
fi
for name in "${selected[@]}"; do
  [[ -n $(host_of "$name") ]] || { echo "unknown host '$name' (known: ${ORDER[*]})" >&2; exit 2; }
done

repo=$(git rev-parse --show-toplevel)

# deploy.sh refuses anything but the head of main, so resolve and check it here
# rather than discover it on the first host. Both remotes must agree: the hosts
# fetch from GitHub, CI deploys what was pushed to both.
github_head=$(git -C "$repo" ls-remote github refs/heads/main | cut -f1)
origin_head=$(git -C "$repo" ls-remote origin refs/heads/main | cut -f1)
[[ -n $sha ]] || sha=$github_head
[[ $sha =~ ^[0-9a-f]{40}$ ]] || { echo "not a 40-character sha: $sha" >&2; exit 2; }
if [[ $github_head != "$origin_head" || $sha != "$github_head" ]]; then
  echo "refusing: $sha is not the head of main on both remotes (github $github_head, origin $origin_head)" >&2
  exit 1
fi
git -C "$repo" fetch -q github main
git -C "$repo" cat-file -e "$sha^{commit}" || { echo "commit $sha not available locally" >&2; exit 1; }
echo "deploying $(git -C "$repo" log --oneline -1 "$sha")"

log() { printf '[%s %s] %s\n' "$(date +%H:%M:%S)" "$1" "$2"; }

# The command string is meant to be built here: every value in it is a
# validated sha, a fixed path or a log name this script made.
# shellcheck disable=SC2029
on() { ssh "${SSH_OPTS[@]}" "$(host_of "$1")" "$2"; }

preflight() {
  local name=$1 state head branch active
  if ! state=$(on "$name" 'cd /opt/nerves_compatibility/src && git rev-parse HEAD && git branch --show-current && systemctl is-active ncc-portal || true' 2>&1); then
    log "$name" "unreachable over ssh: $state"
    log "$name" "if this is a new host key, verify it and add it to ~/.ssh/known_hosts first"
    return 1
  fi
  head=$(sed -n 1p <<<"$state")
  branch=$(sed -n 2p <<<"$state")
  active=$(sed -n 3p <<<"$state")
  if [[ $branch != main ]]; then
    log "$name" "checkout is on '$branch', not main; fix by hand"
    return 1
  fi
  if [[ $head == "$sha" && $active == active && $force == false ]]; then
    log "$name" "already on ${sha:0:7} and ncc-portal is active; skipping (-f to redeploy)"
    return 3
  fi
  log "$name" "on ${head:0:7}, ncc-portal $active"
}

# The hosts run their own installed copies of deploy.sh/build-release.sh, not
# the checkout's, so a deploy of a commit that changed them must ship them
# first. Taken from the commit being deployed, never from this working tree.
install_scripts() {
  local name=$1 f
  for f in deploy.sh build-release.sh; do
    git -C "$repo" show "$sha:ops/$f" |
      on "$name" "cat > /opt/nerves_compatibility/$f.new && chmod 0755 /opt/nerves_compatibility/$f.new && mv /opt/nerves_compatibility/$f.new /opt/nerves_compatibility/$f"
  done
  log "$name" "installed deploy.sh and build-release.sh from ${sha:0:7}"
}

# Prints the remote log path. The trailing DEPLOY_EXIT line is what the poll
# waits for; deploy.sh's own output never prints it.
start_deploy() {
  local name=$1 logfile
  logfile=/root/deploy_builders_$(date +%Y%m%d%H%M%S)_${sha:0:7}.log
  # `setsid -f` forks the deploy into its own session and returns at once,
  # and `ssh -n` gives ssh no stdin to hold open. Without both, ssh stayed
  # attached until deploy.sh finished (measured 2026-10-26: the whole ~10
  # minutes), so a dropped connection could still take the deploy with it.
  ssh -n "${SSH_OPTS[@]}" "$(host_of "$name")" \
    "cd /tmp && setsid -f nohup bash -c '/opt/nerves_compatibility/deploy.sh $sha builder; echo DEPLOY_EXIT=\$?' > $logfile 2>&1 < /dev/null"
  log "$name" "started; log $logfile" >&2
  echo "$logfile"
}

# Returns the exit code deploy.sh reported, or 124 if it outlived the wait.
wait_deploy() {
  local name=$1 logfile=$2 waited=0 last="" line code
  while ((waited < MAX_WAIT_SECONDS)); do
    sleep "$POLL_SECONDS"
    waited=$((waited + POLL_SECONDS))
    if ! line=$(on "$name" "grep -m1 '^DEPLOY_EXIT=' $logfile; tail -n1 $logfile" 2>/dev/null); then
      log "$name" "ssh failed while polling; retrying"
      continue
    fi
    if [[ $line == DEPLOY_EXIT=* ]]; then
      code=${line%%$'\n'*}
      code=${code#DEPLOY_EXIT=}
      return "$code"
    fi
    if [[ $line != "$last" ]]; then
      log "$name" "${line:0:160}"
      last=$line
    fi
  done
  return 124
}

verify() {
  local name=$1 out
  out=$(on "$name" 'cd /opt/nerves_compatibility/src && git log --oneline -1 && systemctl is-active ncc-portal' 2>&1) || true
  log "$name" "now: ${out//$'\n'/, }"
  [[ $out == "${sha:0:7}"* && $out == *$'\n'active ]]
}

deploy_one() {
  local name=$1 logfile code=0 rc=0
  preflight "$name" || rc=$?
  ((rc == 3)) && return 0
  ((rc == 0)) || return 1
  if $dry_run; then
    log "$name" "dry run: would install deploy.sh/build-release.sh and run deploy.sh ${sha:0:7} builder"
    return 0
  fi
  install_scripts "$name"
  logfile=$(start_deploy "$name")
  wait_deploy "$name" "$logfile" || code=$?
  if ((code == 124)); then
    log "$name" "still running after $((MAX_WAIT_SECONDS / 3600)) h; check $logfile on the host"
    return 1
  fi
  if ((code != 0)); then
    log "$name" "deploy.sh exited $code; last lines:"
    on "$name" "tail -n 25 $logfile" | sed "s/^/  $name | /"
    return 1
  fi
  verify "$name" || { log "$name" "deployed but verification failed"; return 1; }
  log "$name" "done"
}

failed=()
if $serial; then
  for name in "${selected[@]}"; do
    deploy_one "$name" || failed+=("$name")
  done
else
  pids=()
  for name in "${selected[@]}"; do
    deploy_one "$name" &
    pids+=("$!")
  done
  for i in "${!pids[@]}"; do
    wait "${pids[$i]}" || failed+=("${selected[$i]}")
  done
fi

if ((${#failed[@]})); then
  echo "FAILED: ${failed[*]}" >&2
  exit 1
fi
echo "all selected builders on ${sha:0:7}"
