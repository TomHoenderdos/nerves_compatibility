"""Verify jump-host configuration and credential cleanup using synthetic keys."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("ssh-deploy.sh")


class SshDeploymentTest(unittest.TestCase):
    def run_ssh(self, role, **overrides):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner = root / "runner"
            runner.mkdir()
            log = root / "log"
            ssh = root / "ssh"
            ssh.write_text("""#!/usr/bin/env python3
import json, os, stat, sys
from pathlib import Path
config = Path(sys.argv[2])
data = {"args": sys.argv[3:], "config": config.read_text(),
        "key_modes": [stat.S_IMODE(p.stat().st_mode) for p in config.parent.glob("*key")]}
Path(os.environ["SSH_TEST_LOG"]).write_text(json.dumps(data))
sys.exit(int(os.environ["SSH_STATUS"]))
""")
            ssh.chmod(0o755)
            env = {
                **os.environ,
                "PATH": f"{root}{os.pathsep}{os.environ['PATH']}",
                "SSH_TEST_LOG": str(log), "SSH_STATUS": "0",
                "RUNNER_TEMP": str(runner), "GITHUB_SHA": "a" * 40,
                "DEPLOY_HOST": "portal.example.test", "BUILDER_HOST": "100.64.1.2",
                "DEPLOY_SSH_KEY": "synthetic-portal-key",
                "BUILDER_DEPLOY_SSH_KEY": "synthetic-builder-key",
                "DEPLOY_KNOWN_HOSTS": "synthetic-known-hosts",
                **overrides,
            }
            result = subprocess.run(
                ["bash", str(SCRIPT), role], env=env, capture_output=True, text=True, timeout=5
            )
            data = json.loads(log.read_text()) if log.exists() else None
            self.assertEqual(list(runner.iterdir()), [], "temporary credentials leaked")
            return result, data

    def test_builder_uses_jump_host_strict_verification_and_exact_sha(self):
        result, data = self.run_ssh("builder")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ProxyJump portal", data["config"])
        self.assertIn("StrictHostKeyChecking yes", data["config"])
        self.assertEqual(data["args"], ["builder", "/opt/nerves_compatibility/deploy.sh", "a" * 40, "builder"])
        self.assertEqual(data["key_modes"], [0o600, 0o600])

    def test_portal_has_no_jump_and_failed_ssh_cleans_up(self):
        result, data = self.run_ssh("portal", SSH_STATUS="255")
        self.assertEqual(result.returncode, 255)
        self.assertNotIn("ProxyJump", data["config"])
        self.assertEqual(data["key_modes"], [0o600])

    def test_invalid_commit_or_host_never_reaches_ssh(self):
        for overrides in ({"GITHUB_SHA": "main"}, {"BUILDER_HOST": "host\nProxyCommand unsafe"}):
            with self.subTest(overrides=overrides):
                result, data = self.run_ssh("builder", **overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(data)


if __name__ == "__main__":
    unittest.main()
