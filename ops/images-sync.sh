#!/bin/bash
# Fetches images.json for the deployed commit from the GitHub release the
# images workflow publishes (agent-<sha>) into /etc/ncc-portal/images.json,
# which Portal.Builders.Images reads. Best-effort: the release lands minutes
# after the deploy, so a miss is a retry on the next run, not a failure.
#
# Usage: images-sync.sh <40-hex sha> [destination]   (see docs/REMOTE_BUILDERS.md)
set -euo pipefail

sha=${1:-}
dest=${2:-/etc/ncc-portal/images.json}
repo=${NCC_IMAGES_REPO:-TomHoenderdos/nerves_compatibility}

if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "usage: $0 <40-character commit sha> [destination]" >&2
  exit 2
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
