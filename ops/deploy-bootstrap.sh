#!/bin/bash
# The deploy entry point installed on each host, as $NCC_INSTALL_DIR/deploy.sh:
# the path CI's NCC_REMOTE_DEPLOY secret names and the one
# ops/deploy-builders.sh runs. It is the only deploy script a host does not
# take from the commit it deploys, so it does as little as it can. A change
# to it reaches the hosts CI deploys only when an operator installs it there
# by hand (the operator runbook, "Installing a change"; deploy-builders.sh
# installs it on every deploy), and every deploy warns while a host's copy
# differs from the deployed commit's.
#
#   deploy.sh [40-character main commit SHA [builder]]
#   deploy.sh rollback
#
# A deploy, under the deploy lock, fetches origin main into the checkout,
# refuses unless the commit is main's head, and then runs that commit's own
# ops/deploy.sh, so a change to deploy.sh takes effect on the deploy that
# ships it. That copy runs from $NCC_INSTALL_DIR/deploy-commit.sh, outside
# the checkout, because deploy.sh fast-forwards the checkout and must not run
# from a file that moves under it. This script moves nothing: deploy.sh
# checks the commit again and makes every other refusal before it moves the
# checkout, as it always did.
#
# A rollback moves no commit: it runs the checkout's own ops/deploy.sh, the
# last deployed commit's, which rolls back with that commit's blue-green.sh.
#
# Either way deploy.sh inherits fd 9 holding the lock, and NCC_DEPLOY_LOCKED
# naming the lock file, and keeps that lock instead of reopening it, so no
# other deploy can start in between.
set -euo pipefail

if [[ $# -eq 1 && $1 == rollback ]]; then
  mode=rollback
elif [[ $# -gt 2 || ( $# -ge 1 && ! "$1" =~ ^[0-9a-f]{40}$ ) ||
        ( $# -eq 2 && "$2" != builder ) ]]; then
  echo "usage: $0 [40-character main commit SHA [builder]] | rollback" >&2
  exit 1
else
  mode=${2:-portal}
fi

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

ncc_layout NCC_SRC_DIR NCC_INSTALL_DIR || exit 1

case $0 in
  /*) self=$0 ;;
  *) self=$PWD/$0 ;;
esac

# Serialize manual and automated deploys as well as separate Actions runs:
# the same lock deploy.sh takes, held from here to the end of its run.
lock=$NCC_INSTALL_DIR/deploy.lock
exec 9>"$lock"
flock -n 9 || { echo 'another deployment is running' >&2; exit 1; }
export NCC_DEPLOY_LOCKED=$lock

if [[ $mode == rollback ]]; then
  exec "$BASH" "$NCC_SRC_DIR/ops/deploy.sh" rollback
fi

cd "$NCC_SRC_DIR"
git fetch origin main
target=${1:-$(git rev-parse origin/main)}
if [[ "$target" != "$(git rev-parse origin/main)" ]]; then
  echo 'refusing to deploy: requested commit is no longer the head of main' >&2
  exit 1
fi

if ! git cat-file blob "$target:ops/deploy-bootstrap.sh" 2>/dev/null | cmp -s - "$self"; then
  echo "WARNING: $self is not ops/deploy-bootstrap.sh of ${target:0:12}; install that copy here by hand (the operator runbook, \"Installing a change\")" >&2
fi

run=$NCC_INSTALL_DIR/deploy-commit.sh
git cat-file blob "$target:ops/deploy.sh" >"$run.new"
# An empty script would run nothing and exit 0: a deploy that did nothing
# would look like one that worked.
if [[ ! -s $run.new ]]; then
  echo "refusing to deploy: ops/deploy.sh of $target is empty" >&2
  exit 1
fi
mv -f "$run.new" "$run"

# The commit is passed even when none was given, so deploy.sh deploys the
# very commit whose deploy.sh this is, or refuses if main moved since.
echo "running ops/deploy.sh of ${target:0:12}"
if [[ $mode == builder ]]; then
  exec "$BASH" "$run" "$target" builder
fi
exec "$BASH" "$run" "$target"
