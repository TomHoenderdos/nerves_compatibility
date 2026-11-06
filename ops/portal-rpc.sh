#!/bin/bash
# rpc against the portal release that serves this host (blue/green: the colour
# the Apache include names), or a named colour. Runs as the service user from
# its work dir with its env, which a bare `bin/portal rpc` from root's home
# gets wrong in three ways (unreadable cwd, no env, wrong node name).
#
#   portal-rpc.sh 'Oban.check_all_queues(Oban)'
#   portal-rpc.sh --color green 'node()'
set -euo pipefail

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

ncc_layout NCC_SRC_DIR NCC_INSTALL_DIR NCC_PORTAL_ENV NCC_PORTAL_WORKDIR NCC_APACHE_UPSTREAM || exit 1

color=
if [[ ${1:-} == --color ]]; then
  color=${2:?--color needs blue or green}
  shift 2
fi
[[ $# -eq 1 ]] || { echo "usage: $0 [--color blue|green] '<elixir expression>'" >&2; exit 1; }

# shellcheck source=ops/blue-green.sh
source "$NCC_SRC_DIR/ops/blue-green.sh"
color=${color:-$(bg_serving_color)}
bg_port "$color" >/dev/null || { echo "unknown colour: $color" >&2; exit 1; }
bg_rpc "$color" "$1"
