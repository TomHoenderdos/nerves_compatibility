#!/usr/bin/env bash
# A stand-in for `iptables` in the agent's egress tests.
#
# Every invocation is appended (one line, space-separated) to
# FAKE_IPTABLES_LOG. Chain state lives in the FAKE_IPTABLES_STATE
# directory, one file per chain holding its `-S` output: `-N CHAIN` then
# one `-A CHAIN ...` line per rule, echoed verbatim (no normalisation of
# matches such as `-m conntrack --ctstate ...`). A leading `-w [SECONDS]`
# and `-t filter` are accepted and ignored. FAKE_IPTABLES_DELAY (seconds)
# sleeps after logging, to widen races in tests. Implemented:
#
#   -N CHAIN         create (exit 1 if it exists)
#   -F CHAIN         drop every rule
#   -A CHAIN RULE    append
#   -I CHAIN [N] RULE  insert at position N (default 1)
#   -C CHAIN RULE    exit 0 when the rule is present, else 1
#   -D CHAIN RULE    delete the first matching rule (exit 1 if none)
#   -X CHAIN         delete an empty chain
#   -E OLD NEW       rename a chain; jumps to it in other chains follow
#   -S [CHAIN]       print the chain (or every chain)
#
# Any command on a missing chain exits 1. With FAKE_IPTABLES_DOCKER_USER=1
# the chains a running Docker daemon leaves are created first if missing:
# an empty DOCKER-USER, FORWARD jumping to it, and an empty INPUT.
set -euo pipefail

state="${FAKE_IPTABLES_STATE:?FAKE_IPTABLES_STATE is not set}"
mkdir -p "$state"

if [ -n "${FAKE_IPTABLES_LOG:-}" ]; then
  echo "$*" >>"$FAKE_IPTABLES_LOG"
fi

if [ -n "${FAKE_IPTABLES_DELAY:-}" ]; then
  sleep "$FAKE_IPTABLES_DELAY"
fi

if [ "${FAKE_IPTABLES_DOCKER_USER:-0}" = "1" ]; then
  [ -f "$state/DOCKER-USER" ] || echo "-N DOCKER-USER" >"$state/DOCKER-USER"
  [ -f "$state/FORWARD" ] || printf -- '-N FORWARD\n-A FORWARD -j DOCKER-USER\n' >"$state/FORWARD"
  [ -f "$state/INPUT" ] || echo "-N INPUT" >"$state/INPUT"
fi

while [ $# -gt 0 ]; do
  case "$1" in
    -w)
      shift
      if [[ "${1:-}" =~ ^[0-9]+$ ]]; then shift; fi
      ;;
    -t)
      [ "${2:-}" = "filter" ] || { echo "fake iptables: only the filter table" >&2; exit 2; }
      shift 2
      ;;
    *) break ;;
  esac
done

op="${1:-}"
shift || true

if [ "$op" = "-S" ] && [ $# -eq 0 ]; then
  for f in "$state"/*; do
    [ -f "$f" ] && cat "$f"
  done
  exit 0
fi

chain="${1:-}"
[ -n "$chain" ] || { echo "fake iptables: $op needs a chain" >&2; exit 2; }
shift
file="$state/$chain"

if [ "$op" = "-N" ]; then
  if [ -f "$file" ]; then
    echo "iptables: Chain already exists." >&2
    exit 1
  fi
  echo "-N $chain" >"$file"
  exit 0
fi

if [ "$op" = "-E" ]; then
  new="${1:-}"
  [ -n "$new" ] || { echo "fake iptables: -E needs a new name" >&2; exit 2; }
  [ -f "$file" ] || { echo "iptables: No chain/target/match by that name." >&2; exit 1; }
  [ ! -f "$state/$new" ] || { echo "iptables: File exists." >&2; exit 1; }
  sed -e "s/^-N $chain\$/-N $new/" -e "s/^-A $chain /-A $new /" "$file" >"$state/$new"
  rm "$file"
  for f in "$state"/*; do
    [ -f "$f" ] || continue
    sed -i -e "s/ -j $chain\$/ -j $new/" "$f"
  done
  exit 0
fi

if [ ! -f "$file" ]; then
  echo "iptables: No chain/target/match by that name." >&2
  exit 1
fi

case "$op" in
  -S)
    cat "$file"
    ;;
  -F)
    echo "-N $chain" >"$file"
    ;;
  -A)
    echo "-A $chain $*" >>"$file"
    ;;
  -I)
    pos=1
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
      pos="$1"
      shift
    fi
    line="-A $chain $*"
    # Line 1 is `-N CHAIN`; rule N is line N + 1.
    awk -v pos="$((pos + 1))" -v line="$line" '
      NR == pos { print line; done = 1 }
      { print }
      END { if (!done) print line }
    ' "$file" >"$file.tmp"
    mv "$file.tmp" "$file"
    ;;
  -C)
    grep -qxF -- "-A $chain $*" "$file" || {
      echo "iptables: Bad rule (does a matching rule exist in that chain?)." >&2
      exit 1
    }
    ;;
  -X)
    if grep -q '^-A ' "$file"; then
      echo "iptables: Directory not empty." >&2
      exit 1
    fi
    rm "$file"
    ;;
  -D)
    line="-A $chain $*"
    grep -qxF -- "$line" "$file" || {
      echo "iptables: Bad rule (does a matching rule exist in that chain?)." >&2
      exit 1
    }
    awk -v line="$line" '!done && $0 == line { done = 1; next } { print }' "$file" >"$file.tmp"
    mv "$file.tmp" "$file"
    ;;
  *)
    echo "fake iptables: unsupported $op" >&2
    exit 2
    ;;
esac
