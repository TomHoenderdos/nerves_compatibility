#!/usr/bin/env bash
# Sourced by deploy.sh only for a builder release.

builder_paused=false

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

builder_activate_image() {
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
}
