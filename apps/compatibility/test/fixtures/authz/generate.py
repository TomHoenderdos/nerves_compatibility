#!/usr/bin/env python3
"""Regenerates create_payloads.json: the POST /containers/create bodies the
docker CLI sends for every container ncc starts on a builder.

The authorization policy in front of the builders' docker daemon is tested
against these, in the builder host's configuration, so
they must be what a real CLI sends, not a hand-written guess. The build and
warm argv come from `Compatibility.Builder.Argv.build/1` on the pinned input
of ../argv/post_isolation.exs, with the builders' host layout (uid 950,
/var/lib/ncc/*). The egress probe and the promotion
copy are transcribed from `Portal.EgressCheck.bare_args/1` and
`Portal.BuildCache.Promotion.copy_args/5`.

Needs elixirc, a docker CLI and nothing listening: the CLI talks to a fake
daemon on a temporary unix socket that records the body and refuses.

    python3 apps/compatibility/test/fixtures/authz/generate.py

Then copy create_payloads.json to where the builder host's configuration
tests its policy.
"""

import http.server
import json
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
ARGV_SRC = ROOT / "apps/compatibility/lib/compatibility/builder/argv.ex"
OUT = HERE / "create_payloads.json"

RUN = "ncc-11111111-2222-3333-4444-555555555555"
SCRATCH = f"/var/lib/ncc/scratch/{RUN}"
USER = "950:950"
IMAGE = "ncc-worker:local"

SPEC = f'''
paths = %{{
  work: "{SCRATCH}/work",
  out: "{SCRATCH}/out",
  files: "{SCRATCH}/files",
  tmp: "{SCRATCH}/tmp",
  cache: "{SCRATCH}/cache",
  nerves_cache: "/var/lib/ncc/nerves-cache",
  hex_cache: "/var/lib/ncc/hex-cache",
  build_cache: "/var/lib/ncc/build-cache/sha256_deadbeef"
}}
spec = %{{
  container_name: "{RUN}",
  user: "{USER}",
  image: "{IMAGE}",
  cpus: "2",
  memory: "4g",
  build_concurrency: "2",
  nerves_cache_mode: :readonly,
  paths: paths
}}
warm = %{{spec | nerves_cache_mode: :warm, container_name: "ncc-warm_nerves-1730000000000"}}
IO.puts(JSON.encode!(%{{
  build: Compatibility.Builder.Argv.build(spec),
  warm_nerves: Compatibility.Builder.Argv.build(warm)
}}))
'''

EGRESS_PROBE = [
    "run", "--rm", "--pull=never", "--cap-drop=ALL", "--security-opt=no-new-privileges",
    "--runtime=runsc", "--read-only", "--memory", "256m", "--user", USER,
    "--entrypoint", "bash", IMAGE, "-c", "probe", "192.0.2.1", "5432",
]

PROMOTION_COPY = [
    "run", "--rm", "--pull=never", "--name", "ncc-promote-0123456789abcdef",
    "--network", "none", "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges",
    "--pids-limit", "64", "--runtime=runsc", "--memory", "256m", "--user", USER,
    "--mount", f"type=bind,source={SCRATCH}/out,target=/src,readonly",
    "--mount", # Portal.BuildCache.Staging.name/1 of the slug's entry: <dest>.tmp.<host>.<hex>.
    "type=bind,source=/var/lib/ncc/build-cache/sha256_deadbeef/" + "b" * 64
    + ".tmp.builder-1.0123456789abcdef,target=/dst",
    "--entrypoint", "cp", IMAGE, "-a", "/src/build-cache/" + "a" * 64 + "/.", "/dst",
]


def argv_from_elixir():
    with tempfile.TemporaryDirectory() as ebin:
        subprocess.run(["elixirc", "-o", ebin, str(ARGV_SRC)], check=True,
                       capture_output=True)
        out = subprocess.run(["elixir", "-pa", ebin, "-e", SPEC], check=True,
                             capture_output=True, text=True).stdout
    return json.loads(out)


def capture(argv):
    captured = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def address_string(self):
            return "unix"

        def reply(self, code, body=b"{}"):
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Api-Version", "1.47")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_HEAD(self):
            self.reply(200, b"")

        def do_GET(self):
            self.reply(200, b"OK" if "_ping" in self.path else b"{}")

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            if "/containers/create" in self.path:
                captured["Path"] = self.path
                captured["Body"] = json.loads(body)
            self.reply(500, b'{"message":"captured"}')

    class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
        daemon_threads = True

    with tempfile.TemporaryDirectory() as directory:
        sock = os.path.join(directory, "docker.sock")
        server = Server(sock, Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        env = {**os.environ, "DOCKER_HOST": f"unix://{sock}", "DOCKER_CONTEXT": ""}
        env.pop("DOCKER_CONFIG", None)
        subprocess.run(["docker", *argv], env=env, capture_output=True, timeout=30)
        server.shutdown()
    if "Body" not in captured:
        raise SystemExit(f"the docker CLI sent no create for {argv}")
    # The CLI sends Env in map order, different on every run; sorted, so a
    # regeneration only shows what changed.
    body = captured["Body"]
    body["Env"] = sorted(body.get("Env") or [])
    # As dockerd hands it to the authz plugin: the path with its API version.
    return {"Method": "POST", "Path": captured["Path"], "Body": body}


def main():
    argvs = argv_from_elixir()
    argvs["egress_probe"] = EGRESS_PROBE
    argvs["promotion_copy"] = PROMOTION_COPY
    cli = subprocess.run(["docker", "version", "--format", "{{.Client.Version}}"],
                         capture_output=True, text=True).stdout.strip()
    payloads = {name: {"argv": argv, "request": capture(argv)} for name, argv in argvs.items()}
    OUT.write_text(json.dumps({"ncc_authz_fixtures": {"docker_cli": cli, **payloads}},
                              indent=2, sort_keys=True) + "\n")
    print(f"wrote {OUT} ({', '.join(payloads)}; docker CLI {cli})")


if __name__ == "__main__":
    main()
