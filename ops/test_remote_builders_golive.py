"""remote-builders-golive.sh: read-only by default, fails on each missing piece, and
--init-ca only creates a CA that does not exist. sudo, ss and bin/portal are fakes."""

import getpass
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("remote-builders-golive.sh")

# Runs the command as the caller: `sudo -u <user> cmd...`.
FAKE_SUDO = """#!/usr/bin/env bash
[ "$1" = -u ] && shift 2
exec "$@"
"""

FAKE_SS = """#!/usr/bin/env bash
[ -n "${FAKE_LISTENING:-}" ] && echo "LISTEN 0 1024 0.0.0.0:8443 0.0.0.0:*"
exit 0
"""

# eval: logs the expression and, for the CA init, writes the files.
# rpc: prints FAKE_RPC.
FAKE_PORTAL = """#!/usr/bin/env bash
echo "$1 $2" >>"$FAKE_LOG"
case "$1" in
  eval)
    mkdir -p "$(dirname "$NCC_BUILDER_CA_KEY")"
    echo key >"$NCC_BUILDER_CA_KEY"; chmod 600 "$NCC_BUILDER_CA_KEY"
    echo cert >"$(dirname "$NCC_BUILDER_CA_KEY")/ca.pem"
    echo created ;;
  rpc) [ -n "${FAKE_RPC_FAIL:-}" ] && { echo "noconnection"; exit 1; }
       printf '%s\\n' "$FAKE_RPC" ;;
esac
"""

GOOD_RPC = "\n".join(
    [
        "ca_loads=true",
        "images_path=/etc/example/images.json",
        "images_load=:ok",
        'worker=%{name: "ghcr.io/example/ncc-worker", digest: "sha256:aa"}',
        "agent=1800000000.abc for aarch64, x86_64",
        "remote_mode=auto threshold=10",
    ]
)


class GoLiveTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.root = root
        self.bin = root / "bin"
        self.bin.mkdir()
        for name, body in [("sudo", FAKE_SUDO), ("ss", FAKE_SS)]:
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        install = root / "install"
        (install / "portal/bin").mkdir(parents=True)
        portal = install / "portal/bin/portal"
        portal.write_text(FAKE_PORTAL)
        portal.chmod(0o755)
        self.workdir = root / "home"
        self.workdir.mkdir()
        self.ca_key = root / "builder-ca/ca-key.pem"
        self.portal_env = root / "portal.env"
        self.write_env()
        self.log = root / "portal.log"
        self.layout = root / "deploy.env"
        self.layout.write_text(
            f"NCC_INSTALL_DIR={install}\nNCC_PORTAL_ENV={self.portal_env}\n"
            f"NCC_PORTAL_WORKDIR={self.workdir}\n"
        )

    def tearDown(self):
        self.tmp.cleanup()

    def write_env(self, **overrides):
        values = {
            "PHX_SERVER": "true",
            "OBAN_QUEUES": "intake:5,maintenance:1,remote:2",
            "NCC_BUILDER_CA_KEY": str(self.ca_key),
            "NCC_UPLOAD_ROOT": str(self.root / "uploads"),
            **overrides,
        }
        self.portal_env.write_text("".join(f"{k}={v}\n" for k, v in values.items() if v))

    def make_ca(self):
        self.ca_key.parent.mkdir()
        self.ca_key.write_text("key")
        self.ca_key.chmod(0o600)
        (self.ca_key.parent / "ca.pem").write_text("cert")

    def run_golive(self, *args, **env):
        environment = {
            **os.environ,
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "NCC_DEPLOY_ENV": str(self.layout),
            "NCC_PORTAL_USER": getpass.getuser(),
            "FAKE_LOG": str(self.log),
            "FAKE_RPC": GOOD_RPC,
            "FAKE_LISTENING": "1",
            **env,
        }
        return subprocess.run(
            ["bash", str(SCRIPT), *args], env=environment, capture_output=True, text=True
        )

    def portal_calls(self):
        return self.log.read_text() if self.log.exists() else ""

    def test_usage(self):
        self.assertEqual(self.run_golive("--force").returncode, 2)
        self.assertEqual(self.run_golive("--init-ca", "x").returncode, 2)

    def test_a_ready_host_passes_and_prints_the_next_steps(self):
        self.make_ca()
        result = self.run_golive()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("All checks passed", result.stdout)
        self.assertIn("New enrolment token", result.stdout)
        self.assertIn("publishing", result.stdout)
        self.assertNotIn("eval", self.portal_calls())

    def test_a_missing_ca_fails_and_is_not_created_without_the_flag(self):
        result = self.run_golive()
        self.assertEqual(result.returncode, 1)
        self.assertIn("--init-ca", result.stdout)
        self.assertFalse(self.ca_key.exists())
        self.assertNotIn("eval", self.portal_calls())

    def test_init_ca_creates_a_missing_ca(self):
        result = self.run_golive("--init-ca")
        self.assertIn("Portal.Builders.CA.init", self.portal_calls())
        self.assertTrue(self.ca_key.exists())
        self.assertEqual(oct(self.ca_key.parent.stat().st_mode & 0o777), "0o700")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_init_ca_leaves_an_existing_ca_alone(self):
        self.make_ca()
        result = self.run_golive("--init-ca")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("eval", self.portal_calls())
        self.assertEqual(self.ca_key.read_text(), "key")

    def test_a_readable_key_fails(self):
        self.make_ca()
        self.ca_key.chmod(0o644)
        result = self.run_golive()
        self.assertEqual(result.returncode, 1)
        self.assertIn("not mode 600", result.stdout)

    def test_no_remote_queue_fails(self):
        self.make_ca()
        self.write_env(OBAN_QUEUES="intake:5,maintenance:1")
        result = self.run_golive()
        self.assertEqual(result.returncode, 1)
        self.assertIn("no remote queue", result.stdout)

    def test_no_listener_fails(self):
        self.make_ca()
        result = self.run_golive(FAKE_LISTENING="")
        self.assertEqual(result.returncode, 1)
        self.assertIn("nothing listens on TCP 8443", result.stdout)

    def test_no_images_json_fails(self):
        self.make_ca()
        rpc = GOOD_RPC.replace("images_load=:ok", "images_load=:error").replace(
            'worker=%{name: "ghcr.io/example/ncc-worker", digest: "sha256:aa"}', "worker=none"
        )
        result = self.run_golive(FAKE_RPC=rpc)
        self.assertEqual(result.returncode, 1)
        self.assertIn("names no worker image", result.stdout)

    def test_a_portal_that_does_not_answer_fails(self):
        self.make_ca()
        result = self.run_golive(FAKE_RPC_FAIL="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("rpc failed", result.stdout)

    def test_builders_are_listed(self):
        self.make_ca()
        rpc = GOOD_RPC + "\nbuilder=box-1 status=active egress=host_unready publishing=false last_seen=never"
        result = self.run_golive(FAKE_RPC=rpc)
        self.assertIn("builder box-1 status=active egress=host_unready", result.stdout)


if __name__ == "__main__":
    unittest.main()
