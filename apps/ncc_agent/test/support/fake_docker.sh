#!/usr/bin/env bash
# A stand-in for `docker` in the agent's tests.
#
#   image inspect  exit 0 when FAKE_DOCKER_IMAGE_PRESENT=1, else 1
#   pull           echo, exit 0
#   kill           exit 0
#   run ...        append the argv (one per line) to FAKE_DOCKER_ARGV_LOG,
#                  write FAKE_DOCKER_RESULT to <out>/result.json, a log to
#                  <out>/logs/host.log, a file named by its own sha256 with
#                  FAKE_DOCKER_FILE_CONTENT into <files>, print
#                  "fake build output", sleep 5 when FAKE_DOCKER_SLEEP=1,
#                  exit FAKE_DOCKER_EXIT (default 0)
#   anything else  echo, exit 0
set -euo pipefail

case "${1:-}" in
  image)
    if [ "${2:-}" = "inspect" ] && [ "${FAKE_DOCKER_IMAGE_PRESENT:-0}" = "1" ]; then
      exit 0
    fi
    exit 1
    ;;
  pull)
    echo "pulled ${2:-}"
    exit 0
    ;;
  kill)
    exit 0
    ;;
  run)
    if [ -n "${FAKE_DOCKER_ARGV_LOG:-}" ]; then
      printf '%s\n' "$@" >>"$FAKE_DOCKER_ARGV_LOG"
    fi

    out=""
    files=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--mount" ]; then
        source=""
        target=""
        IFS=',' read -r -a parts <<<"$arg"
        for part in "${parts[@]}"; do
          case "$part" in
            source=*) source="${part#source=}" ;;
            target=*) target="${part#target=}" ;;
          esac
        done
        case "$target" in
          /out) out="$source" ;;
          /files) files="$source" ;;
        esac
      fi
      prev="$arg"
    done

    if [ -n "$out" ]; then
      result="${FAKE_DOCKER_RESULT:-}"
      printf '%s' "${result:-"{}"}" >"$out/result.json"
      mkdir -p "$out/logs"
      echo "host build log" >"$out/logs/host.log"
    fi

    if [ -n "$files" ]; then
      content="${FAKE_DOCKER_FILE_CONTENT:-fake artifact}"
      sha=$(printf '%s' "$content" | sha256sum | cut -d' ' -f1)
      printf '%s' "$content" >"$files/$sha"
    fi

    echo "fake build output"

    if [ "${FAKE_DOCKER_SLEEP:-0}" = "1" ]; then
      sleep 5
    fi

    exit "${FAKE_DOCKER_EXIT:-0}"
    ;;
  *)
    echo "$@"
    exit 0
    ;;
esac
