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
builder_portal_invocation() { echo "$INVOCATION"; }
# The egress filter is the host configuration's: anything that would install
# or load a ruleset shows up as an event the expected lists do not have.
install() { echo "install $*" >> "$EVENTS"; }
nft() { echo "nft $*" >> "$EVENTS"; }
sudo() { echo "sudo $*" >> "$EVENTS"; }
builder_pause() { echo pause >> "$EVENTS"; return "$PAUSE_STATUS"; }
builder_resume() { echo resume >> "$EVENTS"; return "$RESUME_STATUS"; }
builder_queues_drained() { cat "$DRAINED_FILE"; }
sleep() { echo wait >> "$EVENTS"; echo true > "$DRAINED_FILE"; }
docker() {
  echo "docker $* @${DOCKER_HOST-unset}" >> "$DOCKER_EVENTS"
  [[ $1 != info ]] || printf '%s\n' "$DEFAULT_RUNTIME"
  return "$INFO_STATUS"
}
builder_prepare
echo build >> "$EVENTS"
exit "$BUILD_STATUS"
'''

class BuilderDeploymentTest(unittest.TestCase):
    INVOCATION = "0123456789abcdef0123456789abcdef"

    def run_deploy(self, drained="true", marker=None, **overrides):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            install = root / "install"
            install.mkdir()
            marker_file = install / "builder-paused-by-deploy"
            if marker is not None:
                marker_file.write_text(marker)
            events = root / "events"
            docker_events = root / "docker"
            state = root / "drained"
            state.write_text(drained)
            env = {
                **BASE_ENV,
                "HELPER": str(HELPER),
                "EVENTS": str(events),
                "DOCKER_EVENTS": str(docker_events),
                "DRAINED_FILE": str(state),
                "AVAILABLE": "true",
                "NCC_INSTALL_DIR": str(install),
                "INVOCATION": self.INVOCATION,
                "PAUSE_STATUS": "0",
                "RESUME_STATUS": "0",
                "BUILD_STATUS": "0",
                "DEFAULT_RUNTIME": "runsc",
                "INFO_STATUS": "0",
                "NCC_DEPLOY_DRAIN_SECONDS": "60",
                **overrides,
            }
            result = subprocess.run(
                ["bash", "-c", HARNESS], env=env, capture_output=True, text=True, timeout=5
            )
            self.docker_calls = (
                docker_events.read_text().splitlines() if docker_events.exists() else []
            )
            self.marker = marker_file.read_text() if marker_file.exists() else None
            return result, events.read_text().splitlines() if events.exists() else []

    # Every build container needs runsc, and the authz policy denies any
    # other: a daemon whose default runtime is not runsc is not set up for
    # this release. Refuse before any queue pauses or image moves.
    def test_prepare_asks_docker_host_for_its_default_runtime(self):
        result, events = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.docker_calls,
                         [f"docker info --format {{{{.DefaultRuntime}}}} @{ROOT_SOCKET}"])
        self.assertEqual(events, ["pause", "build", "resume"])

    def test_a_daemon_without_runsc_as_default_refuses_before_anything_moves(self):
        for overrides in ({"DEFAULT_RUNTIME": "runc"}, {"DEFAULT_RUNTIME": "", "INFO_STATUS": "1"}):
            result, events = self.run_deploy(**overrides)
            self.assertNotEqual(result.returncode, 0, overrides)
            self.assertEqual(events, [], overrides)
            self.assertIn("runsc", result.stderr)
            self.assertIn(ROOT_SOCKET, result.stderr)
            if overrides["DEFAULT_RUNTIME"]:
                self.assertIn("'runc'", result.stderr)

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

    # A pause with no marker, or a marker from an ncc-portal process that
    # has since restarted, is not this flow's: it is the operator's, and
    # stands.
    def test_a_paused_queue_without_a_current_marker_refuses(self):
        for marker in (None, f"{'f' * 32}\ndraining\n", f"{self.INVOCATION}\nunknown\n", ""):
            with self.subTest(marker=marker):
                result, events = self.run_deploy(AVAILABLE="paused", marker=marker)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(events, [])
                self.assertIn("already paused", result.stderr)
                self.assertEqual(self.marker, marker)

    # Running queues end whatever pause a marker described, so the marker
    # goes: kept, it would let a later run take over a pause an operator
    # then made on the same process.
    def test_running_queues_clear_a_stale_marker(self):
        # This run writes no marker of its own (no InvocationID) and cannot
        # resume, so only the clear can have removed the stale one.
        result, events = self.run_deploy(RESUME_STATUS="1", INVOCATION="",
                                         marker=f"{self.INVOCATION}\nactivating\n")
        self.assertEqual(result.returncode, 1)
        self.assertIsNone(self.marker)
        self.assertNotIn("taking the pause over", result.stdout)

        result, events = self.run_deploy(marker=f"{self.INVOCATION}\nactivating\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, ["pause", "build", "resume"])
        self.assertIsNone(self.marker)

    # No InvocationID to compare with: nothing can be taken over.
    def test_a_marker_is_not_trusted_without_the_services_invocation_id(self):
        result, events = self.run_deploy(AVAILABLE="paused", INVOCATION="",
                                         marker=f"{self.INVOCATION}\ndraining\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, [])

    # An earlier run of this deploy paused the queues of the same process
    # and never resumed them (killed mid-drain, say): the next run takes the
    # pause over, drains, and resumes as if the pause were its own.
    def test_a_pause_an_earlier_deploy_left_on_this_process_is_taken_over(self):
        result, events = self.run_deploy(AVAILABLE="paused", drained="false",
                                         marker=f"{self.INVOCATION}\ndraining\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, ["pause", "wait", "build", "resume"])
        self.assertIn("taking the pause over", result.stdout)
        self.assertIsNone(self.marker)

    def test_a_taken_over_pause_is_resumed_when_this_run_fails_before_activating(self):
        result, events = self.run_deploy(AVAILABLE="paused", BUILD_STATUS="42",
                                         marker=f"{self.INVOCATION}\ndraining\n")
        self.assertEqual(result.returncode, 42)
        self.assertEqual(events, ["pause", "build", "resume"])
        self.assertIsNone(self.marker)

    # One left while activating stays paused for that run's reason (the old
    # release's builds are denied) until this run activates.
    def test_a_pause_left_while_activating_stays_until_this_run_activates(self):
        result, events = self.run_deploy(AVAILABLE="paused", BUILD_STATUS="42",
                                         marker=f"{self.INVOCATION}\nactivating\n")
        self.assertEqual(result.returncode, 42)
        self.assertEqual(events, ["pause", "build"])
        self.assertIn("stay paused", result.stderr)
        self.assertEqual(self.marker, f"{self.INVOCATION}\nactivating\n")

    # The marker lives from the pause until this flow resumes: a run that
    # resumes removes it, and one that cannot resume keeps it for the next.
    def test_the_pause_marker_names_the_process_and_goes_with_the_resume(self):
        result, events = self.run_deploy(BUILD_STATUS="42")
        self.assertEqual(result.returncode, 42)
        self.assertIsNone(self.marker)

        result, events = self.run_deploy(RESUME_STATUS="1")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.marker, f"{self.INVOCATION}\ndraining\n")

    # Without an InvocationID or a writable install directory the deploy
    # still runs; only a pause it leaves behind will refuse the next run.
    def test_a_marker_that_cannot_be_written_does_not_stop_the_deploy(self):
        for overrides in ({"INVOCATION": ""}, {"NCC_INSTALL_DIR": "/nonexistent/install"}):
            with self.subTest(overrides=overrides):
                result, events = self.run_deploy(RESUME_STATUS="1", **overrides)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(events, ["pause", "build", "resume"])
                self.assertIn("will need an operator", result.stderr)
                self.assertIsNone(self.marker)

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

    # A job whose process hung on this node after its row was rescued and
    # retried elsewhere stays in the producer's running list. The running
    # release reports it as an orphan (Portal.BuilderDrain) instead of a
    # job to wait for: the drain completes and the deploy log names it.
    # Nothing is killed from here.
    ORPHAN = ("orphan queue=builds job=4242 worker=Portal.Workers.Build state=available "
              "attempted_by=node-b,uuid container=ncc-jason-1.4.1-*")

    def test_an_orphaned_job_does_not_hold_the_drain_and_is_named(self):
        result, events = self.run_deploy(drained=f"true\n{self.ORPHAN}\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, ["pause", "build", "resume"])
        self.assertIn("job=4242", result.stderr)
        self.assertIn("ncc-jason-1.4.1-*", result.stderr)
        self.assertIn("not killed", result.stderr)
        self.assertNotIn("kill", " ".join(self.docker_calls))

    def test_a_live_job_beside_an_orphan_is_still_waited_for(self):
        result, events = self.run_deploy(drained=f"false\n{self.ORPHAN}\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, ["pause", "wait", "build", "resume"])

    def test_an_orphan_line_alone_is_not_a_verdict(self):
        result, events = self.run_deploy(drained=f"{self.ORPHAN}\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, ["pause", "resume"])

    # The drain question goes to the running release, which may predate
    # Portal.BuilderDrain: it then answers as before, from the producer's
    # running list alone.
    def test_the_drain_query_falls_back_for_an_older_running_release(self):
        script = r'''
set -euo pipefail
source "$HELPER"
builder_rpc() { printf '%s' "$1" > "$OUT"; }
builder_queues_drained
'''
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "rpc"
            result = subprocess.run(
                ["bash", "-c", script],
                env={**BASE_ENV, "HELPER": str(HELPER), "OUT": str(out)},
                capture_output=True, text=True, timeout=5,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            expression = out.read_text()
        self.assertIn("Portal.BuilderDrain.report(", expression)
        self.assertIn("function_exported?(Portal.BuilderDrain, :report, 1)", expression)
        self.assertIn("%{paused: true, running: []}", expression)

    def rendered_rpc(self, function):
        script = r'''
set -euo pipefail
source "$HELPER"
builder_rpc() { printf '%s' "$1" > "$OUT"; }
"$FUNCTION"
'''
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "rpc"
            result = subprocess.run(
                ["bash", "-c", script],
                env={**BASE_ENV, "HELPER": str(HELPER), "OUT": str(out), "FUNCTION": function},
                capture_output=True, text=True, timeout=5,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return out.read_text()

    # A queue the running release paused by itself, because a host check
    # failed (Portal.Builder.AutoPause), is no operator's pause: it must not
    # refuse the deploy. A release from before the module pauses nothing.
    def test_a_queue_the_release_paused_by_itself_counts_as_running(self):
        expression = self.rendered_rpc("builder_queues_available")
        self.assertIn("function_exported?(Portal.Builder.AutoPause, :held_queues, 0)", expression)
        self.assertIn("Portal.Builder.AutoPause.held_queues()", expression)
        self.assertIn("else: []", expression)
        self.assertIn("if to_string(queue) in auto_paused, do: :running, else: :paused", expression)

    # The release lets go of its own pauses before the deploy pauses, so it
    # can never resume a queue the deploy paused.
    def test_the_release_lets_go_of_its_own_pauses_before_the_deploy_pauses(self):
        expression = self.rendered_rpc("builder_pause")
        self.assertIn("function_exported?(Portal.Builder.AutoPause, :let_go, 1)", expression)
        let_go = expression.index("Portal.Builder.AutoPause.let_go(queues)")
        self.assertLess(let_go, expression.index("Oban.pause_queue(queue: queue, local_only: true)"))

    SHA = "0123456789abcdef0123456789abcdef01234567"

    def run_build_image(self, pull_status="0", inspect_status="0", toolchain_pull_status="0",
                        label=SHA, remote_label=None, **env):
        script = r'''
set -euo pipefail
source "$HELPER"
id() { echo 999; }
git() { echo 0123456789abcdef0123456789abcdef01234567; }
docker() {
  echo "docker $*" >> "$EVENTS"
  echo "docker ${DOCKER_HOST-unset}" >> "$HOSTS"
  if [[ $1 == pull ]]; then
    [[ $3 != *ncc-worker-toolchain:* ]] || return "$TOOLCHAIN_PULL_STATUS"
    return "$PULL_STATUS"
  fi
  if [[ $1 == image && $2 == inspect ]]; then
    if [[ $3 == --format && $5 == *ncc-worker-toolchain:* ]]; then
      printf '%s\n' "$REMOTE_LABEL"
    elif [[ $3 == --format ]]; then
      printf '%s\n' "$LABEL"
    fi
    return "$INSPECT_STATUS"
  fi
}
make() {
  echo "make $*" >> "$EVENTS"; echo "make ${DOCKER_HOST-unset}" >> "$HOSTS"
  [[ $1 != -s || $2 != toolchain-tags ]] || echo ncc-worker:elixir-1.19-otp-28
}
sudo() { echo "sudo $*" >> "$HOSTS"; }
builder_build_image
'''
        with tempfile.TemporaryDirectory() as directory:
            events = Path(directory) / "events"
            hosts = Path(directory) / "hosts"
            result = subprocess.run(
                ["bash", "-c", script],
                env={**BASE_ENV, "HELPER": str(HELPER), "EVENTS": str(events),
                     "HOSTS": str(hosts), "PULL_STATUS": pull_status,
                     "INSPECT_STATUS": inspect_status,
                     "TOOLCHAIN_PULL_STATUS": toolchain_pull_status, "LABEL": label,
                     "REMOTE_LABEL": label if remote_label is None else remote_label,
                     **env},
                capture_output=True, text=True, timeout=5,
            )
            self.hosts = hosts.read_text().splitlines() if hosts.exists() else []
            return result, events.read_text().splitlines() if events.exists() else []

    # The portal's mTLS identity may not build, load or tag; a
    # rootless socket no longer exists. Every image change goes to docker-ncc's
    # root socket, as root, whichever way the image arrives.
    def test_every_image_change_goes_to_the_root_socket_of_docker_ncc(self):
        for overrides in ({}, {"pull_status": "1"}, {"NCC_WORKER_FROM_REGISTRY": "0"},
                          {"toolchain_pull_status": "1"},
                          {"toolchain_pull_status": "1", "NCC_TOOLCHAIN_PREBUILT": "1"},
                          {"NCC_TOOLCHAIN_FROM_REGISTRY": "0"}):
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

    # The first deploy on a new build daemon finds no live tag to keep as
    # previous; it still activates the candidate.
    def test_activation_on_a_daemon_without_a_live_image(self):
        script = r'''
set -euo pipefail
source "$HELPER"
builder_check_egress() { :; }
builder_warm_nerves() { echo warm >> "$EVENTS"; }
builder_toolchain_tags() { echo ncc-toolchain:rpi4; }
docker() {
  echo "docker $*" >> "$EVENTS"
  case "$*" in
    "image inspect ncc-worker:local"*|"image inspect ncc-toolchain:rpi4") return 1 ;;
  esac
}
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
        self.assertNotIn("docker tag ncc-worker:local ncc-worker:previous", lines)
        self.assertIn("docker tag ncc-worker:deploy ncc-worker:local", lines)
        self.assertIn("docker tag ncc-toolchain:rpi4-deploy ncc-toolchain:rpi4", lines)
        self.assertEqual(lines[-1], "warm")

    # A rerun after a deploy that activated and then failed finds the live
    # tags already on this commit's images. Moving them to previous would
    # lose the rollback images; they stay where they are. "This commit's" is
    # the `ncc.commit` label, not the image ID: a rebuild of the same commit
    # (a failed pull, then `make build`) has an ID of its own. A live image
    # without the label, or with another commit's, moves to previous as
    # before.
    def test_a_rerun_keeps_the_previous_images_of_an_earlier_activation(self):
        script = r'''
set -euo pipefail
source "$HELPER"
builder_check_egress() { :; }
builder_warm_nerves() { :; }
builder_toolchain_tags() { echo ncc-toolchain:rpi4; }
git() { echo 0123456789abcdef0123456789abcdef01234567; }
docker() {
  echo "docker $*" >> "$EVENTS"
  if [[ $1 == image && $2 == inspect && $3 == --format ]]; then
    case $3$4 in *ncc.commit*) ;; *) return 1 ;; esac
    case $5 in
      ncc-worker:local) printf '%s\n' "$WORKER_LIVE" ;;
      ncc-toolchain:rpi4) printf '%s\n' "$TOOLCHAIN_LIVE" ;;
      *-deploy | ncc-worker:deploy) echo 0123456789abcdef0123456789abcdef01234567 ;;
    esac
  fi
}
builder_activate_image
'''
        sha = self.SHA
        for worker, toolchain, worker_moved, toolchain_moved in (
            (sha, sha, False, False),
            (sha, "f" * 40, False, True),
            ("", sha, True, False),
            ("<no value>", "", True, True),
            (sha + "-dirty", sha + "-dirty", True, True),
        ):
            with self.subTest(worker=worker, toolchain=toolchain), \
                    tempfile.TemporaryDirectory() as directory:
                events = Path(directory) / "events"
                result = subprocess.run(
                    ["bash", "-c", script],
                    env={**BASE_ENV, "HELPER": str(HELPER), "EVENTS": str(events),
                         "WORKER_LIVE": worker, "TOOLCHAIN_LIVE": toolchain},
                    capture_output=True, text=True, timeout=5,
                )
                lines = events.read_text().splitlines()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    "docker tag ncc-worker:local ncc-worker:previous" in lines, worker_moved)
                self.assertEqual(
                    "docker tag ncc-worker:deploy ncc-worker:local" in lines, worker_moved)
                self.assertEqual(
                    "docker tag ncc-toolchain:rpi4 ncc-toolchain:rpi4-previous" in lines,
                    toolchain_moved)
                self.assertEqual(
                    "docker tag ncc-toolchain:rpi4-deploy ncc-toolchain:rpi4" in lines,
                    toolchain_moved)

    # The worker image carries the label that comparison reads, however it
    # is built: `make build`, `make build-clean` and deploy.yml's push.
    def test_worker_builds_carry_the_commit_label(self):
        for target in ("build", "build-clean"):
            make = subprocess.run(
                ["make", "-n", target, "TOOLCHAIN_COMMIT=" + self.SHA],
                cwd=SRC, capture_output=True, text=True, timeout=10, check=True)
            self.assertIn(f"--label ncc.commit={self.SHA}", make.stdout, target)
        workflow = (SRC / ".github" / "workflows" / "deploy.yml").read_text()
        self.assertIn("labels: ncc.commit=${{ github.sha }}", workflow)

    def test_activation_without_a_candidate_moves_no_tag(self):
        script = r'''
set -euo pipefail
source "$HELPER"
builder_check_egress() { :; }
builder_warm_nerves() { echo warm >> "$EVENTS"; }
builder_toolchain_tags() { echo ncc-toolchain:rpi4; }
docker() {
  echo "docker $*" >> "$EVENTS"
  case "$*" in
    "image inspect ncc-worker:deploy"*) return 1 ;;
  esac
}
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
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(line.startswith("docker tag") for line in lines), lines)
        self.assertNotIn("warm", lines)

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
        self.assertFalse(any(e.startswith("docker tag") and e.endswith(" ncc-worker:deploy")
                             for e in events), events)
        self.assertIn("building locally", result.stderr)

    def test_registry_pull_can_be_turned_off(self):
        result, events = self.run_build_image(NCC_WORKER_FROM_REGISTRY="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(e.startswith("docker pull -q ghcr.io/tomhoenderdos/ncc-worker:")
                             for e in events), events)
        self.assertIn("make build WORKER_IMAGE=ncc-worker:deploy", events)

    TOOLCHAIN_REMOTE = ("ghcr.io/tomhoenderdos/ncc-worker-toolchain:"
                        "elixir-1.19-otp-28-0123456789abcdef0123456789abcdef01234567")

    # Each toolchain image arrives like the worker image: this commit's
    # manifest list from the registry, tagged as the `-deploy` candidate.
    def test_pulls_the_commits_toolchain_images_by_default(self):
        result, events = self.run_build_image()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"docker pull -q {self.TOOLCHAIN_REMOTE}", events)
        self.assertIn(
            f"docker tag {self.TOOLCHAIN_REMOTE} ncc-worker:elixir-1.19-otp-28-deploy", events)
        self.assertNotIn("make build-toolchains TOOLCHAIN_SUFFIX=-deploy", events)
        self.assertIn("docker image inspect --format {{ index .Config.Labels \"ncc.commit\" }} "
                      + self.TOOLCHAIN_REMOTE, events)
        self.assertIn(f"toolchain image: {self.TOOLCHAIN_REMOTE}", result.stdout)

    # The worker and toolchain images fall back on their own.
    def test_a_missing_worker_image_does_not_rebuild_the_toolchain_images(self):
        result, events = self.run_build_image(pull_status="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("make build WORKER_IMAGE=ncc-worker:deploy", events)
        self.assertIn(f"docker pull -q {self.TOOLCHAIN_REMOTE}", events)
        self.assertNotIn("make build-toolchains TOOLCHAIN_SUFFIX=-deploy", events)

    def test_the_toolchain_registry_can_be_overridden(self):
        result, events = self.run_build_image(NCC_TOOLCHAIN_REGISTRY="registry.example/tc")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("docker pull -q registry.example/tc:elixir-1.19-otp-28-"
                      "0123456789abcdef0123456789abcdef01234567", events)

    # A registry tag that names another commit's image counts as no image.
    def test_a_pulled_toolchain_image_for_another_commit_falls_back(self):
        for prebuilt, fallback in (("0", "make build-toolchains TOOLCHAIN_SUFFIX=-deploy"),
                                   ("1", "docker image inspect --format {{ index .Config.Labels "
                                         "\"ncc.commit\" }} ncc-worker:elixir-1.19-otp-28-deploy")):
            for remote_label in ("f" * 40, ""):
                with self.subTest(prebuilt=prebuilt, remote_label=remote_label):
                    result, events = self.run_build_image(
                        remote_label=remote_label, NCC_TOOLCHAIN_PREBUILT=prebuilt)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertNotIn(f"docker tag {self.TOOLCHAIN_REMOTE} "
                                     "ncc-worker:elixir-1.19-otp-28-deploy", events)
                    self.assertIn(fallback, events)
                    self.assertIn(f"not {self.SHA}", result.stderr)

    def test_builds_the_toolchain_images_when_the_registry_has_none(self):
        result, events = self.run_build_image(toolchain_pull_status="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("make build-toolchains TOOLCHAIN_SUFFIX=-deploy", events)
        self.assertFalse(any(e.startswith("docker image inspect") for e in events))
        self.assertNotIn(
            f"docker tag {self.TOOLCHAIN_REMOTE} ncc-worker:elixir-1.19-otp-28-deploy", events)
        self.assertIn("toolchain images: no registry image", result.stderr)

    def test_toolchain_registry_pull_can_be_turned_off(self):
        result, events = self.run_build_image(NCC_TOOLCHAIN_FROM_REGISTRY="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any("ncc-worker-toolchain" in e for e in events), events)
        self.assertIn("make build-toolchains TOOLCHAIN_SUFFIX=-deploy", events)

    # A host whose docker cannot run a Dockerfile's RUN steps (BuildKit under
    # gVisor, where every dpkg install fails) pulls from the registry too:
    # that is the fix for it. Only without a registry image does it fall back
    # to checking for images loaded from elsewhere, never to a build.
    def test_a_prebuilt_host_pulls_from_the_registry_first(self):
        result, events = self.run_build_image(NCC_TOOLCHAIN_PREBUILT="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"docker pull -q {self.TOOLCHAIN_REMOTE}", events)
        self.assertIn(
            f"docker tag {self.TOOLCHAIN_REMOTE} ncc-worker:elixir-1.19-otp-28-deploy", events)
        self.assertNotIn("make build-toolchains TOOLCHAIN_SUFFIX=-deploy", events)
        self.assertFalse(any(e.startswith("docker image inspect") and e.endswith("-deploy")
                             for e in events), events)

    def test_a_prebuilt_host_without_a_registry_image_checks_the_loaded_one(self):
        for overrides in ({"toolchain_pull_status": "1"}, {"NCC_TOOLCHAIN_FROM_REGISTRY": "0"}):
            with self.subTest(overrides=overrides):
                result, events = self.run_build_image(NCC_TOOLCHAIN_PREBUILT="1", **overrides)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("make build-toolchains TOOLCHAIN_SUFFIX=-deploy", events)
                self.assertIn(
                    "docker image inspect --format {{ index .Config.Labels \"ncc.commit\" }} "
                    "ncc-worker:elixir-1.19-otp-28-deploy", events)
                self.assertIn("prebuilt ncc-worker:elixir-1.19-otp-28-deploy", result.stdout)

    def test_a_missing_prebuilt_toolchain_image_stops_the_deploy(self):
        result, events = self.run_build_image(
            NCC_TOOLCHAIN_PREBUILT="1", toolchain_pull_status="1", inspect_status="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("make build-toolchains TOOLCHAIN_SUFFIX=-deploy", events)
        self.assertIn("ncc-worker:elixir-1.19-otp-28-deploy", result.stderr)
        self.assertIn("NCC_TOOLCHAIN_PREBUILT", result.stderr)

    # An image an earlier deploy left under `<tag>-deploy`, or one without
    # the label, must not pass for this commit.
    def test_a_prebuilt_toolchain_image_for_another_commit_stops_the_deploy(self):
        for label in ("f" * 40, "", "<no value>", self.SHA + "-dirty"):
            with self.subTest(label=label):
                result, events = self.run_build_image(
                    NCC_TOOLCHAIN_PREBUILT="1", toolchain_pull_status="1", label=label)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("make build-toolchains TOOLCHAIN_SUFFIX=-deploy", events)
                self.assertIn(f"not {self.SHA}", result.stderr)
                self.assertNotIn("toolchain image: prebuilt", result.stdout)

    def test_toolchain_builds_carry_the_commit_label(self):
        make = subprocess.run(
            ["make", "-n", "build-toolchains", "TOOLCHAIN_COMMIT=" + self.SHA],
            cwd=SRC, capture_output=True, text=True, timeout=10, check=True)
        self.assertIn(f"--label ncc.commit={self.SHA}", make.stdout)
        workflow = (SRC / ".github" / "workflows" / "deploy.yml").read_text()
        self.assertIn('--label "ncc.commit=$GITHUB_SHA"', workflow)

    # A hand build from a checkout with uncommitted changes is not the
    # commit's image: its label says so, and the prebuilt check refuses it.
    def test_a_dirty_checkout_labels_its_toolchain_builds_dirty(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            (repo / "Makefile").write_text((SRC / "Makefile").read_text())
            # The target's prerequisite; `make -n` reads no more of it.
            (repo / "apps" / "ncc_worker").mkdir(parents=True)
            (repo / "apps" / "ncc_worker" / "Dockerfile.toolchain").write_text("FROM scratch\n")
            git = ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@example.com"]
            subprocess.run(git + ["init", "-q"], check=True)
            subprocess.run(git + ["add", "."], check=True)
            subprocess.run(git + ["commit", "-q", "-m", "x"], check=True)
            head = subprocess.run(git + ["rev-parse", "HEAD"], check=True,
                                  capture_output=True, text=True).stdout.strip()

            def label():
                out = subprocess.run(["make", "-n", "-C", str(repo), "build-toolchains"],
                                     capture_output=True, text=True, timeout=10, check=True)
                return out.stdout.split("--label ncc.commit=")[1].split()[0]

            self.assertEqual(label(), head)
            with (repo / "Makefile").open("a") as makefile:
                makefile.write("\n# changed\n")
            self.assertEqual(label(), head + "-dirty")

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
        tags = [i for i, line in enumerate(lines) if line.startswith("docker tag")]
        self.assertTrue(tags, lines)
        self.assertLess(lines.index("check"), tags[0])
        self.assertEqual(lines[-1], "warm")
        self.assertIn("docker tag ncc-worker:deploy ncc-worker:local", lines[:-1])

    def test_a_failed_egress_check_moves_no_tag(self):
        result, lines = self.run_activation(check_status="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("check", lines)
        self.assertFalse([line for line in lines if line.startswith("docker tag")], lines)
        self.assertNotIn("warm", lines)

    # On a daemon with no live image yet, a failed check must not leave the
    # new release, which the next restart starts, with no image at all.
    def test_a_daemon_without_a_live_image_gets_the_candidate_before_the_check(self):
        script = r'''
set -euo pipefail
source "$HELPER"
builder_check_egress() { echo check >> "$EVENTS"; return "$CHECK_STATUS"; }
builder_docker() {
  echo "docker $*" >> "$EVENTS"
  case "$*" in
    "image inspect ncc-worker:local"*|"image inspect ncc-toolchain:rpi4") return 1 ;;
  esac
}
builder_toolchain_tags() { echo ncc-toolchain:rpi4; }
builder_warm_nerves() { echo warm >> "$EVENTS"; }
builder_activate_image
'''
        for status in ("1", "0"):
            with tempfile.TemporaryDirectory() as directory:
                events = Path(directory) / "events"
                result = subprocess.run(
                    ["bash", "-c", script],
                    env={**BASE_ENV, "HELPER": str(HELPER), "EVENTS": str(events),
                         "CHECK_STATUS": status},
                    capture_output=True, text=True, timeout=5,
                )
                lines = events.read_text().splitlines()
            self.assertEqual(result.returncode == 0, status == "0", result.stderr)
            check = lines.index("check")
            self.assertIn("docker tag ncc-worker:deploy ncc-worker:local", lines[:check])
            self.assertIn("docker tag ncc-toolchain:rpi4-deploy ncc-toolchain:rpi4",
                          lines[:check])
            self.assertFalse([line for line in lines if "previous" in line], lines)

    # A failed activation leaves the old release running in memory, whose
    # argv the daemon's authz policy denies: resuming its queues would burn
    # every build's retries. So the queues stay paused, and the deploy says so.
    INVOCATION = "0123456789abcdef0123456789abcdef"

    def run_failed_activation(self, check_status="1", inspect_status="0", install=None,
                              available="true"):
        script = r'''
set -euo pipefail
source "$HELPER"
builder_queues_available() { echo "$AVAILABLE"; }
builder_portal_invocation() { echo "$INVOCATION"; }
builder_pause() { echo pause >> "$EVENTS"; }
builder_resume() { echo resume >> "$EVENTS"; }
builder_queues_drained() { echo true; }
builder_check_runtime() { :; }
builder_check_egress() { echo check >> "$EVENTS"; return "$CHECK_STATUS"; }
builder_docker() {
  [[ "$*" != "image inspect ncc-worker:deploy" ]] || return "$INSPECT_STATUS"
}
builder_toolchain_tags() { :; }
builder_warm_nerves() { echo warm >> "$EVENTS"; }
builder_prepare
builder_activate_image
echo activated >> "$EVENTS"
'''
        with tempfile.TemporaryDirectory() as directory:
            events = Path(directory) / "events"
            result = subprocess.run(
                ["bash", "-c", script],
                env={**BASE_ENV, "HELPER": str(HELPER), "EVENTS": str(events),
                     "CHECK_STATUS": check_status, "INSPECT_STATUS": inspect_status,
                     "AVAILABLE": available, "INVOCATION": self.INVOCATION,
                     **({"NCC_INSTALL_DIR": str(install)} if install else {})},
                capture_output=True, text=True, timeout=5,
            )
            return result, events.read_text().splitlines() if events.exists() else []

    # The failed activation's pause is marked as such, so the next run of
    # the deploy takes it over (no refusal, no operator) and resumes only
    # once it has activated itself.
    def test_the_next_run_takes_over_the_pause_a_failed_activation_left(self):
        with tempfile.TemporaryDirectory() as directory:
            install = Path(directory)
            marker = install / "builder-paused-by-deploy"
            result, events = self.run_failed_activation(install=install)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(events, ["pause", "check"])
            self.assertEqual(marker.read_text(), f"{self.INVOCATION}\nactivating\n")

            result, events = self.run_failed_activation(install=install, available="paused")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(events, ["pause", "check"])
            self.assertIn("taking the pause over", result.stdout)
            self.assertTrue(marker.exists())

            result, events = self.run_failed_activation(check_status="0", install=install,
                                                        available="paused")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(events, ["pause", "check", "warm", "activated", "resume"])
            self.assertFalse(marker.exists())

    def test_a_failed_egress_check_keeps_the_queues_paused(self):
        result, events = self.run_failed_activation()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, ["pause", "check"])
        self.assertIn("queues stay paused", result.stderr)

    def test_a_missing_candidate_keeps_the_queues_paused(self):
        result, events = self.run_failed_activation(check_status="0", inspect_status="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("resume", events)
        self.assertIn("queues stay paused", result.stderr)

    def test_a_successful_activation_resumes_the_queues(self):
        result, events = self.run_failed_activation(check_status="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, ["pause", "check", "warm", "activated", "resume"])


class BuilderPruneOldImagesTest(unittest.TestCase):
    """A builder deploy pulls a freshly tagged image from both registries on
    every run and nothing removed the old ones: a builder reached ten
    `ghcr.io/.../ncc-worker:<sha>` tags and filled its disk, deferring every
    build for "not enough disk" for a day. builder_prune_old_images is the
    fix: after activation, drop every registry-named tag except the live and
    rollback images, compared by image ID."""

    WORKER_REPO = "ghcr.io/tomhoenderdos/ncc-worker"
    TOOLCHAIN_REPO = "ghcr.io/tomhoenderdos/ncc-worker-toolchain"
    LOCAL_ID = "sha256:" + "b" * 64
    PREVIOUS_ID = "sha256:" + "c" * 64
    TOOLCHAIN_LIVE_ID = "sha256:" + "d" * 64
    TOOLCHAIN_PREVIOUS_ID = "sha256:" + "e" * 64
    OLD_ID = "sha256:" + "a" * 64

    SCRIPT = r'''
set -euo pipefail
source "$HELPER"
builder_toolchain_tags() { echo ncc-worker:rpi4; }
docker() {
  echo "docker $*" >> "$EVENTS"
  case "$1" in
    image)
      case "$2" in
        inspect)
          case "$5" in
            ncc-worker:local) [ -n "${WORKER_LOCAL_ID:-}" ] || return 1
              printf '%s\n' "$WORKER_LOCAL_ID" ;;
            ncc-worker:previous) [ -n "${WORKER_PREVIOUS_ID:-}" ] || return 1
              printf '%s\n' "$WORKER_PREVIOUS_ID" ;;
            ncc-worker:rpi4) [ -n "${TOOLCHAIN_LIVE_ID:-}" ] || return 1
              printf '%s\n' "$TOOLCHAIN_LIVE_ID" ;;
            ncc-worker:rpi4-previous) [ -n "${TOOLCHAIN_PREVIOUS_ID:-}" ] || return 1
              printf '%s\n' "$TOOLCHAIN_PREVIOUS_ID" ;;
            *) return 1 ;;
          esac
          ;;
        prune) return "${PRUNE_STATUS:-0}" ;;
      esac
      ;;
    images)
      case "$3" in
        "$WORKER_REPO") printf '%s' "${WORKER_LISTING:-}" ;;
        "$TOOLCHAIN_REPO") printf '%s' "${TOOLCHAIN_LISTING:-}" ;;
      esac
      ;;
    rmi) return "${RMI_STATUS:-0}" ;;
  esac
}
builder_prune_old_images
echo after >> "$EVENTS"
'''

    def run_prune(self, worker_listing="", toolchain_listing="", **overrides):
        with tempfile.TemporaryDirectory() as directory:
            events = Path(directory) / "events"
            env = {
                **BASE_ENV,
                "HELPER": str(HELPER),
                "EVENTS": str(events),
                "WORKER_REPO": self.WORKER_REPO,
                "TOOLCHAIN_REPO": self.TOOLCHAIN_REPO,
                "WORKER_LISTING": worker_listing,
                "TOOLCHAIN_LISTING": toolchain_listing,
                **overrides,
            }
            result = subprocess.run(
                ["bash", "-c", self.SCRIPT], env=env, capture_output=True, text=True, timeout=5
            )
            lines = events.read_text().splitlines() if events.exists() else []
            return result, lines

    # The old, unreferenced tags of both registries go; the ones still live
    # or kept for rollback do not, and the daemon's dangling layers are
    # dropped afterwards.
    def test_old_registry_tags_are_removed(self):
        worker_listing = (
            f"{self.WORKER_REPO}:oldsha {self.OLD_ID}\n"
            f"{self.WORKER_REPO}:newsha {self.LOCAL_ID}\n"
            f"{self.WORKER_REPO}:midsha {self.PREVIOUS_ID}\n"
        )
        result, lines = self.run_prune(
            worker_listing=worker_listing,
            WORKER_LOCAL_ID=self.LOCAL_ID,
            WORKER_PREVIOUS_ID=self.PREVIOUS_ID,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"docker rmi {self.WORKER_REPO}:oldsha", lines)
        self.assertNotIn(f"docker rmi {self.WORKER_REPO}:newsha", lines)
        self.assertNotIn(f"docker rmi {self.WORKER_REPO}:midsha", lines)
        self.assertIn("docker image prune -f", lines)
        self.assertIn(f"pruned old registry image: {self.WORKER_REPO}:oldsha", result.stdout)
        self.assertIn("after", lines)

    # Compared by image ID, not by tag string: a registry-named tag that
    # still points at the live or the rollback image is kept, in either
    # repository.
    def test_current_and_previous_images_are_kept_under_the_registry_name(self):
        worker_listing = (
            f"{self.WORKER_REPO}:oldsha {self.OLD_ID}\n"
            f"{self.WORKER_REPO}:livesha {self.LOCAL_ID}\n"
            f"{self.WORKER_REPO}:rollbacksha {self.PREVIOUS_ID}\n"
        )
        toolchain_listing = (
            f"{self.TOOLCHAIN_REPO}:rpi4-oldsha {self.OLD_ID}\n"
            f"{self.TOOLCHAIN_REPO}:rpi4-livesha {self.TOOLCHAIN_LIVE_ID}\n"
            f"{self.TOOLCHAIN_REPO}:rpi4-rollbacksha {self.TOOLCHAIN_PREVIOUS_ID}\n"
        )
        result, lines = self.run_prune(
            worker_listing=worker_listing,
            toolchain_listing=toolchain_listing,
            WORKER_LOCAL_ID=self.LOCAL_ID,
            WORKER_PREVIOUS_ID=self.PREVIOUS_ID,
            TOOLCHAIN_LIVE_ID=self.TOOLCHAIN_LIVE_ID,
            TOOLCHAIN_PREVIOUS_ID=self.TOOLCHAIN_PREVIOUS_ID,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        removed = [line for line in lines if line.startswith("docker rmi")]
        self.assertEqual(
            removed,
            [f"docker rmi {self.WORKER_REPO}:oldsha",
             f"docker rmi {self.TOOLCHAIN_REPO}:rpi4-oldsha"],
        )
        self.assertNotIn(f"docker rmi {self.WORKER_REPO}:livesha", lines)
        self.assertNotIn(f"docker rmi {self.WORKER_REPO}:rollbacksha", lines)
        self.assertNotIn(f"docker rmi {self.TOOLCHAIN_REPO}:rpi4-livesha", lines)
        self.assertNotIn(f"docker rmi {self.TOOLCHAIN_REPO}:rpi4-rollbacksha", lines)

    # Never touched: a local ncc-worker:* tag is a different repository, and
    # nothing outside builder_registry_image/builder_toolchain_registry is
    # even listed.
    def test_local_tags_and_other_repositories_are_never_listed_or_removed(self):
        worker_listing = f"{self.WORKER_REPO}:oldsha {self.OLD_ID}\n"
        result, lines = self.run_prune(
            worker_listing=worker_listing,
            WORKER_LOCAL_ID=self.LOCAL_ID,
            WORKER_PREVIOUS_ID=self.PREVIOUS_ID,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        images_calls = [line for line in lines if line.startswith("docker images")]
        self.assertEqual(
            images_calls,
            [f"docker images --no-trunc {self.WORKER_REPO} "
             "--format {{.Repository}}:{{.Tag}} {{.ID}}",
             f"docker images --no-trunc {self.TOOLCHAIN_REPO} "
             "--format {{.Repository}}:{{.Tag}} {{.ID}}"],
        )
        self.assertFalse([line for line in lines if "docker rmi ncc-worker:" in line
                          and "ghcr.io" not in line], lines)

    # A daemon that refuses a removal (an image still referenced elsewhere,
    # a transient error) must not fail the deploy: the function logs and
    # moves on to the next tag and to the prune.
    def test_a_removal_error_does_not_fail_the_deploy(self):
        worker_listing = f"{self.WORKER_REPO}:oldsha {self.OLD_ID}\n"
        result, lines = self.run_prune(
            worker_listing=worker_listing,
            WORKER_LOCAL_ID=self.LOCAL_ID,
            WORKER_PREVIOUS_ID=self.PREVIOUS_ID,
            RMI_STATUS="1",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"docker rmi {self.WORKER_REPO}:oldsha", lines)
        self.assertIn(
            f"warning: could not prune old registry image {self.WORKER_REPO}:oldsha",
            result.stderr,
        )
        self.assertIn("docker image prune -f", lines)
        self.assertIn("after", lines)

    # A refused listing or prune call is logged the same way and never stops
    # the function from finishing.
    def test_a_failed_prune_call_does_not_fail_the_deploy(self):
        result, lines = self.run_prune(
            WORKER_LOCAL_ID=self.LOCAL_ID,
            WORKER_PREVIOUS_ID=self.PREVIOUS_ID,
            PRUNE_STATUS="1",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("warning: docker image prune failed", result.stderr)
        self.assertIn("after", lines)

    # Placed right after activation in deploy.sh; set -e there means a
    # failed activation never reaches it.
    def test_deploy_prunes_right_after_activating(self):
        deploy = (Path(__file__).with_name("deploy.sh")).read_text()
        activate = deploy.index("builder_activate_image")
        prune = deploy.index("builder_prune_old_images")
        self.assertLess(activate, prune)
        self.assertIn(
            "builder_activate_image\n  builder_prune_old_images\n", deploy)


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
                # A toolchain_big slot no bigger than a toolchain one refuses
                # the activation too, so the deploy says so.
                self.assertIn("Portal.Builder.check_toolchain_big_memory()", args)
                self.assertEqual(result.returncode == 0, expect_ok, result.stderr)
                if not expect_ok:
                    self.assertIn("egress filter", result.stderr)
                    self.assertIn("NCC_TOOLCHAIN_BIG_MEMORY", result.stderr)

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
            # Not every builder runs NixOS; every one has the status socket.
            self.assertNotIn("NixOS", result.stderr)
            self.assertIn("ncc-egress-status.socket", result.stderr)
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
        self.assertIn("if [[ $mode == builder ]]; then\n  builder_check_running_egress",
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
                # build-release.sh stamps the release with `git -C "$SRC"
                # rev-parse HEAD`; $src here is a plain temp dir, not a repo.
                "git": 'echo 0123456789abcdef0123456789abcdef01234567\n',
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
