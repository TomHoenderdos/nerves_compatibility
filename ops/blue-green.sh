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

# Every vhost file `apachectl -S` lists, on any port, in either of the two
# line shapes bg_vhost_file reads, once each. Fails when apachectl -S does.
bg_all_vhost_files() {
  local out
  out=$(apachectl -S 2>/dev/null) || return 1
  printf '%s\n' "$out" |
    awk '
      $1 == "port" && $3 == "namevhost" { print $5; next }
      $1 ~ /:[0-9]+$/ && $3 ~ /^\(/ { print $3 }
    ' |
    tr -d '()' | sed -E 's/:[0-9]+$//' | sort -u
}

# Refuses when an enabled vhost other than the include still proxies straight
# to a colour's port: after the next switch it would keep sending traffic to
# a colour that is stopped, or worse, to the idle one being built over.
bg_check_direct_proxies() {
  local f files
  if ! files=$(bg_all_vhost_files) || [[ -z $files ]]; then
    echo "refusing: apachectl -S failed or listed no vhost files, so no vhost can be checked for a direct proxy to 127.0.0.1:4002/4003; run apachectl -S by hand and fix what it reports" >&2
    return 1
  fi
  while IFS= read -r f; do
    [[ -n $f && $f != "$NCC_APACHE_UPSTREAM" ]] || continue
    if [[ ! -r $f ]]; then
      echo "refusing: cannot read $f (listed by apachectl -S) to check it for a direct proxy to 127.0.0.1:4002/4003" >&2
      return 1
    fi
    # One awk, not grep -v | grep -q: under pipefail the -q's early exit can
    # SIGPIPE the first grep and turn a match into a pass.
    if awk '!/^[ \t]*#/ && /127\.0\.0\.1:400[23]([^0-9]|$)/ { found = 1; exit } END { exit !found }' "$f"; then
      echo "refusing: $f proxies straight to 127.0.0.1:4002 or 127.0.0.1:4003; replace those lines with Include $NCC_APACHE_UPSTREAM, so the switch moves its traffic too" >&2
      return 1
    fi
  done <<<"$files"
}

# The include belongs to a release: it is the template as of the commit the
# serving colour runs, not the checkout's, which deploy.sh has already moved
# to the commit being deployed. A template change ships when the colour that
# carries it is switched to, and leaves again with a switch-back or rollback.

# The commit $1 serves: its served-<colour> record, else its BUILD_SHA.
bg_served_sha() { # color
  local sha
  sha=$(cat "$(bg_served_file "$1")" 2>/dev/null || true)
  [[ -n $sha ]] || sha=$(cat "$(bg_release "$1")/BUILD_SHA" 2>/dev/null || true)
  printf '%s\n' "$sha"
}

# Prints $1 when the checkout holds the template as of commit $1, nothing
# otherwise (the working tree's template is then the one to use, and a note
# says why). Empty $1 means the working tree's, without a note.
bg_template_ref() { # sha-or-empty what
  [[ -n $1 ]] || return 0
  if [[ $1 =~ ^[0-9a-f]{7,40}$ ]] &&
     git -C "$NCC_SRC_DIR" cat-file -e "$1:ops/ncc-upstream.conf.template" 2>/dev/null; then
    printf '%s\n' "$1"
    return 0
  fi
  echo "note: cannot read ops/ncc-upstream.conf.template as of $2 ($1) from $NCC_SRC_DIR; using the working tree's template instead" >&2
}

bg_template_name() { # ref
  if [[ -n $1 ]]; then
    printf '%s\n' "ops/ncc-upstream.conf.template as of $1"
  else
    printf '%s\n' "the working tree's ops/ncc-upstream.conf.template"
  fi
}

bg_render_include() { # ref port
  if [[ -n $1 ]]; then
    git -C "$NCC_SRC_DIR" show "$1:ops/ncc-upstream.conf.template" | sed "s/@PORT@/$2/g"
  else
    sed "s/@PORT@/$2/g" "$NCC_SRC_DIR/ops/ncc-upstream.conf.template"
  fi
}

# Refuses unless the include is exactly the serving commit's template
# rendered with the serving port: a deploy rewrites it from a template, so
# anything edited into it by hand would be lost at the switch, silently.
bg_check_include_rendered() { # ref port
  if ! cmp -s <(bg_render_include "$1" "$2") "$NCC_APACHE_UPSTREAM"; then
    echo "refusing: $NCC_APACHE_UPSTREAM is not $(bg_template_name "$1") (the serving release's) rendered with port $2: it was edited by hand or has drifted. Put the change in the template (or undo it), render the include from the template, and deploy again." >&2
    return 1
  fi
}

bg_write_include() { # port [template-ref]
  local port=$1 status
  bg_render_include "${2:-}" "$port" > "$NCC_APACHE_UPSTREAM.new"
  status=$?
  if ((status != 0)) || [[ ! -s "$NCC_APACHE_UPSTREAM.new" ]] ||
     ! grep -q "127\.0\.0\.1:$port" "$NCC_APACHE_UPSTREAM.new"; then
    echo "ERROR: rendering the include for port $port failed (sed exit $status, or the result is empty or missing the backend address); leaving the old include in place" >&2
    rm -f "$NCC_APACHE_UPSTREAM.new"
    return 1
  fi
  mv "$NCC_APACHE_UPSTREAM.new" "$NCC_APACHE_UPSTREAM"
}

# Sets BG_ACTIVE, BG_IDLE and BG_ACTIVE_REF (the template ref the include was
# rendered from, for a switch back to the active colour).
bg_preflight() {
  local cached host vhost state sha
  BG_ACTIVE=$(bg_serving_color) || return 1
  BG_IDLE=$(bg_other "$BG_ACTIVE")
  cached=$(cat "$NCC_INSTALL_DIR/active-color" 2>/dev/null || true)
  if [[ $cached != "$BG_ACTIVE" ]]; then
    echo "refusing: $NCC_APACHE_UPSTREAM serves $BG_ACTIVE but $NCC_INSTALL_DIR/active-color says '$cached'." >&2
    echo "A deploy stopped between the switch and the cache write. Check which colour answers /health through Apache, write it to active-color, and deploy again." >&2
    return 1
  fi
  # Only inactive or failed: activating (an auto-restart in progress),
  # reloading and the rest mean the unit may be about to run.
  state=$(systemctl is-active "$BG_UNIT@$BG_IDLE" 2>/dev/null || true)
  if [[ $state != inactive && $state != failed ]]; then
    echo "refusing: $BG_UNIT@$BG_IDLE is ${state:-in an unknown state} (systemctl is-active), not inactive or failed: it is running or restarting but not serving (left from an incomplete deploy); look at it, stop it, then deploy again" >&2
    return 1
  fi
  sha=$(bg_served_sha "$BG_ACTIVE")
  if [[ -z $sha ]]; then
    echo "note: neither $(bg_served_file "$BG_ACTIVE") nor $(bg_release "$BG_ACTIVE")/BUILD_SHA names the commit $BG_ACTIVE serves; using the working tree's ops/ncc-upstream.conf.template instead" >&2
  fi
  BG_ACTIVE_REF=$(bg_template_ref "$sha" "the commit $BG_ACTIVE serves")
  bg_check_include_rendered "$BG_ACTIVE_REF" "$(bg_port "$BG_ACTIVE")" || return 1
  host=$(bg_public_host) || return 1
  vhost=$(bg_vhost_file "$host")
  if [[ -z $vhost ]] || ! bg_includes_upstream "$vhost"; then
    echo "refusing: the :443 vhost of $host (${vhost:-not found by apachectl -S}) does not Include $NCC_APACHE_UPSTREAM; was it regenerated?" >&2
    return 1
  fi
  bg_check_direct_proxies || return 1
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

bg_point_apache_at() { # color template-ref; 0 ok, 1 failed & restored, 2 the
                        # restore itself failed too -- Apache's running config
                        # is unknown
  local out
  cp "$NCC_APACHE_UPSTREAM" "$NCC_APACHE_UPSTREAM.bak" || return 1
  if ! bg_write_include "$(bg_port "$1")" "$2"; then
    mv "$NCC_APACHE_UPSTREAM.bak" "$NCC_APACHE_UPSTREAM" || return 2
    return 1
  fi
  if ! out=$(apachectl configtest 2>&1); then
    echo "apachectl configtest failed (it checks every vhost on this host, not only ours):" >&2
    echo "$out" >&2
    mv "$NCC_APACHE_UPSTREAM.bak" "$NCC_APACHE_UPSTREAM" || return 2
    return 1
  fi
  if ! systemctl reload apache2; then
    echo "systemctl reload apache2 failed; restoring the include" >&2
    mv "$NCC_APACHE_UPSTREAM.bak" "$NCC_APACHE_UPSTREAM" || return 2
    if ! systemctl reload apache2; then
      echo "ERROR: restoring reload also failed; Apache's running config is unknown" >&2
      return 2
    fi
    return 1
  fi
}

# Called once Apache is verified serving $1. Its BUILD_SHA is recorded as
# served-<colour> first, whatever happens to the rest: the one thing
# bg_rollback accepts as proof that the release in a directory is one that
# served, not a build that failed over it, and what the next preflight reads
# the include's template from. The rest is chained with && so a failure stops
# at the first broken step instead of silently running the rest; the caller
# decides what "incomplete" means.
bg_mark_serving() { # new old
  bg_record_served "$1"
  printf '%s\n' "$1" > "$NCC_INSTALL_DIR/active-color.tmp" &&
    mv "$NCC_INSTALL_DIR/active-color.tmp" "$NCC_INSTALL_DIR/active-color" &&
    systemctl enable "$BG_UNIT@$1" &&
    systemctl disable "$BG_UNIT@$2"
}

bg_served_file() { printf '%s\n' "$NCC_INSTALL_DIR/served-$1"; }

# Best effort: a colour that cannot be recorded is merely not a rollback
# target later, so this never fails the deploy that marked it.
bg_record_served() { # color
  local sha file
  file=$(bg_served_file "$1")
  sha=$(cat "$(bg_release "$1")/BUILD_SHA" 2>/dev/null || true)
  if [[ -z $sha ]]; then
    rm -f "$file" || true
    echo "warning: $(bg_release "$1")/BUILD_SHA is missing or empty; $1 cannot be rolled back to later" >&2
    return 0
  fi
  if ! { printf '%s\n' "$sha" > "$file.tmp" && mv "$file.tmp" "$file"; }; then
    rm -f "$file" "$file.tmp" || true
    echo "warning: could not record $file; $1 cannot be rolled back to later" >&2
  fi
  return 0
}

# Only points Apache and verifies; does not mark anything or stop anything.
# 0: the new colour is now verified and serving. 1: verification failed and
# the include was restored to the old colour (nothing changed). 2: the
# restore itself failed, so Apache's running config is unknown -- the caller
# must not assume either colour is the one actually being served.
bg_switch() { # old new sha template-ref
  local rc=0
  bg_point_apache_at "$2" "$4" || rc=$?
  if ((rc == 2)); then
    return 2
  elif ((rc != 0)); then
    return 1
  fi
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
# longer active) fails at once. A miss of the Apache probe alone needs two
# in a row to fail at once too, since one bad poll can just be a slow reload
# settling; but the drain may finish only on a probe that was itself healthy
# (misses == 0), so a miss right at the end of the watch window does not let
# a sick colour through, and three misses anywhere across the whole drain
# (not only consecutive ones) are treated the same as two in a row. The
# drain cap is bound by the same rule: it only stops the old colour on a
# probe that came back healthy, so a miss sitting right on the cap probe
# buys one more iteration rather than stopping the old colour on the
# strength of a probe that just failed. This cannot loop forever, since two
# consecutive or three total misses return 2 well before the cap could
# repeat indefinitely.
bg_drain() { # old new sha
  local waited=0 running misses=0 total_misses=0 rc unreadable_warned=0
  bg_rpc "$1" "$BG_PAUSE_EXPR" || echo "warning: could not pause $1's queues; its jobs may be cut short" >&2
  while :; do
    rc=0
    bg_new_healthy "$2" "$3" "$BG_BASELINE_RESTARTS" || rc=$?
    if ((rc == 2)); then
      return 2
    elif ((rc != 0)); then
      misses=$((misses + 1))
      total_misses=$((total_misses + 1))
      if ((misses >= 2)) || ((total_misses >= 3)); then
        return 2
      fi
    else
      misses=0
    fi
    running=$(bg_rpc "$1" "$BG_RUNNING_EXPR" 2>/dev/null | tail -n 1 || true)
    if [[ ! $running =~ ^[0-9]+$ ]] && ((unreadable_warned == 0)); then
      echo "warning: cannot read the executing job count on $1 (rpc answered '${running:0:100}'); waiting until the drain cap. Check it by hand: ops/portal-rpc.sh --color $1 'Oban.check_all_queues(Oban)'" >&2
      unreadable_warned=1
    fi
    if [[ $running == 0 && $misses == 0 && $waited -ge $BG_WATCH_SECONDS ]]; then
      return 0
    fi
    if ((waited >= BG_DRAIN_CAP_SECONDS)) && ((misses == 0)); then
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
# half-done. The include goes back to the template the old colour's was
# rendered from (preflight checked it).
bg_switch_back() { # old new old-template-ref
  local rc=0
  echo "$BG_UNIT@$2 failed after taking traffic; switching back to $1" >&2
  journalctl -u "$BG_UNIT@$2" -n 50 --no-pager >&2 || true
  bg_point_apache_at "$1" "$3" || rc=$?
  if ((rc == 2)); then
    echo "ERROR: Apache state unknown while switching back to $1; both colours left running. Check $NCC_APACHE_UPSTREAM and apachectl -S by hand before touching either unit." >&2
    bg_rpc "$1" "$BG_RESUME_EXPR" || echo "warning: could not resume $1's queues" >&2
    return 1
  elif ((rc != 0)); then
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
  rm -f "$NCC_APACHE_UPSTREAM.bak" || true
  bg_mark_serving "$1" "$2" ||
    echo "ERROR: $1 serves again but marking it active failed (active-color cache, systemctl enable $1, or systemctl disable $2); fix each by hand, and check that $(bg_served_file "$1") holds $(bg_release "$1")/BUILD_SHA." >&2
  # $2 fell over while serving: never a release to roll back to.
  rm -f "$(bg_served_file "$2")" || true
  bg_rpc "$1" "$BG_RESUME_EXPR" || echo "warning: could not resume $1's queues" >&2
  systemctl stop "$BG_UNIT@$2" || true
}

# old is BG_ACTIVE: a switch back renders its include from BG_ACTIVE_REF.
bg_activate() { # old new sha-or-empty new-template-ref
  local old=$1 new=$2 sha=$3 ref=$4 rc=0 i
  if ! systemctl start "$BG_UNIT@$new"; then
    bg_fail_idle "$new" "systemctl start"
    return 1
  fi
  BG_BASELINE_RESTARTS=$(systemctl show -p NRestarts --value "$BG_UNIT@$new") ||
    { bg_fail_idle "$new" "reading NRestarts"; return 1; }
  if ! bg_wait_idle_health "$new" "$sha" "$BG_IDLE_HEALTH_SECONDS"; then
    bg_fail_idle "$new" "health check on its own port"
    return 1
  fi
  bg_switch "$old" "$new" "$sha" "$ref" || rc=$?
  if ((rc == 2)); then
    echo "ERROR: Apache state unknown after a failed restore; both colours left running. Check $NCC_APACHE_UPSTREAM and apachectl -S by hand before touching either unit." >&2
    return 1
  elif ((rc != 0)); then
    bg_fail_idle "$new" "the switch"
    return 1
  fi
  # Verification passed: the switch has happened, so the backup can never be
  # restored again, and a failure from here on must not stop either colour.
  rm -f "$NCC_APACHE_UPSTREAM.bak" || true
  if ! bg_mark_serving "$new" "$old"; then
    echo "ERROR: incomplete deploy: Apache now serves $new, but marking it active failed (active-color cache, systemctl enable $new, or systemctl disable $old). Fix each by hand, check that $(bg_served_file "$new") holds $(bg_release "$new")/BUILD_SHA, then verify systemctl is-enabled before the next deploy." >&2
    return 1
  fi
  rc=0
  bg_drain "$old" "$new" "$sha" || rc=$?
  if ((rc == 2)); then
    bg_switch_back "$old" "$new" "$BG_ACTIVE_REF"
    return 1
  fi
  if ! systemctl stop "$BG_UNIT@$old"; then
    echo "ERROR: incomplete deploy: $BG_UNIT@$old did not stop. $new serves the public site, but $old still holds the builder port and runs queues on old code. Stop it by hand; the next deploy refuses until then." >&2
    return 1
  fi
  for ((i = 0; i < BG_BIND_SECONDS; i += 1)); do
    # "off" is done too: a host whose builder listener is off has nothing to bind.
    case $(curl -s --max-time 2 "http://127.0.0.1:$(bg_port "$new")/health" || true) in
      *'"builder_endpoint":"bound"'* | *'"builder_endpoint":"off"'*) return 0 ;;
    esac
    sleep 1
  done
  echo "warning: $new has not bound the builder port ${BG_BIND_SECONDS} s after $old stopped" >&2
}

bg_deploy() { # target-sha
  bg_preflight || return 1
  echo "blue/green: $BG_ACTIVE serves; building $BG_IDLE"
  # From here the idle directory is no longer the release that served,
  # whatever its BUILD_SHA says, until it serves again.
  rm -f "$(bg_served_file "$BG_IDLE")" || return 1
  bg_build "$BG_IDLE" || return 1
  bg_carry_assets "$BG_ACTIVE" "$BG_IDLE" || return 1
  bg_migrate "$BG_IDLE" || return 1
  # The checked-out template: deploy.sh has moved the checkout to the
  # commit being deployed, so this is how a template change ships.
  bg_activate "$BG_ACTIVE" "$BG_IDLE" "$1" ""
}

# Back to the release in the other colour's directory: no build, no
# migration rollback. That release survives only until the next deploy
# builds over it, and only a release recorded as served (served-<colour>
# equal to its BUILD_SHA) is one: a deploy that failed after building over
# the directory left a release that never served. Health checks then verify
# that sha, and the serving release's digested assets are carried over first
# so pages it rendered keep loading.
bg_rollback() {
  bg_preflight || return 1
  local release target_sha served
  release=$(bg_release "$BG_IDLE")
  if [[ ! -d $release || -z $(ls -A "$release" 2>/dev/null) ]]; then
    echo "refusing: no release in $release to roll back to" >&2
    return 1
  fi
  target_sha=$(cat "$release/BUILD_SHA" 2>/dev/null || true)
  served=$(cat "$(bg_served_file "$BG_IDLE")" 2>/dev/null || true)
  if [[ -z $target_sha || $target_sha != "$served" ]]; then
    echo "refusing: the release in $release (sha ${target_sha:-unknown}) is not one that ever served ($(bg_served_file "$BG_IDLE") says '${served}'): a deploy that failed built over it, or it was never marked serving. Deploy a known-good commit instead." >&2
    return 1
  fi
  echo "blue/green rollback: $BG_ACTIVE serves; bringing back $BG_IDLE (sha $target_sha)"
  bg_carry_assets "$BG_ACTIVE" "$BG_IDLE" ||
    echo "warning: could not carry $BG_ACTIVE's digested assets into $BG_IDLE; pages $BG_ACTIVE rendered may miss their assets after the switch" >&2
  # The release brings back its own include: the template as of its commit.
  bg_activate "$BG_ACTIVE" "$BG_IDLE" "$target_sha" \
    "$(bg_template_ref "$target_sha" "the commit $BG_IDLE served")"
}
