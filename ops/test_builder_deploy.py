"""Check queue draining and failure cleanup without touching a live builder."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).with_name("builder-deploy.sh")
SRC = Path(__file__).resolve().parent.parent
# A synthetic host layout, as the operator's deploy env file would set it.
LAYOUT = {
    "NCC_SRC_DIR": str(SRC),
    "NCC_INSTALL_DIR": "/test/install",
    "NCC_PORTAL_ENV": "/test/config/portal.env",
    "NCC_PORTAL_WORKDIR": "/test/work",
    "NCC_EGRESS_RULESET": "/test/config/builder-egress.nft",
    "NCC_EGRESS_BRIDGE_RULESET": "/test/config/builder-egress-bridge.nft",
}
BASE_ENV = {**os.environ, **LAYOUT}
HARNESS = r'''
set -euo pipefail
source "$HELPER"
builder_queues_available() { echo "$AVAILABLE"; }
builder_install_egress() { echo egress >> "$EVENTS"; return "$EGRESS_STATUS"; }
builder_pause() { echo pause >> "$EVENTS"; return "$PAUSE_STATUS"; }
builder_resume() { echo resume >> "$EVENTS"; return "$RESUME_STATUS"; }
builder_queues_drained() { cat "$DRAINED_FILE"; }
sleep() { echo wait >> "$EVENTS"; echo true > "$DRAINED_FILE"; }
builder_prepare
echo build >> "$EVENTS"
exit "$BUILD_STATUS"
'''

INSTALL_HARNESS = r'''
set -euo pipefail
source "$HELPER"
id() { case "$1" in -u) echo 999 ;; -gn) echo nccgrp ;; esac; }
install() {
  echo "install $*" >> "$EVENTS"
  if [[ $1 == -d ]]; then mkdir -p "${@: -1}"; return 0; fi
  [[ ${INSTALL_STATUS:-0} == 0 ]] || return "$INSTALL_STATUS"
  case "${@: -1}" in "$NCC_HOME"/*) cp "${@: -2:1}" "${@: -1}" ;; esac
}
systemctl() { echo "systemctl $*" >> "$EVENTS"; }
# Runs what ncc may do to its own home for real, under the temporary home.
sudo() {
  echo "sudo $*" >> "$EVENTS"
  [[ $1 == -u && $2 == ncc ]] || return 99
  shift 2
  case "$1" in
    install) mkdir -p "${@: -1}" ;;
    tee) cat > "${@: -1}" ;;
    chmod) command chmod "$2" "$3" ;;
    *) return "${LOAD_STATUS:-0}" ;;
  esac
}
builder_ncc_home() { echo "$NCC_HOME"; }
builder_is_nixos() { [[ ${IS_NIXOS:-0} == 1 ]]; }
builder_install_egress
'''


class BuilderDeploymentTest(unittest.TestCase):
    def run_deploy(self, drained="true", **overrides):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            events = root / "events"
            state = root / "drained"
            state.write_text(drained)
            env = {
                **BASE_ENV,
                "HELPER": str(HELPER),
                "EVENTS": str(events),
                "DRAINED_FILE": str(state),
                "AVAILABLE": "true",
                "EGRESS_STATUS": "0",
                "PAUSE_STATUS": "0",
                "RESUME_STATUS": "0",
                "BUILD_STATUS": "0",
                "NCC_DEPLOY_DRAIN_SECONDS": "60",
                **overrides,
            }
            result = subprocess.run(
                ["bash", "-c", HARNESS], env=env, capture_output=True, text=True, timeout=5
            )
            return result, events.read_text().splitlines() if events.exists() else []

    def test_waits_for_running_jobs_before_building(self):
        result, events = self.run_deploy(drained="false")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, ["egress", "pause", "wait", "build", "resume"])

    def test_respects_a_preexisting_operator_pause(self):
        result, events = self.run_deploy(AVAILABLE="false")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, [])

    def test_an_egress_filter_that_will_not_load_stops_before_the_pause(self):
        result, events = self.run_deploy(EGRESS_STATUS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, ["egress"])
        self.assertIn("egress filter", result.stderr)

    def test_drain_timeout_resumes_without_starting_a_build(self):
        result, events = self.run_deploy(drained="false", NCC_DEPLOY_DRAIN_SECONDS="0")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, ["egress", "pause", "resume"])

    def test_unexpected_queue_state_fails_closed(self):
        result, events = self.run_deploy(drained="unknown")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, ["egress", "pause", "resume"])

    def test_partial_pause_failure_restores_queues(self):
        result, events = self.run_deploy(PAUSE_STATUS="42")
        self.assertEqual(result.returncode, 42)
        self.assertEqual(events, ["egress", "pause", "resume"])

    def test_failed_build_preserves_failure_and_restores_queues(self):
        result, events = self.run_deploy(BUILD_STATUS="42")
        self.assertEqual(result.returncode, 42)
        self.assertEqual(events, ["egress", "pause", "build", "resume"])

    def test_resume_failure_is_reported(self):
        result, events = self.run_deploy(RESUME_STATUS="1")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(events, ["egress", "pause", "build", "resume"])

    def run_build_image(self, pull_status="0", **env):
        script = r'''
set -euo pipefail
source "$HELPER"
id() { echo 999; }
git() { echo 0123456789abcdef0123456789abcdef01234567; }
docker() {
  echo "docker $*" >> "$EVENTS"
  test "$DOCKER_HOST" = unix:///run/user/999/docker.sock
  [[ $1 != pull ]] || return "$PULL_STATUS"
}
make() { echo "make $*" >> "$EVENTS"; }
builder_build_image
'''
        with tempfile.TemporaryDirectory() as directory:
            events = Path(directory) / "events"
            result = subprocess.run(
                ["bash", "-c", script],
                env={**BASE_ENV, "HELPER": str(HELPER), "EVENTS": str(events),
                     "PULL_STATUS": pull_status, **env},
                capture_output=True, text=True, timeout=5,
            )
            return result, events.read_text().splitlines() if events.exists() else []

    def test_pulls_the_commits_registry_image_instead_of_building(self):
        result, events = self.run_build_image()
        self.assertEqual(result.returncode, 0, result.stderr)
        image = "ghcr.io/tomhoenderdos/ncc-worker:0123456789abcdef0123456789abcdef01234567"
        self.assertIn(f"docker pull -q {image}", events)
        self.assertIn(f"docker tag {image} ncc-worker:deploy", events)
        self.assertNotIn("make build WORKER_IMAGE=ncc-worker:deploy", events)

    def test_builds_locally_when_the_registry_image_is_missing(self):
        result, events = self.run_build_image(pull_status="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("make build WORKER_IMAGE=ncc-worker:deploy", events)
        self.assertFalse(any(e.startswith("docker tag") for e in events))
        self.assertIn("building locally", result.stderr)

    def test_registry_pull_can_be_turned_off(self):
        result, events = self.run_build_image(NCC_WORKER_FROM_REGISTRY="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(e.startswith("docker pull") for e in events))
        self.assertIn("make build WORKER_IMAGE=ncc-worker:deploy", events)

    def test_rootless_daemon_setting_does_not_leak_into_release_build(self):
        script = r'''
set -euo pipefail
source "$HELPER"
unset DOCKER_HOST
id() { echo 999; }
make() { test "$DOCKER_HOST" = unix:///run/user/999/docker.sock; }
docker() { test "$DOCKER_HOST" = unix:///run/user/999/docker.sock; }
sudo() { :; }
builder_build_image
builder_activate_image
test -z "${DOCKER_HOST+x}"
'''
        result = subprocess.run(
            ["bash", "-c", script], env={**BASE_ENV, "HELPER": str(HELPER)},
            capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


    def run_warm(self, status, running=""):
        script = r'''
set -euo pipefail
source "$HELPER"
sudo() { printf '%s\n' "$@" > "$EVENTS"; return "$WARM_STATUS"; }
builder_docker() {
  echo "docker $*" >> "$DOCKER_EVENTS"
  if [ "$1" = ps ]; then printf '%s' "$RUNNING"; fi
}
builder_warm_nerves
'''
        with tempfile.TemporaryDirectory() as directory:
            events = Path(directory) / "events"
            docker_events = Path(directory) / "docker"
            result = subprocess.run(
                ["bash", "-c", script],
                env={**BASE_ENV, "HELPER": str(HELPER), "EVENTS": str(events),
                     "DOCKER_EVENTS": str(docker_events), "RUNNING": running,
                     "WARM_STATUS": str(status)},
                capture_output=True, text=True, timeout=5,
            )
            self.docker_calls = (
                docker_events.read_text().splitlines() if docker_events.exists() else []
            )
            return result, events.read_text() if events.exists() else ""

    def test_deploy_warm_runs_the_new_release_as_ncc_on_its_rootless_daemon(self):
        result, args = self.run_warm(0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(args.startswith("-u\nncc\nbash\n-c\n"), args)
        self.assertIn('exec timeout 60m "$3" eval "$4"', args)
        self.assertIn("\n--\n/test/work\n/test/config/portal.env\n/test/install/portal/bin/portal\n",
                      args)
        self.assertIn("Portal.NervesCache.deploy_warm()", args)
        self.assertIn('DOCKER_HOST="${DOCKER_HOST:-unix:///run/user/$(id -u)/docker.sock}"', args)

    def test_a_failed_deploy_warm_warns_and_does_not_fail_the_deploy(self):
        result, _args = self.run_warm(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Nerves cache warm failed", result.stderr)
        self.assertIn("may still hold untrusted entries", result.stderr)
        self.assertIn("retried next deploy", result.stderr)

    # Killing the eval BEAM ends Portal.Builder's own wall clock; docker run
    # would go on writing the cache, and its ncc- name stalls Sweep.
    def test_a_timed_out_warm_kills_its_container(self):
        result, _args = self.run_warm(124, running="abc123\ndef456\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.docker_calls,
            ["docker ps -q --filter name=^ncc-warm_nerves-", "docker kill abc123 def456"],
        )
        self.assertIn("Nerves cache warm failed", result.stderr)

    def test_a_timed_out_warm_with_no_container_left_kills_nothing(self):
        result, _args = self.run_warm(124)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.docker_calls, ["docker ps -q --filter name=^ncc-warm_nerves-"])

    def test_a_warm_that_failed_otherwise_touches_no_container(self):
        result, _args = self.run_warm(1, running="abc123\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.docker_calls, [])

    def run_activation(self, check_status="0"):
        script = r'''
set -euo pipefail
source "$HELPER"
builder_check_egress() { echo check >> "$EVENTS"; return "$CHECK_STATUS"; }
builder_docker() { echo "docker $*" >> "$EVENTS"; }
builder_toolchain_tags() { :; }
builder_warm_nerves() { echo warm >> "$EVENTS"; }
builder_activate_image
'''
        with tempfile.TemporaryDirectory() as directory:
            events = Path(directory) / "events"
            result = subprocess.run(
                ["bash", "-c", script],
                env={**BASE_ENV, "HELPER": str(HELPER), "EVENTS": str(events),
                     "CHECK_STATUS": check_status},
                capture_output=True, text=True, timeout=5,
            )
            return result, events.read_text().splitlines() if events.exists() else []

    def test_activation_warms_the_cache_after_moving_the_tags(self):
        result, lines = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(lines[0], "check")
        self.assertEqual(lines[-1], "warm")
        self.assertIn("docker tag ncc-worker:deploy ncc-worker:local", lines[:-1])

    def test_a_failed_egress_check_moves_no_tag(self):
        result, lines = self.run_activation(check_status="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(lines, ["check"])


class BuilderEgressInstallTest(unittest.TestCase):
    def install(self, portal_env="", **overrides):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            events = root / "events"
            home = root / "home"
            home.mkdir()
            env_file = root / "portal.env"
            env_file.write_text(portal_env)
            env = {
                **BASE_ENV,
                "HELPER": str(HELPER),
                "EVENTS": str(events),
                "NCC_HOME": str(home),
                "NCC_PORTAL_ENV": str(env_file),
                **overrides,
            }
            result = subprocess.run(
                ["bash", "-c", INSTALL_HARNESS], env=env, capture_output=True, text=True, timeout=5
            )
            dropin = home / ".config/systemd/user/docker.service.d/ncc-egress.conf"
            lines = events.read_text().splitlines() if events.exists() else []
            self.home = home
            self.dropin_mode = dropin.stat().st_mode & 0o777 if dropin.exists() else None
            return result, lines, dropin.read_text() if dropin.exists() else None

    def test_installs_rules_loader_and_dropin_then_loads_as_ncc(self):
        result, lines, dropin = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            f"install -o root -g root -m 0644 {SRC}/ops/builder-egress.nft "
            "/test/config/builder-egress.nft", lines)
        self.assertIn(
            f"install -o root -g root -m 0644 {SRC}/ops/builder-egress-bridge.nft "
            "/test/config/builder-egress-bridge.nft", lines)
        self.assertIn(
            f"install -o root -g root -m 0755 {SRC}/ops/builder-egress-load.sh "
            "/test/install/builder-egress-load.sh", lines)
        self.assertIn("ExecStartPost=-/test/install/builder-egress-load.sh", dropin)
        self.assertIn("systemctl --user -M ncc@ daemon-reload", lines)
        dir = f"{self.home}/.config/systemd/user/docker.service.d"
        # ncc writes its own home: root never creates or writes a path ncc
        # could have swapped for a link into /etc/systemd.
        self.assertIn(f"sudo -u ncc install -d -m 0755 {dir}", lines)
        self.assertIn(f"sudo -u ncc tee {dir}/ncc-egress.conf", lines)
        self.assertIn(f"sudo -u ncc chmod 0644 {dir}/ncc-egress.conf", lines)
        self.assertLess(
            lines.index(f"sudo -u ncc tee {dir}/ncc-egress.conf"),
            lines.index("systemctl --user -M ncc@ daemon-reload"))
        self.assertFalse(
            [line for line in lines if line.startswith("install ") and str(self.home) in line],
            lines)
        self.assertEqual(self.dropin_mode, 0o644)
        self.assertEqual(
            lines[-1],
            "sudo -u ncc env XDG_RUNTIME_DIR=/run/user/999 "
            "/test/install/builder-egress-load.sh")
        self.assertLess(lines.index("systemctl --user -M ncc@ daemon-reload"), len(lines) - 1)

    def test_nixos_leaves_the_unit_to_its_nix_config_but_still_loads(self):
        result, lines, dropin = self.install(IS_NIXOS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(dropin)
        self.assertFalse(any(line.startswith("systemctl") for line in lines))
        self.assertTrue(lines[-1].startswith("sudo -u ncc env XDG_RUNTIME_DIR=/run/user/999"))
        self.assertIn("nix", result.stdout)

    def test_the_rollback_switch_leaves_the_filter_alone(self):
        result, lines, dropin = self.install(portal_env="NCC_EGRESS_CHECK=0\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(lines, [])
        self.assertIsNone(dropin)

    def test_a_failed_load_fails_the_install(self):
        result, _lines, _dropin = self.install(LOAD_STATUS="1")
        self.assertNotEqual(result.returncode, 0)

    def test_a_failed_copy_stops_before_loading(self):
        result, lines, _dropin = self.install(INSTALL_STATUS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(line.startswith("sudo") for line in lines))

    def test_check_runs_the_new_release_as_ncc(self):
        script = r'''
set -euo pipefail
source "$HELPER"
sudo() { printf '%s\n' "$@" > "$EVENTS"; return "$CHECK_STATUS"; }
builder_check_egress
'''
        for status, expect_ok in (("0", True), ("1", False)):
            with tempfile.TemporaryDirectory() as directory:
                events = Path(directory) / "events"
                result = subprocess.run(
                    ["bash", "-c", script],
                    env={**BASE_ENV, "HELPER": str(HELPER), "EVENTS": str(events),
                         "CHECK_STATUS": status},
                    capture_output=True, text=True, timeout=5,
                )
                args = events.read_text()
                self.assertTrue(args.startswith("-u\nncc\nbash\n-c\n"), args)
                self.assertIn('exec "$3" eval "$4"', args)
                self.assertIn("\n--\n/test/work\n/test/config/portal.env\n"
                              "/test/install/portal/bin/portal\n", args)
                self.assertIn("Portal.Builder.check_egress()", args)
                self.assertEqual(result.returncode == 0, expect_ok, result.stderr)
                if not expect_ok:
                    self.assertIn("egress filter", result.stderr)

    def check_running(self, answer, status="0", portal_env="", **overrides):
        script = r'''
set -euo pipefail
source "$HELPER"
builder_rpc() { printf '%s\n' "$1" > "$EVENTS"; printf '%s\n' "$ANSWER"; return "$RPC_STATUS"; }
builder_check_running_egress
echo after
'''
        with tempfile.TemporaryDirectory() as directory:
            events = Path(directory) / "events"
            env_file = Path(directory) / "portal.env"
            env_file.write_text(portal_env)
            env = {key: value for key, value in BASE_ENV.items() if key != "NCC_EGRESS_CHECK"}
            env.update(HELPER=str(HELPER), EVENTS=str(events), ANSWER=answer,
                       RPC_STATUS=status, NCC_PORTAL_ENV=str(env_file), **overrides)
            result = subprocess.run(
                ["bash", "-c", script], env=env, capture_output=True, text=True, timeout=5
            )
            return result, events.read_text() if events.exists() else None

    def test_the_running_service_is_asked_after_the_restart(self):
        result, rpc = self.check_running(":ok")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rpc, "IO.inspect(Portal.Builder.check_egress())\n")
        self.assertIn("after", result.stdout)

    def test_a_running_service_without_the_filter_fails_loudly(self):
        for answer, status in (("{:error, :egress_filter_missing}", "0"),
                               ("--rpc-eval : RPC failed with reason :nodedown", "1"),
                               ("", "0")):
            result, _rpc = self.check_running(answer, status=status)
            self.assertNotEqual(result.returncode, 0, answer)
            self.assertNotIn("after", result.stdout)
            self.assertIn("ERROR: the running ncc-portal finds no build egress filter",
                          result.stderr)
            self.assertIn("RestrictNamespaces", result.stderr)
            self.assertIn("PrivateUsers", result.stderr)
            if answer:
                self.assertIn(answer, result.stderr)

    def test_the_rollback_switch_skips_the_running_check(self):
        for kwargs in ({"portal_env": "NCC_EGRESS_CHECK=0\n"}, {"NCC_EGRESS_CHECK": "0"}):
            result, rpc = self.check_running("{:error, :egress_filter_missing}", **kwargs)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIsNone(rpc)

    def test_deploy_asks_the_running_service_only_after_it_is_up(self):
        deploy = (Path(__file__).with_name("deploy.sh")).read_text()
        restart = deploy.index("systemctl restart ncc-portal")
        up = deploy.rindex("\nsleep_until_up\n")
        check = deploy.index("builder_check_running_egress")
        self.assertLess(restart, up)
        self.assertLess(up, check)
        self.assertIn("if [[ ${2:-portal} == builder ]]; then\n  builder_check_running_egress",
                      deploy)


if __name__ == "__main__":
    unittest.main()
