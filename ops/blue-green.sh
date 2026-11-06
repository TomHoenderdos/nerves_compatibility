#!/bin/bash
# Blue/green deploys of the web host's portal, sourced by ops/deploy.sh (portal
# mode, NCC_BLUE_GREEN=1) and ops/portal-rpc.sh. Two release directories under
# $NCC_INSTALL_DIR/releases/{blue,green}, two systemd instances
# (ncc-portal@blue on 4002, ncc-portal@green on 4003), and one Apache include,
# $NCC_APACHE_UPSTREAM, naming the port that serves.
#
# The include is the truth about which colour serves; active-color is a cache
# for people and tools. Every deploy starts by checking that the two agree and
# that the idle colour is not running, because the one thing this must never
# do is build into the directory of a running release.
#
# See the design note "Zero-downtime web host deploy" in the operator docs.

BG_UNIT=${BG_UNIT:-ncc-portal}

bg_port() { case $1 in blue) echo 4002 ;; green) echo 4003 ;; *) return 1 ;; esac; }
bg_other() { case $1 in blue) echo green ;; green) echo blue ;; *) return 1 ;; esac; }
bg_color_of_port() { case $1 in 4002) echo blue ;; 4003) echo green ;; *) return 1 ;; esac; }

bg_serving_color() {
  local ports count color
  if [[ ! -r $NCC_APACHE_UPSTREAM ]]; then
    echo "ERROR: $NCC_APACHE_UPSTREAM is missing or unreadable" >&2
    return 1
  fi
  ports=$(grep -oE '127\.0\.0\.1:[0-9]+' "$NCC_APACHE_UPSTREAM" | cut -d: -f2 | sort -u || true)
  count=$(grep -c . <<<"$ports" || true)
  if [[ $count -ne 1 ]]; then
    echo "ERROR: $NCC_APACHE_UPSTREAM names ${count} distinct backend port(s); expected exactly one" >&2
    return 1
  fi
  if ! color=$(bg_color_of_port "$ports"); then
    echo "ERROR: $NCC_APACHE_UPSTREAM points at port $ports, which is neither colour's" >&2
    return 1
  fi
  printf '%s\n' "$color"
}

bg_public_host() {
  (
    set -a
    # shellcheck source=/dev/null
    . "$NCC_PORTAL_ENV"
    printf '%s\n' "${PHX_HOST:?PHX_HOST is not set in $NCC_PORTAL_ENV}"
  )
}

# The file of the :443 name-based vhost for $1, from `apachectl -S`. A host
# sharing :443 with other name-based vhosts prints "port 443 namevhost <host>
# (<file>:<line>)", once per protocol (IPv4 and IPv6); the first match's exit
# handles that. A host alone on its address:port instead prints a flat
# "<address>:443 <host> (<file>:<line>)" line with no "namevhost" at all.
bg_vhost_file() {
  apachectl -S 2>/dev/null |
    awk -v h="$1" '
      $1 == "port" && $2 == "443" && $3 == "namevhost" && $4 == h { print $5; exit }
      $1 ~ /:443$/ && $2 == h { print $3; exit }
    ' |
    tr -d '()' | sed -E 's/:[0-9]+$//'
}

bg_write_include() {
  sed "s/@PORT@/$1/g" "$NCC_SRC_DIR/ops/ncc-upstream.conf.template" > "$NCC_APACHE_UPSTREAM.new"
  mv "$NCC_APACHE_UPSTREAM.new" "$NCC_APACHE_UPSTREAM"
}

bg_preflight() {
  local cached host vhost
  BG_ACTIVE=$(bg_serving_color) || return 1
  BG_IDLE=$(bg_other "$BG_ACTIVE")
  cached=$(cat "$NCC_INSTALL_DIR/active-color" 2>/dev/null || true)
  if [[ $cached != "$BG_ACTIVE" ]]; then
    echo "refusing: $NCC_APACHE_UPSTREAM serves $BG_ACTIVE but $NCC_INSTALL_DIR/active-color says '$cached'." >&2
    echo "A deploy stopped between the switch and the cache write. Check which colour answers /health through Apache, write it to active-color, and deploy again." >&2
    return 1
  fi
  if systemctl is-active --quiet "$BG_UNIT@$BG_IDLE"; then
    echo "refusing: $BG_UNIT@$BG_IDLE is running but not serving (left from an incomplete deploy); look at it, stop it, then deploy again" >&2
    return 1
  fi
  host=$(bg_public_host) || return 1
  vhost=$(bg_vhost_file "$host")
  if [[ -z $vhost ]] || ! bg_includes_upstream "$vhost"; then
    echo "refusing: the :443 vhost of $host (${vhost:-not found by apachectl -S}) does not Include $NCC_APACHE_UPSTREAM; was it regenerated?" >&2
    return 1
  fi
}

# True if $1 (a vhost file) has an uncommented "Include $NCC_APACHE_UPSTREAM"
# line: optional leading whitespace, the literal directive "Include" (not
# "IncludeOptional", not "#Include"), whitespace, the path optionally
# double-quoted, optional trailing whitespace.
bg_includes_upstream() {
  awk -v path="$NCC_APACHE_UPSTREAM" '
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      if (line !~ /^Include[ \t]+/) next
      sub(/^Include[ \t]+/, "", line)
      sub(/^"/, "", line)
      sub(/"$/, "", line)
      if (line == path) { found = 1; exit }
    }
    END { exit !found }
  ' "$1"
}
