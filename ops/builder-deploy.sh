#!/usr/bin/env bash
# Sourced by deploy.sh only for a builder release.

builder_paused=false

# The build egress filter (isolation spec, section 3; ops/README.md "Egress
# filter"). Installed from this checkout, which deploy.sh has already moved to
# the commit being deployed.
builder_src=${SRC:-/opt/nerves_compatibility/src}
builder_portal_env=${NCC_PORTAL_ENV:-/etc/ncc-portal/portal.env}
builder_egress_rules=/etc/ncc-portal/builder-egress.nft
builder_egress_bridge_rules=/etc/ncc-portal/builder-egress-bridge.nft
builder_egress_loader=/opt/nerves_compatibility/builder-egress-load.sh

builder_ncc_home() { getent passwd ncc | cut -d: -f6; }
builder_is_nixos() { [[ -e /etc/NIXOS ]]; }

# `NCC_EGRESS_CHECK=0` in portal.env is the rollback: it turns the portal's
# preflight off, and here it stops a deploy from putting the filter back.
builder_egress_disabled() {
  [[ -r "$builder_portal_env" ]] || return 1
  (
    set -a
    # shellcheck source=/dev/null
    . "$builder_portal_env"
    [[ ${NCC_EGRESS_CHECK:-} == 0 ]]
  )
}

builder_egress_dropin() {
  cat <<EOF
# Installed by ops/builder-deploy.sh. Rootless dockerd recreates its network
# namespace on every start, and the build egress filter goes with it; reload
# it once the daemon answers. "-": a failed load leaves the daemon up, and the
# portal's preflight then refuses builds instead.
[Service]
ExecStartPost=-$builder_egress_loader
EOF
}

# Called from an `if`, where `set -e` does not apply, so every step checks its
# own status.
builder_install_egress() {
  if builder_egress_disabled; then
    echo 'NCC_EGRESS_CHECK=0: leaving the build egress filter alone'
    return 0
  fi

  local uid home dir tmp
  uid=$(id -u ncc) || return 1
  install -o root -g root -m 0644 "$builder_src/ops/builder-egress.nft" \
    "$builder_egress_rules" || return 1
  install -o root -g root -m 0644 "$builder_src/ops/builder-egress-bridge.nft" \
    "$builder_egress_bridge_rules" || return 1
  install -o root -g root -m 0755 "$builder_src/ops/builder-egress-load.sh" \
    "$builder_egress_loader" || return 1

  if builder_is_nixos; then
    echo 'NixOS: the docker user unit is nix-managed; its ExecStartPost comes from the host nix config (ops/README.md, "Egress filter")'
  else
    home=$(builder_ncc_home) || return 1
    [[ -n "$home" ]] || return 1
    dir="$home/.config/systemd/user/docker.service.d"
    install -d -o ncc -g "$(id -gn ncc)" -m 0755 "$dir" || return 1
    tmp=$(mktemp) || return 1
    builder_egress_dropin > "$tmp" || { rm -f "$tmp"; return 1; }
    install -o root -g root -m 0644 "$tmp" "$dir/ncc-egress.conf" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    systemctl --user -M ncc@ daemon-reload || return 1
  fi

  # Now as well: the namespace that exists today has no rules on a host's
  # first deploy of this, and an older ruleset on every later one.
  sudo -u ncc env XDG_RUNTIME_DIR="/run/user/$uid" "$builder_egress_loader" || return 1
}

# The new release's own preflight, so a release that would refuse every build
# is never activated.
builder_check_egress() {
  if ! sudo -u ncc bash -c '
    set -euo pipefail
    cd /var/lib/ncc
    set -a
    . /etc/ncc-portal/portal.env
    set +a
    exec /opt/nerves_compatibility/portal/bin/portal eval "$1"
  ' -- 'case Portal.Builder.check_egress() do
    :ok ->
      :ok

    error ->
      IO.puts(:stderr, inspect(error))
      System.halt(1)
  end'; then
    echo 'refusing to activate: the new release finds no build egress filter (ops/README.md, "Egress filter")' >&2
    return 1
  fi
}

builder_rpc() {
  sudo -u ncc bash -c '
    set -euo pipefail
    cd /var/lib/ncc
    set -a
    . /etc/ncc-portal/portal.env
    set +a
    exec /opt/nerves_compatibility/portal/bin/portal rpc "$1"
  ' -- "$1"
}

# The queues to drain, asked of the running release. One from before
# `builder_queues/0` existed has no node-local ingest queue to drain.
builder_queues='(if Code.ensure_loaded?(Portal.Workers.Ingest) and
    function_exported?(Portal.Workers.Ingest, :builder_queues, 0),
  do: Portal.Workers.Ingest.builder_queues(),
  else: [:builds, :ingest])'

builder_queues_available() {
  builder_rpc "IO.puts(Enum.all?($builder_queues, fn queue ->
    case Oban.check_queue(queue: queue) do
      %{paused: false} -> true
      _ -> false
    end
  end))"
}

builder_pause() {
  builder_rpc "Enum.each($builder_queues, fn queue ->
    :ok = Oban.pause_queue(queue: queue, local_only: true)
  end)"
}

builder_queues_drained() {
  builder_rpc "IO.puts(Enum.all?($builder_queues, fn queue ->
    case Oban.check_queue(queue: queue) do
      %{paused: true, running: []} -> true
      _ -> false
    end
  end))"
}

builder_resume() {
  builder_rpc "Enum.each($builder_queues, fn queue ->
    :ok = Oban.resume_queue(queue: queue, local_only: true)
  end)"
}

builder_cleanup() {
  local result=$?
  trap - EXIT
  if [[ "$builder_paused" == true ]]; then
    if ! builder_resume; then
      echo 'failed to resume builder queues; operator intervention required' >&2
      result=1
    fi
  fi
  exit "$result"
}

builder_prepare() {
  local timeout=${NCC_DEPLOY_DRAIN_SECONDS:-7500}
  [[ "$timeout" =~ ^[0-9]+$ ]] || { echo 'invalid drain timeout' >&2; return 1; }

  # Respect an operator's existing pause; never unpause it as a side effect.
  if [[ $(builder_queues_available) != true ]]; then
    echo 'builder queues are missing or already paused; refusing deployment' >&2
    return 1
  fi

  # Before the pause: a host that cannot load its egress filter keeps its
  # running release and queues, rather than draining into a release whose
  # preflight would refuse every build.
  if ! builder_install_egress; then
    echo 'could not install the build egress filter; leaving the running release in place' >&2
    return 1
  fi

  builder_paused=true
  trap builder_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  builder_pause

  local deadline=$((SECONDS + timeout))
  local drained
  while true; do
    drained=$(builder_queues_drained)
    if [[ "$drained" == true ]]; then
      echo 'builder queues are paused and active jobs have finished'
      return 0
    fi
    if [[ "$drained" != false ]] || (( SECONDS >= deadline )); then
      echo 'builder did not drain; leaving the running release in place' >&2
      return 1
    fi
    echo 'waiting for active builder jobs to finish'
    sleep 15
  done
}

builder_build_image() {
  local uid
  uid=$(id -u ncc)
  # Build a candidate tag. Existing jobs and failed builds retain the live tag.
  DOCKER_HOST="unix:///run/user/$uid/docker.sock" make build WORKER_IMAGE=ncc-worker:deploy
  # The same for every toolchain image: `<tag>-deploy` beside the live `<tag>`.
  # A failure here stops the deploy before any tag moves, like the main image.
  DOCKER_HOST="unix:///run/user/$uid/docker.sock" make build-toolchains TOOLCHAIN_SUFFIX=-deploy
}

# The live toolchain tags, one per line, from the Makefile's TOOLCHAIN_IMAGES.
builder_toolchain_tags() {
  local uid
  uid=$(id -u ncc)
  # Reads the Makefile only, but runs under the rootless daemon like every
  # other make and docker call here, so the deploy tests can assert on it.
  DOCKER_HOST="unix:///run/user/$uid/docker.sock" make -s toolchain-tags
}

builder_docker() {
  local uid
  uid=$(id -u ncc)
  DOCKER_HOST="unix:///run/user/$uid/docker.sock" docker "$@"
}

# Fills the Nerves cache with what the template resolves on the image just
# activated, before the restart lets the first build run (isolation spec,
# section 1). Through the new release's `eval`, so the warm container gets
# exactly the argv every build gets (Portal.Builder), not a copy of it here.
# Bounded at an hour, inside the deploy job's own limit. Never fatal: a run
# that fails before the one-time wipe finishes leaves the cache's old,
# untrusted entries in place and its trust marker unwritten, so the next
# deploy wipes and warms again; one that fails after it leaves builds
# extracting what they miss, which Portal.Workers.WarmNerves then fills.
# A timeout (124) kills the eval BEAM and with it Portal.Builder's own wall
# clock, while `docker run --rm` goes on writing the cache with nothing left
# to stop it, and its ncc- name keeps Portal.Workers.Sweep from evicting;
# builder_kill_warm stops it.
builder_warm_nerves() {
  local status=0
  sudo -u ncc bash -c '
    set -euo pipefail
    cd /var/lib/ncc
    set -a
    . /etc/ncc-portal/portal.env
    set +a
    export DOCKER_HOST="${DOCKER_HOST:-unix:///run/user/$(id -u)/docker.sock}"
    exec timeout 60m /opt/nerves_compatibility/portal/bin/portal eval "$1"
  ' -- 'case Portal.NervesCache.deploy_warm() do
    :ok ->
      :ok

    error ->
      IO.puts(:stderr, inspect(error))
      System.halt(1)
  end' || status=$?
  if [ "$status" -ne 0 ]; then
    if [ "$status" -eq 124 ]; then
      builder_kill_warm
    fi
    echo 'warning: deploy-time Nerves cache warm failed; the cache may still hold untrusted entries, and the warm will be retried next deploy' >&2
  fi
}

# Portal.Builder names a warm's container ncc-warm_nerves-<ms>
# (Portal.NervesCache.deploy_warm/1, container_name/1).
builder_kill_warm() {
  local ids
  ids=$(builder_docker ps -q --filter 'name=^ncc-warm_nerves-') || ids=''
  if [ -n "$ids" ]; then
    # One id per line; word splitting is what passes them as arguments.
    # shellcheck disable=SC2086
    builder_docker kill $ids >/dev/null || echo 'warning: could not kill the timed-out warm container' >&2
  fi
}

builder_activate_image() {
  builder_check_egress || return 1
  builder_docker image inspect ncc-worker:local >/dev/null
  local tags tag
  tags=$(builder_toolchain_tags)
  # Check every candidate before moving any tag, so a missing one leaves all
  # the live tags where they were.
  for tag in $tags; do
    builder_docker image inspect "$tag-deploy" >/dev/null
  done
  builder_docker tag ncc-worker:local ncc-worker:previous
  builder_docker tag ncc-worker:deploy ncc-worker:local
  for tag in $tags; do
    # A toolchain added in this deploy has no live tag yet, so no previous.
    if builder_docker image inspect "$tag" >/dev/null 2>&1; then
      builder_docker tag "$tag" "$tag-previous"
    fi
    builder_docker tag "$tag-deploy" "$tag"
  done
  # The live tags have moved; warm the cache on the image builds will now use.
  builder_warm_nerves
}
