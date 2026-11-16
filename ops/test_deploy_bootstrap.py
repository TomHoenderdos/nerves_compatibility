"""The installed deploy bootstrap (ops/deploy-bootstrap.sh) against real git
repositories: it runs the deployed commit's own ops/deploy.sh, only once that
commit is main's head, and hands it the deploy lock without letting go."""

import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

OPS = Path(__file__).parent
BOOTSTRAP = OPS / "deploy-bootstrap.sh"

# flock(1) as the deploy scripts call it, `flock -n <fd>`, with real locking
# (macOS has no flock(1)). It also writes a line through the fd, so a test can
# tell whether the lock file was reopened, which truncates it, in between.
FLOCK = """#!/usr/bin/env python3
import fcntl, os, sys
if sys.argv[1:2] != ["-n"] or len(sys.argv) != 3:
    sys.exit(f"flock shim: unexpected arguments {sys.argv[1:]}")
fd = int(sys.argv[2])
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(1)
os.write(fd, b"locked\\n")
"""

# Every command but git records that it ran.
RECORDING = '#!/bin/bash\necho "{name} $*" >> "$EVENTS"\n'

# A commit's ops/deploy.sh: records what it was run with, whether fd 9 is
# open, and whether the lock file is held (by fd 9's open file description,
# which a fresh one cannot take).
STUB_DEPLOY = """#!/bin/bash
{
  echo "ran @VERSION@ $*"
  echo "locked=${NCC_DEPLOY_LOCKED:-}"
  echo "head=$(git -C "$NCC_SRC_DIR" rev-parse HEAD)"
  if { true >&9; } 2>/dev/null; then echo "fd9 open"; fi
  python3 -c '
import fcntl, sys
with open(sys.argv[1], "a") as f:
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        print("free")
    except OSError:
        print("held")
' "$NCC_INSTALL_DIR/deploy.lock"
} >> "$EVENTS"
"""


def stub_deploy(version):
    return STUB_DEPLOY.replace("@VERSION@", version)


class Fixture:
    """origin (bare), a clone to commit from, the host's checkout and its
    install dir with the bootstrap installed as deploy.sh."""

    def __init__(self, root):
        self.root = root
        self.events = root / "events"
        self.bin = root / "bin"
        self.bin.mkdir()
        for name in ("tar", "sudo", "systemctl", "curl", "docker"):
            (self.bin / name).write_text(RECORDING.format(name=name))
            (self.bin / name).chmod(0o755)
        (self.bin / "flock").write_text(FLOCK)
        (self.bin / "flock").chmod(0o755)
        home = root / "home"
        home.mkdir()
        self.env = {
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "HOME": str(home),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.test",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.test",
            "EVENTS": str(self.events),
        }
        self.origin = root / "origin.git"
        self.git("init", "-q", "--bare", "-b", "main", str(self.origin))
        self.work = root / "work"
        self.git("clone", "-q", str(self.origin), str(self.work))
        self.git("-C", str(self.work), "checkout", "-q", "-b", "main")
        self.src = root / "src"
        self.install = root / "install"
        self.install.mkdir()
        self.installed = self.install / "deploy.sh"
        shutil.copy(BOOTSTRAP, self.installed)
        self.env_file = root / "deploy.env"
        self.layout = {"NCC_SRC_DIR": self.src, "NCC_INSTALL_DIR": self.install}
        self.write_env_file()

    def write_env_file(self, **extra):
        self.layout.update(extra)
        self.env_file.write_text("".join(f"{k}={v}\n" for k, v in self.layout.items()))

    def git(self, *args):
        return subprocess.run(["git", *args], env={**os.environ, **self.env}, check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, files):
        for path, text in files.items():
            target = self.work / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
        self.git("-C", str(self.work), "add", "-A")
        self.git("-C", str(self.work), "commit", "-q", "-m", "change")
        self.git("-C", str(self.work), "push", "-q", "origin", "main")
        return self.git("-C", str(self.work), "rev-parse", "HEAD")

    def clone_src(self):
        self.git("clone", "-q", str(self.origin), str(self.src))

    def fetched_main(self):
        return self.git("-C", str(self.src), "rev-parse", "origin/main")

    def run(self, *args, script=None, **extra):
        env = {**self.env, "NCC_DEPLOY_ENV": str(self.env_file), **extra}
        result = subprocess.run(
            ["bash", str(script or self.installed), *args], env=env, cwd=self.root,
            capture_output=True, text=True, timeout=60,
        )
        events = self.events.read_text().splitlines() if self.events.exists() else []
        return result, events


class BootstrapTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, directory, ignore_errors=True)
        self.f = Fixture(Path(directory))
        # The checkout is on c1. c2, main's head, changed deploy.sh, and the
        # checkout has not fetched it yet.
        self.c1 = self.f.commit({"ops/deploy.sh": stub_deploy("v1"),
                                 "ops/deploy-bootstrap.sh": BOOTSTRAP.read_text()})
        self.f.clone_src()
        self.c2 = self.f.commit({"ops/deploy.sh": stub_deploy("v2")})
        self.lock = self.f.install / "deploy.lock"

    def ran(self, events):
        return [e for e in events if e.startswith("ran ")]

    def test_a_deploy_runs_the_deployed_commits_deploy_sh(self):
        result, events = self.f.run(self.c2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.ran(events), [f"ran v2 {self.c2}"])
        # The bootstrap moves nothing; deploy.sh fast-forwards the checkout.
        self.assertIn(f"head={self.c1}", events)
        self.assertEqual((self.f.install / "deploy-commit.sh").read_text(), stub_deploy("v2"))
        self.assertIn(f"running ops/deploy.sh of {self.c2[:12]}", result.stdout)
        self.assertNotIn("WARNING", result.stderr)

    def test_builder_mode_reaches_deploy_sh(self):
        result, events = self.f.run(self.c2, "builder")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.ran(events), [f"ran v2 {self.c2} builder"])

    def test_without_a_commit_it_passes_mains_head_on(self):
        # deploy.sh then deploys the commit whose deploy.sh it is, or
        # refuses if main moved in between.
        result, events = self.f.run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.ran(events), [f"ran v2 {self.c2}"])

    def test_a_commit_that_is_no_longer_mains_head_runs_nothing(self):
        result, events = self.f.run(self.c1)
        self.assertEqual(result.returncode, 1)
        self.assertIn("no longer the head of main", result.stderr)
        self.assertEqual(self.ran(events), [])
        self.assertFalse((self.f.install / "deploy-commit.sh").exists())

    def test_bad_arguments_refuse_before_the_lock_or_the_fetch(self):
        for args in (("main",), (self.c2[:7],), (self.c2, "portal"), ("rollback", "builder"),
                     (self.c2, "builder", "x")):
            with self.subTest(args=args):
                result, events = self.f.run(*args)
                self.assertEqual(result.returncode, 1)
                self.assertIn("usage", result.stderr)
                self.assertEqual(events, [])
                self.assertFalse(self.lock.exists())
                self.assertEqual(self.f.fetched_main(), self.c1)

    def test_without_the_env_file_nothing_runs(self):
        result, events = self.f.run(self.c2, NCC_DEPLOY_ENV=str(self.f.root / "absent.env"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ops/deploy.env.example", result.stderr)
        self.assertEqual(events, [])
        self.assertFalse(self.lock.exists())

    def test_a_held_lock_refuses_before_the_fetch(self):
        with open(self.lock, "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            result, events = self.f.run(self.c2)
        self.assertEqual(result.returncode, 1)
        self.assertIn("another deployment is running", result.stderr)
        self.assertEqual(events, [])
        self.assertEqual(self.f.fetched_main(), self.c1)

    def test_deploy_sh_inherits_the_held_lock(self):
        result, events = self.f.run(self.c2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"locked={self.lock}", events)
        self.assertIn("fd9 open", events)
        self.assertIn("held", events)

    def test_rollback_runs_the_checkouts_deploy_sh_without_fetching(self):
        result, events = self.f.run("rollback")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.ran(events), ["ran v1 rollback"])
        self.assertIn("held", events)
        self.assertEqual(self.f.fetched_main(), self.c1)

    def test_an_installed_copy_other_than_the_commits_warns_and_still_deploys(self):
        self.f.installed.write_text(BOOTSTRAP.read_text() + "# edited on the host\n")
        result, events = self.f.run(self.c2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("WARNING", result.stderr)
        self.assertIn("ops/deploy-bootstrap.sh", result.stderr)
        self.assertEqual(self.ran(events), [f"ran v2 {self.c2}"])

    def test_an_empty_deploy_sh_is_refused(self):
        c3 = self.f.commit({"ops/deploy.sh": ""})
        result, events = self.f.run(c3)
        self.assertEqual(result.returncode, 1)
        self.assertIn("empty", result.stderr)
        self.assertEqual(self.ran(events), [])


class FirstDeployTest(unittest.TestCase):
    """The first deploy through a newly installed bootstrap: the checkout
    still has an old deploy.sh, and the commit deployed brings this one."""

    def test_the_deployed_commits_real_deploy_sh_runs_end_to_end(self):
        with tempfile.TemporaryDirectory() as directory:
            f = Fixture(Path(directory))
            f.commit({"ops/deploy.sh": stub_deploy("old")})
            f.clone_src()
            target = f.commit({
                "ops/deploy.sh": (OPS / "deploy.sh").read_text(),
                "ops/deploy-bootstrap.sh": BOOTSTRAP.read_text(),
                "ops/build-release.sh": 'echo "build-release $(git -C "$NCC_SRC_DIR" rev-parse HEAD)" >> "$EVENTS"\n',
                "ops/images-sync.sh": 'echo "images-sync $*" >> "$EVENTS"\n',
            })
            root = Path(directory)
            (f.install / "portal").mkdir()
            # The tar stub writes nothing; deploy.sh moves its output.
            (f.install / "portal-previous.tar.gz.tmp").write_text("")
            f.write_env_file(NCC_PORTAL_ENV=root / "portal.env", NCC_PORTAL_WORKDIR=root,
                             NCC_IMAGES_JSON=root / "images.json",
                             DOCKER_HOST="unix:///var/run/docker.sock")
            result, events = f.run(target)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual([e for e in events if e.startswith("ran ")], [])
            self.assertEqual(f.git("-C", str(f.src), "rev-parse", "HEAD"), target)
            self.assertIn(f"build-release {target}", events)
            self.assertIn("systemctl restart ncc-portal", events)
            self.assertIn(f"images-sync {target} {root / 'images.json'}", events)
            # Locked once by the bootstrap and once more by deploy.sh through
            # the same fd: reopening the file in between would have
            # truncated the first line away.
            self.assertEqual((f.install / "deploy.lock").read_text(), "locked\nlocked\n")


class InstalledCopyTest(unittest.TestCase):
    # No deploy installs the bootstrap on a CI-deployed host: a change to it
    # reaches one only when an operator installs it there by hand. Moving
    # this pin is the reminder; every deploy also warns until it is done.
    PINNED = "0b102a286d8be8730ce82586e3af1fb77c3b0965d55180ee8e8d2e1f9e3ad46f"

    def test_a_change_to_the_bootstrap_is_installed_by_hand(self):
        digest = hashlib.sha256(BOOTSTRAP.read_bytes()).hexdigest()
        self.assertEqual(
            digest, self.PINNED,
            "ops/deploy-bootstrap.sh changed, and no deploy installs it: once the change "
            "is on main, install it by hand on every host CI deploys (operator runbook, "
            f"\"Installing a change\"), and set PINNED to {digest}")


if __name__ == "__main__":
    unittest.main()
