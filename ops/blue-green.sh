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
  local port=$1 status
  sed "s/@PORT@/$port/g" "$NCC_SRC_DIR/ops/ncc-upstream.conf.template" > "$NCC_APACHE_UPSTREAM.new"
  status=$?
  if ((status != 0)) || [[ ! -s "$NCC_APACHE_UPSTREAM.new" ]] ||
     ! grep -q "127\.0\.0\.1:$port" "$NCC_APACHE_UPSTREAM.new"; then
    echo "ERROR: rendering the include for port $port failed (sed exit $status, or the result is empty or missing the backend address); leaving the old include in place" >&2
    rm -f "$NCC_APACHE_UPSTREAM.new"
    return 1
  fi
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

BG_IDLE_HEALTH_SECONDS=${BG_IDLE_HEALTH_SECONDS:-60}
BG_APACHE_HEALTH_SECONDS=${BG_APACHE_HEALTH_SECONDS:-30}
BG_WATCH_SECONDS=${BG_WATCH_SECONDS:-30}
BG_DRAIN_CAP_SECONDS=${BG_DRAIN_CAP_SECONDS:-600}
BG_BIND_SECONDS=${BG_BIND_SECONDS:-15}
# Paused and resumed on one node only: without local_only Oban broadcasts the
# pause to every node, the colour that just took over included.
BG_PAUSE_EXPR='Oban.pause_all_queues(Oban, local_only: true)'
BG_RESUME_EXPR='Oban.resume_all_queues(Oban, local_only: true)'
BG_RUNNING_EXPR='IO.puts(Oban.check_all_queues(Oban) |> Enum.map(&length(&1.running)) |> Enum.sum())'
BG_RUNNING_IDS_EXPR='IO.puts(inspect(Oban.check_all_queues(Oban) |> Enum.flat_map(& &1.running)))'

bg_release() { printf '%s\n' "$NCC_INSTALL_DIR/releases/$1"; }

bg_build() { "$NCC_INSTALL_DIR/build-release.sh" "$(bg_release "$1")"; }

# rpc/eval as the service user, in the colour's own node name and tmp dir.
bg_as_ncc() { # color command expr
  local color=$1
  sudo -u ncc bash -c 'cd "$1" && set -a && . "$2" && . "$3" && set +a && "$4" "$5" "$6"' -- \
    "$NCC_PORTAL_WORKDIR" "$NCC_PORTAL_ENV" "$(dirname "$NCC_PORTAL_ENV")/color-$color.env" \
    "$(bg_release "$color")/bin/portal" "$2" "$3"
}
bg_rpc() { bg_as_ncc "$1" rpc "$2"; }
bg_migrate() {
  bg_as_ncc "$1" eval 'Ecto.Migrator.with_repo(Portal.Repo, &Ecto.Migrator.run(&1, :up, all: true))'
}

# The serving release's own digested files (its cache_manifest.json "latest"),
# copied into the new release without overwriting: a page the old colour
# rendered keeps loading its app-<digest>.js from the new one. Only the
# manifest's files, never the whole directory, so what a release carried from
# its own predecessor is not carried again.
bg_carry_assets() {
  python3 - "$(bg_release "$1")" "$(bg_release "$2")" <<'PY'
import glob, json, os, shutil, sys

def static(release):
    found = glob.glob(os.path.join(release, "lib", "portal-*", "priv", "static"))
    if len(found) != 1:
        sys.exit(f"expected one portal priv/static under {release}, found {len(found)}")
    return found[0]

src, dst = static(sys.argv[1]), static(sys.argv[2])
with open(os.path.join(src, "cache_manifest.json")) as f:
    latest = json.load(f).get("latest", {})
copied = 0
for digested in latest.values():
    for name in (digested, digested + ".gz"):
        a, b = os.path.join(src, name), os.path.join(dst, name)
        if os.path.isfile(a) and not os.path.exists(b):
            os.makedirs(os.path.dirname(b), exist_ok=True)
            shutil.copy2(a, b)
            copied += 1
print(f"carried {copied} digested asset file(s) from the serving release")
PY
}

bg_health_ok() { # body sha-or-empty color
  [[ $1 == *"\"color\":\"$3\""* ]] || return 1
  [[ -z $2 || $1 == *"\"sha\":\"$2\""* ]]
}

bg_wait_idle_health() { # color sha seconds
  local port host body i
  port=$(bg_port "$1")
  host=$(bg_public_host) || return 1
  for ((i = 0; i < $3; i += 2)); do
    body=$(curl -s --max-time 5 -H "Host: $host" -H 'X-Forwarded-Proto: https' \
      "http://127.0.0.1:$port/health" || true)
    bg_health_ok "$body" "$2" "$1" && return 0
    sleep 2
  done
  echo "$BG_UNIT@$1 did not answer /health with sha ${2:-any} within $3 s (last: ${body:0:200})" >&2
  return 1
}

# Through Apache and its TLS vhost, by the public name: the vhost listens on
# the public address, not loopback.
bg_wait_apache_health() { # color sha-or-empty seconds
  local host body i
  host=$(bg_public_host) || return 1
  for ((i = 0; i < $3; i += 2)); do
    body=$(curl -s --max-time 5 "https://$host/health" || true)
    bg_health_ok "$body" "$2" "$1" && return 0
    sleep 2
  done
  echo "Apache did not route /health to $1 (sha ${2:-any}) within $3 s (last: ${body:0:200})" >&2
  return 1
}

bg_fail_idle() { # color what
  echo "deploy failed at: $2; stopping $BG_UNIT@$1 (the serving colour is untouched)" >&2
  journalctl -u "$BG_UNIT@$1" -n 50 --no-pager >&2 || true
  systemctl stop "$BG_UNIT@$1" || true
}

bg_point_apache_at() { # color; fails with the include restored
  local out
  cp "$NCC_APACHE_UPSTREAM" "$NCC_APACHE_UPSTREAM.bak" || return 1
  if ! bg_write_include "$(bg_port "$1")"; then
    mv "$NCC_APACHE_UPSTREAM.bak" "$NCC_APACHE_UPSTREAM"
    return 1
  fi
  if ! out=$(apachectl configtest 2>&1); then
    echo "apachectl configtest failed (it checks every vhost on this host, not only ours):" >&2
    echo "$out" >&2
    mv "$NCC_APACHE_UPSTREAM.bak" "$NCC_APACHE_UPSTREAM"
    return 1
  fi
  if ! systemctl reload apache2; then
    echo "systemctl reload apache2 failed; restoring the include" >&2
    mv "$NCC_APACHE_UPSTREAM.bak" "$NCC_APACHE_UPSTREAM"
    systemctl reload apache2 || true
    return 1
  fi
}

# Chained with && so a failure stops at the first broken step instead of
# silently running the rest; the caller decides what "incomplete" means.
bg_mark_serving() { # new old
  printf '%s\n' "$1" > "$NCC_INSTALL_DIR/active-color.tmp" &&
    mv "$NCC_INSTALL_DIR/active-color.tmp" "$NCC_INSTALL_DIR/active-color" &&
    systemctl enable "$BG_UNIT@$1" &&
    systemctl disable "$BG_UNIT@$2"
}

# Only points Apache and verifies; does not mark anything or stop anything.
# 0: the new colour is now verified and serving. 1: verification failed and
# the include was restored to the old colour (nothing changed). 2: the
# restore itself failed, so Apache's running config is unknown -- the caller
# must not assume either colour is the one actually being served.
bg_switch() { # old new sha
  bg_point_apache_at "$2" || return 1
  if bg_wait_apache_health "$2" "$3" "$BG_APACHE_HEALTH_SECONDS"; then
    return 0
  fi
  if mv "$NCC_APACHE_UPSTREAM.bak" "$NCC_APACHE_UPSTREAM" && systemctl reload apache2; then
    return 1
  fi
  return 2
}

bg_new_healthy() { # new sha baseline-restarts; 0 healthy, 1 apache miss, 2 crashed
  local color=$1 sha=$2 baseline=$3
  if [[ $(systemctl show -p NRestarts --value "$BG_UNIT@$color") != "$baseline" ]] ||
     ! systemctl is-active --quiet "$BG_UNIT@$color"; then
    return 2
  fi
  bg_wait_apache_health "$color" "$sha" 2 && return 0
  return 1
}

# Best effort, never fails the drain: which jobs the drain cap is cutting
# short, for the operator to check afterwards.
bg_log_running_ids() { # old
  local ids
  ids=$(bg_rpc "$1" "$BG_RUNNING_IDS_EXPR" 2>/dev/null | tail -n 1) || true
  [[ -n ${ids:-} ]] && echo "executing job id(s) on $1: $ids" >&2
  return 0
}

# The old colour is out of traffic but up: pause its queues, wait for its
# executing jobs, and keep watching the new colour. Returns 2 when the new
# colour falls over, so the caller can switch back while the old one is warm.
# A crash (NRestarts moved off its post-start baseline, or the unit is no
# longer active) fails at once; a miss of the Apache probe alone needs two in
# a row, since one bad poll can just be a slow reload settling.
bg_drain() { # old new sha
  local waited=0 running misses=0 rc
  bg_rpc "$1" "$BG_PAUSE_EXPR" || echo "warning: could not pause $1's queues; its jobs may be cut short" >&2
  while :; do
    rc=0
    bg_new_healthy "$2" "$3" "$BG_BASELINE_RESTARTS" || rc=$?
    if ((rc == 2)); then
      return 2
    elif ((rc != 0)); then
      misses=$((misses + 1))
      ((misses < 2)) || return 2
    else
      misses=0
    fi
    running=$(bg_rpc "$1" "$BG_RUNNING_EXPR" 2>/dev/null | tail -n 1 || true)
    if [[ $running == 0 && $waited -ge $BG_WATCH_SECONDS ]]; then
      return 0
    fi
    if ((waited >= BG_DRAIN_CAP_SECONDS)); then
      echo "drain cap of ${BG_DRAIN_CAP_SECONDS} s reached with '${running:-?}' job(s) still executing on $1; stopping it anyway (Lifeline rescues them)" >&2
      bg_log_running_ids "$1"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

# Only reached once the new colour has already failed in the drain, so the
# new colour keeps serving until the old one is proven to work again: a
# failure here must never leave both the switch-back and the original switch
# half-done.
bg_switch_back() { # old new
  echo "$BG_UNIT@$2 failed after taking traffic; switching back to $1" >&2
  journalctl -u "$BG_UNIT@$2" -n 50 --no-pager >&2 || true
  if ! bg_point_apache_at "$1"; then
    echo "ERROR: could not switch back to $1; $2 still serves. Fix the Apache include by hand, then confirm $1 is healthy before touching either unit." >&2
    bg_rpc "$1" "$BG_RESUME_EXPR" || echo "warning: could not resume $1's queues" >&2
    return 1
  fi
  if ! bg_wait_apache_health "$1" "" "$BG_APACHE_HEALTH_SECONDS"; then
    echo "ERROR: $1 does not answer through Apache after switching back; pointing Apache at $2 again" >&2
    if mv "$NCC_APACHE_UPSTREAM.bak" "$NCC_APACHE_UPSTREAM" && systemctl reload apache2; then
      echo "$2 still serves" >&2
    else
      echo "ERROR: could not restore the include to $2 either; Apache's running config is unknown" >&2
    fi
    bg_rpc "$1" "$BG_RESUME_EXPR" || echo "warning: could not resume $1's queues" >&2
    return 1
  fi
  rm -f "$NCC_APACHE_UPSTREAM.bak"
  bg_mark_serving "$1" "$2" ||
    echo "ERROR: $1 serves again but marking it active failed (active-color cache, systemctl enable $1, or systemctl disable $2); fix each by hand." >&2
  bg_rpc "$1" "$BG_RESUME_EXPR" || echo "warning: could not resume $1's queues" >&2
  systemctl stop "$BG_UNIT@$2" || true
}

bg_activate() { # old new sha-or-empty
  local old=$1 new=$2 sha=$3 rc=0 i
  if ! systemctl start "$BG_UNIT@$new"; then
    bg_fail_idle "$new" "systemctl start"
    return 1
  fi
  BG_BASELINE_RESTARTS=$(systemctl show -p NRestarts --value "$BG_UNIT@$new")
  if ! bg_wait_idle_health "$new" "$sha" "$BG_IDLE_HEALTH_SECONDS"; then
    bg_fail_idle "$new" "health check on its own port"
    return 1
  fi
  bg_switch "$old" "$new" "$sha" || rc=$?
  if ((rc == 2)); then
    echo "ERROR: Apache state unknown after a failed restore; both colours left running. Check $NCC_APACHE_UPSTREAM and apachectl -S by hand before touching either unit." >&2
    return 1
  elif ((rc != 0)); then
    bg_fail_idle "$new" "the switch"
    return 1
  fi
  # Verification passed: the switch has happened, so the backup can never be
  # restored again, and a failure from here on must not stop either colour.
  rm -f "$NCC_APACHE_UPSTREAM.bak"
  if ! bg_mark_serving "$new" "$old"; then
    echo "ERROR: incomplete deploy: Apache now serves $new, but marking it active failed (active-color cache, systemctl enable $new, or systemctl disable $old). Fix each by hand, then verify systemctl is-enabled before the next deploy." >&2
    return 1
  fi
  rc=0
  bg_drain "$old" "$new" "$sha" || rc=$?
  if ((rc == 2)); then
    bg_switch_back "$old" "$new"
    return 1
  fi
  if ! systemctl stop "$BG_UNIT@$old"; then
    echo "ERROR: incomplete deploy: $BG_UNIT@$old did not stop. $new serves the public site, but $old still holds the builder port and runs queues on old code. Stop it by hand; the next deploy refuses until then." >&2
    return 1
  fi
  for ((i = 0; i < BG_BIND_SECONDS; i += 1)); do
    [[ $(curl -s --max-time 2 "http://127.0.0.1:$(bg_port "$new")/health" || true) == *'"builder_endpoint":"bound"'* ]] && return 0
    sleep 1
  done
  echo "warning: $new has not bound the builder port ${BG_BIND_SECONDS} s after $old stopped" >&2
}

bg_deploy() { # target-sha
  bg_preflight || return 1
  echo "blue/green: $BG_ACTIVE serves; building $BG_IDLE"
  bg_build "$BG_IDLE" || return 1
  bg_carry_assets "$BG_ACTIVE" "$BG_IDLE" || return 1
  bg_migrate "$BG_IDLE" || return 1
  bg_activate "$BG_ACTIVE" "$BG_IDLE" "$1"
}

# Back to the release in the other colour's directory: no build, no
# migration rollback. That release survives only until the next deploy
# builds over it.
bg_rollback() {
  bg_preflight || return 1
  # Present and non-empty; the start and its health check prove the rest.
  if [[ ! -d $(bg_release "$BG_IDLE") || -z $(ls -A "$(bg_release "$BG_IDLE")" 2>/dev/null) ]]; then
    echo "refusing: no release in $(bg_release "$BG_IDLE") to roll back to" >&2
    return 1
  fi
  local target_sha
  target_sha=$(cat "$(bg_release "$BG_IDLE")/BUILD_SHA" 2>/dev/null || true)
  echo "blue/green rollback: $BG_ACTIVE serves; bringing back $BG_IDLE (sha ${target_sha:-unknown})"
  bg_activate "$BG_ACTIVE" "$BG_IDLE" ""
}
