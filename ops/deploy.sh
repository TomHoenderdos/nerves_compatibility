#!/bin/bash
# Deploys the main branch to this host. Installed to
# /opt/nerves_compatibility/deploy.sh; see ops/README.md.
#
# Both hosts run an identical copy of this script and both follow main. The
# only per-host difference is /etc/ncc-portal/portal.env, which decides the
# Oban queues the node runs.
#
# CI does not deploy. GitHub Actions audits the lock
# (.github/workflows/audit.yml); shipping is this script, run by hand.
#
# The worker image is NOT rebuilt here: it only changes when apps/ncc_worker,
# apps/compatibility or the Dockerfile change, and a --no-cache rebuild is a
# ~15 minute job. Run `make build` by hand for that, with DOCKER_HOST pointed
# at ncc's rootless daemon.
set -euo pipefail

SRC=/opt/nerves_compatibility/src
BIN=/opt/nerves_compatibility/portal/bin/portal

cd "$SRC"

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

git pull --ff-only
echo "deploying $(git log --oneline -1)"

/opt/nerves_compatibility/build-release.sh

# Migrations run through `eval`, which starts the repo but no applications.
# That is enough for Ecto.Migrator and keeps the deploy independent of
# whether the service is currently up.
sudo -u ncc bash -c "cd /var/lib/ncc && set -a && . /etc/ncc-portal/portal.env && set +a && \
  $BIN eval 'Ecto.Migrator.with_repo(Portal.Repo, &Ecto.Migrator.run(&1, :up, all: true))'"

systemctl restart ncc-portal

sleep_until_up() {
  for _ in $(seq 1 30); do
    if curl -sf -o /dev/null http://127.0.0.1:4002/; then
      echo "portal is up"
      return 0
    fi
    sleep 2
  done
  echo "portal did not come up; check: journalctl -u ncc-portal -n 50" >&2
  return 1
}
sleep_until_up
