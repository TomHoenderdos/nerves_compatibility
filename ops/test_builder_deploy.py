"""Check queue draining and failure cleanup without touching a live builder."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).with_name("builder-deploy.sh")
RELEASE_BUILD = Path(__file__).with_name("build-release.sh")
SRC = Path(__file__).resolve().parent.parent
# Builds run on the rootful docker-ncc daemon. Its unix socket is
# root-only and unrestricted: the deploy, which runs as root, pulls, builds,
# loads and tags there, named by DOCKER_HOST in the deploy env file. ncc-portal
# reaches the same daemon only over mTLS, where the authz policy allows build
# containers and little else.
ROOT_SOCKET = "unix:///run/docker-ncc/docker.sock"
SYSTEM_SOCKET = "unix:///var/run/docker.sock"
PORTAL_DOCKER = {
    "DOCKER_HOST": "tcp://127.0.0.1:2376",
    "DOCKER_TLS_VERIFY": "1",
    "DOCKER_CERT_PATH": "/etc/ncc/docker-tls",
}
# A synthetic host layout, as the operator's deploy env file would set it.
LAYOUT = {
    "NCC_SRC_DIR": str(SRC),
    "NCC_INSTALL_DIR": "/test/install",
    "NCC_PORTAL_ENV": "/test/config/portal.env",
    "NCC_PORTAL_WORKDIR": "/test/work",
    "DOCKER_HOST": ROOT_SOCKET,
}
BASE_ENV = {**os.environ, **LAYOUT}
for _name in ("DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "DOCKER_CONTEXT"):
    BASE_ENV.pop(_name, None)
BASE_ENV.pop("XDG_RUNTIME_DIR", None)
HARNESS = r'''
set -euo pipefail
source "$HELPER"
builder_queues_available() { echo "$AVAILABLE"; }
# The egress filter is the host configuration's: anything that would install
# or load a ruleset shows up as an event the expected lists do not have.
install() { echo "install $*" >> "$EVENTS"; }
nft() { echo "nft $*" >> "$EVENTS"; }
sudo() { echo "sudo $*" >> "$EVENTS"; }
builder_pause() { echo pause >> "$EVENTS"; return "$PAUSE_STATUS"; }
builder_resume() { echo resume >> "$EVENTS"; return "$RESUME_STATUS"; }
builder_queues_drained() { cat "$DRAINED_FILE"; }
sleep() { echo wait >> "$EVENTS"; echo true > "$DRAINED_FILE"; }
builder_prepare
echo build >> "$EVENTS"
exit "$BUILD_STATUS"
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
        self.assertEqual(events, ["pause", "wait", "build", "resume"])

    # NixOS declares the table and reloads it with every nftables reload; a
    # ruleset loaded from here would be wiped by the next one, or wipe
    # NixOS's own (ops/builder-egress.nft starts with `delete table`).
    def test_a_builder_deploy_installs_and_loads_no_egress_ruleset(self):
        result, events = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, ["pause", "build", "resume"])

    def test_respects_a_preexisting_operator_pause(self):
        result, events = self.run_deploy(AVAILABLE="false")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, [])

    def test_drain_timeout_resumes_without_starting_a_build(self):
        result, events = self.run_deploy(drained="false", NCC_DEPLOY_DRAIN_SECONDS="0")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, ["pause", "resume"])

    def test_unexpected_queue_state_fails_closed(self):
        result, events = self.run_deploy(drained="unknown")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, ["pause", "resume"])

    def test_partial_pause_failure_restores_queues(self):
        result, events = self.run_deploy(PAUSE_STATUS="42")
        self.assertEqual(result.returncode, 42)
        self.assertEqual(events, ["pause", "resume"])

    def test_failed_build_preserves_failure_and_restores_queues(self):
        result, events = self.run_deploy(BUILD_STATUS="42")
        self.assertEqual(result.returncode, 42)
        self.assertEqual(events, ["pause", "build", "resume"])

    def test_resume_failure_is_reported(self):
        result, events = self.run_deploy(RESUME_STATUS="1")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(events, ["pause", "build", "resume"])

    def run_build_image(self, pull_status="0", **env):
        script = r'''
set -euo pipefail
source "$HELPER"
id() { echo 999; }
git() { echo 0123456789abcdef0123456789abcdef01234567; }
docker() {
  echo "docker $*" >> "$EVENTS"
  echo "docker ${DOCKER_HOST-unset}" >> "$HOSTS"
  [[ $1 != pull ]] || return "$PULL_STATUS"
}
make() { echo "make $*" >> "$EVENTS"; echo "make ${DOCKER_HOST-unset}" >> "$HOSTS"; }
sudo() { echo "sudo $*" >> "$HOSTS"; }
builder_build_image
'''
        with tempfile.TemporaryDirectory() as directory:
            events = Path(directory) / "events"
            hosts = Path(directory) / "hosts"
            result = subprocess.run(
                ["bash", "-c", script],
                env={**BASE_ENV, "HELPER": str(HELPER), "EVENTS": str(events),
                     "HOSTS": str(hosts), "PULL_STATUS": pull_status, **env},
                capture_output=True, text=True, timeout=5,
            )
            self.hosts = hosts.read_text().splitlines() if hosts.exists() else []
            return result, events.read_text().splitlines() if events.exists() else []

    # The portal's mTLS identity may not build, load or tag; a
    # rootless socket no longer exists. Every image change goes to docker-ncc's
    # root socket, as root, whichever way the image arrives.
    def test_every_image_change_goes_to_the_root_socket_of_docker_ncc(self):
        for overrides in ({}, {"pull_status": "1"}, {"NCC_WORKER_FROM_REGISTRY": "0"}):
            result, events = self.run_build_image(**overrides)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(events, overrides)
            self.assertEqual(
                sorted(set(self.hosts)),
                sorted({f"{line.split()[0]} {ROOT_SOCKET}" for line in self.hosts}),
                (overrides, self.hosts))
            self.assertFalse([h for h in self.hosts if h.startswith("sudo")], self.hosts)

    # Without it the docker CLI falls back to /var/run/docker.sock: where a
    # host has a system dockerd, one that runs no builds.
    def test_a_builder_deploy_without_docker_host_refuses(self):
        script = 'set -euo pipefail\nsource "$HELPER"\necho sourced\n'
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                ["bash", "-c", script],
                env={**BASE_ENV, "HELPER": str(HELPER), "DOCKER_HOST": "",
                     "NCC_DEPLOY_ENV": str(Path(directory) / "missing.env")},
                capture_output=True, text=True, timeout=5,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("sourced", result.stdout)
        self.assertIn("DOCKER_HOST", result.stderr)

    def test_activation_moves_every_tag_on_the_root_socket(self):
        script = r'''
set -euo pipefail
source "$HELPER"
builder_check_egress() { :; }
builder_warm_nerves() { :; }
builder_toolchain_tags() { echo ncc-toolchain:rpi4; }
id() { echo 999; }
docker() { echo "docker $* @${DOCKER_HOST-unset}" >> "$EVENTS"; }
builder_activate_image
'''
        with tempfile.TemporaryDirectory() as directory:
            events = Path(directory) / "events"
            result = subprocess.run(
                ["bash", "-c", script],
                env={**BASE_ENV, "HELPER": str(HELPER), "EVENTS": str(events)},
                capture_output=True, text=True, timeout=5,
            )
            lines = events.read_text().splitlines() if events.exists() else []
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"docker tag ncc-worker:deploy ncc-worker:local @{ROOT_SOCKET}", lines)
        self.assertIn(f"docker tag ncc-toolchain:rpi4-deploy ncc-toolchain:rpi4 @{ROOT_SOCKET}",
                      lines)
        self.assertTrue(all(line.endswith(f" @{ROOT_SOCKET}") for line in lines), lines)

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

    def test_deploy_warm_runs_the_new_release_as_ncc(self):
        result, args = self.run_warm(0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(args.startswith("-u\nncc\nbash\n-c\n"), args)
        self.assertIn('exec timeout 60m "$3" eval "$4"', args)
        self.assertIn("\n--\n/test/work\n/test/config/portal.env\n/test/install/portal/bin/portal\n",
                      args)
        self.assertIn("Portal.NervesCache.deploy_warm()", args)

    # The warm container is a build container: it runs as the portal does, on
    # docker-ncc's mTLS listener where the authz policy holds it to runsc,
    # never on the root socket the deploy itself uses. The eval runs under
    # sudo, outside the ncc-portal unit and its NixOS environment, so the
    # deploy has to hand it that identity; a rootless DOCKER_HOST left in
    # portal.env must not win.
    def test_deploy_warm_runs_on_the_portals_mtls_identity(self):
        script = r'''
set -euo pipefail
source "$HELPER"
# sudo resets the environment: the deploy's own variables do not reach ncc.
sudo() {
  [[ $1 == -u && $2 == ncc ]] || return 99
  shift 2
  env -i PATH="$PATH" EVENTS="$EVENTS" "$@"
}
builder_warm_nerves
'''
        for portal_env in ("", "DOCKER_HOST=unix:///run/user/950/docker.sock\n"):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "work").mkdir()
                bin_dir = root / "install/portal/bin"
                bin_dir.mkdir(parents=True)
                portal = bin_dir / "portal"
                portal.write_text(
                    '#!/bin/sh\n'
                    'printf "%s\\n" "DOCKER_HOST=${DOCKER_HOST-unset}" '
                    '"DOCKER_TLS_VERIFY=${DOCKER_TLS_VERIFY-unset}" '
                    '"DOCKER_CERT_PATH=${DOCKER_CERT_PATH-unset}" > "$EVENTS"\n')
                portal.chmod(0o755)
                stubs = root / "stubs"
                stubs.mkdir()
                (stubs / "timeout").write_text('#!/bin/sh\nshift\nexec "$@"\n')
                (stubs / "timeout").chmod(0o755)
                env_file = root / "portal.env"
                env_file.write_text(portal_env)
                events = root / "events"
                result = subprocess.run(
                    ["bash", "-c", script],
                    env={**BASE_ENV, "HELPER": str(HELPER), "EVENTS": str(events),
                         "PATH": f"{stubs}:{os.environ['PATH']}",
                         "NCC_INSTALL_DIR": str(root / "install"),
                         "NCC_PORTAL_WORKDIR": str(root / "work"),
                         "NCC_PORTAL_ENV": str(env_file)},
                    capture_output=True, text=True, timeout=5,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("Nerves cache warm failed", result.stderr)
                seen = dict(line.split("=", 1) for line in events.read_text().splitlines())
                self.assertEqual(seen, PORTAL_DOCKER, repr(portal_env))

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


class BuilderEgressCheckTest(unittest.TestCase):
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
            # The table sits in the host's namespace: advice about entering
            # the rootless daemon's namespace would send the operator astray.
            for stale in ("nsenter", "XDG_RUNTIME_DIR", "/run/user/"):
                self.assertNotIn(stale, result.stderr)
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


class RootlessDaemonGoneTest(unittest.TestCase):
    # No rootless fallback anywhere in what deploys a builder.
    def test_no_deploy_script_still_talks_to_a_rootless_daemon(self):
        ops = Path(__file__).parent
        files = sorted([*ops.glob("*.sh"), *ops.glob("*.nft"), ops / "deploy.env.example"])
        self.assertTrue(files)
        for path in files:
            text = path.read_text()
            for stale in ("/run/user/", "dockerd-rootless", "XDG_RUNTIME_DIR", "nsenter",
                          "systemctl --user"):
                self.assertNotIn(stale, text, f"{path.name} still mentions {stale}")

    def test_the_deploy_env_example_names_the_root_socket_and_no_ruleset(self):
        example = (Path(__file__).parent / "deploy.env.example").read_text()
        self.assertRegex(example, r"(?m)^DOCKER_HOST=unix:///run/docker-ncc/docker\.sock$")
        for gone in ("NCC_EGRESS_RULESET", "NCC_EGRESS_BRIDGE_RULESET", "NCC_DOCKER_ADMIN_HOST"):
            self.assertNotRegex(example, rf"(?m)^{gone}=", gone)


    # The web host builds its release on its system dockerd, and says so.
    def test_the_deploy_env_example_shows_the_web_hosts_daemon(self):
        example = (Path(__file__).parent / "deploy.env.example").read_text()
        self.assertRegex(example, r"(?m)^#\s*DOCKER_HOST=unix:///var/run/docker\.sock$")


class ReleaseBuildDaemonTest(unittest.TestCase):
    """build-release.sh runs a trusted hexpm/elixir container with no runtime
    flag. On a build host it runs as root on docker-ncc's root socket, the one
    path the authz policy leaves unrestricted."""

    def build(self, deploy_env="", **overrides):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            src = root / "src"
            (src / "_build/prod/rel/portal/bin").mkdir(parents=True)
            (root / "install").mkdir()
            stubs = root / "stubs"
            stubs.mkdir()
            for name, body in {
                "docker": 'echo "docker $1 @${DOCKER_HOST-unset}" >> "$EVENTS"\n',
                "chown": 'echo "chown $*" >> "$EVENTS"\n',
            }.items():
                (stubs / name).write_text("#!/bin/sh\n" + body)
                (stubs / name).chmod(0o755)
            env_file = root / "deploy.env"
            env_file.write_text(deploy_env)
            events = root / "events"
            env = {**BASE_ENV, "PATH": f"{stubs}:{os.environ['PATH']}", "EVENTS": str(events),
                   "NCC_SRC_DIR": str(src), "NCC_INSTALL_DIR": str(root / "install"),
                   "NCC_DEPLOY_ENV": str(env_file), **overrides}
            result = subprocess.run(
                ["bash", str(RELEASE_BUILD)], env=env, capture_output=True, text=True, timeout=10
            )
            return result, events.read_text().splitlines() if events.exists() else []

    def test_release_build_runs_on_the_root_socket(self):
        result, events = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([e for e in events if e.startswith("docker")],
                         [f"docker run @{ROOT_SOCKET}"])

    # A web host's deploy env names its system dockerd, and the release
    # builds there; a builder's never does.
    def test_a_web_hosts_release_build_runs_on_its_system_dockerd(self):
        result, events = self.build(deploy_env=f"DOCKER_HOST={SYSTEM_SOCKET}\n", DOCKER_HOST="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([e for e in events if e.startswith("docker")],
                         [f"docker run @{SYSTEM_SOCKET}"])

    def test_a_builders_release_build_never_runs_on_the_system_dockerd(self):
        result, events = self.build(deploy_env=f"DOCKER_HOST={ROOT_SOCKET}\n", DOCKER_HOST="")
        self.assertEqual(result.returncode, 0, result.stderr)
        docker = [e for e in events if e.startswith("docker")]
        self.assertTrue(docker)
        self.assertFalse([e for e in docker if SYSTEM_SOCKET in e], docker)

    # From the deploy env file, like the rest of the host layout.
    def test_release_build_reads_the_socket_from_the_deploy_env_file(self):
        result, events = self.build(deploy_env=f"DOCKER_HOST={ROOT_SOCKET}\n", DOCKER_HOST="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([e for e in events if e.startswith("docker")],
                         [f"docker run @{ROOT_SOCKET}"])

    # Without it the CLI falls back to /var/run/docker.sock: a system dockerd
    # where there is one, nothing elsewhere.
    def test_release_build_without_docker_host_runs_nothing(self):
        result, events = self.build(DOCKER_HOST="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DOCKER_HOST", result.stderr)
        self.assertFalse([e for e in events if e.startswith("docker")], events)


if __name__ == "__main__":
    unittest.main()
