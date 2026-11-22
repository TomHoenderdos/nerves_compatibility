#!/usr/bin/env bash
# The real Hex tarballs fixtures_foreign_priv_test.exs builds real kino from, and
# jesse 1.8.2, gproc 1.2.0 and gproc 1.3.0, whose reviewed .app.src.script
# judge_test.exs reads (their outer checksums are the review's keys).
# Needs network access to hex.pm. Writes next to itself.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"
for pkg in kino:0.19.1 table:0.1.2 jesse:1.8.2 gproc:1.2.0 gproc:1.3.0; do
  mix hex.package fetch "${pkg%%:*}" "${pkg##*:}"
done
cp kino-0.19.1.tar table-0.1.2.tar jesse-1.8.2.tar gproc-1.2.0.tar gproc-1.3.0.tar "$here/"
