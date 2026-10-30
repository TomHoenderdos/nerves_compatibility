"""The host layout (install, source and config paths) comes from the operator's
deploy env file, never from this repository, and a host without it fails loudly
instead of guessing a path."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

OPS = Path(__file__).parent
STANDALONE = ["deploy.sh", "build-release.sh", "images-sync.sh"]
SCRIPTS = STANDALONE + ["builder-deploy.sh", "deploy-builders.sh", "ssh-deploy.sh"]
LAYOUT_VARS = [
    "NCC_SRC_DIR", "NCC_INSTALL_DIR", "NCC_PORTAL_ENV", "NCC_PORTAL_WORKDIR",
    "NCC_IMAGES_JSON", "DOCKER_HOST",
]


def clean_env(**extra):
    env = {k: v for k, v in os.environ.items() if k not in LAYOUT_VARS + ["NCC_DEPLOY_ENV"]}
    env.update(extra)
    return env


def recording_stubs(root, names):
    """Commands that only record that they ran, so a test can tell a script
    stopped before touching anything."""
    bindir = root / "bin"
    bindir.mkdir()
    for name in names:
        stub = bindir / name
        stub.write_text(f'#!/bin/bash\necho "{name} $*" >> "$EVENTS"\n')
        stub.chmod(0o755)
    return bindir


class LayoutGuardTest(unittest.TestCase):
    def run_script(self, script, args=(), env_file_text=None, **extra):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            events = root / "events"
            bindir = recording_stubs(
                root, ["git", "flock", "docker", "curl", "tar", "systemctl", "sudo", "nsenter"]
            )
            env_file = root / "deploy.env"
            if env_file_text is not None:
                env_file.write_text(env_file_text)
            env = clean_env(
                PATH=f"{bindir}:{os.environ['PATH']}",
                EVENTS=str(events),
                NCC_DEPLOY_ENV=str(env_file),
                **extra,
            )
            result = subprocess.run(
                ["bash", str(OPS / script), *args], env=env, capture_output=True, text=True,
                timeout=10,
            )
            return result, events.read_text().splitlines() if events.exists() else []

    def test_every_script_refuses_to_run_without_the_env_file(self):
        cases = {
            "deploy.sh": ["a" * 40],
            "build-release.sh": [],
            "images-sync.sh": ["a" * 40],
        }
        for script, args in cases.items():
            with self.subTest(script=script):
                result, events = self.run_script(script, args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("deploy.env", result.stderr)
                self.assertIn("ops/deploy.env.example", result.stderr)
                self.assertEqual(events, [], "ran a command before the layout was known")

    def test_a_missing_variable_is_named(self):
        result, events = self.run_script(
            "deploy.sh", ["a" * 40], env_file_text="NCC_SRC_DIR=/nowhere\n"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NCC_INSTALL_DIR", result.stderr)
        self.assertNotIn("NCC_SRC_DIR ", result.stderr.split("does not set", 1)[-1])
        self.assertEqual(events, [])

    def test_the_sourced_builder_helper_refuses_too(self):
        with tempfile.TemporaryDirectory() as directory:
            env = clean_env(NCC_DEPLOY_ENV=str(Path(directory) / "absent.env"),
                            HELPER=str(OPS / "builder-deploy.sh"))
            result = subprocess.run(
                ["bash", "-c", 'set -euo pipefail; source "$HELPER"; echo loaded'],
                env=env, capture_output=True, text=True, timeout=5,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("loaded", result.stdout)
        self.assertIn("NCC_INSTALL_DIR", result.stderr)

    def test_variables_already_in_the_environment_need_no_file(self):
        # deploy.sh exports the layout to everything it starts, including an
        # older installed deploy.sh sourcing this checkout's builder helper.
        with tempfile.TemporaryDirectory() as directory:
            env = clean_env(NCC_DEPLOY_ENV=str(Path(directory) / "absent.env"),
                            HELPER=str(OPS / "builder-deploy.sh"),
                            **{name: "/x" for name in LAYOUT_VARS})
            result = subprocess.run(
                ["bash", "-c", 'set -euo pipefail; source "$HELPER"; echo "$builder_portal_bin"'],
                env=env, capture_output=True, text=True, timeout=5,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "/x/portal/bin/portal")

    # Every host's release build needs DOCKER_HOST, so a web host whose
    # env file predates it stops before the checkout moves, not halfway.
    def test_a_web_deploy_without_docker_host_refuses_before_the_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "install").mkdir()
            (root / "src").mkdir()
            env_file = root / "deploy.env"
            env_file.write_text(
                f"NCC_SRC_DIR={root}/src\nNCC_INSTALL_DIR={root}/install\n"
                f"NCC_PORTAL_ENV={root}/portal.env\nNCC_PORTAL_WORKDIR={root}\n"
                f"NCC_IMAGES_JSON={root}/images.json\n"
            )
            bindir = root / "bin"
            bindir.mkdir()
            for tool in ("git", "flock"):
                (bindir / tool).write_text(f'#!/bin/bash\necho {tool} >> "$EVENTS"\n')
                (bindir / tool).chmod(0o755)
            events = root / "events"
            env = clean_env(PATH=f"{bindir}:{os.environ['PATH']}", EVENTS=str(events),
                            NCC_DEPLOY_ENV=str(env_file))
            result = subprocess.run(
                ["bash", str(OPS / "deploy.sh"), "a" * 40], env=env, capture_output=True,
                text=True, timeout=10,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("DOCKER_HOST", result.stderr)
            self.assertFalse(events.exists(), events.read_text() if events.exists() else "")

    def test_deploy_takes_its_lock_and_checkout_from_the_env_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            install = root / "install"
            install.mkdir()
            src = root / "src"
            src.mkdir()
            text = (
                f"NCC_SRC_DIR={src}\nNCC_INSTALL_DIR={install}\n"
                f"NCC_PORTAL_ENV={root}/portal.env\nNCC_PORTAL_WORKDIR={root}\n"
                f"NCC_IMAGES_JSON={root}/images.json\n"
                "DOCKER_HOST=unix:///run/docker-ncc/docker.sock\n"
            )
            env_file = root / "deploy.env"
            env_file.write_text(text)
            bindir = root / "bin"
            bindir.mkdir()
            # A checkout that is not on main: deploy.sh must stop right there.
            (bindir / "git").write_text('#!/bin/bash\npwd -P >> "$EVENTS"\necho other\n')
            (bindir / "git").chmod(0o755)
            (bindir / "flock").write_text("#!/bin/bash\nexit 0\n")
            (bindir / "flock").chmod(0o755)
            events = root / "events"
            env = clean_env(PATH=f"{bindir}:{os.environ['PATH']}", EVENTS=str(events),
                            NCC_DEPLOY_ENV=str(env_file))
            result = subprocess.run(
                ["bash", str(OPS / "deploy.sh"), "a" * 40], env=env, capture_output=True,
                text=True, timeout=10,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must be on main", result.stderr)
            self.assertTrue((install / "deploy.lock").exists())
            self.assertEqual(events.read_text().splitlines()[0], str(src.resolve()))

    def test_images_sync_defaults_to_the_env_files_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dest = root / "images.json"
            result, events = self.run_script(
                "images-sync.sh", ["a" * 40], env_file_text=f"NCC_IMAGES_JSON={dest}\n"
            )
            # The curl stub writes nothing, so the download is refused, but
            # only after it was pointed at the configured destination.
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertTrue(any(line.startswith("curl ") and str(dest) in line for line in events),
                            events)

    def test_the_layout_function_is_the_same_in_every_script(self):
        def body(script):
            text = (OPS / script).read_text()
            match = re.search(r"^ncc_layout\(\) \{\n.*?^\}\n", text, re.M | re.S)
            self.assertIsNotNone(match, script)
            return match.group(0)

        reference = body("deploy.sh")
        for script in STANDALONE + ["builder-deploy.sh"]:
            with self.subTest(script=script):
                self.assertEqual(body(script), reference)


class NoHostLayoutInScriptsTest(unittest.TestCase):
    # The env file's own location is the one path the scripts may name.
    ALLOWED = {"/etc/ncc-deploy.env"}

    def test_no_install_or_config_paths_are_hardcoded(self):
        pattern = re.compile(r"/(?:opt|srv|var/lib|etc/ncc-portal|root)/[\w./-]*")
        for script in SCRIPTS:
            with self.subTest(script=script):
                text = (OPS / script).read_text()
                found = set(pattern.findall(text)) - self.ALLOWED
                self.assertEqual(found, set())


if __name__ == "__main__":
    unittest.main()
