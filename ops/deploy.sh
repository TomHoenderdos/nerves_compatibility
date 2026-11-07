#!/bin/bash
# Deploys the main branch to this host. Installed at a fixed operator-chosen
# path; see the operator runbook.
#
# Both hosts run an identical copy of this script and both follow main. The
# only per-host difference is the operator's portal.env file, which decides
# the Oban queues the node runs.
#
# GitHub Actions invokes this on the web host with the exact tested main SHA.
# Operators can still run it by hand (optionally passing a main SHA).
#
# Builder mode pauses new work, waits for active jobs and prepares a worker
# image with the existing Makefile and Docker cache before restarting.
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

# One variable from the deploy env file when the environment does not set it.
# ncc_layout sources the file only when a layout variable is missing, so a
# flag such as NCC_BLUE_GREEN would otherwise go unread whenever the caller
# exported the layout.
ncc_layout_flag() {
  local file=${NCC_DEPLOY_ENV:-/etc/ncc-deploy.env}
  if [[ -n ${!1+x} ]]; then printf '%s\n' "${!1}"; return 0; fi
  [[ -r $file ]] || return 0
  # shellcheck source=/dev/null
  (. "$file" && printf '%s\n' "${!1:-}")
}

# DOCKER_HOST on every host: build-release.sh builds the release on that
# daemon (docker-ncc on a builder, the system dockerd on the web host), so an
# env file without it stops here, before the checkout moves.
layout=(NCC_SRC_DIR NCC_INSTALL_DIR NCC_PORTAL_ENV NCC_PORTAL_WORKDIR DOCKER_HOST)
if [[ $mode != builder ]]; then
  layout+=(NCC_IMAGES_JSON)
fi
ncc_layout "${layout[@]}" || exit 1

# Blue/green (ops/blue-green.sh) is the web host's opt-in: unset keeps the
# single release and the restart below, and is the way back from it.
blue_green=0
NCC_BLUE_GREEN=$(ncc_layout_flag NCC_BLUE_GREEN)
if [[ $mode != builder && $NCC_BLUE_GREEN == 1 ]]; then
  blue_green=1
  ncc_layout NCC_APACHE_UPSTREAM || exit 1
fi
if [[ $mode == rollback && $blue_green != 1 ]]; then
  echo "rollback needs NCC_BLUE_GREEN=1: a single-release host rolls back from portal-previous.tar.gz by hand" >&2
  exit 1
fi

SRC=$NCC_SRC_DIR
BIN=$NCC_INSTALL_DIR/portal/bin/portal

# Serialize manual and automated deploys as well as separate Actions runs.
exec 9>"$NCC_INSTALL_DIR/deploy.lock"
flock -n 9 || { echo 'another deployment is running' >&2; exit 1; }

if [[ $mode == rollback ]]; then
  # shellcheck source=ops/blue-green.sh
  source "$SRC/ops/blue-green.sh"
  bg_rollback
  exit $?
fi

cd "$SRC"

if [[ $(git branch --show-current) != main ]] || ! git diff --cached --quiet; then
  echo 'refusing to deploy: checkout must be on main with no staged edits' >&2
  exit 1
fi

# `mix assets.deploy` rewrites the digested copies of robots.txt, favicon.ico
# and logo.svg under apps/portal/priv/static on every build, and unlike
# priv/static/assets/ those files are tracked. So a normal deploy always leaves
# the checkout dirty, and the next `git pull --ff-only` that happens to touch
# one of them aborts with "local changes would be overwritten by merge" --
# before anything else in this script runs.
#
# That is not hypothetical: on 2026-09-11 both hosts were found 40 commits
# behind main, stuck since the commit that changed robots.txt, with the build
# log viewer's migrations unapplied. The failure is loud but nobody is watching
# a deploy nobody ran.
#
# The build regenerates these files a few lines below, so the working copy is
# disposable and restoring it loses nothing. Deliberately scoped to
# priv/static: a modification anywhere else in the tree is someone's hand-edit,
# and that still must stop the deploy rather than be silently discarded.
if ! git diff --quiet -- apps/portal/priv/static; then
  echo "restoring build-generated assets under apps/portal/priv/static"
  git checkout -- apps/portal/priv/static
fi

# Any other dirty tracked file is a human's, so fail loudly rather than lose it.
if ! git diff --quiet; then
  echo "refusing to deploy: uncommitted changes outside apps/portal/priv/static" >&2
  git status --porcelain >&2
  exit 1
fi

git fetch origin main
target=${1:-$(git rev-parse origin/main)}
if [[ "$target" != "$(git rev-parse origin/main)" ]]; then
  echo 'refusing to deploy: requested commit is no longer the head of main' >&2
  exit 1
fi
git merge --ff-only "$target"
test "$(git rev-parse HEAD)" = "$target"
echo "deploying $(git log --oneline -1)"

if [[ $blue_green == 1 ]]; then
  # shellcheck source=ops/blue-green.sh
  source "$SRC/ops/blue-green.sh"
  bg_deploy "$target"
  bash "$SRC/ops/images-sync.sh" "$target" "$NCC_IMAGES_JSON" || echo 'images.json not yet available; the sync timer will retry' >&2
  exit 0
fi

# The restart path: whatever the colour directories hold, this release and
# its migrations now run past them. Their served records would let a later
# `deploy.sh rollback`, once blue/green is back on, promote one of them over
# a newer schema, so they go. Back on blue/green, a colour becomes a rollback
# target again only by serving.
for served in "$NCC_INSTALL_DIR"/served-*; do
  [[ -e $served ]] || continue
  rm -f "$served"
  echo "removed $served: blue/green is off, so that colour's release is no longer a rollback target"
done

# Preserve the previous release before build-release.sh replaces it. This is
# an operator rollback artifact; database migrations are not reversed here.
tar -czf "$NCC_INSTALL_DIR/portal-previous.tar.gz.tmp" \
  -C "$NCC_INSTALL_DIR" portal
mv "$NCC_INSTALL_DIR/portal-previous.tar.gz.tmp" \
  "$NCC_INSTALL_DIR/portal-previous.tar.gz"

if [[ $mode == builder ]]; then
  # shellcheck source=ops/builder-deploy.sh
  source "$SRC/ops/builder-deploy.sh"
  builder_prepare
  builder_build_image
fi

"$NCC_INSTALL_DIR/build-release.sh"

# Migrations run through `eval`, which starts the repo but no applications.
# That is enough for Ecto.Migrator and keeps the deploy independent of
# whether the service is currently up.
sudo -u ncc bash -c 'cd "$1" && set -a && . "$2" && set +a && "$3" eval "$4"' -- \
  "$NCC_PORTAL_WORKDIR" "$NCC_PORTAL_ENV" "$BIN" \
  'Ecto.Migrator.with_repo(Portal.Repo, &Ecto.Migrator.run(&1, :up, all: true))'

if [[ $mode == builder ]]; then
  builder_activate_image
fi

systemctl restart ncc-portal

sleep_until_up() {
  for _ in $(seq 1 30); do
    if curl -sf --max-time 10 -o /dev/null http://127.0.0.1:4002/packages; then
      echo "portal is up"
      return 0
    fi
    sleep 2
  done
  echo "portal did not come up; check: journalctl -u ncc-portal -n 50" >&2
  return 1
}
sleep_until_up

if [[ $mode == builder ]]; then
  builder_check_running_egress
else
  # Remote builders read the registry digest for this commit from images.json;
  # the images workflow publishes it minutes after this deploy, so a miss here
  # is retried by the ncc-images-sync timer (the operator runbook).
  bash "$SRC/ops/images-sync.sh" "$(git rev-parse HEAD)" "$NCC_IMAGES_JSON" || echo 'images.json not yet available; the sync timer will retry' >&2
fi
