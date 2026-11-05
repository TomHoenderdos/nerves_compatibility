"""Check the root build reaper against a fake cgroup tree and systemd."""

from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).with_name("build-reaper.sh")
OLD, YOUNG, OTHER = "a" * 64, "b" * 64, "c" * 64
HOUR = 3600 * 1_000_000
HARNESS = r'''
set -uo pipefail
source "$HELPER"
reaper_cgroup_root=$ROOT
reaper_now() { echo $(( 10 * 3600 * 1000000 )); }
reaper_active_since() {
  echo "$1" >> "$EVENTS"
  case $1 in
    docker-$OLD.scope) echo $(( 10 * 3600 * 1000000 - 3 * 3600 * 1000000 )) ;;
    docker-$YOUNG.scope) echo $(( 10 * 3600 * 1000000 - 3600 * 1000000 )) ;;
    docker-$OTHER.scope) echo 0 ;;
  esac
}
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
                     "EVENTS": str(events), "OLD": OLD, "YOUNG": YOUNG, "OTHER": OTHER, **env},
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

    def test_a_slice_at_the_cgroup_root_is_found_too(self):
        result = self.reap([f"ncc-builds.slice/docker-{OLD}.scope"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.killed, [f"ncc-builds.slice/docker-{OLD}.scope"])

    # The system dockerd's containers are docker-<id>.scope as well.
    def test_never_touches_a_scope_outside_the_build_slice(self):
        scopes = [f"system.slice/docker-{OLD}.scope",
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

    def test_nothing_to_do_is_quiet_success(self):
        result = self.reap([])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
