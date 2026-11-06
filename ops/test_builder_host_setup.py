"""builder-host-setup.sh: configures daemon.json idempotently, refuses a bad gVisor
download, and its check fails closed. Docker, systemd, apt and curl are fakes."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).parent.parent / "apps/ncc_agent/rel/overlays/builder-host-setup.sh"
VERSION = "20261005.0"

FAKE_DOCKER = """#!/usr/bin/env bash
echo "$*" >>"$FAKE_LOG/docker"
runtimes='{"runc":{},"runsc":{}}'
case "$1 $2 $3" in
  "info --format {{json .Runtimes}}") printf '%s\\n' "${FAKE_RUNTIMES:-$runtimes}" ;;
  "info --format {{.DefaultRuntime}}") echo runsc ;;
  info*) echo "${FAKE_BACKEND:-iptables}" ;;
  run*) printf 'nofile=%s\\n[    0.000000] Starting gVisor...\\n' "${FAKE_NOFILE:-65536/65536}" ;;
esac
"""

FAKE_SYSTEMCTL = """#!/usr/bin/env bash
echo "$*" >>"$FAKE_LOG/systemctl"
"""

# Every package already installed: apt-get must not run.
FAKE_DPKG_QUERY = """#!/usr/bin/env bash
printf 'install ok installed'
"""

FAKE_APT_GET = """#!/usr/bin/env bash
echo "$*" >>"$FAKE_LOG/apt-get"
"""

FAKE_CURL = """#!/usr/bin/env bash
echo "$*" >>"$FAKE_LOG/curl"
out=''
while [ $# -gt 0 ]; do if [ "$1" = -o ]; then out=$2; shift; fi; shift; done
printf 'not the gvisor tarball' >"$out"
"""

FAKE_RUNSC = f"""#!/usr/bin/env bash
echo "runsc version release-{VERSION}"
echo "spec: 1.2.0"
"""


class BuilderHostSetupTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "log"
        self.log.mkdir()
        self.runsc_dir = self.root / "runsc"
        self.daemon_json = self.root / "etc/docker/daemon.json"
        for name, body in [
            ("docker", FAKE_DOCKER),
            ("systemctl", FAKE_SYSTEMCTL),
            ("dpkg-query", FAKE_DPKG_QUERY),
            ("apt-get", FAKE_APT_GET),
            ("curl", FAKE_CURL),
        ]:
            path = self.bin / name
            path.write_text(body)
            path.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def present_runsc(self):
        (self.runsc_dir / "gvisor-bin").mkdir(parents=True)
        for name in ["runsc", "containerd-shim-runsc-v1", "gvisor-bin/gvisor_sentry"]:
            path = self.runsc_dir / name
            path.write_text(FAKE_RUNSC)
            path.chmod(0o755)

    def run_setup(self, *args, **env):
        environment = {
            **os.environ,
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "FAKE_LOG": str(self.log),
            "NCC_SETUP_TEST": "1",
            "NCC_RUNSC_DIR": str(self.runsc_dir),
            "NCC_DOCKER_DAEMON_JSON": str(self.daemon_json),
            "NCC_KVM_DEVICE": str(self.root / "no-kvm"),
            **env,
        }
        return subprocess.run(
            ["bash", str(SCRIPT), *args], env=environment, capture_output=True, text=True
        )

    def logged(self, name):
        path = self.log / name
        return path.read_text() if path.exists() else ""

    def test_usage(self):
        self.assertEqual(self.run_setup().returncode, 2)
        self.assertEqual(self.run_setup("frobnicate").returncode, 2)

    def test_install_writes_daemon_json_keeps_other_keys_and_restarts_once(self):
        self.present_runsc()
        self.daemon_json.parent.mkdir(parents=True)
        self.daemon_json.write_text(json.dumps({"dns": ["10.0.0.2"], "runtimes": {"x": {}}}))

        result = self.run_setup("install")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        doc = json.loads(self.daemon_json.read_text())
        self.assertEqual(doc["dns"], ["10.0.0.2"])
        self.assertIn("x", doc["runtimes"])
        self.assertEqual(
            doc["runtimes"]["runsc"],
            {"path": str(self.runsc_dir / "runsc"), "runtimeArgs": ["--platform=systrap"]},
        )
        self.assertEqual(doc["default-runtime"], "runsc")
        self.assertEqual(
            doc["default-ulimits"]["nofile"], {"Name": "nofile", "Soft": 65536, "Hard": 65536}
        )
        self.assertIn("restart docker", self.logged("systemctl"))
        self.assertIn("host ready", result.stdout)
        self.assertEqual(self.logged("curl"), "")
        self.assertEqual(self.logged("apt-get"), "")

        # A second run changes nothing and leaves docker running as it is.
        (self.log / "systemctl").unlink()
        before = self.daemon_json.read_text()
        again = self.run_setup("install")
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertEqual(self.daemon_json.read_text(), before)
        self.assertNotIn("restart", self.logged("systemctl"))

    def test_dns_is_written_only_when_given_and_must_be_addresses(self):
        self.present_runsc()
        self.daemon_json.parent.mkdir(parents=True)
        self.daemon_json.write_text(json.dumps({"dns": ["10.0.0.2"]}))
        self.run_setup("install")
        self.assertEqual(json.loads(self.daemon_json.read_text())["dns"], ["10.0.0.2"])

        result = self.run_setup("install", NCC_DOCKER_DNS="1.1.1.1 9.9.9.9")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.daemon_json.read_text())["dns"], ["1.1.1.1", "9.9.9.9"])

        bad = self.run_setup("install", NCC_DOCKER_DNS="1.1.1.1 resolver.example")
        self.assertNotEqual(bad.returncode, 0)
        self.assertEqual(json.loads(self.daemon_json.read_text())["dns"], ["1.1.1.1", "9.9.9.9"])

    def test_platform_follows_kvm_and_the_override(self):
        self.present_runsc()
        kvm = self.root / "kvm"
        kvm.write_text("")
        # A regular file is not a character device: still systrap.
        self.run_setup("install", NCC_KVM_DEVICE=str(kvm))
        args = json.loads(self.daemon_json.read_text())["runtimes"]["runsc"]["runtimeArgs"]
        self.assertEqual(args, ["--platform=systrap"])

        result = self.run_setup("install", NCC_RUNSC_PLATFORM="kvm")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(self.daemon_json.read_text())["runtimes"]["runsc"]["runtimeArgs"]
        self.assertEqual(args, ["--platform=kvm"])

        bad = self.run_setup("install", NCC_RUNSC_PLATFORM="ptrace")
        self.assertNotEqual(bad.returncode, 0)

    def test_a_download_that_does_not_match_the_pinned_sha512_is_not_installed(self):
        result = self.run_setup("install")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match the pinned sha512", result.stderr)
        self.assertIn(f"/{VERSION}/", self.logged("curl"))
        self.assertFalse((self.runsc_dir / "runsc").exists())
        self.assertFalse(self.daemon_json.exists())

    def test_install_refuses_the_nftables_backend(self):
        self.present_runsc()
        self.daemon_json.parent.mkdir(parents=True)
        self.daemon_json.write_text(json.dumps({"firewall-backend": "nftables"}))
        result = self.run_setup("install")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("iptables", result.stderr)
        self.assertEqual(json.loads(self.daemon_json.read_text()), {"firewall-backend": "nftables"})

    def check_with(self, nofile=65536, **env):
        self.daemon_json.parent.mkdir(parents=True, exist_ok=True)
        limit = {"Name": "nofile", "Soft": nofile, "Hard": nofile}
        self.daemon_json.write_text(json.dumps({"default-ulimits": {"nofile": limit}}))
        return self.run_setup("check", **env)

    def test_check_passes_on_a_ready_host_and_changes_nothing(self):
        result = self.check_with()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("run --rm --runtime=runsc --network=none busybox", self.logged("docker"))
        self.assertEqual(self.logged("systemctl"), "")

    def test_check_fails_without_runsc(self):
        result = self.check_with(FAKE_RUNTIMES='{"runc":{}}')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing: runsc", result.stdout)
        self.assertNotIn("run --rm", self.logged("docker"))

    def test_check_fails_on_a_low_nofile_default(self):
        result = self.check_with(nofile=1024)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("1024/1024", result.stderr)

    def test_check_fails_when_the_container_sees_another_limit(self):
        result = self.check_with(FAKE_NOFILE="1048576/1048576")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("nofile is not 65536", result.stderr)

    def test_check_fails_on_the_nftables_backend(self):
        result = self.check_with(FAKE_BACKEND="nftables")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("firewall backend 'nftables'", result.stdout)


if __name__ == "__main__":
    unittest.main()
