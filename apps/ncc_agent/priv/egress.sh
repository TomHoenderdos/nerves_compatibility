#!/usr/bin/env bash
# The builder's egress ruleset for build containers (isolation design,
# section 3), in the rootful Docker daemon's DOCKER-USER chain.
#
#   egress.sh install   (re)write chain NCC-EGRESS and jump to it first
#                       from DOCKER-USER, and chain NCC-INPUT first from
#                       INPUT; IPv6 too when ip6tables has a DOCKER-USER
#                       chain
#   egress.sh verify    exit 0 only when the ruleset is in place, else
#                       print why and exit 1
#
# The chain is rebuilt as NCC-EGRESS-NEW and swapped in (jump inserted,
# old jump removed, old chain deleted, new chain renamed), so a build that
# runs during a reinstall never sees an empty chain.
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
#   2. DNS (udp/tcp 53) to the resolvers Docker hands the containers, one
#      pair per resolver, before the private-range drops on purpose: the
#      resolver is usually a private address (the VPC resolver), and DNS
#      is the one private destination a build needs. The resolvers are, in
#      order: NCC_DNS_SERVERS (space-separated, for operators and tests);
#      the `dns` list of /etc/docker/daemon.json; the usable `nameserver`
#      lines of /etc/resolv.conf; and, when the only one there is
#      127.0.0.53 (systemd-resolved), the "Current DNS Server" / "DNS
#      Servers" of `resolvectl status`. Each must be an IPv4 or IPv6
#      literal and not loopback, unspecified, link-local, multicast,
#      broadcast or v4-mapped. IPv4 ones go to iptables, IPv6 ones to
#      ip6tables. When none is found install fails before touching any
#      chain: DNS is never opened to any destination.
#   3. Drop RFC1918, CGNAT, link-local (IMDS) and loopback.
#   4. Accept TCP 443/80 to the Internet; drop everything else.
#
# NCC-EGRESS filters what the containers send through FORWARD. Traffic
# from a container to the builder host itself (172.17.0.1, the VM's own
# addresses) goes through INPUT instead: INPUT's first two rules send what
# arrives on docker0 or a br-* bridge to chain NCC-INPUT, which accepts
# established replies and DNS to the resolvers (the host may be one) and
# drops the rest, so nothing listening on the VM (sshd, whatever an
# operator adds) is reachable from a build. Traffic on any other interface
# never enters the chain. A daemon configured with another bridge name is
# not covered by it; FORWARD filtering does not depend on it.
#
# verify checks the whole policy, not just a few rules: the NCC-EGRESS jump
# is the first rule of DOCKER-USER, FORWARD jumps to DOCKER-USER, the chain
# is the conntrack accept, the DNS accepts, exactly the drops and the
# Internet accepts in order, then DROP, and nothing else; NCC-INPUT the
# same. With IPv6 enabled on the daemon's default bridge and no ip6tables
# DOCKER-USER chain to filter it, verify fails (NCC_DOCKER_BRIDGE_IPV6
# overrides the `docker network inspect` lookup; DOCKER the binary).
#
# IPTABLES / IP6TABLES / RESOLVECTL override the binaries, and
# NCC_DOCKER_DAEMON_JSON / NCC_RESOLV_CONF the files (tests stub them).
set -euo pipefail

IPTABLES="${IPTABLES:-iptables}"
IP6TABLES="${IP6TABLES:-ip6tables}"
RESOLVECTL="${RESOLVECTL:-resolvectl}"
DOCKER="${DOCKER:-docker}"
DAEMON_JSON="${NCC_DOCKER_DAEMON_JSON:-/etc/docker/daemon.json}"
RESOLV_CONF="${NCC_RESOLV_CONF:-/etc/resolv.conf}"
CHAIN=NCC-EGRESS
INPUT_CHAIN=NCC-INPUT

CONNTRACK="-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"

# Only plain addresses ever become rule words: a dotted quad of decimal
# octets 0-255 without leading zeros (which some parsers read as octal),
# or an IPv6 address in hex groups (no embedded dotted quad, no zone).
is_v4() {
  local octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])'
  [[ "$1" =~ ^$octet(\.$octet){3}$ ]]
}

# The eight groups of an IPv6 literal, each as four lowercase hex digits
# separated by `:`; fails when $1 is not one.
expand_v6() {
  local ip="${1,,}" head tail groups=() h=() t=() g out=()
  [[ "$ip" =~ ^[0-9a-f:]+$ ]] || return 1
  [[ "$ip" != *:::* ]] || return 1

  if [[ "$ip" == *::* ]]; then
    head="${ip%%::*}"
    tail="${ip#*::}"
    [[ "$tail" != *::* ]] || return 1
    [ -z "$head" ] || IFS=: read -r -a h <<<"$head"
    [ -z "$tail" ] || IFS=: read -r -a t <<<"$tail"
    [ $((${#h[@]} + ${#t[@]})) -le 7 ] || return 1
    groups=(${h[@]+"${h[@]}"})
    for ((g = ${#h[@]} + ${#t[@]}; g < 8; g++)); do groups+=(0); done
    groups+=(${t[@]+"${t[@]}"})
  else
    [[ "$ip" != :* && "$ip" != *: ]] || return 1
    IFS=: read -r -a groups <<<"$ip"
    [ ${#groups[@]} -eq 8 ] || return 1
  fi

  for g in "${groups[@]}"; do
    [[ "$g" =~ ^[0-9a-f]{1,4}$ ]] || return 1
    out+=("$(printf '%04x' "$((16#$g))")")
  done
  local IFS=:
  echo "${out[*]}"
}

is_v6() { expand_v6 "$1" >/dev/null; }

# A resolver a build container could never usefully (or safely) be sent
# to: loopback and unspecified are the builder itself, link-local is the
# metadata service, multicast and broadcast are not one resolver, and
# v4-mapped v6 would reach a v4 address the v4 chain never checked.
is_unusable() {
  local ip="$1" full
  if is_v4 "$ip"; then
    [[ "$ip" =~ ^(0|127)\. || "$ip" =~ ^169\.254\. ]] && return 0
    [ "${ip%%.*}" -ge 224 ] && return 0
    return 1
  fi
  full="$(expand_v6 "$ip")" || return 0
  case "$full" in
    0000:0000:0000:0000:0000:0000:0000:000[01]) return 0 ;; # :: and ::1
    0000:0000:0000:0000:0000:ffff:*) return 0 ;;            # v4-mapped
    fe[89ab]?:*) return 0 ;;                                # fe80::/10
    ff??:*) return 0 ;;                                     # multicast
  esac
  return 1
}

# The addresses (one per line) in the `"dns": [...]` list of daemon.json.
daemon_dns() {
  [ -r "$DAEMON_JSON" ] || return 0
  tr -d '\n' <"$DAEMON_JSON" |
    grep -oE '"dns"[[:space:]]*:[[:space:]]*\[[^]]*\]' |
    sed -E 's/^"dns"[[:space:]]*:[[:space:]]*\[//; s/\]$//' |
    tr ',' '\n' | tr -d ' "\t' || true
}

resolv_conf_dns() {
  [ -r "$RESOLV_CONF" ] || return 0
  awk '$1 == "nameserver" { print $2 }' "$RESOLV_CONF"
}

# "Current DNS Server: a" and "DNS Servers: a b" lines; a `#name` (DoT) or
# `%iface` suffix is dropped.
resolvectl_dns() {
  command -v "$RESOLVECTL" >/dev/null 2>&1 || return 0
  "$RESOLVECTL" status 2>/dev/null |
    grep -E '(Current DNS Server|DNS Servers?):' |
    sed -E 's/^[^:]*:[[:space:]]*//' | tr ' ' '\n' | sed -E 's/[#%].*$//' || true
}

# The resolvers the containers use, one per line, deduplicated; nothing
# when they cannot be determined.
resolvers() {
  local candidates=() line
  if [ -n "${NCC_DNS_SERVERS:-}" ]; then
    read -r -a candidates <<<"$NCC_DNS_SERVERS"
  else
    while IFS= read -r line; do [ -n "$line" ] && candidates+=("$line"); done < <(daemon_dns)

    if [ ${#candidates[@]} -eq 0 ]; then
      local from_conf=()
      while IFS= read -r line; do [ -n "$line" ] && from_conf+=("$line"); done < <(resolv_conf_dns)

      for line in "${from_conf[@]}"; do
        is_unusable "$line" || candidates+=("$line")
      done

      if [ ${#candidates[@]} -eq 0 ] && [ "${from_conf[*]}" = "127.0.0.53" ]; then
        while IFS= read -r line; do [ -n "$line" ] && candidates+=("$line"); done < <(resolvectl_dns)
      fi
    fi
  fi

  for line in ${candidates[@]+"${candidates[@]}"}; do
    if { is_v4 "$line" || is_v6 "$line"; } && ! is_unusable "$line"; then
      echo "$line"
    fi
  done | awk '!seen[$0]++'
}

DNS_V4=()
DNS_V6=()

# Fills DNS_V4 / DNS_V6 with the per-resolver accepts. With no usable
# resolver install stops here, before its first iptables call, so the live
# ruleset (if any) stays as it was and none is half-built: port 53 is
# never opened to any destination or range instead, since a build can do
# nothing without DNS anyway and an open port 53 is a tunnel out of the
# sandbox. The agent then claims nothing until an install succeeds.
dns_rules() {
  local found=0 ip
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    found=1
    if is_v4 "$ip"; then
      DNS_V4+=("-d $ip/32 -p udp --dport 53 -j ACCEPT" "-d $ip/32 -p tcp --dport 53 -j ACCEPT")
    else
      DNS_V6+=("-d $ip/128 -p udp --dport 53 -j ACCEPT" "-d $ip/128 -p tcp --dport 53 -j ACCEPT")
    fi
  done < <(resolvers)

  if [ "$found" = 0 ]; then
    echo "egress: no DNS resolver found (NCC_DNS_SERVERS, the dns list of $DAEMON_JSON," \
      "the nameservers of $RESOLV_CONF, resolvectl); not installing. Set NCC_DNS_SERVERS." >&2
    exit 1
  fi
}

# The private drops and the Internet accepts, after the conntrack accept
# and the DNS accepts.
V4_TAIL=(
  "-d 10.0.0.0/8 -j DROP"
  "-d 172.16.0.0/12 -j DROP"
  "-d 192.168.0.0/16 -j DROP"
  "-d 100.64.0.0/10 -j DROP"
  "-d 169.254.0.0/16 -j DROP"
  "-d 127.0.0.0/8 -j DROP"
  "-p tcp --dport 443 -j ACCEPT"
  "-p tcp --dport 80 -j ACCEPT"
)

V6_TAIL=(
  "-d fc00::/7 -j DROP"
  "-d fe80::/10 -j DROP"
  "-d ::1/128 -j DROP"
  "-p tcp --dport 443 -j ACCEPT"
  "-p tcp --dport 80 -j ACCEPT"
)

# The INPUT side (IPv4 only: the default bridge's v6 is the ip6tables
# DOCKER-USER case, and containers reach the host over v4). Only bridge
# traffic is sent to the chain, by these jump matches, so its final DROP
# never touches the operator's ssh or the portal's answers.
INPUT_JUMPS=("-i docker0" "-i br-+")
EGRESS_JUMPS=("")

# build_chain BIN CHAIN TERMINAL RULE...: (re)create CHAIN with exactly
# RULE... then `-j TERMINAL`. The terminal rule goes in first and the rest
# are inserted above it, so the chain never ends in an open fall-through.
build_chain() {
  local bin="$1" chain="$2" terminal="$3"
  shift 3

  if "$bin" -w 10 -S "$chain" >/dev/null 2>&1; then
    "$bin" -w 10 -F "$chain"
  else
    "$bin" -w 10 -N "$chain"
  fi

  "$bin" -w 10 -A "$chain" -j "$terminal"
  local pos=1 rule
  for rule in "$@"; do
    # shellcheck disable=SC2086 # each rule is a list of iptables words
    "$bin" -w 10 -I "$chain" "$pos" $rule
    pos=$((pos + 1))
  done
}

# remove_jumps BIN PARENT TARGET JUMP...: every `-A PARENT JUMP -j TARGET`.
remove_jumps() {
  local bin="$1" parent="$2" target="$3"
  shift 3
  local jump
  for jump in "$@"; do
    # shellcheck disable=SC2086 # a jump is a list of iptables words, or empty
    while "$bin" -w 10 -C "$parent" $jump -j "$target" >/dev/null 2>&1; do
      "$bin" -w 10 -D "$parent" $jump -j "$target"
    done
  done
}

# drop_chain BIN CHAIN: flush and delete CHAIN when it exists.
drop_chain() {
  local bin="$1" chain="$2"
  if "$bin" -w 10 -S "$chain" >/dev/null 2>&1; then
    "$bin" -w 10 -F "$chain"
    "$bin" -w 10 -X "$chain"
  fi
}

# recover_chain BIN PARENT CHAIN JUMP...: a CHAIN-NEW left by an install
# that died mid-swap. If PARENT already jumps to it, the swap is finished
# (it is the live chain: never flushed); otherwise it is removed. Either
# way the next build starts from one CHAIN and no -NEW.
recover_chain() {
  local bin="$1" parent="$2" chain="$3"
  shift 3
  local new="$chain-NEW"

  "$bin" -w 10 -S "$new" >/dev/null 2>&1 || return 0

  # Read first, grep after: with pipefail a `grep -q` that closes the pipe
  # early would fail the pipeline and send a live chain down the else branch.
  local parent_rules
  parent_rules="$("$bin" -w 10 -S "$parent" 2>/dev/null || true)"
  if grep -qF -- "-j $new" <<<"$parent_rules"; then
    echo "egress: finishing a swap to $new an earlier install left behind"
    remove_jumps "$bin" "$parent" "$chain" "$@"
    drop_chain "$bin" "$chain"
    "$bin" -w 10 -E "$new" "$chain"
  else
    echo "egress: removing a stale $new an earlier install left behind"
    drop_chain "$bin" "$new"
  fi
}

# swap_chain BIN PARENT CHAIN JUMP...: CHAIN-NEW is built; make PARENT
# jump to it first (one rule per JUMP match, in order), drop the jumps to
# and the old CHAIN, and rename CHAIN-NEW to CHAIN (the kernel follows the
# rename in PARENT). A build running during the swap is filtered by one
# chain or the other at every moment.
swap_chain() {
  local bin="$1" parent="$2" chain="$3"
  shift 3
  local new="$chain-NEW" i
  for ((i = $#; i >= 1; i--)); do
    # shellcheck disable=SC2086 # a jump is a list of iptables words, or empty
    "$bin" -w 10 -I "$parent" 1 ${!i} -j "$new"
  done
  remove_jumps "$bin" "$parent" "$chain" "$@"
  drop_chain "$bin" "$chain"
  "$bin" -w 10 -E "$new" "$chain"
}

# install_family BIN RULE...
install_family() {
  local bin="$1"
  shift

  if ! "$bin" -w 10 -S DOCKER-USER >/dev/null 2>&1; then
    echo "$bin: no DOCKER-USER chain (is the Docker daemon running?)" >&2
    return 1
  fi

  recover_chain "$bin" DOCKER-USER "$CHAIN" "${EGRESS_JUMPS[@]}"
  build_chain "$bin" "$CHAIN-NEW" DROP "$@"
  swap_chain "$bin" DOCKER-USER "$CHAIN" "${EGRESS_JUMPS[@]}"
}

# install_input BIN DNS_RULE...
install_input() {
  local bin="$1"
  shift

  if ! "$bin" -w 10 -S INPUT >/dev/null 2>&1; then
    echo "$bin: no INPUT chain" >&2
    return 1
  fi

  recover_chain "$bin" INPUT "$INPUT_CHAIN" "${INPUT_JUMPS[@]}"
  build_chain "$bin" "$INPUT_CHAIN-NEW" DROP "$CONNTRACK" "$@"
  swap_chain "$bin" INPUT "$INPUT_CHAIN" "${INPUT_JUMPS[@]}"
}

# Real iptables prints what it was given with the implicit match modules
# spelled out (`-p tcp -m tcp --dport 443`); drop those so a rule reads as
# it was written. The conntrack states come back in either order.
normalise() {
  sed -E 's/ -m (tcp|udp) --dport/ --dport/; s/RELATED,ESTABLISHED/ESTABLISHED,RELATED/'
}

# A DNS accept as install writes it: to one resolver (-d x/32 or x/128).
# One to any destination or to a range, which an older install wrote when
# it found no resolver, is not, so verify fails on it and the slot
# reinstalls.
dns_accept() {
  [[ "$1" =~ ^-A\ [A-Z-]+\ -d\ ([0-9.]+/32|[0-9A-Fa-f:]+/128)\ -p\ (udp|tcp)\ --dport\ 53\ -j\ ACCEPT$ ]]
}

# verify_chain BIN PARENT CHAIN TERMINAL JUMPS_VAR TAIL_RULE...: the
# parent's first rules are the jumps to CHAIN (one per entry of the array
# named JUMPS_VAR, in order), and CHAIN is the conntrack accept, then only
# DNS accepts (any number, to port 53 only), then exactly TAIL_RULE... in
# order, then `-j TERMINAL`.
verify_chain() {
  local bin="$1" parent="$2" chain="$3" terminal="$4" jumps_var="$5"
  shift 5
  # A nameref: bash 4.3+ (Ubuntu 24.04 ships 5.2).
  local -n jumps="$jumps_var"
  local parent_rules rules rest expected rule line jump

  if ! parent_rules="$("$bin" -w 10 -S "$parent" 2>&1)"; then
    echo "$bin: no $parent chain: $parent_rules"
    return 1
  fi

  expected=""
  for jump in "${jumps[@]}"; do
    expected+="-A $parent${jump:+ $jump} -j $chain"$'\n'
  done
  expected="${expected%$'\n'}"

  if [ "$(grep -E '^-A ' <<<"$parent_rules" | head -n "${#jumps[@]}" || true)" != "$expected" ]; then
    echo "$bin: the first rule(s) of $parent are not the jump(s) to $chain"
    return 1
  fi

  if ! rules="$("$bin" -w 10 -S "$chain" 2>&1)"; then
    echo "$bin: no $chain chain: $rules"
    return 1
  fi

  rules="$(grep -E '^-A ' <<<"$rules" | normalise || true)"

  if [ "$(head -n 1 <<<"$rules")" != "-A $chain $CONNTRACK" ]; then
    echo "$bin: the first rule of $chain is not the ESTABLISHED,RELATED accept"
    return 1
  fi

  rest="$(tail -n +2 <<<"$rules")"
  while IFS= read -r line; do
    dns_accept "$line" || break
    rest="$(tail -n +2 <<<"$rest")"
  done <<<"$rest"

  expected=""
  for rule in "$@" "-j $terminal"; do
    expected+="-A $chain $rule"$'\n'
  done
  expected="${expected%$'\n'}"

  if [ "$rest" != "$expected" ]; then
    echo "$bin: $chain is not the policy after its DNS accepts (expected, then found):"
    echo "$expected"
    echo "---"
    echo "$rest"
    return 1
  fi
}

# verify_family BIN TAIL_RULE...
verify_family() {
  local bin="$1"
  shift
  local forward

  if ! forward="$("$bin" -w 10 -S FORWARD 2>&1)"; then
    echo "$bin: no FORWARD chain: $forward"
    return 1
  fi

  if ! grep -qxF -- "-A FORWARD -j DOCKER-USER" <<<"$forward"; then
    echo "$bin: FORWARD does not jump to DOCKER-USER (is the Docker daemon running?)"
    return 1
  fi

  verify_chain "$bin" DOCKER-USER "$CHAIN" DROP EGRESS_JUMPS "$@"
}

ip6_present() {
  if "$IP6TABLES" -w 10 -S DOCKER-USER >/dev/null 2>&1; then
    return 0
  fi
  echo "egress: ip6tables DOCKER-USER chain not present, v6 rules skipped"
  return 1
}

# Without an ip6tables DOCKER-USER chain nothing filters IPv6, so the
# daemon's default bridge must not have it: ask docker, unless
# NCC_DOCKER_BRIDGE_IPV6 says. Anything but "false" fails closed.
bridge_ipv6() {
  if [ -n "${NCC_DOCKER_BRIDGE_IPV6:-}" ]; then
    echo "$NCC_DOCKER_BRIDGE_IPV6"
  elif command -v "$DOCKER" >/dev/null 2>&1; then
    "$DOCKER" network inspect bridge -f '{{.EnableIPv6}}' 2>/dev/null || echo unknown
  else
    echo unknown
  fi
}

verify_ipv6_unfiltered_ok() {
  local v6
  v6="$(bridge_ipv6)"
  if [ "$v6" != "false" ]; then
    echo "egress: IPv6 is '$v6' on the default bridge and ip6tables has no DOCKER-USER chain to filter it"
    return 1
  fi
}

case "${1:-}" in
  install)
    dns_rules
    install_family "$IPTABLES" "$CONNTRACK" ${DNS_V4[@]+"${DNS_V4[@]}"} "${V4_TAIL[@]}"
    install_input "$IPTABLES" ${DNS_V4[@]+"${DNS_V4[@]}"}
    if ip6_present; then
      install_family "$IP6TABLES" "$CONNTRACK" ${DNS_V6[@]+"${DNS_V6[@]}"} "${V6_TAIL[@]}"
    fi
    echo "egress ruleset installed"
    ;;
  verify)
    verify_family "$IPTABLES" "${V4_TAIL[@]}"
    verify_chain "$IPTABLES" INPUT "$INPUT_CHAIN" DROP INPUT_JUMPS
    if ip6_present; then
      verify_family "$IP6TABLES" "${V6_TAIL[@]}"
    else
      verify_ipv6_unfiltered_ok
    fi
    echo "egress ruleset in place"
    ;;
  *)
    echo "usage: $0 install|verify" >&2
    exit 2
    ;;
esac
