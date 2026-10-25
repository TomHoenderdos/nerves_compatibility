#!/usr/bin/env bash
# The builder's egress ruleset for build containers (isolation design,
# section 3), in the rootful Docker daemon's DOCKER-USER chain.
#
#   egress.sh install   (re)write chain NCC-EGRESS and jump to it first
#                       from DOCKER-USER; IPv6 too when ip6tables has a
#                       DOCKER-USER chain
#   egress.sh verify    exit 0 only when the ruleset is in place, else
#                       print why and exit 1
#
# Container traffic only (DOCKER-USER sees forwarded packets): DNS is
# accepted before the private-range drops on purpose, since the VM's
# resolver is usually a private address; then RFC1918, CGNAT, link-local
# (IMDS) and loopback are dropped, TCP 80/443 to the Internet accepted and
# everything else dropped. Return traffic is Docker's own chains' job.
#
# IPTABLES / IP6TABLES override the binaries (tests stub them).
set -euo pipefail

IPTABLES="${IPTABLES:-iptables}"
IP6TABLES="${IP6TABLES:-ip6tables}"
CHAIN=NCC-EGRESS

V4_RULES=(
  "-p udp --dport 53 -j ACCEPT"
  "-p tcp --dport 53 -j ACCEPT"
  "-d 10.0.0.0/8 -j DROP"
  "-d 172.16.0.0/12 -j DROP"
  "-d 192.168.0.0/16 -j DROP"
  "-d 100.64.0.0/10 -j DROP"
  "-d 169.254.0.0/16 -j DROP"
  "-d 127.0.0.0/8 -j DROP"
  "-p tcp --dport 443 -j ACCEPT"
  "-p tcp --dport 80 -j ACCEPT"
)

V6_RULES=(
  "-p udp --dport 53 -j ACCEPT"
  "-p tcp --dport 53 -j ACCEPT"
  "-d fc00::/7 -j DROP"
  "-d fe80::/10 -j DROP"
  "-d ::1/128 -j DROP"
  "-p tcp --dport 443 -j ACCEPT"
  "-p tcp --dport 80 -j ACCEPT"
)

V4_REQUIRED=("-d 169.254.0.0/16 -j DROP" "-d 10.0.0.0/8 -j DROP")
V6_REQUIRED=("-d fc00::/7 -j DROP" "-d fe80::/10 -j DROP")

# install_family BIN RULE...
install_family() {
  local bin="$1"
  shift

  if ! "$bin" -w -S DOCKER-USER >/dev/null 2>&1; then
    echo "$bin: no DOCKER-USER chain (is the Docker daemon running?)" >&2
    return 1
  fi

  if ! "$bin" -w -S "$CHAIN" >/dev/null 2>&1; then
    "$bin" -w -N "$CHAIN"
  fi

  # The final DROP goes in first and the rest are inserted above it, so
  # the rewritten chain never ends in an open fall-through for longer
  # than the flush itself.
  "$bin" -w -F "$CHAIN"
  "$bin" -w -A "$CHAIN" -j DROP
  local pos=1 rule
  for rule in "$@"; do
    # shellcheck disable=SC2086 # each rule is a list of iptables words
    "$bin" -w -I "$CHAIN" "$pos" $rule
    pos=$((pos + 1))
  done

  if ! "$bin" -w -C DOCKER-USER -j "$CHAIN" >/dev/null 2>&1; then
    "$bin" -w -I DOCKER-USER 1 -j "$CHAIN"
  fi
}

# verify_family BIN REQUIRED_RULE...
verify_family() {
  local bin="$1"
  shift
  local docker_user chain rule last

  if ! docker_user="$("$bin" -w -S DOCKER-USER 2>&1)"; then
    echo "$bin: no DOCKER-USER chain: $docker_user"
    return 1
  fi

  if ! grep -qF -- "-j $CHAIN" <<<"$docker_user"; then
    echo "$bin: DOCKER-USER does not jump to $CHAIN"
    return 1
  fi

  if ! chain="$("$bin" -w -S "$CHAIN" 2>&1)"; then
    echo "$bin: no $CHAIN chain: $chain"
    return 1
  fi

  for rule in "$@"; do
    if ! grep -qxF -- "-A $CHAIN $rule" <<<"$chain"; then
      echo "$bin: $CHAIN lacks '$rule'"
      return 1
    fi
  done

  last="$(tail -n 1 <<<"$chain")"
  if [ "$last" != "-A $CHAIN -j DROP" ]; then
    echo "$bin: $CHAIN does not end in '-j DROP'"
    return 1
  fi
}

ip6_present() {
  "$IP6TABLES" -w -S DOCKER-USER >/dev/null 2>&1
}

case "${1:-}" in
  install)
    install_family "$IPTABLES" "${V4_RULES[@]}"
    if ip6_present; then
      install_family "$IP6TABLES" "${V6_RULES[@]}"
    fi
    echo "egress ruleset installed"
    ;;
  verify)
    verify_family "$IPTABLES" "${V4_REQUIRED[@]}"
    if ip6_present; then
      verify_family "$IP6TABLES" "${V6_REQUIRED[@]}"
    fi
    echo "egress ruleset in place"
    ;;
  *)
    echo "usage: $0 install|verify" >&2
    exit 2
    ;;
esac
