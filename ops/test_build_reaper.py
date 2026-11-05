"""Check the root build reaper against a fake cgroup tree and systemd."""

from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).with_name("build-reaper.sh")
SRC = Path(__file__).resolve().parent.parent
OLD, YOUNG, OTHER = "a" * 64, "b" * 64, "c" * 64
NOW = 1_800_000_000
# systemctl stands in for systemd: unix stamps, as `--timestamp=unix`
# prints them. reaper_now is the real `date +%s` unless NOW_OVERRIDE.
HARNESS = r'''
set -uo pipefail
source "$HELPER"
reaper_cgroup_root=$ROOT
systemctl() {
  echo "systemctl $*" >> "$EVENTS"
  case $* in
    *"docker-$OLD.scope") echo "@$(( NOW - 3 * 3600 ))" ;;
    *"docker-$YOUNG.scope") echo "@$(( NOW - 3600 ))" ;;
    *"docker-$OTHER.scope") echo "" ;;
  esac
}
date() { echo "$NOW"; }
reaper_main
'''


class BuildReaperTest(unittest.TestCase):
    def reap(self, scopes, **env):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for scope in scopes:
                (root / scope).mkdir(parents=True)
                (root / scope / "cgroup.kill").write_text("")
            events = root / "events"
            result = subprocess.run(
                ["bash", "-c", HARNESS],
                env={"PATH": "/usr/bin:/bin", "HELPER": str(HELPER), "ROOT": str(root),
                     "EVENTS": str(events), "OLD": OLD, "YOUNG": YOUNG, "OTHER": OTHER,
                     "NOW": str(NOW), **env},
                capture_output=True, text=True, timeout=10,
            )
            self.killed = sorted(
                str(path.parent.relative_to(root)) for path in root.rglob("cgroup.kill")
                if path.read_text() == "1\n")
            self.asked = events.read_text().splitlines() if events.exists() else []
            return result

    def test_kills_only_build_scopes_past_the_ceiling(self):
        scopes = [f"ncc.slice/ncc-builds.slice/docker-{OLD}.scope",
                  f"ncc.slice/ncc-builds.slice/docker-{YOUNG}.scope"]
        result = self.reap(scopes)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.killed, [scopes[0]])
        self.assertIn(OLD[:12], result.stdout)
        self.assertIn("scanned 2 build container scopes in 1 slice(s), killed 1", result.stdout)
        # Wall clock against wall clock: the unix form of the start stamp.
        self.assertIn(f"systemctl show -P ActiveEnterTimestamp --timestamp=unix docker-{OLD}.scope",
                      self.asked)

    def test_a_slice_at_the_cgroup_root_is_found_too(self):
        result = self.reap([f"ncc-builds.slice/docker-{OLD}.scope"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.killed, [f"ncc-builds.slice/docker-{OLD}.scope"])

    # The system dockerd's containers are docker-<id>.scope as well.
    def test_never_touches_a_scope_outside_the_build_slice(self):
        scopes = ["ncc.slice/ncc-builds.slice",
                  f"system.slice/docker-{OLD}.scope",
                  f"ncc.slice/other.slice/docker-{OLD}.scope",
                  f"ncc.slice/ncc-builds.slice/inner/docker-{OLD}.scope",
                  "ncc.slice/ncc-builds.slice/docker-1234.scope",
                  f"ncc.slice/ncc-builds.slice/buildkit-{OLD}.scope"]
        result = self.reap(scopes)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.killed, [])
        self.assertEqual(self.asked, [])

    def test_a_scope_systemd_cannot_date_is_left_alone(self):
        result = self.reap([f"ncc.slice/ncc-builds.slice/docker-{OTHER}.scope"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.killed, [])
        self.assertIn("skipping", result.stderr)

    def test_the_age_limit_is_configurable_but_not_below_an_hour(self):
        scopes = [f"ncc.slice/ncc-builds.slice/docker-{YOUNG}.scope"]
        self.reap(scopes, NCC_REAPER_MAX_AGE_SECONDS="3600")
        self.assertEqual(self.killed, [])
        for bad in ("60", "2h", "-1"):
            result = self.reap(scopes, NCC_REAPER_MAX_AGE_SECONDS=bad)
            self.assertNotEqual(result.returncode, 0, bad)
            self.assertEqual(self.killed, [], bad)

    def test_an_empty_build_slice_succeeds_and_says_so(self):
        result = self.reap(["ncc.slice/ncc-builds.slice"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(),
                         "scanned 0 build container scopes in 1 slice(s), killed 0")

    # A host without the slice (docker-ncc's cgroup parent unset, or another
    # layout) would otherwise pass every run while protecting nothing.
    def test_no_build_slice_at_all_fails_loudly(self):
        result = self.reap([f"system.slice/docker-{OLD}.scope"])
        self.assertEqual(result.returncode, 3)
        self.assertIn("no ncc-builds.slice", result.stderr)
        self.assertEqual(self.killed, [])

    def test_a_systemd_without_unix_timestamps_kills_nothing(self):
        scopes = [f"ncc.slice/ncc-builds.slice/docker-{OLD}.scope"]
        harness = HARNESS.replace('echo "@$(( NOW - 3 * 3600 ))"',
                                  'echo "Tue 2026-11-04 21:53:17 CET"')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / scopes[0]).mkdir(parents=True)
            (root / scopes[0] / "cgroup.kill").write_text("")
            result = subprocess.run(
                ["bash", "-c", harness],
                env={"PATH": "/usr/bin:/bin", "HELPER": str(HELPER), "ROOT": str(root),
                     "EVENTS": str(root / "events"), "OLD": OLD, "YOUNG": YOUNG,
                     "OTHER": OTHER, "NOW": str(NOW)},
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual((root / scopes[0] / "cgroup.kill").read_text(), "")
        self.assertIn("skipping", result.stderr)

    # The default leaves Portal.Builder's two-hour wall clock plus the
    # 15-minute grace Portal.Builder.Stop.overdue_limit_ms/0 allows.
    def test_the_default_limit_clears_the_build_ceiling_and_grace(self):
        text = HELPER.read_text()
        default = int(text.split("NCC_REAPER_MAX_AGE_SECONDS:-", 1)[1].split("}", 1)[0])
        builder = (SRC / "apps/portal/lib/portal/builder.ex").read_text()
        hours = int(builder.split("@total_timeout_ms :timer.hours(", 1)[1].split(")", 1)[0])
        stop = (SRC / "apps/portal/lib/portal/builder/stop.ex").read_text()
        grace = int(stop.split("@overdue_grace_ms :timer.minutes(", 1)[1].split(")", 1)[0])
        self.assertGreaterEqual(default, hours * 3600 + grace * 60)


if __name__ == "__main__":
    unittest.main()
