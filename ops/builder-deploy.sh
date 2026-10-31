#!/usr/bin/env bash
# Sourced by deploy.sh only for a builder release.

builder_paused=false
# Set while the new worker image is being activated. A failure there leaves
# the old release running in memory, and docker-ncc's authz policy denies its
# argv: resuming its queues would only burn every build's retries.
builder_activating=false

# The host layout (where the checkout, the release and the config files live)
# comes from the operator's deploy env file, never from this repository: see
# ops/deploy.env.example. A script deploy.sh starts inherits every variable
# and reads no file. Without the file it refuses rather than guess a path.
ncc_layout() {
  local file=${NCC_DEPLOY_ENV:-/etc/ncc-deploy.env} name missing=()
  for name in "$@"; do [[ -n ${!name:-} ]] || missing+=("$name"); done
  [[ ${#missing[@]} -gt 0 ]] || return 0
  if [[ ! -r $file ]]; then
    echo "ERROR: no host layout: $file is missing or unreadable; it must set ${missing[*]} (see ops/deploy.env.example)" >&2
    return 1
  fi
  set -a
  # shellcheck source=/dev/null
  . "$file"
  set +a
  missing=()
  for name in "$@"; do [[ -n ${!name:-} ]] || missing+=("$name"); done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: $file does not set ${missing[*]} (see ops/deploy.env.example)" >&2
    return 1
  fi
}

# deploy.sh has read the env file already; this is for an older installed
# deploy.sh that predates it, and for the tests.
# DOCKER_HOST names docker-ncc's root-only unix socket, where every image pull,
# build, load and tag below goes, as root. Without it the docker CLI would fall
# back to /var/run/docker.sock, a daemon that runs no builds.
ncc_layout NCC_SRC_DIR NCC_INSTALL_DIR NCC_PORTAL_ENV NCC_PORTAL_WORKDIR \
  DOCKER_HOST || return 1

builder_src=$NCC_SRC_DIR
builder_portal_env=$NCC_PORTAL_ENV
builder_portal_workdir=$NCC_PORTAL_WORKDIR
builder_portal_bin=$NCC_INSTALL_DIR/portal/bin/portal

# `NCC_EGRESS_CHECK=0` in portal.env is the rollback: it turns the portal's
# preflight off, and here the check of the running service.
builder_egress_disabled() {
  [[ -r "$builder_portal_env" ]] || return 1
  (
    set -a
    # shellcheck source=/dev/null
    . "$builder_portal_env"
    [[ ${NCC_EGRESS_CHECK:-} == 0 ]]
  )
}

# The new release's own preflight, before any live image tag moves (except on
# a daemon that has none yet) or the service restarts. By then the new
# release is already installed and migrated, so a failure here does not keep
# it from running: the next restart, crash or reboot starts it, and it then
# refuses every build (fail closed). Until then the queues stay paused
# (builder_cleanup). The release this deploy replaced is in deploy.sh's own
# backup tarball, beside the deploy directory.
builder_check_egress() {
  if ! sudo -u ncc bash -c '
    set -euo pipefail
    cd "$1"
    set -a
    . "$2"
    set +a
    exec "$3" eval "$4"
  ' -- "$builder_portal_workdir" "$builder_portal_env" "$builder_portal_bin" \
    'case Portal.Builder.check_egress() do
    :ok ->
      :ok

    error ->
      IO.puts(:stderr, inspect(error))
      System.halt(1)
  end'; then
    echo 'refusing to activate: the new release finds no build egress filter (see the operator runbook)' >&2
    return 1
  fi
}

# After the restart, the same preflight asked of the running ncc-portal
# service, which is where builds run: the eval above runs under sudo, outside
# the unit's sandboxing, PATH and environment, so it can pass where the
# service refuses. Loud and non-zero, but after the restart: nothing is
# rolled back and no queue is paused.
builder_check_running_egress() {
  if [[ ${NCC_EGRESS_CHECK:-} == 0 ]] || builder_egress_disabled; then
    echo 'NCC_EGRESS_CHECK=0: not asking the running service for the build egress filter'
    return 0
  fi

  local answer
  answer=$(builder_rpc 'IO.inspect(Portal.Builder.check_egress())') || true
  if [[ $(printf '%s\n' "$answer" | tail -n 1) != ':ok' ]]; then
    cat >&2 <<EOF
ERROR: the running ncc-portal finds no build egress filter, so it refuses
every build (each one snoozes 15 minutes), although the deploy-time check
passed. It answered: ${answer:-nothing}
The table is the host configuration's, in the host's network namespace, and
the deploy-time eval found it there, so the likely cause is the ncc-portal
unit itself (its sandboxing, PATH or environment) or the status socket it
reads the table through. Check:
  nft list table inet ncc_egress
  systemctl status ncc-egress-status.socket
  systemctl show ncc-portal -p PrivateNetwork -p RestrictAddressFamilies -p Environment
  journalctl -u ncc-portal -n 50
See the operator runbook.
EOF
    return 1
  fi
  echo 'the running ncc-portal finds the build egress filter'
}

builder_rpc() {
  sudo -u ncc bash -c '
    set -euo pipefail
    cd "$1"
    set -a
    . "$2"
    set +a
    exec "$3" rpc "$4"
  ' -- "$builder_portal_workdir" "$builder_portal_env" "$builder_portal_bin" "$1"
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
  if [[ "$builder_paused" == true && "$builder_activating" == true ]]; then
    cat >&2 <<'EOF'
ERROR: the deploy failed while activating the new worker image, after the new
release was installed and migrated. The builder queues stay paused: the
release still running is the old one, and docker-ncc's authz policy denies
its builds. ncc-worker:local exists either way, so the next restart of
ncc-portal starts the new release with an image; that release refuses every
build until its egress check passes. Fix the cause, then restart ncc-portal
and run the deploy again. See the operator runbook.
EOF
    [[ "$result" -ne 0 ]] || result=1
  elif [[ "$builder_paused" == true ]]; then
    if ! builder_resume; then
      echo 'failed to resume builder queues; operator intervention required' >&2
      result=1
    fi
  fi
  exit "$result"
}

# Every build container runs under runsc, and docker-ncc's authz policy
# denies any other runtime: a daemon whose default is not runsc is not set
# up for this release. Asked before any queue pauses or image moves.
builder_check_runtime() {
  local runtime
  runtime=$(builder_docker info --format '{{.DefaultRuntime}}') || runtime=''
  if [[ "$runtime" != runsc ]]; then
    echo "refusing deployment: the docker daemon at $DOCKER_HOST has default runtime '${runtime:-unknown}', not runsc (see the operator runbook)" >&2
    return 1
  fi
}

builder_prepare() {
  local timeout=${NCC_DEPLOY_DRAIN_SECONDS:-7500}
  [[ "$timeout" =~ ^[0-9]+$ ]] || { echo 'invalid drain timeout' >&2; return 1; }

  builder_check_runtime || return 1

  # Respect an operator's existing pause; never unpause it as a side effect.
  if [[ $(builder_queues_available) != true ]]; then
    echo 'builder queues are missing or already paused; refusing deployment' >&2
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

# The worker image images.yml pushes for every main commit, tagged with the
# commit's sha. Every host that pulls it gets the same image ID, and the build
# cache is keyed by that ID (`Portal.Builder.cache_slug/1`): only hosts on the
# same ID share entries through the L2 bucket. A locally built image gets an ID
# of its own on every host. `NCC_WORKER_FROM_REGISTRY=0` builds locally always.
builder_registry_image=${NCC_WORKER_REGISTRY:-ghcr.io/tomhoenderdos/ncc-worker}

builder_pull_worker_image() {
  local sha
  sha=$(git -C "$builder_src" rev-parse HEAD) || return 1
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || return 1
  builder_docker pull -q "$builder_registry_image:$sha" >/dev/null || return 1
  builder_docker tag "$builder_registry_image:$sha" ncc-worker:deploy || return 1
  echo "worker image: $builder_registry_image:$sha"
}

builder_build_image() {
  # A candidate tag either way. Existing jobs and failed builds retain the live
  # tag. The registry image for this commit exists only once images.yml has run
  # for it, which starts after CI's own deploy; until then this host builds its
  # own and shares no build cache entries with the others.
  if [[ ${NCC_WORKER_FROM_REGISTRY:-1} == 1 ]] && builder_pull_worker_image; then
    :
  else
    echo 'worker image: no registry image for this commit; building locally, so this host shares no build cache entries' >&2
    make build WORKER_IMAGE=ncc-worker:deploy
  fi
  # The same for every toolchain image: `<tag>-deploy` beside the live `<tag>`.
  # A failure here stops the deploy before any tag moves, like the main image.
  make build-toolchains TOOLCHAIN_SUFFIX=-deploy
}

# The live toolchain tags, one per line, from the Makefile's TOOLCHAIN_IMAGES.
builder_toolchain_tags() {
  make -s toolchain-tags
}

# On the daemon DOCKER_HOST names, as root: the portal's mTLS identity may not
# load or tag an image.
builder_docker() {
  docker "$@"
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
# The warm container is a build container, so it runs as the portal's builds
# do: on docker-ncc's mTLS listener, where the authz policy holds it to runsc,
# never on the root socket. The eval runs under sudo, outside the ncc-portal
# unit whose NixOS environment sets that identity, so it is set here, after
# portal.env, which must not override it.
builder_warm_nerves() {
  local status=0
  sudo -u ncc bash -c '
    set -euo pipefail
    cd "$1"
    set -a
    . "$2"
    set +a
    export DOCKER_HOST=tcp://127.0.0.1:2376 DOCKER_TLS_VERIFY=1 DOCKER_CERT_PATH=/etc/ncc/docker-tls
    exec timeout 60m "$3" eval "$4"
  ' -- "$builder_portal_workdir" "$builder_portal_env" "$builder_portal_bin" \
    'case Portal.NervesCache.deploy_warm() do
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
  builder_activating=true
  local tags tag
  tags=$(builder_toolchain_tags)
  # Check every candidate before moving any tag, so a missing one leaves all
  # the live tags where they were.
  builder_docker image inspect ncc-worker:deploy >/dev/null
  for tag in $tags; do
    builder_docker image inspect "$tag-deploy" >/dev/null
  done
  # The first deploy on a new build daemon finds no live image, so there is
  # no previous to keep. The candidate becomes live before the egress check:
  # the new release is installed already, and if the check fails, the next
  # restart still starts it with an image to build with.
  # Space-separated, so an empty list is still set under bash 3's nounset.
  local fresh=' '
  if ! builder_docker image inspect ncc-worker:local >/dev/null 2>&1; then
    builder_docker tag ncc-worker:deploy ncc-worker:local
    fresh+='ncc-worker:local '
  fi
  for tag in $tags; do
    # A toolchain added in this deploy has no live tag yet, so no previous.
    if ! builder_docker image inspect "$tag" >/dev/null 2>&1; then
      builder_docker tag "$tag-deploy" "$tag"
      fresh+="$tag "
    fi
  done
  builder_check_egress || return 1
  if [[ $fresh != *" ncc-worker:local "* ]]; then
    builder_docker tag ncc-worker:local ncc-worker:previous
    builder_docker tag ncc-worker:deploy ncc-worker:local
  fi
  for tag in $tags; do
    if [[ $fresh != *" $tag "* ]]; then
      builder_docker tag "$tag" "$tag-previous"
      builder_docker tag "$tag-deploy" "$tag"
    fi
  done
  # The live tags have moved; warm the cache on the image builds will now use.
  builder_warm_nerves
  builder_activating=false
}
