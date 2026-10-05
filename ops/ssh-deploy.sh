#!/usr/bin/env bash
set -euo pipefail

role=${1:-}
[[ "$role" == portal || "$role" == builder ]] || { echo 'invalid deployment role' >&2; exit 1; }
[[ ${GITHUB_SHA:-} =~ ^[0-9a-f]{40}$ ]] || { echo 'invalid commit SHA' >&2; exit 1; }
[[ ${DEPLOY_HOST:-} =~ ^[a-zA-Z0-9.-]+$ ]] || { echo 'invalid deployment host' >&2; exit 1; }
: "${DEPLOY_SSH_KEY:?}"
: "${DEPLOY_KNOWN_HOSTS:?}"
: "${RUNNER_TEMP:?}"

umask 077
ssh_dir=$(mktemp -d "$RUNNER_TEMP/ncc-ssh.XXXXXX")
cleanup_ssh() {
  local ssh_status=$?
  trap - EXIT
  rm -f "$ssh_dir/key" "$ssh_dir/builder-key" "$ssh_dir/known_hosts" "$ssh_dir/config"
  rmdir "$ssh_dir"
  exit "$ssh_status"
}
trap cleanup_ssh EXIT
printf '%s\n' "$DEPLOY_SSH_KEY" > "$ssh_dir/key"
printf '%s\n' "$DEPLOY_KNOWN_HOSTS" > "$ssh_dir/known_hosts"
unset DEPLOY_SSH_KEY DEPLOY_KNOWN_HOSTS

cat > "$ssh_dir/config" <<EOF
Host *
  User root
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking yes
  UserKnownHostsFile $ssh_dir/known_hosts
  ConnectTimeout 15
  ServerAliveInterval 15
  ServerAliveCountMax 4
Host portal
  HostName $DEPLOY_HOST
  IdentityFile $ssh_dir/key
EOF

set -- /opt/nerves_compatibility/deploy.sh "$GITHUB_SHA"
if [[ "$role" == builder ]]; then
  [[ ${BUILDER_HOST:-} =~ ^[a-zA-Z0-9.-]+$ ]] || { echo 'invalid builder host' >&2; exit 1; }
  : "${BUILDER_DEPLOY_SSH_KEY:?}"
  printf '%s\n' "$BUILDER_DEPLOY_SSH_KEY" > "$ssh_dir/builder-key"
  unset BUILDER_DEPLOY_SSH_KEY
  cat >> "$ssh_dir/config" <<EOF
Host builder
  HostName $BUILDER_HOST
  IdentityFile $ssh_dir/builder-key
  ProxyJump portal
EOF
  set -- "$@" builder

  # The builder is reached through the web host over the tailnet, right after
  # the portal step has compiled a release on that same host. With both hosts
  # loaded, the jumped handshake has missed the 15s ConnectTimeout twice in a
  # row ("Connection timed out during banner exchange"). Probe with a longer
  # timeout and a few attempts first; the deploy itself still runs exactly
  # once, so a retry can never start a second deploy.
  attempt=1
  until ssh -F "$ssh_dir/config" -o ConnectTimeout=60 builder true; do
    if (( attempt >= 4 )); then
      echo "builder unreachable after $attempt attempts" >&2
      exit 255
    fi
    echo "builder connection attempt $attempt failed; retrying in $((attempt * 20))s" >&2
    sleep $((attempt * 20))
    attempt=$((attempt + 1))
  done
fi

ssh -F "$ssh_dir/config" "$role" "$@"
