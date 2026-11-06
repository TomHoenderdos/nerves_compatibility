"""Blue/green deploy on the web host, driven with stub systemctl, apachectl,
curl, journalctl and rpc: the include file plays Apache, a state file plays
systemd, and nothing touches a live host."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

OPS = Path(__file__).parent
SRC = OPS.parent
TARGET = "a" * 40
OLD = "b" * 40

HARNESS = r'''
set -euo pipefail
source "$HELPER"
log() { echo "$*" >> "$EVENTS"; }
running() { grep -qx "$1" "$RUN_FILE" 2>/dev/null; }
systemctl() {
  log "systemctl $*"
  local unit=${*: -1} color
  color=${unit#ncc-portal@}
  case $1 in
    is-active) running "$color" ;;
    start) [[ ${START_FAILS:-} != "$color" ]] || return 1; echo "$color" >> "$RUN_FILE" ;;
    stop)
      [[ ${STOP_FAILS:-} != "$color" ]] || return 1
      grep -vx "$color" "$RUN_FILE" > "$RUN_FILE.new" || true; mv "$RUN_FILE.new" "$RUN_FILE" ;;
    show) if [[ ${CRASHES:-} == "$color" ]]; then echo 1; else echo 0; fi ;;
    reload) [[ ${RELOAD_STATUS:-0} == 0 ]] ;;
    *) return 0 ;;
  esac
}
apachectl() {
  log "apachectl $*"
  case $1 in
    -S) [[ -n ${VHOST:-} ]] && echo "         port 443 namevhost example.test ($VHOST:35)" ;;
    configtest)
      if [[ ${CONFIGTEST_STATUS:-0} != 0 ]]; then echo "AH00526: Syntax error on line 3 of /etc/x/other-site.conf" >&2; return 1; fi
      echo "Syntax OK" ;;
  esac
}
journalctl() { log "journalctl $*"; echo "journal lines"; }
body_for() {
  local color=$1 sha
  running "$color" || return 7
  if [[ ${HEALTH_301:-} == "$color" ]]; then echo '<html><body>301 Moved Permanently</body></html>'; return 0; fi
  if [[ ${CRASHES:-} == "$color" && ${CRASHED_ANSWERS:-yes} == no ]]; then return 7; fi
  sha=$(cat "$STATE/sha-$color")
  printf '{"builder_endpoint":"bound","color":"%s","sha":"%s"}\n' "$color" "$sha"
}
curl() {
  local url=${*: -1} port
  log "curl $url"
  case $url in
    http://127.0.0.1:*/health) port=${url#http://127.0.0.1:}; port=${port%%/*}; body_for "$(bg_color_of_port "$port")" ;;
    https://example.test/health) body_for "$(bg_serving_color)" ;;
    *) return 7 ;;
  esac
}
sleep() { :; }
bg_build() { log "build $1"; mkdir -p "$NCC_INSTALL_DIR/releases/$1"; echo "${BUILT_SHA:-$TARGET}" > "$STATE/sha-$1"; [[ ${BUILD_STATUS:-0} == 0 ]]; }
bg_migrate() { log "migrate $1"; [[ ${MIGRATE_STATUS:-0} == 0 ]]; }
bg_carry_assets() { log "carry $1 $2"; }
bg_rpc() {
  log "rpc $1 $2"
  case $2 in *check_all_queues*) echo "${RUNNING_JOBS:-0}" ;; esac
}
eval "$ACTION"
'''


class BlueGreenTest(unittest.TestCase):
    def run_bg(self, action, active="blue", cache=None, running=None, vhost_include=True,
               include_text=None, **overrides):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            install = root / "install"
            for c in ("blue", "green"):
                (install / "releases" / c / "bin").mkdir(parents=True)
            state = root / "state"
            state.mkdir()
            (state / "sha-blue").write_text(OLD + "\n")
            (state / "sha-green").write_text(OLD + "\n")
            (install / "active-color").write_text((cache or active) + "\n")
            upstream = root / "ncc-upstream.conf"
            port = {"blue": 4002, "green": 4003}[active]
            upstream.write_text(include_text if include_text is not None else
                                (SRC / "ops" / "ncc-upstream.conf.template").read_text()
                                .replace("@PORT@", str(port)))
            vhost = root / "site.conf"
            vhost.write_text(f"<VirtualHost *:443>\n    Include {upstream}\n</VirtualHost>\n"
                             if vhost_include else "<VirtualHost *:443>\n</VirtualHost>\n")
            portal_env = root / "portal.env"
            portal_env.write_text("PHX_HOST=example.test\n")
            run_file = root / "running"
            run_file.write_text("".join(f"{c}\n" for c in (running if running is not None else [active])))
            events = root / "events"
            env = {
                **os.environ,
                "HELPER": str(OPS / "blue-green.sh"),
                "ACTION": action,
                "EVENTS": str(events),
                "STATE": str(state),
                "RUN_FILE": str(run_file),
                "VHOST": str(vhost),
                "TARGET": TARGET,
                "NCC_INSTALL_DIR": str(install),
                "NCC_SRC_DIR": str(SRC),
                "NCC_PORTAL_ENV": str(portal_env),
                "NCC_PORTAL_WORKDIR": str(root),
                "NCC_APACHE_UPSTREAM": str(upstream),
                **overrides,
            }
            result = subprocess.run(["bash", "-c", HARNESS], env=env, capture_output=True,
                                    text=True, timeout=20)
            self.include = upstream.read_text()
            self.cache = (install / "active-color").read_text().strip()
            self.running = run_file.read_text().split()
            return result, events.read_text().splitlines() if events.exists() else []

    # --- preflight -------------------------------------------------------

    def test_preflight_resolves_the_serving_colour_from_the_include(self):
        for active, idle in (("blue", "green"), ("green", "blue")):
            result, _ = self.run_bg('bg_preflight; echo "$BG_ACTIVE $BG_IDLE"', active=active)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.split()[-2:], [active, idle])

    def test_preflight_refuses_when_the_cache_disagrees(self):
        result, _ = self.run_bg("bg_preflight", active="green", cache="blue")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing", result.stderr)
        self.assertIn("active-color", result.stderr)

    def test_preflight_refuses_when_the_idle_colour_is_running(self):
        result, _ = self.run_bg("bg_preflight", running=["blue", "green"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ncc-portal@green is running", result.stderr)

    def test_preflight_refuses_when_the_vhost_lost_its_include(self):
        result, _ = self.run_bg("bg_preflight", vhost_include=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not Include", result.stderr)

    def test_preflight_refuses_an_include_that_names_no_single_known_port(self):
        for text in ("# empty\n",
                     "ProxyPass / http://127.0.0.1:4002/\nProxyPass /x http://127.0.0.1:4003/\n",
                     "ProxyPass / http://127.0.0.1:4009/\n"):
            with self.subTest(text=text):
                result, _ = self.run_bg("bg_preflight", include_text=text)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ERROR", result.stderr)

    def test_the_include_template_carries_retry_0_and_the_websocket_rule(self):
        text = (SRC / "ops" / "ncc-upstream.conf.template").read_text()
        self.assertIn("ProxyPass / http://127.0.0.1:@PORT@/ retry=0", text)
        self.assertIn('RewriteRule ^/?(.*) "ws://127.0.0.1:@PORT@/$1" [P]', text)
        self.assertIn('RequestHeader set X-Forwarded-Proto "https"', text)


if __name__ == "__main__":
    unittest.main()
