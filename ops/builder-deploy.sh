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

builder_queues_available() {
  builder_rpc 'IO.puts(Enum.all?([:builds, :ingest], fn queue ->
    case Oban.check_queue(queue: queue) do
      %{paused: false} -> true
      _ -> false
    end
  end))'
}

builder_pause() {
  builder_rpc 'Enum.each([:builds, :ingest], fn queue ->
    :ok = Oban.pause_queue(queue: queue, local_only: true)
  end)'
}

builder_queues_drained() {
  builder_rpc 'IO.puts(Enum.all?([:builds, :ingest], fn queue ->
    case Oban.check_queue(queue: queue) do
      %{paused: true, running: []} -> true
      _ -> false
    end
  end))'
}

builder_resume() {
  builder_rpc 'Enum.each([:builds, :ingest], fn queue ->
    :ok = Oban.resume_queue(queue: queue, local_only: true)
  end)'
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
}

builder_docker() {
  local uid
  uid=$(id -u ncc)
  DOCKER_HOST="unix:///run/user/$uid/docker.sock" docker "$@"
}

builder_activate_image() {
  builder_docker image inspect ncc-worker:local >/dev/null
  builder_docker tag ncc-worker:local ncc-worker:previous
  builder_docker tag ncc-worker:deploy ncc-worker:local
}
