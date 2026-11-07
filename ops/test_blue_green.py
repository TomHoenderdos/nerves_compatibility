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
    is-active)
      # Prints a state unless --quiet, like the real one; IDLE_STATE names a
      # stopped colour's state (default inactive), ACTIVATING one that is
      # auto-restarting (exit 3, the same as inactive).
      local s
      if running "$color"; then s=active; else s=${IDLE_STATE:-inactive}; fi
      [[ ${ACTIVATING:-} != "$color" ]] || s=activating
      [[ $2 == --quiet ]] || echo "$s"
      [[ $s == active ]] ;;
    start) [[ ${START_FAILS:-} != "$color" ]] || return 1; echo "$color" >> "$RUN_FILE" ;;
    stop)
      [[ ${STOP_FAILS:-} != "$color" ]] || return 1
      grep -vx "$color" "$RUN_FILE" > "$RUN_FILE.new" || true; mv "$RUN_FILE.new" "$RUN_FILE" ;;
    enable) [[ ${ENABLE_FAILS:-} != "$color" ]] ;;
    disable) [[ ${DISABLE_FAILS:-} != "$color" ]] ;;
    show)
      local f="$STATE/show-$color" n base
      n=$(($(cat "$f" 2>/dev/null || echo 0) + 1))
      echo "$n" > "$f"
      base=${NRESTARTS_BASE:-0}
      # The first call per colour is the post-start baseline and always
      # $base; a crash is a later call's NRestarts moving away from it.
      if [[ ${CRASHES:-} == "$color" && $n -gt 1 ]]; then echo $((base + 1)); else echo "$base"; fi ;;
    reload)
      local f="$STATE/reload-calls" n
      n=$(($(cat "$f" 2>/dev/null || echo 0) + 1))
      echo "$n" > "$f"
      [[ ${RELOAD_STATUS:-0} == 0 ]] || return 1
      [[ -z ${RELOAD_FAIL_ON:-} || $n != "${RELOAD_FAIL_ON}" ]] ;;
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
      fi
      # Other enabled vhosts, one apachectl -S line each.
      if [[ -n ${EXTRA_S_LINES:-} ]]; then printf '%s\n' "$EXTRA_S_LINES"; fi
      [[ ${APACHE_S_STATUS:-0} == 0 ]] ;;
    configtest)
      local f="$STATE/configtest-calls" n
      n=$(($(cat "$f" 2>/dev/null || echo 0) + 1))
      echo "$n" > "$f"
      if [[ ${CONFIGTEST_STATUS:-0} != 0 ]] || [[ -n ${CONFIGTEST_FAIL_ON:-} && $n == "${CONFIGTEST_FAIL_ON}" ]]; then
        echo "AH00526: Syntax error on line 3 of /etc/x/other-site.conf" >&2; return 1
      fi
      echo "Syntax OK" ;;
  esac
}
journalctl() { log "journalctl $*"; echo "journal lines"; }
mv() {
  # MV_BAK_FAILS simulates the restore mv itself failing (disk full, perms,
  # ...): only the .bak -> live-include restore, never bg_point_apache_at's
  # own cp/backup step or anything unrelated.
  if [[ -n ${MV_BAK_FAILS:-} && "$1" == "$NCC_APACHE_UPSTREAM.bak" && "$2" == "$NCC_APACHE_UPSTREAM" ]]; then
    log "mv $* (forced failure)"
    return 1
  fi
  command mv "$@"
}
body_for() {
  local color=$1 sha ep
  running "$color" || return 7
  if [[ ${HEALTH_301:-} == "$color" ]]; then echo '<html><body>301 Moved Permanently</body></html>'; return 0; fi
  if [[ ${CRASHES:-} == "$color" && ${CRASHED_ANSWERS:-yes} == no ]]; then return 7; fi
  sha=$(cat "$STATE/sha-$color")
  ep=bound
  [[ ${BUILDER_WAITING:-} != "$color" ]] || ep=waiting
  [[ ${BUILDER_OFF:-} != "$color" ]] || ep=off
  printf '{"builder_endpoint":"%s","color":"%s","sha":"%s"}\n' "$ep" "$color" "$sha"
}
curl() {
  local url=${*: -1} port color
  log "curl $url"
  case $url in
    http://127.0.0.1:*/health) port=${url#http://127.0.0.1:}; port=${port%%/*}; body_for "$(bg_color_of_port "$port")" ;;
    https://example.test/health)
      color=$(bg_serving_color) || return 7
      [[ ${APACHE_HEALTH_FAILS:-} != "$color" ]] || return 7
      # APACHE_MISS_ON names probe numbers (1-based, space-separated) to
      # fail, but only once this colour is the one active-color already
      # names: that is, only once the drain's own probing has started, not
      # during the initial switch's own one-shot verification before it.
      if [[ -n ${APACHE_MISS_ON:-} && $(cat "$NCC_INSTALL_DIR/active-color" 2>/dev/null) == "$color" ]]; then
        local f="$STATE/apache-probe-calls" n miss
        n=$(($(cat "$f" 2>/dev/null || echo 0) + 1))
        echo "$n" > "$f"
        for miss in $APACHE_MISS_ON; do
          [[ $n == "$miss" ]] && return 7
        done
      fi
      body_for "$color" ;;
    *) return 7 ;;
  esac
}
sleep() { :; }
bg_build() {
  log "build $1"; mkdir -p "$NCC_INSTALL_DIR/releases/$1"
  # build-release.sh stamps the target; the node reports BUILT_SHA if set.
  echo "$TARGET" > "$NCC_INSTALL_DIR/releases/$1/BUILD_SHA"
  echo "${BUILT_SHA:-$TARGET}" > "$STATE/sha-$1"; [[ ${BUILD_STATUS:-0} == 0 ]]
}
bg_migrate() { log "migrate $1"; [[ ${MIGRATE_STATUS:-0} == 0 ]]; }
bg_carry_assets() { log "carry $1 $2"; }
bg_rpc() {
  log "rpc $1 $2"
  case $2 in
    *flat_map*) echo '[101]' ;;
    *check_all_queues*)
      if [[ -n ${RUNNING_JOBS_COUNTDOWN:-} ]]; then
        local f="$STATE/rpc-calls" n
        n=$(($(cat "$f" 2>/dev/null || echo 0) + 1))
        echo "$n" > "$f"
        if ((n <= RUNNING_JOBS_COUNTDOWN)); then echo 2; else echo 0; fi
      else
        echo "${RUNNING_JOBS:-0}"
      fi ;;
  esac
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
                # Both colours have served OLD before (the steady state after
                # two deploys): each is a valid rollback target.
                (install / "releases" / c / "BUILD_SHA").write_text(OLD + "\n")
                (install / f"served-{c}").write_text(OLD + "\n")
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
            self.served = {c: (install / f"served-{c}").read_text().strip()
                           if (install / f"served-{c}").exists() else None
                           for c in ("blue", "green")}
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
        self.assertIn("ncc-portal@green is active", result.stderr)

    # --- M3: only inactive or failed counts as stopped ----------------------

    def test_preflight_refuses_an_idle_colour_that_is_activating(self):
        result, _ = self.run_bg("bg_preflight", ACTIVATING="green")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ncc-portal@green is activating", result.stderr)
        self.assertIn("not inactive or failed", result.stderr)

    def test_preflight_passes_an_idle_colour_that_failed(self):
        result, _ = self.run_bg("bg_preflight", IDLE_STATE="failed")
        self.assertEqual(result.returncode, 0, result.stderr)

    # --- I4: the include must be the template, rendered --------------------

    def test_preflight_refuses_a_drifted_include(self):
        rendered = (SRC / "ops" / "ncc-upstream.conf.template").read_text().replace("@PORT@", "4002")
        for text in (rendered + "ProxyTimeout 300\n",
                     rendered.replace(" retry=0", "")):
            with self.subTest(text=text[-40:]):
                result, events = self.run_bg("bg_preflight", include_text=text)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("edited by hand or has drifted", result.stderr)
                self.assertIn("ncc-upstream.conf.template", result.stderr)

    def test_preflight_passes_the_rendered_template(self):
        rendered = (SRC / "ops" / "ncc-upstream.conf.template").read_text().replace("@PORT@", "4003")
        result, _ = self.run_bg("bg_preflight", active="green", include_text=rendered)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_drifted_include_builds_nothing(self):
        rendered = (SRC / "ops" / "ncc-upstream.conf.template").read_text().replace("@PORT@", "4002")
        result, events = self.deploy(include_text=rendered + "# local tweak\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse([e for e in events if e.startswith("build")])

    # --- F1: the include is the template as of the commit that serves ------

    def template_repo(self):
        """A checkout whose template changed in its last commit: the serving
        colour's commit (old) has v1, HEAD and the working tree have v2."""
        directory = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(directory, ignore_errors=True))
        src = Path(directory)
        (src / "ops").mkdir()
        v1 = (SRC / "ops" / "ncc-upstream.conf.template").read_text()
        v2 = v1 + "ProxyTimeout 300\n"

        def git(*args):
            return subprocess.run(
                ["git", "-c", "user.name=t", "-c", "user.email=t@example.test",
                 "-c", "commit.gpgsign=false", "-C", str(src), *args],
                check=True, capture_output=True, text=True).stdout.strip()

        git("init", "-q")
        shas = []
        for text in (v1, v2):
            (src / "ops" / "ncc-upstream.conf.template").write_text(text)
            git("add", "ops/ncc-upstream.conf.template")
            git("commit", "-q", "-m", "template")
            shas.append(git("rev-parse", "HEAD"))
        return src, shas[0], shas[1], v1, v2

    @staticmethod
    def render(text, port):
        return text.replace("@PORT@", str(port))

    def served_as(self, color, sha):
        """Shell that records $color as having served $sha."""
        return (f'echo {sha} > "$NCC_INSTALL_DIR/served-{color}"; '
                f'echo {sha} > "$NCC_INSTALL_DIR/releases/{color}/BUILD_SHA"; '
                f'echo {sha} > "$STATE/sha-{color}"; ')

    def test_a_template_change_since_the_served_commit_passes_and_ships(self):
        src, old, _, v1, v2 = self.template_repo()
        result, events = self.run_bg(self.served_as("blue", old) + f"bg_deploy {TARGET}",
                                     include_text=self.render(v1, 4002), NCC_SRC_DIR=str(src))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("drifted", result.stderr)
        # The new colour's include is the checked-out (new) template.
        self.assertEqual(self.include, self.render(v2, 4003))
        self.assertEqual(self.cache, "green")

    def test_the_served_commit_is_read_from_build_sha_without_a_served_record(self):
        src, old, _, v1, _ = self.template_repo()
        result, _ = self.run_bg(
            self.served_as("blue", old) + 'rm -f "$NCC_INSTALL_DIR/served-blue"; bg_preflight',
            include_text=self.render(v1, 4002), NCC_SRC_DIR=str(src))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_hand_edited_include_still_refuses_against_the_served_template(self):
        src, old, _, v1, v2 = self.template_repo()
        for text in (self.render(v1, 4002) + "# local tweak\n", self.render(v2, 4002)):
            with self.subTest(text=text[-30:]):
                result, events = self.run_bg(self.served_as("blue", old) + f"bg_deploy {TARGET}",
                                             include_text=text, NCC_SRC_DIR=str(src))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("edited by hand or has drifted", result.stderr)
                self.assertIn(old, result.stderr)
                self.assertFalse([e for e in events if e.startswith("build")])

    def test_without_a_served_commit_it_falls_back_to_the_working_tree_and_says_so(self):
        src, _, _, v1, v2 = self.template_repo()
        no_record = ('rm -f "$NCC_INSTALL_DIR/served-blue" '
                     '"$NCC_INSTALL_DIR/releases/blue/BUILD_SHA"; ')
        unknown = self.served_as("blue", "c" * 40)  # git show cannot find it
        for setup in (no_record, unknown):
            with self.subTest(setup=setup[:30]):
                result, _ = self.run_bg(setup + "bg_preflight",
                                        include_text=self.render(v2, 4002), NCC_SRC_DIR=str(src))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("working tree", result.stderr)
                result, _ = self.run_bg(setup + "bg_preflight",
                                        include_text=self.render(v1, 4002), NCC_SRC_DIR=str(src))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("edited by hand or has drifted", result.stderr)
                self.assertIn("working tree", result.stderr)

    def test_a_switch_back_restores_the_old_colours_template(self):
        src, old, _, v1, _ = self.template_repo()
        result, events = self.run_bg(self.served_as("blue", old) + f"bg_deploy {TARGET}",
                                     include_text=self.render(v1, 4002), NCC_SRC_DIR=str(src),
                                     CRASHES="green")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("switching back to blue", result.stderr)
        self.assertEqual(self.include, self.render(v1, 4002))
        self.assertEqual(self.running, ["blue"])

    def test_a_rollback_across_a_template_change_restores_the_old_template(self):
        src, old, new, v1, v2 = self.template_repo()
        result, _ = self.run_bg(
            self.served_as("blue", old) + self.served_as("green", new) + "bg_rollback && bg_preflight",
            active="green", include_text=self.render(v2, 4003), NCC_SRC_DIR=str(src))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.include, self.render(v1, 4002))
        self.assertEqual(self.cache, "blue")

    # --- I1: no other vhost may proxy straight to a colour port -------------

    def other_vhost(self, root_text, shape="namevhost"):
        """A second enabled vhost file and its apachectl -S line."""
        directory = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(directory, ignore_errors=True))
        other = Path(directory) / "other.test.conf"
        other.write_text(root_text)
        line = (f"         port 80 namevhost other.test ({other}:1)" if shape == "namevhost"
                else f"192.0.2.1:8080  other.test ({other}:1)")
        return other, line

    def test_preflight_refuses_another_vhost_that_proxies_straight_to_a_colour(self):
        for port in ("4002", "4003"):
            for shape in ("namevhost", "flat"):
                with self.subTest(port=port, shape=shape):
                    other, line = self.other_vhost(
                        f"<VirtualHost *:80>\n  ProxyPass / http://127.0.0.1:{port}/\n</VirtualHost>\n",
                        shape)
                    result, _ = self.run_bg("bg_preflight", EXTRA_S_LINES=line)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(str(other), result.stderr)
                    self.assertIn("proxies straight to", result.stderr)

    def test_preflight_passes_another_vhost_whose_direct_proxy_is_commented_out(self):
        _, line = self.other_vhost(
            "<VirtualHost *:80>\n  # ProxyPass / http://127.0.0.1:4002/\n"
            "  ProxyPass / http://127.0.0.1:40021/\n</VirtualHost>\n")
        result, _ = self.run_bg("bg_preflight", EXTRA_S_LINES=line)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_direct_proxy_check_refuses_when_apachectl_lists_nothing(self):
        for overrides in ({"VHOST": ""}, {"APACHE_S_STATUS": "1"}):
            with self.subTest(**overrides):
                result, _ = self.run_bg("bg_check_direct_proxies", **overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("refusing", result.stderr)
                self.assertIn("apachectl -S", result.stderr)

    def test_preflight_lists_every_vhost_file_in_both_line_shapes(self):
        result, _ = self.run_bg(
            "bg_all_vhost_files",
            APACHE_S_LINE="*:443                  is a NameVirtualHost\n"
                          "         default server a.test (/etc/x/a.conf:1)\n"
                          "         port 443 namevhost a.test (/etc/x/a.conf:1)\n"
                          "         port 443 namevhost a.test (/etc/x/a.conf:1)\n"
                          "192.0.2.1:80  b.test (/etc/x/b.conf:3)\n"
                          "ServerRoot: \"/etc/apache2\"",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), ["/etc/x/a.conf", "/etc/x/b.conf"])

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
        result, events = self.deploy(RELOAD_FAIL_ON="1")
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

    # --- CRITICAL 1: a failed enable/disable must not stop the new colour -

    def test_disable_failure_leaves_both_colours_running(self):
        result, events = self.deploy(DISABLE_FAILS="blue")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("127.0.0.1:4003/ retry=0", self.include)
        self.assertIn("incomplete", result.stderr)
        self.assertIn("green", self.running)
        self.assertIn("blue", self.running)
        self.assertNotIn("systemctl stop ncc-portal@green", events)
        self.assertNotIn("systemctl stop ncc-portal@blue", events)
        self.assertIn("systemctl enable ncc-portal@green", events)
        self.assertIn("systemctl disable ncc-portal@blue", events)

    def test_enable_failure_leaves_both_colours_running(self):
        result, events = self.deploy(ENABLE_FAILS="green")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("127.0.0.1:4003/ retry=0", self.include)
        self.assertIn("incomplete", result.stderr)
        self.assertIn("green", self.running)
        self.assertIn("blue", self.running)
        self.assertNotIn("systemctl stop ncc-portal@green", events)
        self.assertNotIn("systemctl stop ncc-portal@blue", events)
        # Chained with &&: a failed enable must short-circuit before disable.
        self.assertNotIn("systemctl disable ncc-portal@blue", events)

    # --- F2: the colour that serves is recorded even if marking it fails ---

    def test_a_failed_mark_after_the_switch_still_records_the_new_colour(self):
        for overrides in ({"DISABLE_FAILS": "blue"}, {"ENABLE_FAILS": "green"}):
            with self.subTest(**overrides):
                result, _ = self.deploy(**overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("incomplete", result.stderr)
                self.assertEqual(self.served["green"], TARGET)
                self.assertIn("served-green", result.stderr)

    def test_a_failed_mark_after_a_switch_back_still_records_the_old_colour(self):
        result, _ = self.run_bg(f'rm -f "$NCC_INSTALL_DIR/served-blue"; bg_deploy {TARGET}',
                                CRASHES="green", DISABLE_FAILS="green")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("127.0.0.1:4002/ retry=0", self.include)
        self.assertEqual(self.served, {"blue": OLD, "green": None})
        self.assertIn("served-blue", result.stderr)

    # --- IMPORTANT 1: a failed switch-back must not re-mark the cache or --
    # --- stop the colour that is still actually serving --------------------

    def test_switch_back_configtest_failure_keeps_the_new_colour_serving(self):
        result, events = self.deploy(CRASHES="green", CONFIGTEST_FAIL_ON="2")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("127.0.0.1:4003/ retry=0", self.include)
        self.assertEqual(self.cache, "green")
        self.assertIn("green", self.running)
        self.assertIn("could not switch back", result.stderr)
        self.assertIn("rpc blue Oban.resume_all_queues(Oban, local_only: true)", events)
        self.assertNotIn("systemctl stop ncc-portal@green", events)

    # --- IMPORTANT 2: the drain must actually watch the 30 s window --------

    def test_drain_watches_blue_for_at_least_7_probes_before_stopping_it(self):
        result, events = self.deploy(RUNNING_JOBS="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        pause_i = events.index("rpc blue Oban.pause_all_queues(Oban, local_only: true)")
        stop_i = events.index("systemctl stop ncc-portal@blue")
        shows = [i for i, e in enumerate(events)
                 if "systemctl show -p NRestarts" in e and "ncc-portal@green" in e and pause_i < i < stop_i]
        self.assertGreaterEqual(len(shows), 7)

    def test_drain_keeps_watching_until_the_running_count_actually_reaches_zero(self):
        result, events = self.deploy(RUNNING_JOBS_COUNTDOWN="3")
        self.assertEqual(result.returncode, 0, result.stderr)
        checks = [i for i, e in enumerate(events) if "check_all_queues" in e]
        # The harness's countdown says 2 on the first 3 calls and 0 from the
        # 4th on; that 4th call is the first one to report the drain done.
        self.assertGreaterEqual(len(checks), 4)
        first_zero = checks[3]
        stop_i = events.index("systemctl stop ncc-portal@blue")
        self.assertLess(first_zero, stop_i)
        shows = [i for i, e in enumerate(events)
                 if "systemctl show -p NRestarts" in e and i < stop_i]
        self.assertGreaterEqual(len(shows), 7)

    # --- IMPORTANT (round 2): the drain must finish only on a healthy probe,
    # --- and cap total misses too, not only consecutive ones ---------------

    def test_drain_tolerates_a_single_mid_drain_apache_miss(self):
        result, events = self.deploy(RUNNING_JOBS="0", APACHE_MISS_ON="2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.running, ["green"])

    def test_drain_two_consecutive_apache_misses_switch_back(self):
        result, events = self.deploy(APACHE_MISS_ON="2 3")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.running, ["blue"])
        self.assertIn("127.0.0.1:4002/ retry=0", self.include)

    def test_drain_waits_past_a_miss_on_what_would_have_been_the_last_probe(self):
        result, events = self.deploy(RUNNING_JOBS="0", APACHE_MISS_ON="7")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.running, ["green"])
        shows = [e for e in events
                 if "systemctl show -p NRestarts" in e and "ncc-portal@green" in e]
        # One baseline read in bg_activate plus the usual 7-probe watch
        # window is 8 matching calls when nothing misses; a miss on the 7th
        # probe must not let the drain finish there, so it has to run at
        # least one more iteration (9 calls total).
        self.assertGreaterEqual(len(shows), 9)

    def test_drain_three_non_consecutive_apache_misses_switch_back(self):
        result, events = self.deploy(APACHE_MISS_ON="2 4 6")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.running, ["blue"])

    def test_drain_tolerates_a_nonzero_but_stable_nrestarts_baseline(self):
        result, events = self.deploy(RUNNING_JOBS="0", NRESTARTS_BASE="2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.running, ["green"])

    def test_drain_switches_back_immediately_when_nrestarts_moves_off_a_nonzero_baseline(self):
        result, events = self.deploy(NRESTARTS_BASE="2", CRASHES="green")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.running, ["blue"])
        shows = [e for e in events
                 if "systemctl show -p NRestarts" in e and "ncc-portal@green" in e]
        # One baseline read in bg_activate, one crash-detecting read in
        # bg_drain's first iteration: the crash must be caught at once, not
        # after several misses accumulate.
        self.assertEqual(len(shows), 2)

    # --- N1 (round 3): the drain cap must not stop the old colour right ----
    # --- after a missed probe -----------------------------------------------

    def test_drain_cap_waits_past_a_miss_on_the_cap_probe(self):
        # Exact reproduction: at the cap, a miss must buy one more iteration
        # instead of stopping blue on the strength of a probe that just
        # failed.
        result, events = self.deploy(RUNNING_JOBS="3", BG_DRAIN_CAP_SECONDS="20",
                                     APACHE_MISS_ON="5")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("drain cap", result.stderr)
        self.assertEqual(self.running, ["green"])
        # The cap message must be logged exactly once, at the iteration that
        # actually exits (the 6th probe here), not on every over-cap pass.
        self.assertEqual(result.stderr.count("drain cap"), 1)

    def test_drain_cap_with_a_second_miss_right_after_the_cap_probe_switches_back(self):
        result, events = self.deploy(RUNNING_JOBS="3", BG_DRAIN_CAP_SECONDS="20",
                                     APACHE_MISS_ON="5 6")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.running, ["blue"])
        self.assertNotIn("drain cap", result.stderr)

    # --- S3: the old colour can also fail its own post-point-back verify ---

    def test_switch_back_old_colour_apache_verification_failure_restores_new_colour(self):
        result, events = self.deploy(CRASHES="green", APACHE_HEALTH_FAILS="blue")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("127.0.0.1:4003/ retry=0", self.include)
        self.assertIn("blue", self.running)
        self.assertIn("green", self.running)
        self.assertIn("does not answer through Apache after switching back", result.stderr)
        self.assertIn("green still serves", result.stderr)

    # --- S2: bg_point_apache_at's own restore must not be assumed to work --

    def test_switch_restore_reload_also_failing_is_apache_state_unknown(self):
        # Every reload call fails: the switch's first reload, then
        # bg_point_apache_at's own restore reload too. Unlike the plain
        # "restores and reloads again" case (RELOAD_FAIL_ON="1", the restore
        # reload succeeds), this must come back as state-unknown and leave
        # both colours running, not a clean, restored failure.
        result, events = self.deploy(RELOAD_STATUS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Apache state unknown after a failed restore", result.stderr)
        self.assertIn("blue", self.running)
        self.assertIn("green", self.running)
        self.assertNotIn("systemctl stop ncc-portal@blue", events)
        self.assertNotIn("systemctl stop ncc-portal@green", events)

    def test_switch_configtest_failure_with_a_failing_restore_mv_is_apache_state_unknown(self):
        result, events = self.deploy(CONFIGTEST_STATUS="1", MV_BAK_FAILS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Apache state unknown after a failed restore", result.stderr)
        self.assertIn("blue", self.running)
        self.assertIn("green", self.running)
        self.assertNotIn("systemctl stop ncc-portal@blue", events)
        self.assertNotIn("systemctl stop ncc-portal@green", events)

    def test_switch_reload_failure_with_a_failing_restore_mv_is_apache_state_unknown(self):
        result, events = self.deploy(RELOAD_STATUS="1", MV_BAK_FAILS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Apache state unknown after a failed restore", result.stderr)
        self.assertIn("blue", self.running)
        self.assertIn("green", self.running)
        self.assertNotIn("systemctl stop ncc-portal@blue", events)
        self.assertNotIn("systemctl stop ncc-portal@green", events)

    # --- Minors -------------------------------------------------------------

    def test_write_include_refuses_a_broken_render(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            upstream = root / "ncc-upstream.conf"
            upstream.write_text("original content\n")
            # M1a: sed itself fails (no template to read).
            src_missing = root / "src-missing"
            (src_missing / "ops").mkdir(parents=True)
            env = {**os.environ, "HELPER": str(OPS / "blue-green.sh"),
                   "NCC_SRC_DIR": str(src_missing), "NCC_APACHE_UPSTREAM": str(upstream)}
            result = subprocess.run(["bash", "-c", 'source "$HELPER"; bg_write_include 4002'],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("ERROR", result.stderr)
            self.assertEqual(upstream.read_text(), "original content\n")
            self.assertFalse((root / "ncc-upstream.conf.new").exists())

            # M1b: sed succeeds but the result never names the backend port.
            src_broken = root / "src-broken"
            (src_broken / "ops").mkdir(parents=True)
            (src_broken / "ops" / "ncc-upstream.conf.template").write_text("no port marker here\n")
            env["NCC_SRC_DIR"] = str(src_broken)
            result = subprocess.run(["bash", "-c", 'source "$HELPER"; bg_write_include 4002'],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("ERROR", result.stderr)
            self.assertEqual(upstream.read_text(), "original content\n")

    def test_builder_bind_wait_accepts_a_listener_that_is_off(self):
        result, events = self.deploy(BUILDER_OFF="green")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("has not bound the builder port", result.stderr)
        stop = events.index("systemctl stop ncc-portal@blue")
        probes = [e for e in events[stop:] if e == "curl http://127.0.0.1:4003/health"]
        self.assertEqual(len(probes), 1)

    def test_drain_warns_once_when_the_job_count_cannot_be_read(self):
        result, events = self.deploy(RUNNING_JOBS="{:badrpc, :nodedown}",
                                     BG_DRAIN_CAP_SECONDS="20")
        self.assertEqual(result.returncode, 0, result.stderr)
        warning = "cannot read the executing job count on blue"
        self.assertEqual(result.stderr.count(warning), 1, result.stderr)
        self.assertIn("portal-rpc.sh", result.stderr)
        # Unchanged behaviour: it still waits until the cap.
        self.assertIn("drain cap", result.stderr)
        self.assertEqual(self.running, ["green"])

    def test_drain_does_not_warn_on_a_readable_job_count(self):
        result, _ = self.deploy(RUNNING_JOBS="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("cannot read the executing job count", result.stderr)

    def test_builder_bind_wait_only_accepts_a_literal_bound_status(self):
        result, events = self.deploy(BUILDER_WAITING="green")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("has not bound the builder port", result.stderr)
        self.assertEqual(self.running, ["green"])

    def test_drain_cap_logs_the_executing_job_ids_best_effort(self):
        result, events = self.deploy(RUNNING_JOBS="3", BG_DRAIN_CAP_SECONDS="20")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("drain cap", result.stderr)
        self.assertIn("executing job id(s) on blue", result.stderr)

    def test_switch_restore_reload_failure_leaves_both_colours_running(self):
        result, events = self.deploy(APACHE_HEALTH_FAILS="green", RELOAD_FAIL_ON="2")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Apache state unknown", result.stderr)
        self.assertIn("blue", self.running)
        self.assertIn("green", self.running)
        self.assertNotIn("systemctl stop ncc-portal@blue", events)
        self.assertNotIn("systemctl stop ncc-portal@green", events)

    # --- rollback --------------------------------------------------------

    def test_rollback_starts_the_other_colour_without_building(self):
        result, events = self.run_bg("bg_rollback", active="green")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse([e for e in events if e.startswith(("build", "migrate"))])
        self.assertIn("127.0.0.1:4002/ retry=0", self.include)
        self.assertEqual((self.cache, self.running), ("blue", ["blue"]))

    # --- I2: the serving release's assets are carried before the switch ----

    def test_rollback_carries_the_serving_assets_before_starting(self):
        result, events = self.run_bg("bg_rollback", active="green")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("carry green blue", events)
        self.assertLess(events.index("carry green blue"),
                        events.index("systemctl start ncc-portal@blue"))

    # --- I3: only a release recorded as served is a rollback target --------

    def test_a_successful_deploy_records_what_each_colour_served(self):
        result, _ = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.served, {"blue": OLD, "green": TARGET})

    def test_rollback_after_a_successful_deploy_brings_back_the_previous_colour(self):
        result, events = self.run_bg(f"bg_deploy {TARGET} && bg_rollback")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("127.0.0.1:4002/ retry=0", self.include)
        self.assertEqual((self.cache, self.running), ("blue", ["blue"]))
        self.assertIn(f"bringing back blue (sha {OLD})", result.stdout)
        self.assertIn("carry green blue", events)
        self.assertEqual(self.served, {"blue": OLD, "green": TARGET})

    def test_rollback_verifies_the_recorded_sha(self):
        # blue's node answers a different sha than the one recorded: the
        # health checks catch it, and green keeps serving.
        result, events = self.run_bg(f'echo {TARGET} > "$STATE/sha-blue"; bg_rollback',
                                     active="green")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("127.0.0.1:4003/ retry=0", self.include)
        self.assertEqual((self.cache, self.running), ("green", ["green"]))
        self.assertIn(f"did not answer /health with sha {OLD}", result.stderr)

    def test_rollback_after_a_failed_deploy_refuses(self):
        failures = ({"BUILD_STATUS": "1"}, {"MIGRATE_STATUS": "1"}, {"BUILT_SHA": OLD},
                    {"CRASHES": "green"})
        for overrides in failures:
            with self.subTest(**overrides):
                result, events = self.run_bg(f"bg_deploy {TARGET} || true; bg_rollback",
                                             **overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("not one that ever served", result.stderr)
                self.assertIn("127.0.0.1:4002/ retry=0", self.include)
                self.assertEqual((self.cache, self.running), ("blue", ["blue"]))
                self.assertIsNone(self.served["green"])
                starts = [e for e in events if e == "systemctl start ncc-portal@green"]
                self.assertLessEqual(len(starts), 1, "rollback started the failed build")

    def test_rollback_after_a_failed_redeploy_of_the_same_sha_refuses(self):
        # The build stamps the same sha the directory served before, so only
        # the cleared served-<colour> tells the two apart.
        result, _ = self.run_bg(f'TARGET={OLD}; bg_deploy {OLD} || true; bg_rollback',
                                BUILD_STATUS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not one that ever served", result.stderr)

    def test_rollback_without_a_served_record_refuses(self):
        result, events = self.run_bg('rm -f "$NCC_INSTALL_DIR/served-blue"; bg_rollback',
                                     active="green")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not one that ever served", result.stderr)
        self.assertNotIn("systemctl start ncc-portal@blue", events)
        self.assertNotIn("carry green blue", events)

    def test_rollback_without_a_build_sha_refuses(self):
        result, events = self.run_bg(
            'rm -f "$NCC_INSTALL_DIR/releases/blue/BUILD_SHA"; bg_rollback', active="green")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sha unknown", result.stderr)
        self.assertNotIn("systemctl start ncc-portal@blue", events)

    def test_rollback_refuses_without_a_release_in_the_other_colour(self):
        result, events = self.run_bg('rm -rf "$NCC_INSTALL_DIR/releases/blue"; bg_rollback',
                                     active="green")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no release", result.stderr)
        self.assertNotIn("systemctl start ncc-portal@blue", events)

    def test_rollback_prints_the_target_release_sha(self):
        result, _ = self.run_bg(
            'for f in "$NCC_INSTALL_DIR/releases/blue/BUILD_SHA" "$NCC_INSTALL_DIR/served-blue" '
            '"$STATE/sha-blue"; do echo deadbeef > "$f"; done; bg_rollback',
            active="green")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("sha deadbeef", result.stdout)


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
