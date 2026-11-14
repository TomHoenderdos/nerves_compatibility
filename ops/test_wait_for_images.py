"""Exercise the builder deploy's wait for the image jobs, without GitHub."""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("wait-for-images.sh")
WORKFLOW = Path(__file__).resolve().parent.parent / ".github" / "workflows" / "deploy.yml"
REPO = "TomHoenderdos/nerves_compatibility"
NAMES = ("ncc-worker manifest list", "toolchain manifest list")


def job(name, **overrides):
    return {"id": 1, "name": name, "status": "completed", "conclusion": "success", **overrides}


class WaitForImagesTest(unittest.TestCase):
    def run_wait(self, jobs, timeout="600", raw=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / "jobs.json"
            fixture.write_text(raw if raw is not None else json.dumps({"jobs": jobs}))
            calls = root / "calls"
            gh = root / "gh"
            gh.write_text(f"""#!/bin/sh
echo "$*" >> "{calls}"
cat "{fixture}"
""")
            gh.chmod(0o755)
            # Stop after one pending poll: a wait that would go on exits 99.
            sleeper = root / "sleep"
            sleeper.write_text("#!/bin/sh\nexit 99\n")
            sleeper.chmod(0o755)
            env = {
                **os.environ,
                "PATH": f"{root}{os.pathsep}{os.environ['PATH']}",
                "GITHUB_REPOSITORY": REPO,
                "GITHUB_RUN_ID": "4242",
                "GITHUB_SHA": "a" * 40,
                "NCC_IMAGES_WAIT_SECONDS": timeout,
            }
            result = subprocess.run(
                ["bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=10
            )
            self.calls = calls.read_text() if calls.exists() else ""
            return result

    def test_both_image_jobs_done_lets_the_builder_deploy(self):
        result = self.run_wait([job(name) for name in NAMES])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("are pushed", result.stdout)
        self.assertNotIn("::warning::", result.stdout)
        self.assertIn(f"repos/{REPO}/actions/runs/4242/jobs", self.calls)
        self.assertIn("filter=latest", self.calls)

    def test_waits_while_an_image_job_runs_or_has_not_started(self):
        for jobs in (
            [job(NAMES[0]), job(NAMES[1], status="in_progress", conclusion=None)],
            [job(NAMES[0])],
            [],
        ):
            with self.subTest(jobs=jobs):
                self.assertEqual(self.run_wait(jobs).returncode, 99)

    # The builder falls back for a missing image; the deploy goes on.
    def test_a_failed_image_job_warns_and_deploys(self):
        for conclusion in ("failure", "cancelled", "skipped"):
            with self.subTest(conclusion=conclusion):
                result = self.run_wait([job(NAMES[0]), job(NAMES[1], conclusion=conclusion)])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"::warning::{NAMES[1]} did not pass", result.stdout)

    def test_the_latest_attempt_of_a_job_counts(self):
        jobs = [job(NAMES[0]), job(NAMES[1], conclusion="failure"), job(NAMES[1], id=2)]
        result = self.run_wait(jobs)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("::warning::", result.stdout)

    def test_the_deadline_warns_and_deploys(self):
        result = self.run_wait([job(NAMES[0])], timeout="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("::warning::the image jobs had not finished", result.stdout)

    # An answer jq cannot read is no job yet, never a failed step.
    def test_an_unreadable_answer_never_fails_the_step(self):
        for raw in ("<html>rate limited</html>", "", '{"jobs": "nope"}'):
            with self.subTest(raw=raw):
                self.assertEqual(self.run_wait([], raw=raw).returncode, 99)
                result = self.run_wait([], raw=raw, timeout="0")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("::warning::the image jobs had not finished", result.stdout)

    def test_the_job_names_are_deploy_yml_s(self):
        text = WORKFLOW.read_text()
        script = SCRIPT.read_text()
        for name in NAMES:
            with self.subTest(name=name):
                self.assertRegex(text, rf"\n    name: {re.escape(name)}\n")
                self.assertIn(f"'{name}'", script)


if __name__ == "__main__":
    unittest.main()
