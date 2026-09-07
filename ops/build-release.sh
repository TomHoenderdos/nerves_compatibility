#!/bin/bash
# Builds the portal release for this host.
#
# There is no Elixir on the host, so the build happens in a container. The base
# must be ubuntu-noble: a release links against the glibc of the machine that
# built it, and both hosts are Ubuntu 24.04. Anything else produces a release
# that will not start here.
#
# Installed to /opt/nerves_compatibility/build-release.sh on each host. See
# ops/README.md.
set -euo pipefail

SRC=/opt/nerves_compatibility/src
DEST=/opt/nerves_compatibility/portal
BUILDER=hexpm/elixir:1.20.3-erlang-28.5.0.5-ubuntu-noble-20260810

docker run --rm \
  -v "$SRC":/src -w /src \
  -e MIX_ENV=prod -e HOME=/src/.buildhome \
  "$BUILDER" \
  bash -euo pipefail -c '
    # archive.ubuntu.com and security.ubuntu.com answer plain HTTP from these
    # hosts with "connection reset by peer" (verified 2026-09-04); apt then
    # hangs in its http method until the deploy is killed. Country mirrors are
    # unaffected. HTTPS would also work, but not here: apt cannot verify a
    # certificate before ca-certificates is installed, which is the very thing
    # this apt run exists to install.
    sed -i -e "s|http://archive\.ubuntu\.com/ubuntu|http://nl.archive.ubuntu.com/ubuntu|g" \
           -e "s|http://security\.ubuntu\.com/ubuntu|http://nl.archive.ubuntu.com/ubuntu|g" \
           /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list 2>/dev/null || true

    # The image ships without a CA bundle, and OTP reads the OS store, so
    # every HTTPS call to hex.pm dies on :no_cacerts_found without this.
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends ca-certificates git build-essential >/dev/null
    mix local.hex --force >/dev/null
    mix local.rebar --force >/dev/null

    # Dependency advisory audit.
    #
    # Warn-only on purpose. The blocking copy of this check is
    # .github/workflows/audit.yml, which runs on every push to main and weekly
    # against an unchanged lock. Failing the deploy here as well would mean an
    # advisory published upstream overnight blocks an unrelated hotfix at 3am,
    # for a lock that was already green when it was committed.
    #
    # mix_audit is `only: [:dev, :test]`, so it needs a full `deps.get` rather
    # than the `--only prod` one below; `_build/dev` is separate from the prod
    # tree, so this does not touch what gets released. `deps.loadpaths` is what
    # puts mix_audit s yaml_elixir on the code path — `mix deps.audit` alone
    # dies with `function YamlElixir.read_from_file/1 is undefined`.
    echo "=== dependency advisory audit ==="
    if MIX_ENV=dev mix deps.get >/dev/null && \
       MIX_ENV=dev mix do deps.loadpaths + deps.audit; then
      echo "=== audit clean ==="
    else
      echo "!!!" >&2
      echo "!!! ADVISORY AUDIT FAILED - the deploy continues, but fix mix.lock." >&2
      echo "!!! Reproduce locally: mix do deps.loadpaths + deps.audit" >&2
      echo "!!!" >&2
    fi

    mix deps.get --only prod
    mix assets.setup
    mix assets.deploy
    mix release portal --overwrite
  '

rm -rf "$DEST"
cp -a "$SRC/_build/prod/rel/portal" "$DEST"
chown -R ncc:ncc "$DEST"
echo "Release at $DEST"
