#!/bin/bash
# Checks the web host is ready for remote builders and prints the manual
# steps that remain. Run as root on the web host:
#
#   remote-builders-golive.sh             read-only: check and print
#   remote-builders-golive.sh --init-ca   also create the builder CA when
#                                         NCC_BUILDER_CA_KEY names a key
#                                         that does not exist yet
#
# Checks, in order: the builder CA (NCC_BUILDER_CA_KEY in the portal env
# file, the key mode 600 and owned by the portal user, ca.pem beside it);
# the release's environment (PHX_SERVER, `remote` in OBAN_QUEUES,
# NCC_UPLOAD_ROOT); something listening on NCC_BUILDER_PORT (default 8443);
# then, through `bin/portal rpc` into the running release, that the CA
# loads, that images.json names a worker image and agent releases
# (Portal.Builders.Images, exactly what routing and the claims read), the
# routing settings and the builders enrolled so far.
#
# Without a flag nothing changes. `--init-ca` does one thing, and only when
# the key is missing: Portal.Builders.CA.init/1 as the portal user, which
# writes a new key (mode 600) and ca.pem and refuses to overwrite either.
# It is reversible until the first builder enrols (delete both files).
# The portal must then be restarted for the listener to start (under
# blue/green: deployed, which starts the idle colour); this script never
# restarts anything.
#
# Exit 0 when every check passes, 1 when any fails, 2 on bad usage. The
# host layout comes from the deploy env file (ops/deploy.env.example).
# NCC_PORTAL_USER names the release's user (default ncc). With
# NCC_BLUE_GREEN=1 (ops/blue-green.sh) every bin/portal call goes to the
# colour the Apache include serves, with that colour's env file.
set -euo pipefail

ncc_layout() {
  local file=${NCC_DEPLOY_ENV:-/etc/ncc-deploy.env} name missing=()
  for name in "$@"; do [[ -n ${!name:-} ]] || missing+=("$name"); done
  [[ ${#missing[@]} -gt 0 ]] || return 0
  if [[ ! -r $file ]]; then
    echo "ERROR: no host layout: $file is missing or unreadable; it must set ${missing[*]} (see ops/deploy.env.example)" >&2
    return 1
  fi
  set -a
  # shellcheck source=/dev/null
  . "$file"
  set +a
  missing=()
  for name in "$@"; do [[ -n ${!name:-} ]] || missing+=("$name"); done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: $file does not set ${missing[*]} (see ops/deploy.env.example)" >&2
    return 1
  fi
}

# One variable from the deploy env file when the environment does not set it.
# ncc_layout sources the file only when a layout variable is missing, so a
# flag such as NCC_BLUE_GREEN would otherwise go unread whenever the caller
# exported the layout.
ncc_layout_flag() {
  local file=${NCC_DEPLOY_ENV:-/etc/ncc-deploy.env}
  if [[ -n ${!1+x} ]]; then printf '%s\n' "${!1}"; return 0; fi
  [[ -r $file ]] || return 0
  # The file's last command may return non-zero; under set -e that would end
  # the script with no message, so its status is ignored.
  # shellcheck source=/dev/null
  (. "$file" || true; printf '%s\n' "${!1:-}")
}

# NCC_BLUE_GREEN is empty, 0 (both: the single release) or 1. Anything else
# ("true", "yes", a typo) is refused rather than read as off.
ncc_check_blue_green() {
  case $NCC_BLUE_GREEN in
    "" | 0 | 1) return 0 ;;
  esac
  echo "ERROR: NCC_BLUE_GREEN is '$NCC_BLUE_GREEN'; it must be empty, 0 or 1 (see ops/deploy.env.example)" >&2
  return 1
}

init_ca=false
case "${1:-}" in
  "") ;;
  --init-ca) init_ca=true ;;
  *)
    echo "usage: $0 [--init-ca]" >&2
    exit 2
    ;;
esac
[[ $# -le 1 ]] || { echo "usage: $0 [--init-ca]" >&2; exit 2; }

ncc_layout NCC_INSTALL_DIR NCC_PORTAL_ENV NCC_PORTAL_WORKDIR || exit 1

USER_NAME=${NCC_PORTAL_USER:-ncc}
BIN=$NCC_INSTALL_DIR/portal/bin/portal
UNIT=ncc-portal
color_env=
# A restart takes the site down under blue/green; a deploy starts the other
# colour with the new settings and switches to it, and a rollback swaps back.
restart_hint="restart the portal"
NCC_BLUE_GREEN=$(ncc_layout_flag NCC_BLUE_GREEN)
ncc_check_blue_green || exit 1
if [[ $NCC_BLUE_GREEN == 1 ]]; then
  ncc_layout NCC_SRC_DIR NCC_APACHE_UPSTREAM || exit 1
  # shellcheck source=ops/blue-green.sh
  source "$NCC_SRC_DIR/ops/blue-green.sh"
  color=$(bg_serving_color) || exit 1
  BIN=$(bg_release "$color")/bin/portal
  UNIT=$BG_UNIT@$color
  # The colour's own node name and tmp dir, as bg_rpc reads them.
  color_env=$(dirname "$NCC_PORTAL_ENV")/color-$color.env
  restart_hint="run ops/deploy.sh, which redeploys main into the idle colour with the new settings and switches to it (ops/deploy.sh rollback instead brings back the previous, older release; migrations are not reversed); bouncing $UNIT by hand takes the site down"
fi
failures=0

ok() { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; failures=$((failures + 1)); }
note() { printf '  note  %s\n' "$*"; }

# One variable of the release's env file, read in a subshell so nothing in
# it reaches this script's environment.
env_value() {
  # shellcheck source=/dev/null
  (set -a && . "$NCC_PORTAL_ENV" && printf '%s' "${!1:-}")
}

# Runs `bin/portal <command> <expr>` as the portal user with its env file,
# as ops/deploy.sh does. rpc reaches the running node; its environment does
# not, so everything it needs is in the expression.
portal() {
  if [[ -n $color_env ]]; then
    sudo -u "$USER_NAME" bash -c 'cd "$1" && set -a && . "$2" && . "$3" && set +a && "$4" "$5" "$6"' -- \
      "$NCC_PORTAL_WORKDIR" "$NCC_PORTAL_ENV" "$color_env" "$BIN" "$1" "$2"
  else
    sudo -u "$USER_NAME" bash -c 'cd "$1" && set -a && . "$2" && set +a && "$3" "$4" "$5"' -- \
      "$NCC_PORTAL_WORKDIR" "$NCC_PORTAL_ENV" "$BIN" "$1" "$2"
  fi
}

[[ -r $NCC_PORTAL_ENV ]] || { echo "ERROR: cannot read $NCC_PORTAL_ENV" >&2; exit 1; }

echo "Builder CA"
ca_key=$(env_value NCC_BUILDER_CA_KEY)
if [[ -z $ca_key ]]; then
  bad "NCC_BUILDER_CA_KEY is not set in $NCC_PORTAL_ENV (an absolute path outside the checkout)"
elif [[ $ca_key != /* ]]; then
  bad "NCC_BUILDER_CA_KEY must be an absolute path, got $ca_key"
else
  if [[ ! -e $ca_key && $init_ca == true ]]; then
    ca_dir=$(dirname "$ca_key")
    if [[ ! -d $ca_dir ]]; then
      install -d -o "$USER_NAME" -g "$(id -gn "$USER_NAME")" -m 0700 "$ca_dir"
      echo "  made  $ca_dir (0700, $USER_NAME)"
    fi
    # eval runs in this shell's environment, which has the env file: the
    # path is read there, never spliced into the expression.
    if portal eval 'case Portal.Builders.CA.init(System.fetch_env!("NCC_BUILDER_CA_KEY")) do
        {:ok, _} -> IO.puts("created")
        {:error, why} -> IO.puts("refused: #{inspect(why)}"); System.halt(1)
      end'; then
      echo "  made  $ca_key and ca.pem; to start the listener, $restart_hint"
    else
      bad "CA init failed"
    fi
  fi

  if [[ ! -e $ca_key ]]; then
    bad "$ca_key does not exist (rerun with --init-ca to create it)"
  else
    if [[ -n $(find "$ca_key" -maxdepth 0 -perm 0600) ]]; then
      ok "$ca_key is mode 600"
    else
      bad "$ca_key is not mode 600 (chmod 600 it)"
    fi
    if [[ -n $(find "$ca_key" -maxdepth 0 -user "$USER_NAME") ]]; then
      ok "$ca_key is owned by $USER_NAME"
    else
      bad "$ca_key is not owned by $USER_NAME"
    fi
    if [[ -r $(dirname "$ca_key")/ca.pem ]]; then
      ok "ca.pem is beside it"
    else
      bad "no ca.pem beside $ca_key"
    fi
  fi
fi

echo "Release environment ($NCC_PORTAL_ENV)"
if [[ -n $(env_value PHX_SERVER) ]]; then
  ok "PHX_SERVER is set"
else
  bad "PHX_SERVER is not set: the builder listener starts only with it"
fi
queues=$(env_value OBAN_QUEUES)
if [[ ,$queues, == *,remote:* ]]; then
  ok "OBAN_QUEUES runs remote ($queues)"
else
  bad "OBAN_QUEUES has no remote queue ('$queues'): completed leases would never be ingested; add remote:2"
fi
upload_root=$(env_value NCC_UPLOAD_ROOT)
if [[ -n $upload_root ]]; then
  ok "NCC_UPLOAD_ROOT=$upload_root"
else
  note "NCC_UPLOAD_ROOT is unset: uploads go to the portal user's ~/.ncc-uploads; it needs room for 2 GiB per lease"
fi

port=$(env_value NCC_BUILDER_PORT)
port=${port:-8443}
echo "Builder listener"
if [[ ! $port =~ ^[0-9]+$ ]]; then
  bad "NCC_BUILDER_PORT is not a port number: $port"
elif [[ -n $(ss -Hltn "sport = :$port" 2>/dev/null) ]]; then
  ok "something listens on TCP $port"
else
  bad "nothing listens on TCP $port (needs PHX_SERVER, a CA key that loads, then: $restart_hint; journalctl -u $UNIT | grep 'builder listener')"
fi

# The first `key=value` line of the rpc report for key $1.
field() { sed -n "s/^$1=//p" <<<"$report" | head -n 1; }

echo "Running release (bin/portal rpc)"
# Read-only calls only: Routing.remote_enabled?/0 is not one (it stores its
# auto decision), so the settings are printed rather than evaluated.
if report=$(portal rpc '
    ca = match?({:ok, _}, Portal.Builders.CA.cert_pem())
    images = Portal.Builders.Images
    s = Portal.Settings.get()
    IO.puts("ca_loads=#{ca}")
    IO.puts("images_path=#{images.path() || "unset"}")
    IO.puts("images_load=#{inspect(elem(images.load(), 0))}")
    IO.puts("worker=#{if w = images.worker_image(), do: inspect(w), else: "none"}")
    IO.puts("agent=#{if a = images.agent(), do: a.version <> " for " <> Enum.join(Map.keys(a.releases), ", "), else: "none"}")
    IO.puts("remote_mode=#{s.remote_mode} threshold=#{s.remote_backlog_threshold}")
    for b <- Portal.Builders.list_builders(),
        do: IO.puts("builder=#{b.name} status=#{b.status} egress=#{b.egress_status || "unknown"} publishing=#{b.publishing} last_seen=#{b.last_seen_at || "never"}")
  ' 2>&1); then
  if [[ $(field ca_loads) == true ]]; then
    ok "the running release reads ca.pem"
  else
    bad "the running release cannot read the CA certificate (after creating the CA, $restart_hint)"
  fi
  if [[ $(field images_load) == :ok && $(field worker) != none ]]; then
    ok "images.json ($(field images_path)) names worker $(field worker)"
  else
    bad "images.json ($(field images_path)) is missing or names no worker image: routing keeps every job local (ops/images-sync.sh, ncc-images-sync.timer)"
  fi
  if [[ $(field agent) != none && -n $(field agent) ]]; then
    ok "agent release $(field agent)"
  else
    bad "images.json names no agent release: builders cannot install or update"
  fi
  note "$(field remote_mode) (auto: on while a builder was seen in the last 5 minutes)"
  builders=$(sed -n 's/^builder=//p' <<<"$report")
  if [[ -n $builders ]]; then
    while IFS= read -r line; do note "builder $line"; done <<<"$builders"
  else
    note "no builders enrolled yet"
  fi
else
  bad "bin/portal rpc failed (is $UNIT running?): $report"
fi

cat <<EOF

Next steps (manual):
  1. Fix every FAIL above. After creating the CA or changing $NCC_PORTAL_ENV,
     $restart_hint, and rerun this script.
  2. Open TCP $port on the web host's firewall. The client certificate is the
     gate; only ca.pem and enroll answer without one, and enroll needs a token.
  3. /admin/builders -> New enrolment token, named for the builder. It is shown
     once and expires in 24 h.
  4. On the builder VM (Ubuntu 24.04, x86_64 or aarch64): the cloud-init or the
     manual steps in apps/ncc_agent/README.md ("Setting up a builder host"),
     with the token and this host's PHX_HOST. They run builder-host-setup.sh
     install, then start ncc-agent.
  5. Wait for the builder on /admin/builders with egress "ok" (not "missing" or
     "host_unready"; the agent's journal says why). remote_mode auto then
     routes builds to it while the local backlog is above the threshold.
  6. Inspect its first runs, then turn its publishing on from the tab: until
     then its precompiled files stay out of the manifests.
EOF

if [[ $failures -gt 0 ]]; then
  echo
  echo "$failures check(s) failed."
  exit 1
fi
echo
echo "All checks passed."
