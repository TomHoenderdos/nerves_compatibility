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
git pull --ff-only

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
