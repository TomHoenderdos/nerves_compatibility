#!/bin/bash
# Fetches images.json for the deployed commit from the GitHub release the
# images workflow publishes (agent-<sha>) into the destination
# Portal.Builders.Images reads (`$dest`, by default NCC_IMAGES_JSON from the
# deploy env file). Best-effort:
# the release lands minutes after the deploy, so a miss is a retry on the
# next run, not a failure.
#
# Usage: images-sync.sh <40-hex sha> [destination]   (see the operator runbook)
set -euo pipefail

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

sha=${1:-}
dest=${2:-}
repo=${NCC_IMAGES_REPO:-TomHoenderdos/nerves_compatibility}

if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "usage: $0 <40-character commit sha> [destination]" >&2
  exit 2
fi

if [[ -z $dest ]]; then
  ncc_layout NCC_IMAGES_JSON || exit 2
  dest=$NCC_IMAGES_JSON
fi

url="https://github.com/$repo/releases/download/agent-$sha/images.json"
tmp=$(mktemp "${dest}.XXXXXX")
trap 'rm -f "$tmp"' EXIT

if ! curl -fsSL --max-time 30 -o "$tmp" "$url"; then
  echo "images.json for $sha is not published yet ($url)" >&2
  exit 1
fi

if ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["commit"]==sys.argv[2]; assert d["images"]["ncc-worker"]["digest"].startswith("sha256:")' "$tmp" "$sha"; then
  echo "downloaded images.json is not for $sha or is malformed" >&2
  exit 1
fi

chmod 644 "$tmp"
mv "$tmp" "$dest"
trap - EXIT
echo "installed images.json for $sha at $dest"
