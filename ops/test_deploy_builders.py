"""Check ops/deploy-builders.sh's preflight without reaching any host."""

import os
from pathlib import Path
import shutil
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
    """A real (not dry) run against one host, whose remote commands run
    locally: the install against a scratch NCC_INSTALL_DIR, the rest
    answered. The host runs what this installs as $NCC_INSTALL_DIR/deploy.sh,
    and so does CI on the main builder: an empty or cut-short copy there
    would make every later deploy of that host run nothing and exit 0."""

    # Runs the install command the way the host would, with $TRUNCATE
    # cutting the transfer short; answers preflight, the poll and verify.
    SSH = """#!/bin/bash
last=${!#}
echo "ssh $last" >> "$EVENTS"
case $last in
  *"git rev-parse HEAD"*) printf '%b' "$STATE" ;;
  *deploy.sh.new*)
    head -c "${TRUNCATE:-100000000}" | NCC_INSTALL_DIR=$INSTALL bash -c "${last#*set +a; }" ;;
  *"grep -m1"*) echo DEPLOY_EXIT=0 ;;
  *"git log --oneline -1"*) printf '%s a commit\\nactive\\n' "${SHA:0:7}" ;;
  *setsid*) ;;
  *) echo "unexpected remote command" >&2; exit 99 ;;
esac
"""

    # The commit's ops/deploy-bootstrap.sh is $BOOTSTRAP, absent when that
    # file does not exist; hash-object is the real one.
    GIT = """#!/bin/bash
case $* in
  "rev-parse --show-toplevel") pwd ;;
  *ls-remote*) printf '%s\\trefs/heads/main\\n' "$SHA" ;;
  *"log --oneline"*) echo "${SHA:0:7} a commit" ;;
  *"show $SHA:ops/deploy-bootstrap.sh")
    [[ -e $BOOTSTRAP ]] || { echo "fatal: path 'ops/deploy-bootstrap.sh' does not exist in '$SHA'" >&2; exit 128; }
    cat "$BOOTSTRAP" ;;
  *hash-object*) exec "$REAL_GIT" "$@" ;;
esac
"""

    def deploy(self, bootstrap=True, truncate=None):
        directory = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, directory, ignore_errors=True)
        root = Path(directory)
        bindir = root / "bin"
        bindir.mkdir()
        for name, body in (("ssh", self.SSH), ("git", self.GIT), ("sleep", "#!/bin/bash\n")):
            (bindir / name).write_text(body)
            (bindir / name).chmod(0o755)
        hosts = root / "hosts"
        hosts.write_text("host-a root@host-a.example\n")
        self.install = root / "install"
        self.install.mkdir()
        (self.install / "deploy.sh").write_text("the copy installed before\n")
        self.bootstrap = root / "deploy-bootstrap.sh"
        if bootstrap:
            shutil.copy(SCRIPT.with_name("deploy-bootstrap.sh"), self.bootstrap)
        events = root / "events"
        env = {**os.environ, "PATH": f"{bindir}:{os.environ['PATH']}",
               "NCC_BUILDERS_FILE": str(hosts), "EVENTS": str(events),
               "STATE": f"{'f' * 40}\nmain\nactive\n\n", "SHA": SHA,
               "INSTALL": str(self.install), "BOOTSTRAP": str(self.bootstrap),
               "REAL_GIT": shutil.which("git")}
        if truncate is not None:
            env["TRUNCATE"] = str(truncate)
        result = subprocess.run(["bash", str(SCRIPT), "host-a"], env=env, cwd=root,
                                capture_output=True, text=True, timeout=30)
        self.remote = events.read_text().splitlines() if events.exists() else []
        return result

    def installed(self):
        return (self.install / "deploy.sh").read_bytes()

    def started(self):
        return [line for line in self.remote if "setsid" in line]

    def test_the_commits_bootstrap_is_installed_as_deploy_sh_and_run(self):
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.installed(), self.bootstrap.read_bytes())
        self.assertEqual((self.install / "deploy.sh").stat().st_mode & 0o777, 0o755)
        self.assertFalse((self.install / "deploy.sh.new").exists())
        self.assertEqual(len(self.started()), 1, self.remote)

    def test_a_commit_without_the_bootstrap_installs_and_starts_nothing(self):
        result = self.deploy(bootstrap=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAILED: host-a", result.stderr)
        self.assertEqual(self.installed(), b"the copy installed before\n")
        self.assertEqual(self.started(), [], self.remote)

    def test_a_transfer_cut_short_installs_and_starts_nothing(self):
        # Cut at a line boundary: what is left still parses, and as the
        # host's deploy.sh would end before running anything, with status 0.
        text = SCRIPT.with_name("deploy-bootstrap.sh").read_bytes()
        result = self.deploy(truncate=text.index(b"\nrun=") + 1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed(), b"the copy installed before\n")
        self.assertFalse((self.install / "deploy.sh.new").exists())
        self.assertEqual(self.started(), [], self.remote)

    def test_no_full_deploy_sh_or_build_release_sh_is_installed(self):
        text = SCRIPT.read_text()
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
