"""Exercise the production gate without GitHub credentials or network access."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("wait-for-checks.sh")
SHA = "a" * 40
REPO = "TomHoenderdos/nerves_compatibility"
WORKFLOWS = ("audit.yml", "codeql.yml", "credo.yml", "sobelow.yml")


def check_run(**overrides):
    return {
        "id": 1,
        "head_sha": SHA,
        "head_repository": {"full_name": REPO},
        "status": "completed",
        "conclusion": "success",
        **overrides,
    }


class DeploymentGateTest(unittest.TestCase):
    def run_gate(self, runs=None, latest=SHA):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / "runs.json"
            fixture.write_text(json.dumps({
                "latest": latest,
                "runs": runs if runs is not None else {
                    name: [check_run()] for name in WORKFLOWS
                },
            }))
            gh = root / "gh"
            gh.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
data = json.loads(Path(os.environ["GATE_FIXTURE"]).read_text())
endpoint = next(arg for arg in sys.argv if arg.startswith("repos/"))
if endpoint.endswith("commits/main"):
    print(data["latest"])
else:
    print(json.dumps({"workflow_runs": data["runs"][endpoint.split("/")[-2]]}))
""")
            gh.chmod(0o755)
            # Stop after one pending poll: waiting must never emit deploy=true.
            sleeper = root / "sleep"
            sleeper.write_text("#!/bin/sh\nexit 99\n")
            sleeper.chmod(0o755)
            output = root / "output"
            env = {
                **os.environ,
                "PATH": f"{root}{os.pathsep}{os.environ['PATH']}",
                "GATE_FIXTURE": str(fixture),
                "GITHUB_REPOSITORY": REPO,
                "GITHUB_SHA": SHA,
                "GITHUB_OUTPUT": str(output),
            }
            result = subprocess.run(
                ["bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=10
            )
            return result, output.read_text() if output.exists() else ""

    def test_all_four_successful_workflows_allow_deploy(self):
        result, output = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "deploy=true\n")

    def test_superseded_commit_is_skipped(self):
        result, output = self.run_gate(latest="b" * 40)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(output, "deploy=false\n")

    def test_failed_or_cancelled_scan_blocks_deploy(self):
        for conclusion in ("failure", "cancelled", "timed_out", "skipped"):
            with self.subTest(conclusion=conclusion):
                runs = {name: [check_run()] for name in WORKFLOWS}
                runs["sobelow.yml"] = [check_run(conclusion=conclusion)]
                result, output = self.run_gate(runs)
                self.assertEqual(result.returncode, 1)
                self.assertNotIn("deploy=true", output)

    def test_missing_pending_wrong_commit_or_fork_scan_cannot_pass(self):
        for records in (
            [],
            [check_run(status="in_progress", conclusion=None)],
            [check_run(head_sha="b" * 40)],
            [check_run(head_repository={"full_name": "someone/fork"})],
        ):
            with self.subTest(records=records):
                runs = {name: [check_run()] for name in WORKFLOWS}
                runs["codeql.yml"] = records
                result, output = self.run_gate(runs)
                self.assertEqual(result.returncode, 99)
                self.assertNotIn("deploy=true", output)

    def test_newer_failed_run_is_not_hidden_by_an_older_success(self):
        runs = {name: [check_run()] for name in WORKFLOWS}
        runs["credo.yml"] = [check_run(id=2, conclusion="failure"), check_run()]
        result, output = self.run_gate(runs)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("deploy=true", output)


if __name__ == "__main__":
    unittest.main()
