"""Check the build egress loader and its rulesets without a docker-ncc daemon."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


OPS = Path(__file__).parent
LOADER = OPS / "builder-egress-load.sh"
RULESET = OPS / "builder-egress.nft"
BRIDGE_RULESET = OPS / "builder-egress-bridge.nft"
MARKER = "ncc_egress_v1"
# The root-only endpoint of the docker-ncc daemon (the deploy env file's
# NCC_DOCKER_ADMIN_HOST). ncc's own socket may not inspect networks (#40,
# Unit 2b), so the loader, which runs as root, asks through this one.
ADMIN_HOST = "unix:///test/docker-ncc-admin.sock"
NCC_SOCKET = "unix:///run/docker-ncc/docker.sock"

# What `nft list table inet ncc_egress` prints for a loaded table, trimmed.
LISTING = (
    "table inet ncc_egress {\n"
    "\tchain build_forward {\n"
    "\t\ttype filter hook forward priority filter - 10; policy accept;\n"
    '\t\tdrop comment "ncc_egress_v1"\n'
    "\t}\n"
    "}\n"
)

STUBS = {
    # `docker info` succeeds from its INFO_READY_AFTER-th call on, the way a
    # daemon that is still starting answers. Records the daemon it was sent to.
    "docker": r'''#!/usr/bin/env bash
echo "docker $*" >> "$EVENTS"
echo "${DOCKER_HOST-unset}" >> "$STATE/docker-hosts"
case "$1" in
  info)
    count=$(( $(cat "$STATE/info" 2>/dev/null || echo 0) + 1 ))
    echo "$count" > "$STATE/info"
    (( count >= INFO_READY_AFTER ))
    ;;
  network) printf '%s\n' "$BRIDGE_NAME" ;;
esac
''',
    # nft straight in the host's network namespace, where docker-ncc's bridge
    # lives. The first `nft -f -` is the inet table, the second the bridge
    # table.
    "nft": r'''#!/usr/bin/env bash
echo "nft $*" >> "$EVENTS"
if [[ "$*" == "-f -" ]]; then
  if [[ -e "$STATE/load-inet" ]]; then
    cat > "$STATE/load-bridge"
    exit "$BRIDGE_LOAD_STATUS"
  fi
  cat > "$STATE/load-inet"
  exit 0
fi
printf '%s' "$LISTING"
''',
    # There is no namespace to enter any more: any call is a regression.
    "nsenter": '#!/usr/bin/env bash\necho "nsenter $*" >> "$EVENTS"\nexit 1\n',
    "sleep": '#!/usr/bin/env bash\necho sleep >> "$EVENTS"\n',
    # Records its bound and runs the command, or answers 124 the way a
    # command that outlived its bound does, for the one TIMEOUT_HANGS names.
    "timeout": r'''#!/usr/bin/env bash
echo "timeout ${*:1:4}" >> "$EVENTS"
shift
if [[ -n ${TIMEOUT_HANGS:-} && "$*" == *"$TIMEOUT_HANGS"* ]]; then
  exit 124
fi
exec "$@"
''',
}


class EgressLoaderTest(unittest.TestCase):
    def load(self, **overrides):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stubs = root / "bin"
            stubs.mkdir()
            for name, body in STUBS.items():
                path = stubs / name
                path.write_text(body)
                path.chmod(0o755)
            state = root / "state"
            state.mkdir()
            events = root / "events"
            env = {
                **os.environ,
                "PATH": f"{stubs}:{os.environ['PATH']}",
                # ncc's socket, as portal.env or an operator's shell exports it.
                "DOCKER_HOST": NCC_SOCKET,
                "EVENTS": str(events),
                "STATE": str(state),
                "NCC_EGRESS_RULESET": str(RULESET),
                "NCC_EGRESS_BRIDGE_RULESET": str(BRIDGE_RULESET),
                "NCC_DOCKER_ADMIN_HOST": ADMIN_HOST,
                "NCC_EGRESS_WAIT_SECONDS": "60",
                "NCC_DEPLOY_ENV": str(root / "deploy.env"),
                "INFO_READY_AFTER": "1",
                "BRIDGE_NAME": "br-test0",
                "BRIDGE_LOAD_STATUS": "0",
                "LISTING": LISTING,
                **overrides,
            }
            # A system unit's ExecStartPost has no user runtime dir.
            env.pop("XDG_RUNTIME_DIR", None)
            result = subprocess.run(
                ["bash", str(LOADER)], env=env, capture_output=True, text=True, timeout=10
            )
            loads = {path.name: path.read_text() for path in state.glob("load-*")}
            lines = events.read_text().splitlines() if events.exists() else []
            hosts = state / "docker-hosts"
            self.docker_hosts = hosts.read_text().splitlines() if hosts.exists() else []
            return result, lines, loads

    # From systemd's ExecStartPost the loader has no environment: the
    # rulesets' paths and the daemon come from the operator's deploy env file.
    def test_reads_the_ruleset_paths_and_daemon_from_the_deploy_env_file(self):
        with tempfile.TemporaryDirectory() as directory:
            env_file = Path(directory) / "deploy.env"
            env_file.write_text(
                f"NCC_EGRESS_RULESET={RULESET}\nNCC_EGRESS_BRIDGE_RULESET={BRIDGE_RULESET}\n"
                f"NCC_DOCKER_ADMIN_HOST={ADMIN_HOST}\n"
            )
            result, _lines, loads = self.load(
                NCC_DEPLOY_ENV=str(env_file), NCC_EGRESS_RULESET="",
                NCC_EGRESS_BRIDGE_RULESET="", NCC_DOCKER_ADMIN_HOST="",
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("table inet ncc_egress", loads["load-inet"])
        self.assertIn("table bridge ncc_egress", loads["load-bridge"])
        self.assertEqual(set(self.docker_hosts), {ADMIN_HOST})

    def test_without_the_deploy_env_file_nothing_is_loaded(self):
        result, lines, loads = self.load(NCC_EGRESS_RULESET="", NCC_EGRESS_BRIDGE_RULESET="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no host layout", result.stderr)
        self.assertEqual((lines, loads), ([], {}))

    # Without it the loader would ask whatever DOCKER_HOST names, and filter
    # the bridge of a daemon that runs no builds.
    def test_without_the_docker_ncc_admin_endpoint_nothing_is_loaded(self):
        result, lines, loads = self.load(NCC_DOCKER_ADMIN_HOST="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NCC_DOCKER_ADMIN_HOST", result.stderr)
        self.assertEqual((lines, loads), ([], {}))

    def test_loads_both_tables_into_the_host_namespace(self):
        result, lines, loads = self.load()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(lines.count("nft -f -"), 2, lines)
        self.assertIn("nft list table inet ncc_egress", lines)
        self.assertFalse([line for line in lines if line.startswith("nsenter")], lines)
        self.assertIn('define ncc_bridge = "br-test0"', loads["load-inet"])
        self.assertNotIn('define ncc_bridge = "docker0"', loads["load-inet"])
        self.assertIn("table inet ncc_egress", loads["load-inet"])
        self.assertIn('define ncc_bridge = "br-test0"', loads["load-bridge"])
        self.assertIn("table bridge ncc_egress", loads["load-bridge"])

    # box-a also runs the system dockerd, whose docker0 is not the build
    # bridge; and ncc's own socket may not inspect networks.
    def test_reads_the_bridge_of_docker_ncc_through_its_admin_endpoint(self):
        result, lines, _loads = self.load()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue([line for line in lines if line.startswith("docker network inspect")],
                        lines)
        self.assertEqual(set(self.docker_hosts), {ADMIN_HOST})

    def test_loads_without_a_rootless_runtime_dir(self):
        result, _lines, loads = self.load()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("load-inet", loads)
        self.assertNotIn("/run/user/", result.stdout + result.stderr)

    def test_bounds_every_docker_and_nft_call(self):
        result, lines, _loads = self.load()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [line for line in lines if line.startswith(("docker ", "nft "))]
        bounded = [line for line in lines if line.startswith("timeout ")]
        self.assertEqual(len(calls), 5, lines)
        self.assertEqual(len(bounded), len(calls), lines)
        self.assertTrue(all(line.startswith("timeout 10 ") for line in bounded), bounded)
        self.assertIn("timeout 10 docker info", bounded)
        self.assertIn("timeout 10 docker network inspect", bounded)
        self.assertEqual(sum(line.startswith("timeout 10 nft ") for line in bounded), 3, bounded)

    def test_a_hung_docker_info_is_retried_within_the_overall_wait(self):
        result, lines, loads = self.load(TIMEOUT_HANGS="docker info", NCC_EGRESS_WAIT_SECONDS="0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not ready", result.stderr)
        self.assertEqual(loads, {})

    def test_a_hung_nft_load_fails_the_load(self):
        result, _lines, loads = self.load(TIMEOUT_HANGS="nft -f -")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(loads, {})

    def test_a_hung_listing_fails_the_load(self):
        result, _lines, _loads = self.load(TIMEOUT_HANGS="nft list table")
        self.assertNotEqual(result.returncode, 0)

    def test_a_hung_network_inspect_fails_the_load(self):
        result, _lines, loads = self.load(TIMEOUT_HANGS="docker network inspect")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(loads, {})

    def test_waits_for_a_daemon_that_is_still_starting(self):
        result, lines, loads = self.load(INFO_READY_AFTER="3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(lines.count("sleep"), 2)
        self.assertIn("load-inet", loads)

    def test_gives_up_without_loading_when_the_daemon_never_answers(self):
        result, lines, loads = self.load(INFO_READY_AFTER="1000", NCC_EGRESS_WAIT_SECONDS="0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not ready", result.stderr)
        self.assertFalse(any(line.startswith(("nft", "nsenter")) for line in lines))
        self.assertEqual(loads, {})

    def test_refuses_a_bridge_name_nft_would_read_as_rules(self):
        result, _lines, loads = self.load(BRIDGE_NAME='docker0"; flush ruleset; #')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected bridge name", result.stderr)
        self.assertEqual(loads, {})

    def test_a_loaded_table_without_the_final_drop_fails(self):
        result, _lines, _loads = self.load(LISTING="table inet ncc_egress {\n}\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("final drop", result.stderr)

    def test_the_bridge_table_is_best_effort(self):
        result, _lines, loads = self.load(BRIDGE_LOAD_STATUS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("bridge-family table not loaded", result.stderr)
        self.assertIn("load-inet", loads)


class EgressRulesetTest(unittest.TestCase):
    rules = RULESET.read_text()

    def test_touches_only_its_own_table(self):
        for text in (self.rules, BRIDGE_RULESET.read_text()):
            self.assertNotIn("flush ruleset", text)
            tables = set(re.findall(r"^\s*(?:delete )?table (\w+ \w+)", text, re.M))
            self.assertEqual(len(tables), 1, tables)
        self.assertLess(
            self.rules.index("table inet ncc_egress {}"),
            self.rules.index("delete table inet ncc_egress"),
        )

    def test_drops_every_private_range(self):
        for prefix in [
            "10.0.0.0/8",
            "100.64.0.0/10",
            "127.0.0.0/8",
            "169.254.0.0/16",
            "172.16.0.0/12",
            "192.168.0.0/16",
            "fc00::/7",
            "fe80::/10",
            "::1",
        ]:
            self.assertIn(prefix, self.rules)

    def test_dns_rules_sit_either_side_of_the_private_drops(self):
        resolver = self.rules.index("ip daddr { 10.0.2.2, 10.0.2.3 }")
        private = self.rules.index("10.0.0.0/8")
        web = self.rules.index("tcp dport { 80, 443 } accept")
        public_dns = self.rules.index("meta l4proto { tcp, udp } th dport 53 accept", private)
        final = self.rules.index(f'drop comment "{MARKER}"')
        self.assertLess(resolver, private)
        self.assertLess(private, web)
        self.assertLess(web, final)
        self.assertLess(public_dns, final)

    def test_loader_and_ruleset_carry_the_same_marker(self):
        self.assertIn(f'drop comment "{MARKER}"', self.rules)
        self.assertIn(f"marker={MARKER}", LOADER.read_text())

    def test_preflight_looks_for_the_same_marker(self):
        builder = (OPS.parent / "apps/portal/lib/portal/builder.ex").read_text()
        self.assertIn(f'@egress_marker "{MARKER}"', builder)

    @unittest.skipUnless(shutil.which("nft") and shutil.which("unshare"), "needs nft and unshare")
    def test_nft_parses_the_ruleset(self):
        if subprocess.run(["unshare", "-rn", "true"], capture_output=True).returncode != 0:
            self.skipTest("unprivileged network namespaces are not available here")
        result = subprocess.run(
            ["unshare", "-rn", "nft", "-c", "-f", str(RULESET)], capture_output=True, text=True
        )
        if result.returncode != 0 and re.search(
            r"Operation not supported|No such file or directory", result.stderr
        ):
            self.skipTest(f"this kernel lacks an nf_tables feature: {result.stderr.strip()}")
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
