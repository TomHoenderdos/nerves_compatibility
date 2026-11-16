"""Check ops/deploy-builders.sh's preflight without reaching any host."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("deploy-builders.sh")
SHA = "0123456789abcdef0123456789abcdef01234567"

# Answers the preflight's remote command with $STATE (four lines: HEAD,
# branch, `systemctl is-active`, the deploy-incomplete marker) and records
# every other remote command.
SSH = """#!/bin/bash
last=${!#}
echo "ssh $last" >> "$EVENTS"
if [[ $last == *"git rev-parse HEAD"* ]]; then
  printf '%b' "$STATE"
fi
"""

GIT = """#!/bin/bash
case $* in
  "rev-parse --show-toplevel") pwd ;;
  *ls-remote*) printf '%s\\trefs/heads/main\\n' "$SHA" ;;
  *"log --oneline"*) echo "${SHA:0:7} a commit" ;;
esac
"""


class PreflightTest(unittest.TestCase):
    def run_preflight(self, state, *args):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bindir = root / "bin"
            bindir.mkdir()
            for name, body in (("ssh", SSH), ("git", GIT)):
                (bindir / name).write_text(body)
                (bindir / name).chmod(0o755)
            hosts = root / "hosts"
            hosts.write_text("host-a builder@host-a.example\n")
            events = root / "events"
            env = {**os.environ, "PATH": f"{bindir}:{os.environ['PATH']}",
                   "NCC_BUILDERS_FILE": str(hosts), "EVENTS": str(events),
                   "STATE": state, "SHA": SHA}
            result = subprocess.run(
                ["bash", str(SCRIPT), "-n", *args, "host-a"], env=env, cwd=root,
                capture_output=True, text=True, timeout=10,
            )
            self.remote = events.read_text().splitlines() if events.exists() else []
            return result

    def test_a_host_on_the_commit_with_a_finished_deploy_is_skipped(self):
        result = self.run_preflight(f"{SHA}\nmain\nactive\n\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("skipping (-f to redeploy)", result.stdout)
        self.assertNotIn("would install", result.stdout)

    # A deploy that stopped halfway already moved the checkout and left the
    # old ncc-portal active; its deploy-incomplete marker sends the host
    # through the deploy again, without -f.
    def test_a_host_whose_last_deploy_did_not_finish_is_deployed_again(self):
        result = self.run_preflight(f"{SHA}\nmain\nactive\n{SHA}\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("did not finish; deploying again", result.stdout)
        self.assertIn("would install", result.stdout)
        self.assertNotIn("skipping", result.stdout)

    def test_the_preflight_reads_the_marker_from_the_install_dir(self):
        self.run_preflight(f"{SHA}\nmain\nactive\n\n")
        self.assertTrue(any('"$NCC_INSTALL_DIR/deploy-incomplete"' in line
                            for line in self.remote), self.remote)

    def test_force_still_redeploys_a_finished_host(self):
        result = self.run_preflight(f"{SHA}\nmain\nactive\n\n", "-f")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("would install", result.stdout)

    def test_a_host_on_another_commit_is_deployed(self):
        result = self.run_preflight(f"{'f' * 40}\nmain\nactive\n\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("would install", result.stdout)

    # The marker never overrides the branch check.
    def test_a_checkout_off_main_still_refuses(self):
        result = self.run_preflight(f"{SHA}\nother\nactive\n{SHA}\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not main", result.stdout)


class InstallTest(unittest.TestCase):
    # The host runs what this installs as $NCC_INSTALL_DIR/deploy.sh: the
    # deployed commit's bootstrap, which then runs that commit's deploy.sh.
    # Installing a full deploy.sh there would overwrite the bootstrap the
    # CI-deployed hosts rely on.
    def test_the_deploy_installs_the_commits_bootstrap_as_deploy_sh(self):
        text = SCRIPT.read_text()
        self.assertIn('git -C "$repo" show "$sha:ops/deploy-bootstrap.sh" |', text)
        self.assertIn('mv "$NCC_INSTALL_DIR/deploy.sh.new" "$NCC_INSTALL_DIR/deploy.sh"', text)
        self.assertNotIn(":ops/deploy.sh", text)
        self.assertNotIn(":ops/build-release.sh", text)


class DeployMarkerTest(unittest.TestCase):
    # deploy.sh marks a builder deploy incomplete before the checkout moves
    # and clears the mark only after its last check; a web deploy never
    # writes it.
    def test_deploy_writes_the_marker_before_the_merge_and_clears_it_last(self):
        text = SCRIPT.with_name("deploy.sh").read_text()
        write = text.index('>"$deploy_incomplete"')
        # Only once the commit is checked to be main's head: a run refused
        # before that moved nothing and must not send the host round again.
        self.assertLess(text.index("git fetch origin main"), write)
        self.assertLess(text.index("no longer the head of main"), write)
        self.assertLess(write, text.index("git merge --ff-only"))
        clear = text.index('rm -f "$deploy_incomplete"')
        self.assertLess(text.index("  builder_check_running_egress"), clear)
        self.assertLess(text.index("systemctl restart ncc-portal"), clear)
        self.assertIn("if [[ $mode == builder ]]; then\n  printf '%s\\n' \"$target\" "
                      '>"$deploy_incomplete"', text)


if __name__ == "__main__":
    unittest.main()
