#!/usr/bin/env bash
# A stand-in for `docker` in the agent's tests.
#
#   image inspect  exit 0 when FAKE_DOCKER_IMAGE_PRESENT=1, else 1
#   container inspect  print "running" and exit 0 when
#                  FAKE_DOCKER_CONTAINER_PRESENT=1; print the daemon's
#                  connection error and exit 1 when FAKE_DOCKER_DOWN=1;
#                  else "Error: No such container", exit 1
#   rm             echo, exit 0
#   pull           echo, exit 0
#   kill           append the container name to FAKE_DOCKER_KILL_LOG, exit 0
#   ps             append the argv to FAKE_DOCKER_PS_LOG, print FAKE_DOCKER_PS
#                  (container ids, one per line), exit 0
#   run ...        append the argv (one per line) to FAKE_DOCKER_ARGV_LOG,
#                  write FAKE_DOCKER_RESULT to <out>/result.json, a log to
#                  <out>/logs/host.log, a file named by its own sha256 with
#                  FAKE_DOCKER_FILE_CONTENT into <files>, print
#                  FAKE_DOCKER_OUTPUT_BYTES bytes of "x" and a newline when
#                  set, then "fake build output", sleep 5 when FAKE_DOCKER_SLEEP=1,
#                  with FAKE_DOCKER_PLANT=1 also a symlink named like a sha
#                  and a non-sha file in <files>, and result.json as a
#                  symlink to FAKE_DOCKER_RESULT_LINK when that is set,
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
  container)
    if [ "${2:-}" = "inspect" ] && [ "${FAKE_DOCKER_CONTAINER_PRESENT:-0}" = "1" ]; then
      echo running
      exit 0
    fi
    if [ "${FAKE_DOCKER_DOWN:-0}" = "1" ]; then
      echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock" >&2
      exit 1
    fi
    echo "Error: No such container: ${*: -1}" >&2
    exit 1
    ;;
  pull)
    echo "pulled ${2:-}"
    exit 0
    ;;
  ps)
    if [ -n "${FAKE_DOCKER_PS_LOG:-}" ]; then
      printf '%s\n' "$*" >>"$FAKE_DOCKER_PS_LOG"
    fi
    if [ -n "${FAKE_DOCKER_PS:-}" ]; then
      printf '%s\n' "$FAKE_DOCKER_PS"
    fi
    exit 0
    ;;
  kill)
    if [ -n "${FAKE_DOCKER_KILL_LOG:-}" ]; then
      printf '%s\n' "${2:-}" >>"$FAKE_DOCKER_KILL_LOG"
    fi
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

      if [ "${FAKE_DOCKER_PLANT:-0}" = "1" ]; then
        ln -s /etc/hostname "$files/$(printf '%064d' 0)"
        echo "not a sha" >"$files/README"
      fi
    fi

    if [ -n "$out" ] && [ -n "${FAKE_DOCKER_RESULT_LINK:-}" ]; then
      rm -f "$out/result.json"
      ln -s "$FAKE_DOCKER_RESULT_LINK" "$out/result.json"
    fi

    if [ -n "${FAKE_DOCKER_OUTPUT_BYTES:-}" ]; then
      head -c "$FAKE_DOCKER_OUTPUT_BYTES" /dev/zero | tr '\0' x
      echo
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
