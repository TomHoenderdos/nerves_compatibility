"""Check queue draining and failure cleanup without touching a live builder."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).with_name("builder-deploy.sh")
HARNESS = r'''
set -euo pipefail
source "$HELPER"
builder_queues_available() { echo "$AVAILABLE"; }
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
                **os.environ,
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

    def test_rootless_daemon_setting_does_not_leak_into_release_build(self):
        script = r'''
set -euo pipefail
source "$HELPER"
unset DOCKER_HOST
id() { echo 999; }
make() { test "$DOCKER_HOST" = unix:///run/user/999/docker.sock; }
docker() { test "$DOCKER_HOST" = unix:///run/user/999/docker.sock; }
builder_build_image
builder_activate_image
test -z "${DOCKER_HOST+x}"
'''
        result = subprocess.run(
            ["bash", "-c", script], env={**os.environ, "HELPER": str(HELPER)},
            capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
