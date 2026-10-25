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
# Order of NCC-EGRESS:
#
#   1. -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT, first, always.
#      FORWARD jumps to DOCKER-USER before Docker's own
#      `-o docker0 --ctstate RELATED,ESTABLISHED -j ACCEPT`, so replies to
#      the containers cross this chain too. A SYN-ACK from x:443 back to
#      172.17.0.2 matches `-d 172.16.0.0/12 -j DROP`, and a DNS answer
#      does too. Without this accept no build could finish a TCP handshake
#      or a lookup. It only lets through packets of connections that a
#      later rule already allowed out (a builder publishes no ports).
#   2. DNS (udp/tcp 53), before the private-range drops on purpose: the
#      VM's resolver is usually a private address (127.0.0.53, the VPC
#      resolver), and DNS is the one private destination a build needs.
#   3. Drop RFC1918, CGNAT, link-local (IMDS) and loopback.
#   4. Accept TCP 443/80 to the Internet; drop everything else.
#
# IPTABLES / IP6TABLES override the binaries (tests stub them).
set -euo pipefail

IPTABLES="${IPTABLES:-iptables}"
IP6TABLES="${IP6TABLES:-ip6tables}"
CHAIN=NCC-EGRESS

CONNTRACK="-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"

V4_RULES=(
  "$CONNTRACK"
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
  "$CONNTRACK"
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

  if ! "$bin" -w 10 -S DOCKER-USER >/dev/null 2>&1; then
    echo "$bin: no DOCKER-USER chain (is the Docker daemon running?)" >&2
    return 1
  fi

  if ! "$bin" -w 10 -S "$CHAIN" >/dev/null 2>&1; then
    "$bin" -w 10 -N "$CHAIN"
  fi

  # The final DROP goes in first and the rest are inserted above it, so
  # the rewritten chain never ends in an open fall-through for longer
  # than the flush itself.
  "$bin" -w 10 -F "$CHAIN"
  "$bin" -w 10 -A "$CHAIN" -j DROP
  local pos=1 rule
  for rule in "$@"; do
    # shellcheck disable=SC2086 # each rule is a list of iptables words
    "$bin" -w 10 -I "$CHAIN" "$pos" $rule
    pos=$((pos + 1))
  done

  if ! "$bin" -w 10 -C DOCKER-USER -j "$CHAIN" >/dev/null 2>&1; then
    "$bin" -w 10 -I DOCKER-USER 1 -j "$CHAIN"
  fi
}

# verify_family BIN REQUIRED_RULE...
verify_family() {
  local bin="$1"
  shift
  local docker_user chain rule first last

  if ! docker_user="$("$bin" -w 10 -S DOCKER-USER 2>&1)"; then
    echo "$bin: no DOCKER-USER chain: $docker_user"
    return 1
  fi

  if ! grep -qF -- "-j $CHAIN" <<<"$docker_user"; then
    echo "$bin: DOCKER-USER does not jump to $CHAIN"
    return 1
  fi

  if ! chain="$("$bin" -w 10 -S "$CHAIN" 2>&1)"; then
    echo "$bin: no $CHAIN chain: $chain"
    return 1
  fi

  # Rule 1 (line 2, after `-N`) must be the conntrack accept; iptables-nft
  # prints the states as RELATED,ESTABLISHED.
  first="$(sed -n 2p <<<"$chain")"
  case "$first" in
    "-A $CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT" | \
      "-A $CHAIN -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT") ;;
    *)
      echo "$bin: the first rule of $CHAIN is not the ESTABLISHED,RELATED accept"
      return 1
      ;;
  esac

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
  if "$IP6TABLES" -w 10 -S DOCKER-USER >/dev/null 2>&1; then
    return 0
  fi
  echo "egress: ip6tables DOCKER-USER chain not present, v6 rules skipped"
  return 1
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
