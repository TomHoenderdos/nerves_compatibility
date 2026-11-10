#!/usr/bin/env bash
# Re-records OTP's code-loading stack shapes in each worker image given and
# compares them with the pinned fixture for that image's OTP release
# (otp-<release>.term, the table in src/ncc_code_loading_shapes.hrl). Exits
# non-zero when an image prints other shapes, an unmatched event, or a
# release with no fixture: re-record with the README's steps and regenerate
# the include. Run by `make build`, `make build-toolchains` and
# `make test-integration`.
#
# Usage: check_images.sh IMAGE...
set -u

dir=$(cd "$(dirname "$0")" && pwd)
# The reproduction goes in on stdin, so no bind mount is needed on the daemon.
repro='cat > code_loading_repro.erl && timeout 300 sh -c '\''erlc code_loading_repro.erl && erl -noshell -eval "code_loading_repro:build(\"repro.escript\")" && escript repro.escript'\'''

status=0
for image in "$@"; do
  if ! out=$(docker run --rm -i --network none --entrypoint /bin/sh -e HOME=/tmp -w /tmp \
    "$image" -c "$repro" < "$dir/code_loading_repro.erl"); then
    echo "code-loading shapes: $image: the reproduction failed" >&2
    status=1
    continue
  fi
  release=$(printf '%s\n' "$out" | sed -n 's/^{shapes,"\([0-9][0-9]*\)",.*/\1/p')
  fixture="$dir/otp-$release.term"
  if [ -z "$release" ] || [ ! -f "$fixture" ]; then
    echo "code-loading shapes: $image: no fixture for OTP release '$release'" >&2
    printf '%s\n' "$out" >&2
    status=1
    continue
  fi
  expected=$(grep -v '^%%' "$fixture"; echo '{unmatched,[]}.')
  if [ "$out" = "$expected" ]; then
    echo "code-loading shapes: $image: OTP $release matches otp-$release.term"
  else
    echo "code-loading shapes: $image: OTP $release differs from otp-$release.term" >&2
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$out") >&2
    status=1
  fi
done
exit "$status"
