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
    -S)
      if [[ -n ${APACHE_S_LINE:-} ]]; then
        echo "$APACHE_S_LINE"
      elif [[ -n ${VHOST:-} ]]; then
        echo "         port 443 namevhost example.test ($VHOST:35)"
      fi ;;
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
               include_text=None, vhost_text=None, **overrides):
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
            if vhost_text is not None:
                vhost.write_text(vhost_text.replace("@UPSTREAM@", str(upstream)))
            else:
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

    def test_preflight_refuses_a_commented_out_include(self):
        result, _ = self.run_bg(
            "bg_preflight",
            vhost_text="<VirtualHost *:443>\n    #Include @UPSTREAM@\n</VirtualHost>\n",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not Include", result.stderr)

    def test_preflight_refuses_include_optional(self):
        result, _ = self.run_bg(
            "bg_preflight",
            vhost_text="<VirtualHost *:443>\n    IncludeOptional @UPSTREAM@\n</VirtualHost>\n",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not Include", result.stderr)

    def test_preflight_passes_an_indented_include(self):
        result, _ = self.run_bg(
            "bg_preflight",
            vhost_text="<VirtualHost *:443>\n\t\tInclude @UPSTREAM@\n</VirtualHost>\n",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_preflight_passes_a_quoted_include_path(self):
        result, _ = self.run_bg(
            "bg_preflight",
            vhost_text='<VirtualHost *:443>\n    Include "@UPSTREAM@"\n</VirtualHost>\n',
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_preflight_refuses_an_include_that_names_no_single_known_port(self):
        for text in ("# empty\n",
                     "ProxyPass / http://127.0.0.1:4002/\nProxyPass /x http://127.0.0.1:4003/\n",
                     "ProxyPass / http://127.0.0.1:4009/\n"):
            with self.subTest(text=text):
                result, _ = self.run_bg("bg_preflight", include_text=text)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ERROR", result.stderr)

    # --- bg_vhost_file ----------------------------------------------------

    def test_vhost_file_matches_the_namevhost_line(self):
        result, _ = self.run_bg(
            "bg_vhost_file example.test",
            APACHE_S_LINE="         port 443 namevhost example.test "
                           "(/etc/apache2/sites-enabled/example.test.conf:12)",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "/etc/apache2/sites-enabled/example.test.conf")

    def test_vhost_file_matches_the_flat_single_vhost_line(self):
        result, _ = self.run_bg(
            "bg_vhost_file example.test",
            APACHE_S_LINE="192.0.2.1:443  example.test "
                           "(/etc/apache2/sites-enabled/example.test.conf:12)",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "/etc/apache2/sites-enabled/example.test.conf")

    def test_vhost_file_is_empty_when_only_another_host_is_listed(self):
        result, _ = self.run_bg(
            "bg_vhost_file example.test",
            APACHE_S_LINE="         port 443 namevhost other.test "
                           "(/etc/apache2/sites-enabled/other.test.conf:9)",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "")

    def test_the_include_template_carries_retry_0_and_the_websocket_rule(self):
        text = (SRC / "ops" / "ncc-upstream.conf.template").read_text()
        self.assertIn("ProxyPass / http://127.0.0.1:@PORT@/ retry=0", text)
        self.assertIn('RewriteRule ^/?(.*) "ws://127.0.0.1:@PORT@/$1" [P]', text)
        self.assertIn('RequestHeader set X-Forwarded-Proto "https"', text)

    # --- deploy ----------------------------------------------------------

    def deploy(self, **kw):
        return self.run_bg(f"bg_deploy {TARGET}", **kw)

    def test_happy_path_blue_to_green(self):
        result, events = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("127.0.0.1:4003/ retry=0", self.include)
        self.assertEqual(self.cache, "green")
        self.assertEqual(self.running, ["green"])
        order = [e for e in events if not e.startswith(
            ("curl", "systemctl show", "systemctl is-active", "rpc", "apachectl", "journalctl"))]
        self.assertEqual(order[:4], ["build green", "carry blue green", "migrate green",
                                     "systemctl start ncc-portal@green"])
        self.assertLess(events.index("apachectl configtest"), events.index("systemctl reload apache2"))
        self.assertIn("systemctl enable ncc-portal@green", events)
        self.assertIn("systemctl disable ncc-portal@blue", events)
        pause = "rpc blue Oban.pause_all_queues(Oban, local_only: true)"
        self.assertIn(pause, events)
        self.assertLess(events.index(pause), events.index("systemctl stop ncc-portal@blue"))

    def test_happy_path_green_to_blue(self):
        result, _ = self.deploy(active="green")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("127.0.0.1:4002/ retry=0", self.include)
        self.assertEqual((self.cache, self.running), ("blue", ["blue"]))

    def test_pause_is_local_only(self):
        _, events = self.deploy()
        pauses = [e for e in events if "pause_all_queues" in e]
        self.assertTrue(pauses)
        for e in pauses:
            self.assertIn("local_only: true", e)

    def assert_untouched(self, result, events, active="blue"):
        self.assertNotEqual(result.returncode, 0)
        port = {"blue": 4002, "green": 4003}[active]
        self.assertIn(f"127.0.0.1:{port}/ retry=0", self.include)
        self.assertEqual(self.cache, active)
        self.assertEqual(self.running, [active])
        self.assertNotIn(f"systemctl stop ncc-portal@{active}", events)

    def test_preflight_refusal_builds_nothing(self):
        result, events = self.deploy(running=["blue", "green"])
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse([e for e in events if e.startswith("build")])

    def test_build_or_migrate_failure_leaves_blue_serving(self):
        for overrides in ({"BUILD_STATUS": "1"}, {"MIGRATE_STATUS": "1"}):
            with self.subTest(**overrides):
                result, events = self.deploy(**overrides)
                self.assert_untouched(result, events)
                self.assertNotIn("systemctl start ncc-portal@green", events)

    def test_idle_that_never_reports_the_target_sha_is_stopped(self):
        result, events = self.deploy(BUILT_SHA=OLD)
        self.assert_untouched(result, events)
        self.assertIn("systemctl stop ncc-portal@green", events)
        self.assertNotIn("systemctl reload apache2", events)
        self.assertIn("journal lines", result.stderr)

    def test_a_301_from_the_idle_colour_is_a_failure(self):
        result, events = self.deploy(HEALTH_301="green")
        self.assert_untouched(result, events)
        self.assertNotIn("systemctl reload apache2", events)

    def test_idle_that_fails_to_start_is_a_failure(self):
        result, events = self.deploy(START_FAILS="green")
        self.assert_untouched(result, events)

    def test_configtest_failure_restores_the_include_and_names_the_other_vhost(self):
        result, events = self.deploy(CONFIGTEST_STATUS="1")
        self.assert_untouched(result, events)
        self.assertIn("other-site.conf", result.stderr)
        self.assertNotIn("systemctl reload apache2", events)

    def test_reload_failure_restores_and_reloads_again(self):
        result, events = self.deploy(RELOAD_STATUS="1")
        self.assert_untouched(result, events)
        self.assertGreaterEqual(events.count("systemctl reload apache2"), 2)

    def test_new_colour_crashing_during_the_drain_switches_back(self):
        result, events = self.deploy(CRASHES="green")
        self.assert_untouched(result, events)
        self.assertIn("rpc blue Oban.resume_all_queues(Oban, local_only: true)", events)
        self.assertIn("systemctl stop ncc-portal@green", events)
        self.assertIn("systemctl enable ncc-portal@blue", events)

    def test_drain_cap_stops_the_old_colour_anyway(self):
        result, events = self.deploy(RUNNING_JOBS="3", BG_DRAIN_CAP_SECONDS="20")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("drain cap", result.stderr)
        self.assertEqual(self.running, ["green"])

    def test_waits_for_running_jobs_until_drained(self):
        result, events = self.deploy(RUNNING_JOBS="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        checks = [e for e in events if "check_all_queues" in e]
        self.assertTrue(checks)

    def test_old_colour_that_will_not_stop_is_a_red_deploy(self):
        result, events = self.deploy(STOP_FAILS="blue")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("127.0.0.1:4003/ retry=0", self.include)
        self.assertEqual(self.cache, "green")
        self.assertIn("incomplete", result.stderr)

    # --- rollback --------------------------------------------------------

    def test_rollback_starts_the_other_colour_without_building(self):
        result, events = self.run_bg("bg_rollback", active="green")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse([e for e in events if e.startswith(("build", "migrate", "carry"))])
        self.assertIn("127.0.0.1:4002/ retry=0", self.include)
        self.assertEqual((self.cache, self.running), ("blue", ["blue"]))

    def test_rollback_refuses_without_a_release_in_the_other_colour(self):
        result, events = self.run_bg('rm -rf "$NCC_INSTALL_DIR/releases/blue"; bg_rollback',
                                     active="green")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no release", result.stderr)
        self.assertNotIn("systemctl start ncc-portal@blue", events)


class CarryAssetsTest(unittest.TestCase):
    """The real bg_carry_assets: only the serving release's own manifest files."""

    def test_carries_the_manifest_files_and_nothing_older(self):
        with tempfile.TemporaryDirectory() as directory:
            install = Path(directory)
            old = install / "releases/blue/lib/portal-0.1.0/priv/static"
            new = install / "releases/green/lib/portal-0.1.0/priv/static"
            (old / "assets/js").mkdir(parents=True)
            (new / "assets/js").mkdir(parents=True)
            (old / "cache_manifest.json").write_text(
                '{"latest": {"assets/js/app.js": "assets/js/app-old1.js"}, "digests": {}}')
            (old / "assets/js/app-old1.js").write_text("old")
            (old / "assets/js/app-old1.js.gz").write_text("oldgz")
            (old / "assets/js/app-older0.js").write_text("carried before")
            (new / "assets/js/app-new2.js").write_text("new")
            env = {**os.environ, "NCC_INSTALL_DIR": str(install), "HELPER": str(OPS / "blue-green.sh")}
            result = subprocess.run(["bash", "-c", 'source "$HELPER"; bg_carry_assets blue green'],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            names = sorted(p.name for p in (new / "assets/js").iterdir())
            self.assertEqual(names, ["app-new2.js", "app-old1.js", "app-old1.js.gz"])


if __name__ == "__main__":
    unittest.main()
