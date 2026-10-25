# Remote Builders over mTLS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a builder VM on someone else's cloud account enrol with a one-time token, claim build jobs over mutual TLS, run the worker container with the same isolation as a local build host, and upload `result.json`, logs and files that the web host ingests exactly like a local build.

**Architecture:** The portal gains a second Phoenix endpoint (`PortalWeb.BuilderEndpoint`, Bandit, port 8443, mTLS against the portal's own ECDSA P-256 CA) serving a small JSON/raw API, an Ash domain `Portal.Builders` (builders, certificates, enrolment tokens, leases), a `:remote` Oban queue whose only job is to turn a build job into a `builder_leases` row, and a remote loader in `Portal.Workers.Ingest`. The agent is a new umbrella app `apps/ncc_agent` (release, no database) that enrols, long-polls claims, drives the VM's rootful Docker with argv built by the shared `Compatibility.Builder.Argv`, uploads content-addressed files in tar batches and completes the lease. Routing between `:builds` and `:remote` is decided at enqueue time by `Portal.Builders.Routing`, which every enqueuer consults.

**Tech Stack:** Elixir 1.20 / OTP 29, Phoenix 1.8 + Bandit 1.13, Ash 3 + AshPostgres (generated migrations), Oban 2.23, `x509` 0.9.2 (CA, CSR), Req 0.7 + Finch (agent HTTP, mTLS, streamed uploads), `:erl_tar`, Docker, iptables, GitHub Actions + GHCR.

**Spec:** `docs/superpowers/specs/2026-10-25-remote-builders-design.md` (v2). Isolation interfaces the agent is written against: `docs/superpowers/specs/2026-10-21-build-sandbox-isolation-design.md` sections 1, 3 and 4 (being implemented on branch `feat/sandbox-isolation` by another session; this plan does **not** implement their host side).

## Workspace

Work on branch `agent/chat-f61630354660` in `/home/agent/repo` (a snapshot of `main`; no remote, never push, never `git stash`). Toolchain: `source ~/toolchain/env.sh` before every `mix` command (OTP 29.1, Elixir 1.20.4, Postgres 17 on `127.0.0.1:5432` with trust auth, shellcheck). All `mix` commands run from the umbrella root. **Never run `mix deps.*` inside `apps/*`.** There is no Docker on this machine: Docker-tagged tests are written, not run; say so.

## Global Constraints

- Owner's rulings (do not reopen): no database access for remote builders; HTTPS only to `PortalWeb.BuilderEndpoint` on `NCC_BUILDER_PORT` (default `8443`), Bandit, mutual TLS, portal's own ECDSA P-256 CA, Apache not involved; enrolment token format `<token id>.<32-byte secret, base64url no padding>.<first 16 hex chars of the CA certificate sha256>`; client certificates one year, renewal via `POST /builder/v1/renew` within 30 days of expiry (425 too early, 403 revoked); builders enrol with `publishing: false`; revoking a builder revokes its runs and re-enqueues those package versions locally through `Portal.BulkRebuild` (`what: :full`, `created_by: "revoke builder <name>"`); `:remote` queue only writes `builder_leases`; claim long-polls up to 25 s, woken by a `Phoenix.PubSub` broadcast on `builders:leases`; heartbeat every 60 s during build and upload; `files/missing` then tar batches verified on extraction with per-file/batch/total caps and a free-space floor; `complete` then today's `Portal.Catalog.Ingestion.ingest/2` on the web host; reaper re-queues silent leases (10 min leased, 60 min uploading, 3 attempts); routing goes remote only when the local backlog exceeds a threshold (default 10), toolchain/warm/pinned jobs stay local, `remote_enabled` auto-flips on builders' `last_seen_at` (on within 5 min, off after 15 min); agent is `apps/ncc_agent`, a release run directly on the VM, Req/Finch with mTLS, rootful Docker; CI publishes `ncc-worker` to GHCR and agent tarballs plus `images.json` of registry digests; staleness checks never compare run digests with the current image.
- Worker exit codes stay `0/10/11`; host codes `20/21`. Remote `complete` maps exit codes exactly as `Portal.Workers.Build.classify/1`.
- `Portal.Builder.build_docker_args/4` is **not modified** here (the isolation branch is changing it). Main already carries the isolation design's section 4 in it: `--read-only`, `--pids-limit 4096`, per-run `/tmp` and `/home/nerves/.cache` scratch binds and a read-only `/build-cache`; only section 1 (the Nerves cache at `/nerves-cache`, read-only, with the per-run farm) is still to land. `Compatibility.Builder.Argv.build/1` reproduces today's argv with `nerves_cache_mode: :legacy, hardening: true` and carries the post-isolation `:readonly`/`:readwrite` modes; a parity test in `apps/portal` pins the two together so the isolation branch's landing is forced to switch `Portal.Builder` over.
- Oban 2.23: any `unique:` option names `states` (use `states: :incomplete` where the worker is a singleton). AshPostgres partial identities need `identity_wheres_to_sql`; index names stay under 63 chars.
- Sobelow: every `File.*` on a trusted path carries `# sobelow_skip ["Traversal.FileModule"]` above the `def`; `String.to_atom` on boot-only values carries `# sobelow_skip ["DOS.StringToAtom"]`. Sobelow prints `SCAN COMPLETE` on failure too: check `$?`.
- The Elixir type checker rejects `send(...) && :ok` in tests; write two statements.
- Env vars never reach `bin/portal rpc`; anything an operator runs on a release goes through `bin/portal eval` with explicit arguments.
- Gates, from the umbrella root, before every commit of a task: `mix format` (then `git diff --exit-code` on nothing else), `mix compile --warnings-as-errors`, the task's own tests. Before the final commit: `mix credo`, `mix test`, the three sobelow lines, `mix do deps.loadpaths + deps.audit`, `mix hex.audit`, `bash -n` + `shellcheck -x` on every ops script and `python3 -m unittest discover -s ops -p 'test_*.py'`.
- Commit trailer on every commit: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Generated migrations: `MIX_ENV=test mix ash_postgres.generate_migrations --name <name>` from the root, then `MIX_ENV=test mix ecto.migrate`; commit `apps/portal/priv/repo/migrations/*` and `apps/portal/priv/resource_snapshots/**`.

## Review Focus

1. **A tar entry whose name is a valid sha but whose bytes hash differently** must be discarded without ever landing under `files/<sha>`, the batch answered 422 listing it, and every other entry of the batch kept. Task 8 test "a bad sha is discarded, the batch is 422, the good entry stays".
2. **A builder whose certificate was superseded more than 24 hours ago** must be refused with 403 even though the CA still trusts the certificate. Task 6 test "a superseded certificate is accepted for 24 h and refused after".
3. **Two builders claiming at the same instant** must never both hold the same lease, and a builder at its `slots` limit must get 204, not a second lease. Task 7 test "claim is atomic across two concurrent claimants" and "a builder holds at most slots leases".
4. **A run ingested from a builder with `publishing: false`** must be absent from the manifest and from `packages_with_precompiled_files/0` while every local run of the same package stays published; flipping `publishing` publishes it with no re-ingest. Task 9 test "publication follows the builder's publishing flag".
5. **A revoked builder's open leases** must go back to `:queued` so another builder or the reaper's failure path owns them, and its already-ingested runs must be revoked and the package versions re-enqueued locally with `meta.pin_local`, never routed remote again. Task 5 test "revoking a builder revokes its runs, requeues its leases and pins the rebuilds locally".

---

### Task 1: CI images workflow, `images.json`, and `Portal.Builders.Images`

**Files:**
- Create: `.github/workflows/images.yml`
- Create: `ops/images-sync.sh`, `ops/test_images_sync.py`
- Create: `apps/portal/lib/portal/builders/images.ex`
- Modify: `.github/workflows/deploy.yml` (validation list gains `ops/images-sync.sh`), `ops/deploy.sh` (best-effort sync at the end), `config/runtime.exs` (`NCC_IMAGES_JSON`), `apps/portal/config/config.exs` (default path), `apps/portal/config/test.exs` (tmp path)
- Test: `apps/portal/test/portal/builders/images_test.exs`

**Interfaces:**
- Produces: `Portal.Builders.Images.path/0 :: Path.t()`, `load/0 :: {:ok, map()} | {:error, :missing | :invalid}`, `worker_image/0 :: %{name: String.t(), digest: String.t(), tag: String.t()} | nil`, `agent/0 :: %{version: String.t(), releases: %{String.t() => %{url: String.t(), sha256: String.t()}}} | nil`, `min_agent_version/0 :: String.t() | nil`.
- `images.json` shape (written by CI, read by the portal):

```json
{
  "commit": "<40-hex sha>",
  "generated_at": "2026-10-25T20:00:00Z",
  "images": {
    "ncc-worker": {"name": "ghcr.io/tomhoenderdos/ncc-worker", "tag": "<sha>", "digest": "sha256:<64 hex>"}
  },
  "agent": {
    "version": "<commit unix seconds>.<12-char sha>",
    "releases": {
      "x86_64": {"url": "https://github.com/TomHoenderdos/nerves_compatibility/releases/download/agent-<sha>/ncc-agent-x86_64.tar.gz", "sha256": "<64 hex>"},
      "aarch64": {"url": "...ncc-agent-aarch64.tar.gz", "sha256": "<64 hex>"}
    }
  }
}
```

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Portal.Builders.ImagesTest do
  use ExUnit.Case, async: false

  alias Portal.Builders.Images

  setup do
    path = Path.join(System.tmp_dir!(), "images-#{System.unique_integer([:positive])}.json")
    previous = Application.get_env(:portal, Images, [])
    Application.put_env(:portal, Images, Keyword.put(previous, :path, path))

    on_exit(fn ->
      Application.put_env(:portal, Images, previous)
      File.rm(path)
    end)

    %{path: path}
  end

  @doc_json """
  {"commit": "abc", "generated_at": "2026-10-25T20:00:00Z",
   "images": {"ncc-worker": {"name": "ghcr.io/tomhoenderdos/ncc-worker", "tag": "abc",
                             "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"}},
   "agent": {"version": "1761400000.abcdefabcdef",
             "releases": {"x86_64": {"url": "https://example.com/a.tar.gz", "sha256": "aa"}}}}
  """

  test "reads the worker image and the agent release", %{path: path} do
    File.write!(path, @doc_json)

    assert %{name: "ghcr.io/tomhoenderdos/ncc-worker", digest: "sha256:" <> _, tag: "abc"} =
             Images.worker_image()

    assert %{version: "1761400000.abcdefabcdef", releases: %{"x86_64" => %{url: _, sha256: "aa"}}} =
             Images.agent()

    assert Images.min_agent_version() == "1761400000.abcdefabcdef"
  end

  test "a missing or invalid file is nil, never a crash", %{path: path} do
    assert Images.worker_image() == nil
    assert Images.agent() == nil
    assert {:error, :missing} = Images.load()

    File.write!(path, "{not json")
    assert {:error, :invalid} = Images.load()
    assert Images.worker_image() == nil
  end

  test "a digest that is not sha256:<64 hex> is refused", %{path: path} do
    File.write!(path, String.replace(@doc_json, ~r/sha256:1+/, "sha256:zz"))
    assert Images.worker_image() == nil
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `source ~/toolchain/env.sh && mix test apps/portal/test/portal/builders/images_test.exs`
Expected: FAIL, `Portal.Builders.Images` undefined.

- [ ] **Step 3: Write `Portal.Builders.Images`**

```elixir
defmodule Portal.Builders.Images do
  @moduledoc """
  The registry digests and agent releases CI published for the deployed
  commit, read from `images.json` (`NCC_IMAGES_JSON`, default
  `/etc/ncc-portal/images.json`, written by `ops/images-sync.sh`).

  A remote lease carries the registry digest from here, so every builder
  means the same image by it. Missing or malformed, every reader answers nil
  and `Portal.Builders.Routing` keeps work local; nothing here ever raises.
  """

  @digest ~r/\Asha256:[0-9a-f]{64}\z/

  @spec path() :: Path.t()
  def path do
    :portal
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:path, "/etc/ncc-portal/images.json")
  end

  @spec load() :: {:ok, map()} | {:error, :missing | :invalid}
  # The path is operator configuration, never request input.
  # sobelow_skip ["Traversal.FileModule"]
  def load do
    with {:ok, bytes} <- File.read(path()),
         {:ok, %{} = doc} <- Jason.decode(bytes) do
      {:ok, doc}
    else
      {:error, :enoent} -> {:error, :missing}
      _ -> {:error, :invalid}
    end
  end

  @spec worker_image() :: %{name: String.t(), digest: String.t(), tag: String.t()} | nil
  def worker_image do
    with {:ok, doc} <- load(),
         %{"name" => name, "digest" => digest} = image <- get_in(doc, ["images", "ncc-worker"]),
         true <- is_binary(name) and is_binary(digest) and Regex.match?(@digest, digest) do
      %{name: name, digest: digest, tag: Map.get(image, "tag")}
    else
      _ -> nil
    end
  end

  @spec agent() ::
          %{version: String.t(), releases: %{String.t() => %{url: String.t(), sha256: String.t()}}}
          | nil
  def agent do
    with {:ok, doc} <- load(),
         %{"version" => version, "releases" => %{} = releases} <- Map.get(doc, "agent"),
         true <- is_binary(version) do
      releases =
        for {arch, %{"url" => url, "sha256" => sha}} <- releases,
            is_binary(url) and is_binary(sha),
            into: %{},
            do: {arch, %{url: url, sha256: sha}}

      %{version: version, releases: releases}
    else
      _ -> nil
    end
  end

  @spec min_agent_version() :: String.t() | nil
  def min_agent_version do
    case agent() do
      %{version: version} -> version
      nil -> nil
    end
  end
end
```

Config: in `apps/portal/config/config.exs` add `config :portal, Portal.Builders.Images, path: "/etc/ncc-portal/images.json"`; in `apps/portal/config/test.exs` add `config :portal, Portal.Builders.Images, path: Path.join(System.tmp_dir!(), "ncc-test-images.json")`; in `config/runtime.exs` inside the `portal_available?` block: `if images = System.get_env("NCC_IMAGES_JSON"), do: config(:portal, Portal.Builders.Images, path: images)`.

- [ ] **Step 4: Run the test, expect PASS**

- [ ] **Step 5: Write `.github/workflows/images.yml`**

```yaml
name: Images and agent releases

# Publishes what a remote builder needs to mean the same thing as a local
# build host: the worker image by registry digest, and the agent release per
# architecture, all described in one images.json the web host reads
# (Portal.Builders.Images). Runs only after the test workflow passed on main.
on:
  workflow_run:
    workflows: ["Test and deploy"]
    types: [completed]
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: images-${{ github.event.workflow_run.head_sha || github.sha }}
  cancel-in-progress: false

env:
  REGISTRY: ghcr.io
  WORKER_IMAGE: ghcr.io/tomhoenderdos/ncc-worker

jobs:
  worker-image:
    name: Push ncc-worker
    if: github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success'
    runs-on: ubuntu-24.04
    timeout-minutes: 90
    permissions:
      contents: read
      packages: write
    outputs:
      digest: ${{ steps.push.outputs.digest }}
      sha: ${{ steps.sha.outputs.sha }}
    steps:
      - id: sha
        run: echo "sha=${{ github.event.workflow_run.head_sha || github.sha }}" >> "$GITHUB_OUTPUT"
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7
        with:
          ref: ${{ steps.sha.outputs.sha }}
          persist-credentials: false
      - uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Build and push
        id: push
        uses: docker/build-push-action@v6
        with:
          context: .
          file: apps/ncc_worker/Dockerfile
          push: true
          tags: |
            ${{ env.WORKER_IMAGE }}:${{ steps.sha.outputs.sha }}
            ${{ env.WORKER_IMAGE }}:latest

  agent-release:
    name: Agent release (${{ matrix.arch }})
    if: github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success'
    strategy:
      matrix:
        include:
          - arch: x86_64
            runner: ubuntu-24.04
          - arch: aarch64
            runner: ubuntu-24.04-arm
    runs-on: ${{ matrix.runner }}
    timeout-minutes: 30
    steps:
      - id: sha
        run: echo "sha=${{ github.event.workflow_run.head_sha || github.sha }}" >> "$GITHUB_OUTPUT"
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7
        with:
          ref: ${{ steps.sha.outputs.sha }}
          persist-credentials: false
      - uses: erlef/setup-beam@54075bcc5e249e4758d363f27d099f55d843f124 # v1
        with:
          elixir-version: "1.20"
          otp-version: "28"
      - name: Build release
        env:
          MIX_ENV: prod
        run: |
          sha="${{ steps.sha.outputs.sha }}"
          export NCC_AGENT_VERSION="$(git show -s --format=%ct "$sha").${sha:0:12}"
          mix deps.get --only prod
          mix release ncc_agent --overwrite
          tar -C _build/prod/rel -czf "ncc-agent-${{ matrix.arch }}.tar.gz" ncc_agent
          sha256sum "ncc-agent-${{ matrix.arch }}.tar.gz" > "ncc-agent-${{ matrix.arch }}.tar.gz.sha256"
      - uses: actions/upload-artifact@v4
        with:
          name: ncc-agent-${{ matrix.arch }}
          path: ncc-agent-${{ matrix.arch }}.tar.gz*

  publish:
    name: Release and images.json
    needs: [worker-image, agent-release]
    runs-on: ubuntu-24.04
    permissions:
      contents: write
    steps:
      - uses: actions/download-artifact@v4
        with:
          path: artifacts
          merge-multiple: true
      - name: Write images.json
        env:
          SHA: ${{ needs.worker-image.outputs.sha }}
          DIGEST: ${{ needs.worker-image.outputs.digest }}
          REPO: ${{ github.repository }}
        run: |
          set -euo pipefail
          version="$(curl -fsSL -H "Authorization: Bearer ${{ github.token }}" \
            "https://api.github.com/repos/$REPO/commits/$SHA" | python3 -c '
          import json,sys,datetime
          c=json.load(sys.stdin)["commit"]["committer"]["date"]
          t=datetime.datetime.fromisoformat(c.replace("Z","+00:00"))
          print(int(t.timestamp()))')"
          version="${version}.${SHA:0:12}"
          x86="$(cut -d" " -f1 artifacts/ncc-agent-x86_64.tar.gz.sha256)"
          arm="$(cut -d" " -f1 artifacts/ncc-agent-aarch64.tar.gz.sha256)"
          base="https://github.com/$REPO/releases/download/agent-$SHA"
          python3 - "$SHA" "$DIGEST" "$version" "$x86" "$arm" "$base" <<'PY' > artifacts/images.json
          import json, sys, datetime
          sha, digest, version, x86, arm, base = sys.argv[1:]
          print(json.dumps({
            "commit": sha,
            "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "images": {"ncc-worker": {"name": "ghcr.io/tomhoenderdos/ncc-worker", "tag": sha, "digest": digest}},
            "agent": {"version": version, "releases": {
              "x86_64": {"url": f"{base}/ncc-agent-x86_64.tar.gz", "sha256": x86},
              "aarch64": {"url": f"{base}/ncc-agent-aarch64.tar.gz", "sha256": arm}}}
          }, indent=2))
          PY
          cat artifacts/images.json
      - name: Create release
        env:
          GH_TOKEN: ${{ github.token }}
          SHA: ${{ needs.worker-image.outputs.sha }}
        run: |
          gh release create "agent-$SHA" --repo "${{ github.repository }}" \
            --title "Agent $SHA" --notes "ncc-agent release and images.json for $SHA" \
            --target "$SHA" artifacts/ncc-agent-x86_64.tar.gz artifacts/ncc-agent-aarch64.tar.gz \
            artifacts/images.json
```

- [ ] **Step 6: Write `ops/images-sync.sh` and its unittest**

```bash
#!/bin/bash
# Fetches images.json for the deployed commit from the GitHub release the
# images workflow publishes (agent-<sha>) into /etc/ncc-portal/images.json,
# which Portal.Builders.Images reads. Best-effort: the release lands minutes
# after the deploy, so a miss is a retry on the next run, not a failure.
#
# Usage: images-sync.sh <40-hex sha> [destination]   (see docs/REMOTE_BUILDERS.md)
set -euo pipefail

sha=${1:-}
dest=${2:-/etc/ncc-portal/images.json}
repo=${NCC_IMAGES_REPO:-TomHoenderdos/nerves_compatibility}

if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "usage: $0 <40-character commit sha> [destination]" >&2
  exit 2
fi

url="https://github.com/$repo/releases/download/agent-$sha/images.json"
tmp=$(mktemp "${dest}.XXXXXX")
trap 'rm -f "$tmp"' EXIT

if ! curl -fsSL --max-time 30 -o "$tmp" "$url"; then
  echo "images.json for $sha is not published yet ($url)" >&2
  exit 1
fi

if ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["commit"]==sys.argv[2]; assert d["images"]["ncc-worker"]["digest"].startswith("sha256:")' "$tmp" "$sha"; then
  echo "downloaded images.json is not for $sha or is malformed" >&2
  exit 1
fi

chmod 644 "$tmp"
mv "$tmp" "$dest"
trap - EXIT
echo "installed images.json for $sha at $dest"
```

`ops/test_images_sync.py`:

```python
"""images-sync.sh refuses bad arguments and malformed downloads without touching the destination."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("images-sync.sh")
SHA = "a" * 40


class ImagesSyncTest(unittest.TestCase):
    def run_sync(self, args, fake_curl_body=None, curl_status=0):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dest = root / "images.json"
            bindir = root / "bin"
            bindir.mkdir()
            curl = bindir / "curl"
            body = json.dumps(fake_curl_body) if fake_curl_body is not None else ""
            curl.write_text(
                "#!/bin/bash\n"
                "out=''\nwhile [ $# -gt 0 ]; do if [ \"$1\" = -o ]; then out=$2; shift; fi; shift; done\n"
                f"printf '%s' '{body}' > \"$out\"\nexit {curl_status}\n"
            )
            curl.chmod(0o755)
            env = {**os.environ, "PATH": f"{bindir}:{os.environ['PATH']}"}
            result = subprocess.run(
                ["bash", str(SCRIPT), *args, str(dest)], env=env, capture_output=True, text=True
            )
            return result, dest.exists()

    def test_rejects_a_short_sha(self):
        result, written = self.run_sync(["abc"])
        self.assertEqual(result.returncode, 2)
        self.assertFalse(written)

    def test_installs_a_matching_document(self):
        doc = {"commit": SHA, "images": {"ncc-worker": {"digest": "sha256:" + "0" * 64}}}
        result, written = self.run_sync([SHA], fake_curl_body=doc)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(written)

    def test_refuses_a_document_for_another_commit(self):
        doc = {"commit": "b" * 40, "images": {"ncc-worker": {"digest": "sha256:" + "0" * 64}}}
        result, written = self.run_sync([SHA], fake_curl_body=doc)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(written)

    def test_a_missing_release_is_a_retry_not_a_crash(self):
        result, written = self.run_sync([SHA], curl_status=22)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(written)


if __name__ == "__main__":
    unittest.main()
```

In `ops/deploy.sh`, after `sleep_until_up`, append:

```bash
# Remote builders read the registry digest for this commit from images.json;
# the images workflow publishes it minutes after this deploy, so a miss here
# is retried by the ncc-images-sync timer (docs/REMOTE_BUILDERS.md).
if [[ ${2:-portal} != builder ]]; then
  bash "$SRC/ops/images-sync.sh" "$(git rev-parse HEAD)" || echo 'images.json not yet available; the sync timer will retry' >&2
fi
```

In `.github/workflows/deploy.yml`, add `ops/images-sync.sh` to both the `bash -n` and the `shellcheck -x` lists.

- [ ] **Step 7: Validate**

Run: `source ~/toolchain/env.sh && python3 -c "import yaml; yaml.safe_load(open('.github/workflows/images.yml'))" && bash -n ops/deploy.sh ops/images-sync.sh && shellcheck -x ops/deploy.sh ops/images-sync.sh && python3 -m unittest discover -s ops -p 'test_*.py' && mix test apps/portal/test/portal/builders/images_test.exs`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add .github/workflows/images.yml .github/workflows/deploy.yml ops/images-sync.sh ops/test_images_sync.py ops/deploy.sh apps/portal/lib/portal/builders/images.ex apps/portal/test/portal/builders/images_test.exs apps/portal/config config/runtime.exs
git commit -m "Publish worker images and agent releases to GHCR, read images.json

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: `Compatibility.Builder.Argv` with the argv-parity fixture

**Files:**
- Create: `apps/compatibility/lib/compatibility/builder/argv.ex`
- Test: `apps/compatibility/test/compatibility/builder/argv_test.exs`, `apps/portal/test/portal/builder_argv_parity_test.exs`

**Interfaces:**
- Produces: `Compatibility.Builder.Argv.build(spec) :: [String.t()]` (the argv after `docker`), `Compatibility.Builder.Argv.container_name(run_id)`, `Compatibility.Builder.Argv.safe_name(run_id)`. `spec` keys: `:run_id`, `:image` (the exact image ref to run), `:user` (`"uid:gid"`), `:work_dir`, `:output_dir`, `:files_dir`, `:nerves_cache`, `:hex_cache`, optional `:build_cache` (host dir or nil), `:cpus`, `:memory`, `:build_concurrency` (strings or nil), `:nerves_cache_mode` (`:legacy` default | `:readonly` | `:readwrite`), `:hardening` (boolean, default false; **today's `Portal.Builder` runs with it true**), `:tmp_dir`, `:cache_dir` (required when `hardening: true`), `:extra_env` (`[{"K", "v"}]`, appended last before the image). Argument order mirrors `Portal.Builder.build_docker_args/4` on main exactly: base flags, `--read-only`/`--pids-limit 4096` when hardening, `--cpus`/`--memory`, mounts in the order `/work`, `/out`, `/files`, `/tmp` and `/home/nerves/.cache` (hardening), the Nerves cache, `/hex-cache`, `/build-cache` (always `,readonly`), then env.
- `Portal.Builder.build_docker_args/4` is **not** changed; the parity test ties them together.

- [ ] **Step 1: Write the failing compatibility test**

```elixir
defmodule Compatibility.Builder.ArgvTest do
  use ExUnit.Case, async: true

  alias Compatibility.Builder.Argv

  @spec_base %{
    run_id: "jason-1.4.4-1",
    image: "ncc-worker:local",
    user: "1000:1000",
    work_dir: "/s/work",
    output_dir: "/s/out",
    files_dir: "/s/files",
    nerves_cache: "/c/nerves",
    hex_cache: "/c/hex"
  }

  test "legacy mode mounts the nerves cache read-write at /home/nerves/.nerves" do
    argv = Argv.build(@spec_base)

    assert ["run", "--rm", "--pull=never", "--name", "ncc-jason-1.4.4-1", "--user", "1000:1000",
            "--cap-drop=ALL", "--security-opt=no-new-privileges" | _] = argv

    assert "type=bind,source=/c/nerves,target=/home/nerves/.nerves" in argv
    assert "type=bind,source=/c/hex,target=/hex-cache" in argv
    refute "--read-only" in argv
    assert List.last(argv) == "ncc-worker:local"
    assert "NCC_INPUT=/work/input.json" in argv
    assert "TAR_OPTIONS=--no-same-owner" in argv
  end

  test "readonly mode mounts the nerves cache read-only at /nerves-cache" do
    argv = Argv.build(Map.put(@spec_base, :nerves_cache_mode, :readonly))
    assert "type=bind,source=/c/nerves,target=/nerves-cache,readonly" in argv
    refute Enum.any?(argv, &String.contains?(&1, "/home/nerves/.nerves"))
  end

  test "readwrite mode mounts /nerves-cache without readonly, for the warm job" do
    argv = Argv.build(Map.put(@spec_base, :nerves_cache_mode, :readwrite))
    assert "type=bind,source=/c/nerves,target=/nerves-cache" in argv
  end

  test "hardening adds the read-only root, the scratch binds and the pids limit" do
    argv = Argv.build(Map.merge(@spec_base, %{hardening: true, tmp_dir: "/s/tmp", cache_dir: "/s/cache"}))
    assert Enum.slice(argv, 7, 4) == ["--cap-drop=ALL", "--security-opt=no-new-privileges", "--read-only", "--pids-limit"]
    assert Enum.at(argv, 11) == "4096"
    # Scratch binds come right after /files, before the Nerves cache, as on the local host.
    mounts = argv |> Enum.filter(&String.starts_with?(&1, "type=bind")) |> Enum.map(&(&1 |> String.split("target=") |> List.last()))
    assert mounts == ["/work", "/out", "/files", "/tmp", "/home/nerves/.cache", "/home/nerves/.nerves", "/hex-cache"]
  end

  test "limits, cpu env and concurrency follow the spec" do
    argv = Argv.build(Map.merge(@spec_base, %{cpus: "2", memory: "4g", build_concurrency: "2"}))
    assert ["--cpus", "2", "--memory", "4g"] = Enum.slice(argv, 9, 4)
    assert "ERL_FLAGS=+S 2:2 +sbwt none +sbwtdcpu none +sbwtdio none" in argv
    assert "NCC_SQUASHFS_PROCESSORS=2" in argv
    assert "NCC_BUILD_CONCURRENCY=2" in argv
  end

  test "a build cache mounts at /build-cache and is announced in the env" do
    argv = Argv.build(Map.put(@spec_base, :build_cache, "/c/build/slug"))
    assert "type=bind,source=/c/build/slug,target=/build-cache,readonly" in argv
    assert "NCC_BUILD_CACHE=/build-cache" in argv
  end

  test "extra env lands after the standard env and before the image" do
    argv = Argv.build(Map.put(@spec_base, :extra_env, [{"NERVES_DL_DIR", "/work/nerves/dl"}]))
    assert Enum.slice(argv, -3, 3) == ["-e", "NERVES_DL_DIR=/work/nerves/dl", "ncc-worker:local"]
  end

  test "names are sanitized the way Portal.Builder sanitizes them" do
    assert Argv.safe_name("a/b c") == "a_b_c"
    assert Argv.container_name("x y") == "ncc-x_y"
    for bad <- ["", ".", ".."], do: assert_raise(ArgumentError, fn -> Argv.safe_name(bad) end)
  end
end
```

- [ ] **Step 2: Run it, expect failure (module undefined)**

Run: `source ~/toolchain/env.sh && mix test apps/compatibility/test/compatibility/builder/argv_test.exs`

- [ ] **Step 3: Write the module**

```elixir
defmodule Compatibility.Builder.Argv do
  @moduledoc """
  The `docker run` argument list for one worker container, shared by
  `Portal.Builder` (local build hosts) and `NccAgent` (remote builders), so a
  remote builder can only ever run what a local host runs.

  `build/1` takes a plain map and returns the argv after `docker`. With
  `nerves_cache_mode: :legacy` and `hardening: false` (the defaults) it
  reproduces `Portal.Builder.build_docker_args/4` as of 2026-10-25 flag for
  flag; `Portal.BuilderArgvParityTest` holds the two together. `:readonly`,
  `:readwrite` and `hardening: true` are the sandbox-isolation design's
  sections 1 and 4 (`docs/superpowers/specs/2026-10-21-build-sandbox-isolation-design.md`).
  """

  @pids_limit "4096"

  @type nerves_cache_mode :: :legacy | :readonly | :readwrite

  @type spec :: %{
          required(:run_id) => String.t(),
          required(:image) => String.t(),
          required(:user) => String.t(),
          required(:work_dir) => Path.t(),
          required(:output_dir) => Path.t(),
          required(:files_dir) => Path.t(),
          required(:nerves_cache) => Path.t(),
          required(:hex_cache) => Path.t(),
          optional(:build_cache) => Path.t() | nil,
          optional(:cpus) => String.t() | nil,
          optional(:memory) => String.t() | nil,
          optional(:build_concurrency) => String.t() | nil,
          optional(:nerves_cache_mode) => nerves_cache_mode(),
          optional(:hardening) => boolean(),
          optional(:tmp_dir) => Path.t(),
          optional(:cache_dir) => Path.t(),
          optional(:extra_env) => [{String.t(), String.t()}]
        }

  @spec build(spec()) :: [String.t()]
  def build(spec) do
    base = [
      "run",
      "--rm",
      "--pull=never",
      "--name",
      container_name(spec.run_id),
      "--user",
      spec.user,
      "--cap-drop=ALL",
      "--security-opt=no-new-privileges"
    ]

    base ++
      hardening_flags(spec) ++
      limits(spec) ++
      mounts(spec) ++
      env(spec) ++
      build_cache_env(spec) ++
      cpu_env(spec) ++
      concurrency_env(spec) ++
      extra_env(spec) ++
      [spec.image]
  end

  defp hardening_flags(%{hardening: true}), do: ["--read-only", "--pids-limit", @pids_limit]
  defp hardening_flags(_spec), do: []

  defp limits(spec) do
    [{:cpus, "--cpus"}, {:memory, "--memory"}]
    |> Enum.flat_map(fn {key, flag} ->
      case Map.get(spec, key) do
        nil -> []
        value -> [flag, to_string(value)]
      end
    end)
  end

  defp mounts(spec) do
    List.flatten([
      mount(spec.work_dir, "/work"),
      mount(spec.output_dir, "/out"),
      mount(spec.files_dir, "/files"),
      hardening_mounts(spec),
      nerves_mount(spec),
      mount(spec.hex_cache, "/hex-cache"),
      build_cache_mount(spec)
    ])
  end

  defp mount(source, target, suffix \\ ""),
    do: ["--mount", "type=bind,source=#{source},target=#{target}#{suffix}"]

  defp nerves_mount(%{nerves_cache_mode: :readonly} = spec),
    do: mount(spec.nerves_cache, "/nerves-cache", ",readonly")

  defp nerves_mount(%{nerves_cache_mode: :readwrite} = spec),
    do: mount(spec.nerves_cache, "/nerves-cache")

  defp nerves_mount(spec), do: mount(spec.nerves_cache, "/home/nerves/.nerves")

  # Always read-only: a build runs untrusted package code (isolation design section 2, on main).
  defp build_cache_mount(%{build_cache: dir}) when is_binary(dir), do: mount(dir, "/build-cache", ",readonly")
  defp build_cache_mount(_spec), do: []

  defp hardening_mounts(%{hardening: true} = spec) do
    [mount(Map.fetch!(spec, :tmp_dir), "/tmp"), mount(Map.fetch!(spec, :cache_dir), "/home/nerves/.cache")]
  end

  defp hardening_mounts(_spec), do: []

  defp env(_spec) do
    [
      "-e",
      "NCC_INPUT=/work/input.json",
      "-e",
      "LANG=C.UTF-8",
      "-e",
      "HOME=/home/nerves",
      "-e",
      "HEX_HOME=/hex-cache",
      "-e",
      "TAR_OPTIONS=--no-same-owner"
    ]
  end

  defp build_cache_env(%{build_cache: dir}) when is_binary(dir), do: ["-e", "NCC_BUILD_CACHE=/build-cache"]
  defp build_cache_env(_spec), do: []

  defp cpu_env(spec) do
    case cpu_quota(Map.get(spec, :cpus)) do
      nil ->
        []

      quota ->
        flags = "+S #{quota}:#{quota} +sbwt none +sbwtdcpu none +sbwtdio none"
        ["-e", "ERL_FLAGS=#{flags}", "-e", "ELIXIR_ERL_OPTIONS=#{flags}", "-e", "NCC_SQUASHFS_PROCESSORS=#{quota}"]
    end
  end

  defp cpu_quota(nil), do: nil

  defp cpu_quota(value) do
    case Float.parse(to_string(value)) do
      {cpus, _rest} -> max(1, trunc(cpus))
      :error -> nil
    end
  end

  defp concurrency_env(%{build_concurrency: value}) when not is_nil(value),
    do: ["-e", "NCC_BUILD_CONCURRENCY=#{value}"]

  defp concurrency_env(_spec), do: []

  defp extra_env(%{extra_env: pairs}) when is_list(pairs),
    do: Enum.flat_map(pairs, fn {k, v} -> ["-e", "#{k}=#{v}"] end)

  defp extra_env(_spec), do: []

  @doc "Container name for a run id: `ncc-` plus the sanitized id."
  @spec container_name(String.t()) :: String.t()
  def container_name(run_id), do: "ncc-#{safe_name(run_id)}"

  @doc "The one directory/container name transform, identical to `Portal.Builder.safe_name/1`."
  @spec safe_name(String.t()) :: String.t()
  def safe_name(run_id) when run_id in ["", ".", ".."], do: raise(ArgumentError, "invalid directory name")
  def safe_name(run_id), do: String.replace(run_id, ~r/[^A-Za-z0-9_.\-]/, "_")
end
```

- [ ] **Step 4: Run the compatibility test, expect PASS**

- [ ] **Step 5: Write the parity test in portal**

```elixir
defmodule Portal.BuilderArgvParityTest do
  @moduledoc """
  `Compatibility.Builder.Argv` is what the remote agent runs; `Portal.Builder`
  is what the local host runs. They must agree flag for flag, or a remote
  builder would run something a local host does not. When the isolation branch
  changes `Portal.Builder.build_docker_args/4`, this test is what forces it
  to switch over to `Argv.build/1` (with `nerves_cache_mode: :readonly` and
  `hardening: true`) rather than drift.
  """
  use ExUnit.Case, async: false

  alias Compatibility.Builder.Argv
  alias Portal.Builder

  setup do
    previous = Application.get_env(:portal, Portal.Builder, [])
    on_exit(fn -> Application.put_env(:portal, Portal.Builder, previous) end)
    %{previous: previous}
  end

  defp put_builder(overrides, previous),
    do: Application.put_env(:portal, Portal.Builder, Keyword.merge(previous, overrides))

  defp job, do: %{run_id: "jason-1.4.4-1", image_name: "ncc-worker:local", image_digest: "sha256:abc"}

  # `Portal.Builder` derives the /tmp and ~/.cache scratch binds from the
  # scratch dir above `work_dir`, so the spec names them explicitly.
  defp spec do
    %{
      run_id: "jason-1.4.4-1",
      image: "ncc-worker:local",
      user: "0:0",
      work_dir: "/s/work",
      output_dir: "/s/out",
      files_dir: "/s/files",
      tmp_dir: "/s/tmp",
      cache_dir: "/s/cache",
      nerves_cache: Builder.nerves_cache(),
      hex_cache: Builder.hex_cache(),
      build_cache: nil,
      cpus: nil,
      memory: nil,
      build_concurrency: nil,
      nerves_cache_mode: :legacy,
      hardening: true
    }
  end

  test "the two builders produce the same argv for a plain build", %{previous: previous} do
    put_builder([run_as_user: "0:0", cpus: nil, memory: nil, build_concurrency: nil, build_cache: nil], previous)
    assert Builder.build_docker_args(job(), "/s/work", "/s/out", "/s/files") == Argv.build(spec())
  end

  test "and for a capped build with concurrency", %{previous: previous} do
    put_builder([run_as_user: "0:0", cpus: "2", memory: "4g", build_concurrency: "2", build_cache: nil], previous)

    assert Builder.build_docker_args(job(), "/s/work", "/s/out", "/s/files") ==
             Argv.build(Map.merge(spec(), %{cpus: "2", memory: "4g", build_concurrency: "2"}))
  end

  test "and with a build cache, which is read-only on both sides", %{previous: previous} do
    root = Path.join(System.tmp_dir!(), "parity-cache-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    put_builder([run_as_user: "0:0", cpus: nil, memory: nil, build_concurrency: nil, build_cache: root], previous)
    slug = Builder.build_cache_slug_dir("sha256:abc")

    assert Builder.build_docker_args(job(), "/s/work", "/s/out", "/s/files") ==
             Argv.build(Map.put(spec(), :build_cache, slug))
  end
end
```

- [ ] **Step 6: Run both, expect PASS**

Run: `source ~/toolchain/env.sh && mix test apps/compatibility/test/compatibility/builder/argv_test.exs apps/portal/test/portal/builder_argv_parity_test.exs`

- [ ] **Step 7: Commit**

```bash
git add apps/compatibility/lib/compatibility/builder apps/compatibility/test/compatibility/builder apps/portal/test/portal/builder_argv_parity_test.exs
git commit -m "Share the worker docker argv through Compatibility.Builder.Argv

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: The portal CA (`Portal.Builders.CA`) and its mix tasks

**Files:**
- Create: `apps/portal/lib/portal/builders/ca.ex`, `apps/portal/lib/mix/tasks/portal.builder_ca.init.ex`, `apps/portal/lib/mix/tasks/portal.builder_ca.server_cert.ex`
- Modify: `apps/portal/mix.exs` (add `{:x509, "~> 0.9"}`; it is already in `mix.lock` through `wax_`, so the lock does not change), `apps/portal/config/config.exs`, `apps/portal/config/test.exs`, `config/runtime.exs`
- Test: `apps/portal/test/portal/builders/ca_test.exs`

**Interfaces:**
- Produces: `Portal.Builders.CA.key_path/0 :: Path.t() | nil` (config `:portal, Portal.Builders.CA, key_path:`; `NCC_BUILDER_CA_KEY`), `dir/0`, `cert_path/0` (`<dir>/ca.pem`), `server_cert_path/0` (`<dir>/server.pem`), `server_key_path/0` (`<dir>/server-key.pem`), `init(key_path) :: {:ok, %{key_path:, cert_path:}} | {:error, :exists | term()}`, `load/0 :: {:ok, %{key: term(), cert: term()}} | {:error, :not_configured | :missing | :unreadable}`, `cert_pem/0 :: {:ok, String.t()} | {:error, term()}`, `fingerprint(cert) :: String.t()` (lowercase hex sha256 of the DER), `prefix/1` (first 16 chars of `fingerprint/1`), `issue_client(csr_pem, name, builder_id) :: {:ok, %{pem: String.t(), fingerprint: String.t(), expires_at: DateTime.t()}} | {:error, :invalid_csr}`, `ensure_server_cert(host) :: {:ok, %{certfile: Path.t(), keyfile: Path.t()}} | {:error, term()}`, `expires_at(cert) :: DateTime.t()`, `not_after_from_pem(pem)`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Portal.Builders.CATest do
  use ExUnit.Case, async: false

  alias Portal.Builders.CA

  setup do
    dir = Path.join(System.tmp_dir!(), "ncc-ca-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    key_path = Path.join(dir, "ca-key.pem")
    previous = Application.get_env(:portal, CA, [])
    Application.put_env(:portal, CA, Keyword.put(previous, :key_path, key_path))

    on_exit(fn ->
      Application.put_env(:portal, CA, previous)
      File.rm_rf(dir)
    end)

    %{dir: dir, key_path: key_path}
  end

  defp csr_pem do
    key = X509.PrivateKey.new_ec(:secp256r1)
    X509.CSR.new(key, "/CN=ignored") |> X509.CSR.to_pem()
  end

  test "init writes a P-256 CA with key mode 600 and refuses to overwrite", %{key_path: key_path} do
    assert {:ok, %{key_path: ^key_path, cert_path: cert_path}} = CA.init(key_path)
    assert File.stat!(key_path).mode |> Bitwise.band(0o777) == 0o600
    assert {:ok, %{key: _, cert: cert}} = CA.load()
    assert String.length(CA.fingerprint(cert)) == 64
    assert CA.prefix(cert) == String.slice(CA.fingerprint(cert), 0, 16)
    assert {:ok, "-----BEGIN CERTIFICATE-----" <> _} = CA.cert_pem()
    assert File.exists?(cert_path)
    assert {:error, :exists} = CA.init(key_path)
  end

  test "unconfigured and missing CAs are distinguishable", %{key_path: key_path} do
    assert {:error, :missing} = CA.load()
    Application.put_env(:portal, CA, [])
    assert {:error, :not_configured} = CA.load()
    refute File.exists?(key_path)
  end

  test "issues a one-year client certificate naming the builder, ignoring the CSR subject", %{key_path: key_path} do
    {:ok, _} = CA.init(key_path)
    assert {:ok, %{pem: pem, fingerprint: fp, expires_at: expires}} = CA.issue_client(csr_pem(), "box-a", "b1d2")
    cert = X509.Certificate.from_pem!(pem)
    assert X509.Certificate.subject(cert, "CN") == ["box-a"]
    assert X509.Certificate.subject(cert, "serialNumber") == ["b1d2"]
    assert fp == CA.fingerprint(cert)
    assert DateTime.diff(expires, DateTime.utc_now(), :day) in 364..366
    assert CA.expires_at(cert) == expires

    {:ok, %{cert: ca}} = CA.load()
    assert :public_key.pkix_is_issuer(X509.Certificate.to_der(cert), X509.Certificate.to_der(ca))
    assert {:ok, _} = :public_key.pkix_path_validation(X509.Certificate.to_der(ca), [X509.Certificate.to_der(cert)], [])
  end

  test "a CSR with a broken signature is refused", %{key_path: key_path} do
    {:ok, _} = CA.init(key_path)
    assert {:error, :invalid_csr} = CA.issue_client("-----BEGIN CERTIFICATE REQUEST-----\nAAAA\n-----END CERTIFICATE REQUEST-----\n", "x", "y")
  end

  test "ensure_server_cert issues a SAN certificate once and reuses it", %{key_path: key_path, dir: dir} do
    {:ok, _} = CA.init(key_path)
    assert {:ok, %{certfile: certfile, keyfile: keyfile}} = CA.ensure_server_cert("portal.example")
    assert certfile == Path.join(dir, "server.pem")
    assert File.stat!(keyfile).mode |> Bitwise.band(0o777) == 0o600
    cert = certfile |> File.read!() |> X509.Certificate.from_pem!()
    assert X509.Certificate.subject(cert, "CN") == ["portal.example"]
    {:Extension, _, _, [dNSName: ~c"portal.example"]} = X509.Certificate.extension(cert, :subject_alt_name)
    first = File.read!(certfile)
    assert {:ok, _} = CA.ensure_server_cert("portal.example")
    assert File.read!(certfile) == first
  end
end
```

- [ ] **Step 2: Run, expect failure**

- [ ] **Step 3: Write the module**

```elixir
defmodule Portal.Builders.CA do
  @moduledoc """
  The portal's own certificate authority for remote builders: an ECDSA P-256
  root at `NCC_BUILDER_CA_KEY` (owner `ncc`, mode 600), its certificate next
  to it as `ca.pem`, and the mTLS listener's server certificate it signs
  (`server.pem`/`server-key.pem`, renewed when missing or within 30 days of
  expiry). Client certificates are issued for one year from a CSR whose
  subject is ignored: `CN=<builder name>`, `serialNumber=<builder id>`.

  Losing the key means a new CA and re-enrolling every builder: the
  enrolment token carries the CA certificate's sha256 prefix, so a rotated
  CA is a new token, never a new agent image.
  """

  @client_days 365
  @server_days 365
  @server_renew_within_days 30

  @spec key_path() :: Path.t() | nil
  def key_path, do: :portal |> Application.get_env(__MODULE__, []) |> Keyword.get(:key_path)

  @spec dir() :: Path.t() | nil
  def dir, do: if(path = key_path(), do: Path.dirname(path))

  def cert_path, do: if(d = dir(), do: Path.join(d, "ca.pem"))
  def server_cert_path, do: if(d = dir(), do: Path.join(d, "server.pem"))
  def server_key_path, do: if(d = dir(), do: Path.join(d, "server-key.pem"))

  @doc "Create the CA at `key_path` (key mode 600, `ca.pem` beside it). Refuses an existing key."
  @spec init(Path.t()) :: {:ok, %{key_path: Path.t(), cert_path: Path.t()}} | {:error, term()}
  # The path is operator input to a mix task or `bin/portal eval`, never a request.
  # sobelow_skip ["Traversal.FileModule"]
  def init(key_path) do
    cert_path = Path.join(Path.dirname(key_path), "ca.pem")

    if File.exists?(key_path) do
      {:error, :exists}
    else
      key = X509.PrivateKey.new_ec(:secp256r1)
      cert = X509.Certificate.self_signed(key, "/CN=ncc builder CA", template: :root_ca)
      File.mkdir_p!(Path.dirname(key_path))
      write_private(key_path, X509.PrivateKey.to_pem(key))
      File.write!(cert_path, X509.Certificate.to_pem(cert))
      {:ok, %{key_path: key_path, cert_path: cert_path}}
    end
  end

  @spec load() :: {:ok, %{key: term(), cert: term()}} | {:error, :not_configured | :missing | :unreadable}
  # Operator-configured paths.
  # sobelow_skip ["Traversal.FileModule"]
  def load do
    case key_path() do
      nil ->
        {:error, :not_configured}

      key_path ->
        with {:ok, key_pem} <- File.read(key_path),
             {:ok, cert_pem} <- File.read(cert_path()),
             {:ok, key} <- X509.PrivateKey.from_pem(key_pem),
             {:ok, cert} <- X509.Certificate.from_pem(cert_pem) do
          {:ok, %{key: key, cert: cert}}
        else
          {:error, :enoent} -> {:error, :missing}
          _ -> {:error, :unreadable}
        end
    end
  end

  @spec cert_pem() :: {:ok, String.t()} | {:error, term()}
  def cert_pem do
    with {:ok, %{cert: cert}} <- load(), do: {:ok, X509.Certificate.to_pem(cert)}
  end

  @spec fingerprint(term()) :: String.t()
  def fingerprint(cert), do: cert |> X509.Certificate.to_der() |> fingerprint_der()

  @spec fingerprint_der(binary()) :: String.t()
  def fingerprint_der(der), do: :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)

  @spec prefix(term()) :: String.t()
  def prefix(cert), do: cert |> fingerprint() |> String.slice(0, 16)

  @spec issue_client(String.t(), String.t(), String.t()) ::
          {:ok, %{pem: String.t(), fingerprint: String.t(), expires_at: DateTime.t()}} | {:error, :invalid_csr}
  def issue_client(csr_pem, name, builder_id) do
    with {:ok, %{key: ca_key, cert: ca_cert}} <- load(),
         {:ok, csr} <- X509.CSR.from_pem(csr_pem),
         true <- X509.CSR.valid?(csr) do
      cert =
        X509.Certificate.new(
          X509.CSR.public_key(csr),
          "/CN=#{name}/serialNumber=#{builder_id}",
          ca_cert,
          ca_key,
          template: :server,
          validity: @client_days,
          extensions: [
            ext_key_usage: X509.Certificate.Extension.ext_key_usage([:clientAuth]),
            subject_alt_name: false
          ]
        )

      {:ok, %{pem: X509.Certificate.to_pem(cert), fingerprint: fingerprint(cert), expires_at: expires_at(cert)}}
    else
      _ -> {:error, :invalid_csr}
    end
  end

  @spec expires_at(term()) :: DateTime.t()
  def expires_at(cert) do
    {:Validity, _not_before, not_after} = X509.Certificate.validity(cert)
    X509.DateTime.to_datetime(not_after)
  end

  @spec not_after_from_pem(String.t()) :: {:ok, DateTime.t()} | :error
  def not_after_from_pem(pem) do
    case X509.Certificate.from_pem(pem) do
      {:ok, cert} -> {:ok, expires_at(cert)}
      _ -> :error
    end
  end

  @doc "The listener's certificate for `host`, issued when missing or expiring within 30 days."
  @spec ensure_server_cert(String.t()) :: {:ok, %{certfile: Path.t(), keyfile: Path.t()}} | {:error, term()}
  # Operator-configured paths.
  # sobelow_skip ["Traversal.FileModule"]
  def ensure_server_cert(host) do
    with {:ok, %{key: ca_key, cert: ca_cert}} <- load() do
      certfile = server_cert_path()
      keyfile = server_key_path()

      if server_cert_current?(certfile, host) do
        {:ok, %{certfile: certfile, keyfile: keyfile}}
      else
        key = X509.PrivateKey.new_ec(:secp256r1)

        cert =
          X509.Certificate.new(X509.PublicKey.derive(key), "/CN=#{host}", ca_cert, ca_key,
            template: :server,
            validity: @server_days,
            extensions: [subject_alt_name: X509.Certificate.Extension.subject_alt_name([host])]
          )

        write_private(keyfile, X509.PrivateKey.to_pem(key))
        File.write!(certfile, X509.Certificate.to_pem(cert))
        {:ok, %{certfile: certfile, keyfile: keyfile}}
      end
    end
  end

  defp server_cert_current?(certfile, host) do
    with {:ok, pem} <- File.read(certfile),
         {:ok, cert} <- X509.Certificate.from_pem(pem),
         [^host] <- X509.Certificate.subject(cert, "CN") do
      DateTime.diff(expires_at(cert), DateTime.utc_now(), :day) > @server_renew_within_days
    else
      _ -> false
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_private(path, pem) do
    File.write!(path, pem)
    File.chmod!(path, 0o600)
  end
end
```

Check `deps/x509/lib/x509/certificate.ex` for the exact option names of `new/5` (`:template`, `:validity` accepting a day count, `:extensions`) and `deps/x509/lib/x509/certificate/extension.ex` for `subject_alt_name/1` and `ext_key_usage/1` before relying on the code above; if `validity:` wants a `Validity` struct, use `X509.Certificate.Validity.days_from_now(@client_days)`. `X509.Certificate.subject/2` with `"serialNumber"` works because `X509.RDNSequence` names that attribute.

Mix tasks (`Mix.Task.run("app.config")` is enough; no database):

```elixir
defmodule Mix.Tasks.Portal.BuilderCa.Init do
  @shortdoc "Create the remote-builder CA key and certificate"
  @moduledoc """
      mix portal.builder_ca.init --key /etc/ncc-portal/builder-ca/ca-key.pem

  Writes the key (mode 600) and `ca.pem` beside it; refuses to overwrite.
  On a release: `bin/portal eval 'Portal.Builders.CA.init("/etc/ncc-portal/builder-ca/ca-key.pem")'`.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [key: :string])
    key = opts[:key] || Mix.raise("--key PATH is required")

    case Portal.Builders.CA.init(key) do
      {:ok, %{cert_path: cert}} -> Mix.shell().info("wrote #{key} and #{cert}")
      {:error, :exists} -> Mix.raise("#{key} exists; refusing to overwrite")
      {:error, reason} -> Mix.raise("could not create the CA: #{inspect(reason)}")
    end
  end
end
```

```elixir
defmodule Mix.Tasks.Portal.BuilderCa.ServerCert do
  @shortdoc "Issue or renew the mTLS listener's server certificate"
  @moduledoc """
      mix portal.builder_ca.server_cert --host compatibility.nerves-project.org

  Uses `NCC_BUILDER_CA_KEY` (or `--key`). Issues when missing or within 30
  days of expiry. On a release: `bin/portal eval 'Portal.Builders.CA.ensure_server_cert("HOST")'`.
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {opts, _, _} = OptionParser.parse(args, strict: [host: :string, key: :string])
    host = opts[:host] || Mix.raise("--host HOST is required")
    if key = opts[:key], do: Application.put_env(:portal, Portal.Builders.CA, key_path: key)

    case Portal.Builders.CA.ensure_server_cert(host) do
      {:ok, %{certfile: certfile}} -> Mix.shell().info("server certificate at #{certfile}")
      {:error, reason} -> Mix.raise("could not issue the server certificate: #{inspect(reason)}")
    end
  end
end
```

Config: `config :portal, Portal.Builders.CA, key_path: nil` in `apps/portal/config/config.exs`; in `config/runtime.exs` (portal block): `if key = System.get_env("NCC_BUILDER_CA_KEY"), do: config(:portal, Portal.Builders.CA, key_path: key)`. Add `{:x509, "~> 0.9"}` to `apps/portal/mix.exs` deps and confirm `git diff --exit-code mix.lock` after `mix deps.get`.

- [ ] **Step 4: Run the test, expect PASS**

- [ ] **Step 5: Commit**

```bash
git add apps/portal/lib/portal/builders/ca.ex apps/portal/lib/mix/tasks/portal.builder_ca.init.ex apps/portal/lib/mix/tasks/portal.builder_ca.server_cert.ex apps/portal/test/portal/builders/ca_test.exs apps/portal/mix.exs apps/portal/config config/runtime.exs
git commit -m "Add the remote-builder CA: P-256 root, client and server certificates

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: `Portal.Builders` resources, `Run.builder_id`, settings fields, migration

**Files:**
- Create: `apps/portal/lib/portal/builders.ex` (Ash domain; context functions come in later tasks), `apps/portal/lib/portal/builders/builder.ex`, `apps/portal/lib/portal/builders/builder_certificate.ex`, `apps/portal/lib/portal/builders/enrolment_token.ex`, `apps/portal/lib/portal/builders/lease.ex`
- Modify: `apps/portal/lib/portal/catalog/run.ex` (`belongs_to :builder`, accept `:builder_id`), `apps/portal/lib/portal/settings/setting.ex` and `apps/portal/lib/portal/settings.ex` (`remote_mode`, `remote_backlog_threshold`, `remote_auto_on`), `apps/portal/config/config.exs` (`ash_domains` gains `Portal.Builders`)
- Generate: migration `remote_builders` + snapshots
- Test: `apps/portal/test/portal/builders/resources_test.exs`

**Interfaces:**
- `Portal.Builders.Builder` (table `builders`): `name :string` (unique identity `unique_name`), `fingerprint :string` (unique identity `unique_fingerprint`), `cert_pem :string`, `cert_expires_at :utc_datetime_usec`, `status :atom` in `[:enrolled, :revoked]` default `:enrolled`, `publishing :boolean` default `false`, `slots :integer` default 1 (`min: 1, max: 16`), `enrolled_at`, `last_seen_at`, `last_version :string`, `egress_status :string`, `revoked_at`, `note :string`, timestamps. Actions: `:read`, `create :enrol` (accept name, fingerprint, cert_pem, cert_expires_at, slots, last_version, enrolled_at), `update :touch` (last_seen_at, last_version), `update :set_publishing` (publishing), `update :set_slots` (slots), `update :set_egress` (egress_status), `update :rotate_cert` (fingerprint, cert_pem, cert_expires_at), `update :revoke` (sets status `:revoked`, `revoked_at` now), `update :set_note` (note). `has_many :certificates`, `has_many :leases`.
- `Portal.Builders.BuilderCertificate` (table `builder_certificates`): `builder_id` (belongs_to), `fingerprint :string` (unique identity), `issued_at`, `expires_at`, `superseded_at`. Actions `:read`, `create :create`, `update :supersede` (sets `superseded_at` now).
- `Portal.Builders.EnrolmentToken` (table `builder_enrolment_tokens`): `token_hash :string` (unique identity), `name :string`, `created_by :string`, `expires_at`, `used_at`, `builder_id` (belongs_to Builder, nullable). Actions `:read`, `create :create`, `update :use` (used_at now, builder_id).
- `Portal.Builders.Lease` (table `builder_leases`): `package :string`, `version :string`, `image_name :string`, `image_digest :string`, `args :map` (the `Build` job args, string keys), `scan_request_id :uuid`, `priority :integer` default 5, `state :atom` in `[:queued, :leased, :uploading, :done, :failed]` default `:queued`, `builder_id` (belongs_to, nullable), `leased_at`, `heartbeat_at`, `phase :string`, `log_tail :string`, `attempt :integer` default 0, `max_attempts :integer` default 3, `run_id :string`, `bytes_uploaded :integer` default 0, `error :string`, timestamps; custom index `[:state, :priority, :inserted_at]` named `builder_leases_queue_index`, index `[:builder_id]`. Actions `:read`, `create :create` (accept everything but timestamps), `update :update` (accept state, builder_id, leased_at, heartbeat_at, phase, log_tail, attempt, run_id, bytes_uploaded, error).
- `Portal.Catalog.Run`: `belongs_to :builder, Portal.Builders.Builder` (`allow_nil? true`, `attribute_type :uuid`), `:create` accepts `:builder_id`. Ash allows cross-domain `belongs_to`.
- `Portal.Settings.Setting`: `remote_mode :atom` in `[:auto, :on, :off]` default `:auto`; `remote_backlog_threshold :integer` default 10 (`min: 0`); `remote_auto_on :boolean` default false. Added to `:upsert`'s `accept` and to `Portal.Settings`' `@defaults`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Portal.Builders.ResourcesTest do
  use Portal.DataCase, async: false

  alias Portal.Builders.{Builder, BuilderCertificate, EnrolmentToken, Lease}
  alias Portal.Catalog.Run

  defp builder!(attrs \\ %{}) do
    Builder
    |> Ash.Changeset.for_create(
      :enrol,
      Map.merge(
        %{name: "box-#{System.unique_integer([:positive])}", fingerprint: "fp#{System.unique_integer([:positive])}",
          cert_pem: "pem", cert_expires_at: DateTime.add(DateTime.utc_now(), 365, :day), slots: 2,
          last_version: "1.a", enrolled_at: DateTime.utc_now()},
        attrs
      )
    )
    |> Ash.create!(domain: Portal.Builders)
  end

  test "a builder enrols unpublished and can be revoked" do
    builder = builder!()
    assert builder.publishing == false
    assert builder.status == :enrolled
    revoked = builder |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update!(domain: Portal.Builders)
    assert revoked.status == :revoked
    assert %DateTime{} = revoked.revoked_at
  end

  test "names and fingerprints are unique" do
    builder = builder!(%{name: "dup", fingerprint: "f1"})
    assert {:error, _} = Builder |> Ash.Changeset.for_create(:enrol, %{name: "dup", fingerprint: "f2", cert_pem: "p", cert_expires_at: DateTime.utc_now(), enrolled_at: DateTime.utc_now()}) |> Ash.create(domain: Portal.Builders)
    assert {:error, _} = Builder |> Ash.Changeset.for_create(:enrol, %{name: "other", fingerprint: builder.fingerprint, cert_pem: "p", cert_expires_at: DateTime.utc_now(), enrolled_at: DateTime.utc_now()}) |> Ash.create(domain: Portal.Builders)
  end

  test "certificates, tokens and leases hang off a builder" do
    builder = builder!()

    cert = BuilderCertificate |> Ash.Changeset.for_create(:create, %{builder_id: builder.id, fingerprint: "old", issued_at: DateTime.utc_now(), expires_at: DateTime.utc_now()}) |> Ash.create!(domain: Portal.Builders)
    assert %DateTime{} = (cert |> Ash.Changeset.for_update(:supersede, %{}) |> Ash.update!(domain: Portal.Builders)).superseded_at

    token = EnrolmentToken |> Ash.Changeset.for_create(:create, %{token_hash: "h", name: "n", created_by: "admin", expires_at: DateTime.utc_now()}) |> Ash.create!(domain: Portal.Builders)
    used = token |> Ash.Changeset.for_update(:use, %{builder_id: builder.id}) |> Ash.update!(domain: Portal.Builders)
    assert used.builder_id == builder.id and %DateTime{} = used.used_at

    lease = Lease |> Ash.Changeset.for_create(:create, %{package: "jason", version: "1.4.4", image_name: "ghcr.io/x/ncc-worker", image_digest: "sha256:abc", args: %{"package" => "jason"}, priority: 3}) |> Ash.create!(domain: Portal.Builders)
    assert lease.state == :queued and lease.attempt == 0 and lease.max_attempts == 3 and lease.bytes_uploaded == 0
  end

  test "a run may name its builder" do
    builder = builder!()
    {:ok, package} = Portal.Catalog.Package |> Ash.Changeset.for_create(:upsert, %{name: "jason", description: "d"}) |> Ash.create(domain: Portal.Catalog)
    run = Run |> Ash.Changeset.for_create(:create, %{run_id: "r1", package_id: package.id, version_tested: "1.4.4", image_digest: "sha256:x", builder_id: builder.id}) |> Ash.create!(domain: Portal.Catalog)
    assert run.builder_id == builder.id
  end

  test "settings carry the remote routing policy" do
    settings = Portal.Settings.get()
    assert settings.remote_mode == :auto and settings.remote_backlog_threshold == 10 and settings.remote_auto_on == false
    {:ok, saved} = Portal.Settings.save(%{remote_mode: :on, remote_backlog_threshold: 3})
    assert saved.remote_mode == :on and saved.remote_backlog_threshold == 3
    assert Portal.Settings.get().argus_enabled == true
  end
end
```

Check `Portal.Catalog.Package`'s create action name in `apps/portal/lib/portal/catalog/package.ex` (`:upsert` is what `ToolchainBuildTest` uses) and adjust the test if it differs.

- [ ] **Step 2: Run, expect failure (modules undefined)**

- [ ] **Step 3: Write the resources**

Follow `apps/portal/lib/portal/catalog/toolchain_build.ex` style. Domain:

```elixir
defmodule Portal.Builders do
  @moduledoc """
  Ash domain for remote builders: the machines (`Builder`), their
  certificate history (`BuilderCertificate`), one-time enrolment tokens and
  the remote job queue (`Lease`). Context functions live here too; the
  resources carry only attributes and actions.
  """
  use Ash.Domain

  resources do
    resource(Portal.Builders.Builder)
    resource(Portal.Builders.BuilderCertificate)
    resource(Portal.Builders.EnrolmentToken)
    resource(Portal.Builders.Lease)
  end
end
```

`Builder` (the shape; every attribute `public?(true)`):

```elixir
defmodule Portal.Builders.Builder do
  @moduledoc "A remote build machine, identified by its current client certificate's fingerprint."
  use Ash.Resource, domain: Portal.Builders, data_layer: AshPostgres.DataLayer

  postgres do
    table("builders")
    repo(Portal.Repo)
  end

  actions do
    defaults([:read])

    create :enrol do
      accept([:name, :fingerprint, :cert_pem, :cert_expires_at, :slots, :last_version, :enrolled_at])
    end

    update :touch do
      accept([:last_seen_at, :last_version])
    end

    update :set_publishing do
      accept([:publishing])
    end

    update :set_slots do
      accept([:slots])
    end

    update :set_egress do
      accept([:egress_status])
    end

    update :set_note do
      accept([:note])
    end

    update :rotate_cert do
      accept([:fingerprint, :cert_pem, :cert_expires_at])
    end

    update :revoke do
      change(set_attribute(:status, :revoked))
      change(set_attribute(:revoked_at, &DateTime.utc_now/0))
    end
  end

  identities do
    identity(:unique_name, [:name])
    identity(:unique_fingerprint, [:fingerprint])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:fingerprint, :string, allow_nil?: false, public?: true)
    attribute(:cert_pem, :string, allow_nil?: false, public?: true)
    attribute(:cert_expires_at, :utc_datetime_usec, allow_nil?: false, public?: true)

    attribute :status, :atom do
      allow_nil?(false)
      default(:enrolled)
      public?(true)
      constraints(one_of: [:enrolled, :revoked])
    end

    # Default false on purpose: a new machine's runs count for the tracker
    # but its files are not published until an admin has looked at them.
    attribute(:publishing, :boolean, allow_nil?: false, default: false, public?: true)

    attribute :slots, :integer do
      allow_nil?(false)
      default(1)
      public?(true)
      constraints(min: 1, max: 16)
    end

    attribute(:enrolled_at, :utc_datetime_usec, public?: true)
    attribute(:last_seen_at, :utc_datetime_usec, public?: true)
    attribute(:last_version, :string, public?: true)
    attribute(:egress_status, :string, public?: true)
    attribute(:revoked_at, :utc_datetime_usec, public?: true)
    attribute(:note, :string, public?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    has_many(:certificates, Portal.Builders.BuilderCertificate, public?: true)
    has_many(:leases, Portal.Builders.Lease, public?: true)
  end
end
```

`BuilderCertificate`, `EnrolmentToken` and `Lease` follow the same pattern with the attributes listed in Interfaces (`Lease` with `custom_indexes do index([:state, :priority, :inserted_at], name: "builder_leases_queue_index"); index([:builder_id]) end`; `belongs_to :builder, Portal.Builders.Builder, allow_nil?: true, attribute_type: :uuid, define_attribute?: true`).

`Run`: add `belongs_to :builder, Portal.Builders.Builder do allow_nil?(true); public?(true); attribute_type(:uuid); define_attribute?(true) end` and `:builder_id` to the `:create` accept list.

`Setting`: three attributes, added to the `:upsert` accept list; `Portal.Settings` `@defaults` gains `remote_mode: :auto, remote_backlog_threshold: 10, remote_auto_on: false`.

Add `Portal.Builders` to `ash_domains` in `apps/portal/config/config.exs`.

- [ ] **Step 4: Generate and run the migration**

Run: `source ~/toolchain/env.sh && MIX_ENV=test mix ash_postgres.generate_migrations --name remote_builders && MIX_ENV=test mix ecto.migrate`
Expected: one migration under `apps/portal/priv/repo/migrations/` creating `builders`, `builder_certificates`, `builder_enrolment_tokens`, `builder_leases`, altering `catalog_runs` (`builder_id`) and `settings`; snapshots under `apps/portal/priv/resource_snapshots/repo/`. Read the migration: every index name under 63 chars; the foreign key from `catalog_runs.builder_id` to `builders` present.

- [ ] **Step 5: Run the test and the existing settings/run tests, expect PASS**

Run: `source ~/toolchain/env.sh && mix test apps/portal/test/portal/builders/resources_test.exs apps/portal/test/portal/settings_test.exs apps/portal/test/portal/catalog/run_test.exs apps/portal/test/portal/catalog/ingestion_test.exs`

- [ ] **Step 6: Commit**

```bash
git add apps/portal/lib/portal/builders.ex apps/portal/lib/portal/builders apps/portal/lib/portal/catalog/run.ex apps/portal/lib/portal/settings apps/portal/lib/portal/settings.ex apps/portal/config/config.exs apps/portal/priv apps/portal/test/portal/builders/resources_test.exs
git commit -m "Add builders, certificates, enrolment tokens and leases

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Tokens, enrolment, renewal, fingerprint lookup and revocation (`Portal.Builders` context)

**Files:**
- Modify: `apps/portal/lib/portal/builders.ex`
- Modify: `apps/portal/lib/portal/bulk_rebuild.ex` (`:pin_local` option carried into the Backfill job args as `"pin_local"`), `apps/portal/lib/portal/workers/backfill.ex` (`build.pin_local`), `apps/portal/lib/portal/scan_requests.ex` (`insert_build_job/4` puts `pin_local: true` in `meta` when `build[:pin_local]`)
- Test: `apps/portal/test/portal/builders/enrolment_test.exs`, `apps/portal/test/portal/builders/revoke_test.exs`

**Interfaces:**
- Produces (all in `Portal.Builders`):
  - `create_token(name, created_by) :: {:ok, %{token: String.t(), record: EnrolmentToken.t()}} | {:error, :no_ca | term()}` — token `"<record id>.<base64url(32 random bytes), no padding>.<CA prefix>"`, 24 h expiry, stores `sha256(secret)` hex as `token_hash`.
  - `enrol(token, csr_pem, attrs) :: {:ok, %{builder: Builder.t(), cert_pem: String.t(), expires_at: DateTime.t()}} | {:error, :invalid_token | :token_used | :token_expired | :invalid_csr | :name_taken}` where `attrs` is `%{agent_version: String.t() | nil, slots: pos_integer() | nil}`. One transaction: issue, create builder, create certificate row, mark token used.
  - `renew(builder, csr_pem) :: {:ok, %{cert_pem, expires_at}} | {:error, :too_early | :revoked | :invalid_csr}` — only within 30 days of `cert_expires_at`; supersedes the old certificate row (kept 24 h), creates the new one, rotates the builder's fingerprint.
  - `by_fingerprint(fp) :: {:ok, Builder.t()} | {:error, :unknown | :revoked}` — current fingerprint, or a certificate row with `superseded_at` nil or within the last 24 h.
  - `touch(builder, version) :: Builder.t()` — writes `last_seen_at` only when older than 60 s (or nil); always records a changed `last_version`.
  - `list_builders/0`, `get_builder(id) :: {:ok, _} | {:error, :not_found}`, `set_publishing(builder, bool)`, `set_egress(builder, status)`, `set_slots(builder, n)`.
  - `revoke(builder) :: {:ok, %{builder: Builder.t(), runs_revoked: non_neg_integer(), packages: [String.t()], sweep_id: String.t() | nil}}` — status revoked; every `Run` with this `builder_id` and `revoked_at` nil gets the `:revoke` action; its open leases (`:leased`/`:uploading`) go back to `:queued` with `builder_id: nil`; the affected package names go to `Portal.BulkRebuild.run(names: names, limit: length(names), what: :full, pin_local: true, created_by: "revoke builder <name>")`.
  - `revoke_preview(builder) :: %{runs: n, packages: [names]}` for the admin confirm text.
- `Portal.BulkRebuild.run/1` accepts `pin_local: true`; the Backfill job args carry `"pin_local" => true`; `Portal.Workers.Backfill` passes `pin_local: args["pin_local"] == true` in the `build` map; `Portal.ScanRequests.insert_build_job/4` adds `pin_local: true` to the job `meta` when `build[:pin_local]`. (Task 10 reads `meta.pin_local` in Routing.)

- [ ] **Step 1: Write the failing enrolment test**

```elixir
defmodule Portal.Builders.EnrolmentTest do
  use Portal.DataCase, async: false

  alias Portal.Builders
  alias Portal.Builders.{Builder, BuilderCertificate, CA}

  setup do
    dir = Path.join(System.tmp_dir!(), "ncc-ca-#{System.unique_integer([:positive])}")
    key_path = Path.join(dir, "ca-key.pem")
    previous = Application.get_env(:portal, CA, [])
    Application.put_env(:portal, CA, Keyword.put(previous, :key_path, key_path))
    {:ok, _} = CA.init(key_path)
    on_exit(fn -> Application.put_env(:portal, CA, previous); File.rm_rf(dir) end)
    :ok
  end

  defp csr, do: X509.CSR.new(X509.PrivateKey.new_ec(:secp256r1), "/CN=x") |> X509.CSR.to_pem()

  test "a token is shown once, enrols once, and names the CA" do
    {:ok, %{token: token}} = Builders.create_token("box-a", "admin")
    [id, secret, prefix] = String.split(token, ".")
    assert String.length(prefix) == 16
    assert byte_size(Base.url_decode64!(secret, padding: false)) == 32
    {:ok, %{cert: ca}} = CA.load()
    assert prefix == CA.prefix(ca)

    assert {:ok, %{builder: builder, cert_pem: pem, expires_at: expires}} =
             Builders.enrol(token, csr(), %{agent_version: "1.a", slots: 2})

    assert builder.name == "box-a" and builder.publishing == false and builder.slots == 2
    assert builder.fingerprint == CA.fingerprint(X509.Certificate.from_pem!(pem))
    assert DateTime.diff(expires, DateTime.utc_now(), :day) in 364..366
    assert [%BuilderCertificate{superseded_at: nil}] = Ash.load!(builder, :certificates, domain: Builders).certificates
    assert {:ok, ^id} = {:ok, id}

    assert {:error, :token_used} = Builders.enrol(token, csr(), %{})
    assert {:error, :invalid_token} = Builders.enrol("nope.nope.nope", csr(), %{})
    assert {:error, :invalid_token} = Builders.enrol("#{id}.AAAA.#{prefix}", csr(), %{})
  end

  test "an expired token is refused" do
    {:ok, %{token: token, record: record}} = Builders.create_token("box-b", "admin")
    record |> Ash.Changeset.for_update(:expire_now, %{}) |> Ash.update!(domain: Builders)
    assert {:error, :token_expired} = Builders.enrol(token, csr(), %{})
  end

  test "a second token for the same name cannot enrol while the first builder exists" do
    {:ok, %{token: t1}} = Builders.create_token("box-c", "admin")
    {:ok, _} = Builders.enrol(t1, csr(), %{})
    {:ok, %{token: t2}} = Builders.create_token("box-c", "admin")
    assert {:error, :name_taken} = Builders.enrol(t2, csr(), %{})
  end

  test "lookup by fingerprint honours current, superseded-within-24h and revoked" do
    {:ok, %{token: token}} = Builders.create_token("box-d", "admin")
    {:ok, %{builder: builder}} = Builders.enrol(token, csr(), %{})
    assert {:ok, %Builder{id: id}} = Builders.by_fingerprint(builder.fingerprint)
    assert id == builder.id
    assert {:error, :unknown} = Builders.by_fingerprint("nope")

    assert {:error, :too_early} = Builders.renew(builder, csr())

    near = builder |> Ash.Changeset.for_update(:rotate_cert, %{cert_expires_at: DateTime.add(DateTime.utc_now(), 10, :day), fingerprint: builder.fingerprint, cert_pem: builder.cert_pem}) |> Ash.update!(domain: Builders)
    assert {:ok, %{cert_pem: new_pem}} = Builders.renew(near, csr())
    new_fp = CA.fingerprint(X509.Certificate.from_pem!(new_pem))
    assert {:ok, %Builder{fingerprint: ^new_fp}} = Builders.by_fingerprint(new_fp)
    assert {:ok, %Builder{}} = Builders.by_fingerprint(builder.fingerprint)

    old = BuilderCertificate |> Ash.Query.filter(fingerprint == ^builder.fingerprint) |> Ash.read_one!(domain: Builders)
    old |> Ash.Changeset.for_update(:update_superseded_at, %{superseded_at: DateTime.add(DateTime.utc_now(), -25, :hour)}) |> Ash.update!(domain: Builders)
    assert {:error, :unknown} = Builders.by_fingerprint(builder.fingerprint)

    {:ok, _} = Builders.revoke(near)
    assert {:error, :revoked} = Builders.by_fingerprint(new_fp)
    assert {:error, :revoked} = Builders.renew(Ash.get!(Builder, builder.id, domain: Builders), csr())
  end

  test "touch writes last_seen_at at most once a minute" do
    {:ok, %{token: token}} = Builders.create_token("box-e", "admin")
    {:ok, %{builder: builder}} = Builders.enrol(token, csr(), %{})
    first = Builders.touch(builder, "1.a")
    assert %DateTime{} = first.last_seen_at
    second = Builders.touch(first, "1.a")
    assert second.last_seen_at == first.last_seen_at
    stale = first |> Ash.Changeset.for_update(:touch, %{last_seen_at: DateTime.add(DateTime.utc_now(), -120, :second)}) |> Ash.update!(domain: Builders)
    assert DateTime.compare(Builders.touch(stale, "1.b").last_seen_at, stale.last_seen_at) == :gt
    assert Builders.touch(stale, "1.b").last_version == "1.b"
  end
end
```

The test needs two test-only conveniences on the resources: `EnrolmentToken` `update :expire_now` (sets `expires_at` to now minus one hour) and `BuilderCertificate` `update :update_superseded_at` (accept `superseded_at`). Add both; they are harmless in production.

- [ ] **Step 2: Write the failing revoke test**

```elixir
defmodule Portal.Builders.RevokeTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query

  alias Portal.Builders
  alias Portal.Builders.{CA, Lease}
  alias Portal.Catalog.Run

  setup do
    dir = Path.join(System.tmp_dir!(), "ncc-ca-#{System.unique_integer([:positive])}")
    key_path = Path.join(dir, "ca-key.pem")
    previous = Application.get_env(:portal, CA, [])
    Application.put_env(:portal, CA, Keyword.put(previous, :key_path, key_path))
    {:ok, _} = CA.init(key_path)
    on_exit(fn -> Application.put_env(:portal, CA, previous); File.rm_rf(dir) end)
    {:ok, %{token: token}} = Builders.create_token("box-r", "admin")
    csr = X509.CSR.new(X509.PrivateKey.new_ec(:secp256r1), "/CN=x") |> X509.CSR.to_pem()
    {:ok, %{builder: builder}} = Builders.enrol(token, csr, %{})
    %{builder: builder}
  end

  defp ingest!(name, version, builder_id) do
    {:ok, run} =
      Portal.Catalog.Ingestion.ingest(
        %{"package" => %{"name" => name, "version" => version}, "finished_at" => "2026-10-10T10:00:00Z",
          "systems" => %{"host" => %{"status" => "pass"}}},
        %{run_id: "r-#{name}-#{System.unique_integer([:positive])}", image_digest: "sha256:x", files_dir: System.tmp_dir!(), builder_id: builder_id}
      )

    run
  end

  test "revoking a builder revokes its runs, requeues its leases and pins the rebuilds locally", %{builder: builder} do
    mine = ingest!("jason", "1.4.4", builder.id)
    other = ingest!("decimal", "2.1.1", nil)

    lease = Lease |> Ash.Changeset.for_create(:create, %{package: "plug", version: "1.0.0", image_name: "i", image_digest: "sha256:d", args: %{}, state: :leased, builder_id: builder.id, attempt: 1}) |> Ash.create!(domain: Builders)

    assert %{runs: 1, packages: ["jason"]} = Builders.revoke_preview(builder)
    assert {:ok, %{runs_revoked: 1, packages: ["jason"], sweep_id: sweep_id}} = Builders.revoke(builder)
    assert is_binary(sweep_id)

    assert %Run{revoked_at: %DateTime{}} = Ash.get!(Run, mine.id, domain: Portal.Catalog)
    assert %Run{revoked_at: nil} = Ash.get!(Run, other.id, domain: Portal.Catalog)
    assert %Lease{state: :queued, builder_id: nil, attempt: 1} = Ash.get!(Lease, lease.id, domain: Builders)

    assert [job] = all_enqueued(worker: Portal.Workers.Backfill)
    assert job.args["package"] == "jason" and job.args["pin_local"] == true and job.args["force"] == true
    assert job.meta["sweep_id"] == sweep_id
  end
end
```

Task 4's `Run` needs `builder_id` in `Ingestion.create_run/7`; add `builder_id: Map.get(opts, :builder_id)` there now (Task 9 covers the rest of the loader) and the `ingest_opts` typespec gains `optional(:builder_id) => String.t() | nil`.

- [ ] **Step 3: Run both, expect failure**

- [ ] **Step 4: Implement the context functions**

```elixir
# in Portal.Builders, below the `resources` block
require Ash.Query
import Ecto.Query, only: [from: 2]

alias Portal.Builders.{Builder, BuilderCertificate, CA, EnrolmentToken, Lease}
alias Portal.Catalog.Run
alias Portal.Repo

@token_ttl_hours 24
@renew_within_days 30
@superseded_grace_hours 24
@touch_every_seconds 60

@doc "A one-time enrolment token, shown once: `<id>.<secret>.<CA prefix>`."
def create_token(name, created_by) do
  with {:ok, %{cert: ca}} <- ca() do
    secret = :crypto.strong_rand_bytes(32)

    with {:ok, record} <-
           EnrolmentToken
           |> Ash.Changeset.for_create(:create, %{
             token_hash: hash(secret),
             name: name,
             created_by: created_by,
             expires_at: DateTime.add(DateTime.utc_now(), @token_ttl_hours, :hour)
           })
           |> Ash.create(domain: __MODULE__) do
      token = Enum.join([record.id, Base.url_encode64(secret, padding: false), CA.prefix(ca)], ".")
      {:ok, %{token: token, record: record}}
    end
  end
end

defp ca do
  case CA.load() do
    {:ok, ca} -> {:ok, ca}
    {:error, _} -> {:error, :no_ca}
  end
end

defp hash(secret), do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)

@doc "Exchange a token and CSR for a builder and its one-year certificate."
def enrol(token, csr_pem, attrs) when is_binary(token) do
  with {:ok, record} <- token_record(token),
       :ok <- token_usable(record),
       :ok <- name_free(record.name) do
    Repo.transaction(fn ->
      with {:ok, builder} <- create_builder(record.name, attrs),
           {:ok, issued} <- CA.issue_client(csr_pem, record.name, builder.id),
           {:ok, builder} <- rotate(builder, issued),
           {:ok, _cert} <- record_certificate(builder, issued),
           {:ok, _token} <- record |> Ash.Changeset.for_update(:use, %{builder_id: builder.id}) |> Ash.update(domain: __MODULE__) do
        %{builder: builder, cert_pem: issued.pem, expires_at: issued.expires_at}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end

defp token_record(token) do
  with [id, secret, _prefix] <- String.split(token, "."),
       {:ok, _} <- Ecto.UUID.cast(id),
       {:ok, bytes} <- Base.url_decode64(secret, padding: false),
       %EnrolmentToken{} = record <- Ash.get!(EnrolmentToken, id, domain: __MODULE__, error?: false),
       true <- Plug.Crypto.secure_compare(record.token_hash, hash(bytes)) do
    {:ok, record}
  else
    _ -> {:error, :invalid_token}
  end
end

defp token_usable(%EnrolmentToken{used_at: used}) when not is_nil(used), do: {:error, :token_used}

defp token_usable(%EnrolmentToken{expires_at: expires}) do
  if DateTime.compare(expires, DateTime.utc_now()) == :lt, do: {:error, :token_expired}, else: :ok
end

defp name_free(name) do
  case Builder |> Ash.Query.filter(name == ^name) |> Ash.read_one!(domain: __MODULE__) do
    nil -> :ok
    _ -> {:error, :name_taken}
  end
end

# The fingerprint is not known until the certificate exists, and the
# certificate names the builder id, so the row is created with a placeholder
# fingerprint and rotated in the same transaction.
defp create_builder(name, attrs) do
  Builder
  |> Ash.Changeset.for_create(:enrol, %{
    name: name,
    fingerprint: "pending-" <> Ecto.UUID.generate(),
    cert_pem: "",
    cert_expires_at: DateTime.utc_now(),
    slots: Map.get(attrs, :slots) || 1,
    last_version: Map.get(attrs, :agent_version),
    enrolled_at: DateTime.utc_now()
  })
  |> Ash.create(domain: __MODULE__)
end

defp rotate(builder, issued) do
  builder
  |> Ash.Changeset.for_update(:rotate_cert, %{fingerprint: issued.fingerprint, cert_pem: issued.pem, cert_expires_at: issued.expires_at})
  |> Ash.update(domain: __MODULE__)
end

defp record_certificate(builder, issued) do
  BuilderCertificate
  |> Ash.Changeset.for_create(:create, %{builder_id: builder.id, fingerprint: issued.fingerprint, issued_at: DateTime.utc_now(), expires_at: issued.expires_at})
  |> Ash.create(domain: __MODULE__)
end

@doc "A new one-year certificate for a builder within 30 days of expiry; the old one stays valid 24 h."
def renew(%Builder{status: :revoked}, _csr), do: {:error, :revoked}

def renew(%Builder{} = builder, csr_pem) do
  if DateTime.diff(builder.cert_expires_at, DateTime.utc_now(), :day) > @renew_within_days do
    {:error, :too_early}
  else
    Repo.transaction(fn ->
      with {:ok, issued} <- CA.issue_client(csr_pem, builder.name, builder.id),
           {:ok, _} <- supersede_current(builder),
           {:ok, builder} <- rotate(builder, issued),
           {:ok, _} <- record_certificate(builder, issued) do
        %{cert_pem: issued.pem, expires_at: issued.expires_at}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end

defp supersede_current(builder) do
  BuilderCertificate
  |> Ash.Query.filter(builder_id == ^builder.id and fingerprint == ^builder.fingerprint and is_nil(superseded_at))
  |> Ash.read!(domain: __MODULE__)
  |> Enum.reduce_while({:ok, nil}, fn cert, _acc ->
    case cert |> Ash.Changeset.for_update(:supersede, %{}) |> Ash.update(domain: __MODULE__) do
      {:ok, c} -> {:cont, {:ok, c}}
      error -> {:halt, error}
    end
  end)
end

@doc "The builder a client certificate belongs to, by current or recently superseded fingerprint."
def by_fingerprint(fp) when is_binary(fp) do
  grace = DateTime.add(DateTime.utc_now(), -@superseded_grace_hours, :hour)

  builder =
    case Builder |> Ash.Query.filter(fingerprint == ^fp) |> Ash.read_one!(domain: __MODULE__) do
      nil ->
        BuilderCertificate
        |> Ash.Query.filter(fingerprint == ^fp and (is_nil(superseded_at) or superseded_at > ^grace))
        |> Ash.Query.load(:builder)
        |> Ash.read_one!(domain: __MODULE__)
        |> case do
          nil -> nil
          cert -> cert.builder
        end

      builder ->
        builder
    end

  case builder do
    nil -> {:error, :unknown}
    %Builder{status: :revoked} -> {:error, :revoked}
    %Builder{} = builder -> {:ok, builder}
  end
end

def by_fingerprint(_), do: {:error, :unknown}

@doc "Refresh `last_seen_at` (at most once a minute) and the agent version."
def touch(%Builder{} = builder, version) do
  now = DateTime.utc_now()
  stale? = is_nil(builder.last_seen_at) or DateTime.diff(now, builder.last_seen_at, :second) >= @touch_every_seconds
  version_changed? = is_binary(version) and version != builder.last_version

  if stale? or version_changed? do
    builder
    |> Ash.Changeset.for_update(:touch, %{last_seen_at: if(stale?, do: now, else: builder.last_seen_at), last_version: version || builder.last_version})
    |> Ash.update!(domain: __MODULE__)
  else
    builder
  end
end

def list_builders, do: Builder |> Ash.Query.sort(name: :asc) |> Ash.read!(domain: __MODULE__)

def get_builder(id) do
  case Ecto.UUID.cast(id) do
    {:ok, id} -> (if b = Ash.get!(Builder, id, domain: __MODULE__, error?: false), do: {:ok, b}, else: {:error, :not_found})
    :error -> {:error, :not_found}
  end
end

def set_publishing(builder, flag), do: builder |> Ash.Changeset.for_update(:set_publishing, %{publishing: flag}) |> Ash.update(domain: __MODULE__)
def set_egress(builder, status), do: builder |> Ash.Changeset.for_update(:set_egress, %{egress_status: status}) |> Ash.update(domain: __MODULE__)
def set_slots(builder, slots), do: builder |> Ash.Changeset.for_update(:set_slots, %{slots: slots}) |> Ash.update(domain: __MODULE__)

@doc "What `revoke/1` would do: how many runs, which packages."
def revoke_preview(%Builder{id: id}) do
  runs = Run |> Ash.Query.filter(builder_id == ^id and is_nil(revoked_at)) |> Ash.Query.load(:package) |> Ash.read!(domain: Portal.Catalog)
  %{runs: length(runs), packages: runs |> Enum.map(& &1.package.name) |> Enum.uniq() |> Enum.sort()}
end

@doc """
Revoke a builder: status `:revoked`, its runs revoked (the next precompiled
batch drops their files), its open leases back to `:queued`, and the affected
package versions rebuilt on your own host through `Portal.BulkRebuild` with
`pin_local`, so the catalogue heals without ever routing remote again.
"""
def revoke(%Builder{} = builder) do
  %{packages: packages} = revoke_preview(builder)

  with {:ok, builder} <- builder |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update(domain: __MODULE__) do
    runs_revoked =
      Run
      |> Ash.Query.filter(builder_id == ^builder.id and is_nil(revoked_at))
      |> Ash.read!(domain: Portal.Catalog)
      |> Enum.count(fn run -> match?({:ok, _}, run |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update(domain: Portal.Catalog)) end)

    {_n, _} =
      Repo.update_all(
        from(l in "builder_leases", where: l.builder_id == type(^builder.id, Ecto.UUID) and l.state in ["leased", "uploading"]),
        set: [state: "queued", builder_id: nil, leased_at: nil, heartbeat_at: nil, phase: nil, updated_at: DateTime.utc_now()]
      )

    sweep_id =
      case packages do
        [] -> nil
        names ->
          {:ok, %{sweep_id: id}} = Portal.BulkRebuild.run(names: names, limit: length(names), what: :full, pin_local: true, created_by: "revoke builder #{builder.name}")
          id
      end

    {:ok, %{builder: builder, runs_revoked: runs_revoked, packages: packages, sweep_id: sweep_id}}
  end
end
```

`Portal.BulkRebuild.job/7`: add `"pin_local" => true` to the args map when `Keyword.get(opts, :pin_local, false)` (thread `opts` into `job/7`, or compute `pin_local` once in `enqueue/4`). `Portal.Workers.Backfill.perform/1`: `pin_local: args["pin_local"] == true` in `build`. `Portal.ScanRequests.insert_build_job/4`: `meta = meta |> Map.merge(if build[:pin_local], do: %{pin_local: true}, else: %{})`. Check `ScanRequests.create_once/1` forwards the `build` map keys it receives (it takes `force`/`scope`/`systems`/`sweep_id` from attrs; add `pin_local` the same way).

- [ ] **Step 5: Run the tests, expect PASS**

Run: `source ~/toolchain/env.sh && mix test apps/portal/test/portal/builders/enrolment_test.exs apps/portal/test/portal/builders/revoke_test.exs apps/portal/test/portal/bulk_rebuild_test.exs apps/portal/test/portal/workers/backfill_test.exs apps/portal/test/portal/scan_requests`

- [ ] **Step 6: Commit**

```bash
git add apps/portal/lib/portal/builders.ex apps/portal/lib/portal/builders apps/portal/lib/portal/bulk_rebuild.ex apps/portal/lib/portal/workers/backfill.ex apps/portal/lib/portal/scan_requests.ex apps/portal/lib/portal/catalog/ingestion.ex apps/portal/test/portal/builders
git commit -m "Enrol, renew, look up and revoke remote builders

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `PortalWeb.BuilderEndpoint`, the certificate plug, rate limits, enrolment routes

**Files:**
- Create: `apps/portal/lib/portal_web/builder_endpoint.ex`, `apps/portal/lib/portal_web/builder_router.ex`, `apps/portal/lib/portal_web/plugs/builder_cert.ex`, `apps/portal/lib/portal/builders/rate_limit.ex`, `apps/portal/lib/portal/builders/listener.ex`, `apps/portal/lib/portal_web/controllers/builder/enrolment_controller.ex`
- Modify: `apps/portal/lib/portal/application.ex` (start `Portal.Builders.RateLimit` and, when `Portal.Builders.Listener.enabled?/0`, `PortalWeb.BuilderEndpoint` after the main endpoint), `apps/portal/config/config.exs`, `apps/portal/config/test.exs`, `config/runtime.exs`
- Test: `apps/portal/test/support/builder_conn_case.ex`, `apps/portal/test/portal_web/builder/enrolment_controller_test.exs`, `apps/portal/test/portal_web/plugs/builder_cert_test.exs`, `apps/portal/test/portal/builders/rate_limit_test.exs`, `apps/portal/test/portal_web/builder_endpoint_config_test.exs`

**Interfaces:**
- `PortalWeb.BuilderEndpoint`: `use Phoenix.Endpoint, otp_app: :portal`; plugs `Plug.RequestId`, `Plug.Telemetry` (`event_prefix: [:phoenix, :builder_endpoint]`), `Plug.Parsers` with `parsers: [:json, {:multipart, length: 80_000_000}]`, `pass: ["*/*"]`, `json_decoder: Jason`, `length: 8_000_000`, then `PortalWeb.BuilderRouter`. No session, no static, no sockets. Config in `config.exs`: `adapter: Bandit.PhoenixAdapter`, `server: false`, `pubsub_server: Portal.PubSub`, `render_errors: [formats: [json: PortalWeb.ErrorJSON], layout: false]`, `url: [host: "localhost"]`, `secret_key_base` same literal as the main endpoint in test/dev and `SECRET_KEY_BASE` in prod (never used for signing; Phoenix wants one).
- `Portal.Builders.Listener.enabled?/0 :: boolean()` — true when `Portal.Builders.CA.key_path/0` is set, `CA.load/0` succeeds and `Application.get_env(:portal, PortalWeb.BuilderEndpoint)[:server]` is true. `Portal.Builders.Listener.https_options/0 :: keyword()` — `[port:, ip: {0,0,0,0,0,0,0,0}, certfile:, keyfile:, cacertfile: CA.cert_path(), verify: :verify_peer, fail_if_no_peer_cert: false, cipher_suite: :strong, http_2_options: [enabled: false]]` after `CA.ensure_server_cert(host)`; `Portal.Builders.Listener.child_spec_options/0` merges it into the endpoint's `https:` config via `Application.put_env` before the endpoint starts (Phoenix reads config at boot).
- `PortalWeb.BuilderRouter`: pipeline `:builder_api` = `plug :accepts, ["json"]` + `plug PortalWeb.Plugs.BuilderCert`; pipeline `:open` = `plug :accepts, ["json"]`. Routes: `GET /builder/v1/ca.pem`, `POST /builder/v1/enroll` (open, rate limited 10/min per IP); `POST /builder/v1/renew`, `POST /builder/v1/status`, and the `/builder/v1/jobs/*` routes (Tasks 7–8) behind `:builder_api`.
- `PortalWeb.Plugs.BuilderCert`: `Plug.Conn.get_peer_data/1`; no `ssl_cert` → 401 `{"error":"client_certificate_required"}`; `Portal.Builders.by_fingerprint(CA.fingerprint_der(der))` → `{:error, :unknown}` 403 `unknown_builder`, `{:error, :revoked}` 403 `builder_revoked`; `{:ok, builder}` → `assign(conn, :builder, Builders.touch(builder, get_req_header(conn, "x-ncc-agent-version") |> List.first()))`.
- `Portal.Builders.RateLimit`: GenServer owning a public ETS table `:ncc_builder_rate_limit`; `allow?(key :: term(), limit :: pos_integer(), window_ms :: pos_integer()) :: boolean()` with a fixed window keyed on `{key, div(now_ms, window_ms)}` via `:ets.update_counter/4`; sweeps old windows every minute.
- `PortalWeb.Builder.EnrolmentController`: `ca/2` → 200 `application/x-pem-file` body; `enroll/2` body `{"token","csr_pem","agent_version","slots"}` → 201 `{"certificate_pem","builder_id","name","expires_at"}`, 401 `{"error": "invalid_token" | "token_used" | "token_expired"}`, 422 `invalid_csr`, 409 `name_taken`, 429 `rate_limited`, 503 `no_ca`; `renew/2` body `{"csr_pem"}` → 200 `{"certificate_pem","expires_at"}`, 425 `too_early`, 403 `revoked`, 422 `invalid_csr`; `status/2` body `{"agent_version","egress":"ok"|"missing","free_slots"}` → 200 `{"ok":true}` after `Builders.set_egress/2`.
- Test support `PortalWeb.BuilderConnCase`: `@endpoint PortalWeb.BuilderEndpoint`; `setup` starts a temp CA (as `Portal.Builders.CATest` does), returns `conn`; helpers `enrolled_builder!(name)` (token → CSR → `Builders.enrol`, returns `%{builder, cert_der, key}`), `with_cert(conn, cert_der)` = `Plug.Test.put_peer_data(conn, %{address: {127,0,0,1}, port: 4444, ssl_cert: cert_der})`, `without_cert(conn)` with `ssl_cert: nil`.

- [ ] **Step 1: Write the failing tests**

`builder_cert_test.exs`:

```elixir
defmodule PortalWeb.Plugs.BuilderCertTest do
  use PortalWeb.BuilderConnCase, async: false

  alias Portal.Builders

  test "no certificate is 401", %{conn: conn} do
    conn = conn |> without_cert() |> post("/builder/v1/status", %{"agent_version" => "1", "egress" => "ok"})
    assert json_response(conn, 401) == %{"error" => "client_certificate_required"}
  end

  test "an unknown certificate is 403", %{conn: conn} do
    stray = X509.PrivateKey.new_ec(:secp256r1) |> X509.Certificate.self_signed("/CN=stray") |> X509.Certificate.to_der()
    conn = conn |> with_cert(stray) |> post("/builder/v1/status", %{"agent_version" => "1", "egress" => "ok"})
    assert json_response(conn, 403) == %{"error" => "unknown_builder"}
  end

  test "a known certificate is assigned and refreshes last_seen_at", %{conn: conn} do
    %{builder: builder, cert_der: der} = enrolled_builder!("box-p")
    assert builder.last_seen_at == nil
    conn = conn |> with_cert(der) |> put_req_header("x-ncc-agent-version", "7.x") |> post("/builder/v1/status", %{"agent_version" => "7.x", "egress" => "missing"})
    assert json_response(conn, 200) == %{"ok" => true}
    {:ok, seen} = Builders.get_builder(builder.id)
    assert %DateTime{} = seen.last_seen_at
    assert seen.last_version == "7.x"
    assert seen.egress_status == "missing"
  end

  test "a revoked builder is 403 on its next request", %{conn: conn} do
    %{builder: builder, cert_der: der} = enrolled_builder!("box-q")
    {:ok, _} = Builders.revoke(builder)
    conn = conn |> with_cert(der) |> post("/builder/v1/status", %{"agent_version" => "1", "egress" => "ok"})
    assert json_response(conn, 403) == %{"error" => "builder_revoked"}
  end

  test "a superseded certificate is accepted for 24 h and refused after", %{conn: conn} do
    %{builder: builder, cert_der: old_der} = enrolled_builder!("box-s")
    near = builder |> Ash.Changeset.for_update(:rotate_cert, %{cert_expires_at: DateTime.add(DateTime.utc_now(), 5, :day), fingerprint: builder.fingerprint, cert_pem: builder.cert_pem}) |> Ash.update!(domain: Builders)
    csr = X509.CSR.new(X509.PrivateKey.new_ec(:secp256r1), "/CN=x") |> X509.CSR.to_pem()
    {:ok, _} = Builders.renew(near, csr)

    assert conn |> with_cert(old_der) |> post("/builder/v1/status", %{"agent_version" => "1", "egress" => "ok"}) |> json_response(200)

    old_fp = Portal.Builders.CA.fingerprint_der(old_der)
    cert = Portal.Builders.BuilderCertificate |> Ash.Query.filter(fingerprint == ^old_fp) |> Ash.read_one!(domain: Builders)
    cert |> Ash.Changeset.for_update(:update_superseded_at, %{superseded_at: DateTime.add(DateTime.utc_now(), -25, :hour)}) |> Ash.update!(domain: Builders)

    assert conn |> with_cert(old_der) |> post("/builder/v1/status", %{"agent_version" => "1", "egress" => "ok"}) |> json_response(403) == %{"error" => "unknown_builder"}
  end
end
```

`enrolment_controller_test.exs`:

```elixir
defmodule PortalWeb.Builder.EnrolmentControllerTest do
  use PortalWeb.BuilderConnCase, async: false

  alias Portal.Builders

  defp csr do
    key = X509.PrivateKey.new_ec(:secp256r1)
    {key, X509.CSR.new(key, "/CN=whatever") |> X509.CSR.to_pem()}
  end

  test "ca.pem is served without a certificate", %{conn: conn} do
    conn = conn |> without_cert() |> get("/builder/v1/ca.pem")
    assert response(conn, 200) =~ "BEGIN CERTIFICATE"
    assert response_content_type(conn, :"x-pem-file") =~ "application/x-pem-file"
  end

  test "enrolment exchanges a token and CSR for a certificate", %{conn: conn} do
    {:ok, %{token: token}} = Builders.create_token("box-1", "admin")
    {_key, csr_pem} = csr()
    conn = conn |> without_cert() |> post("/builder/v1/enroll", %{"token" => token, "csr_pem" => csr_pem, "agent_version" => "1.a", "slots" => 2})
    assert %{"certificate_pem" => pem, "builder_id" => id, "name" => "box-1", "expires_at" => _} = json_response(conn, 201)
    assert {:ok, builder} = Builders.get_builder(id)
    assert builder.fingerprint == Portal.Builders.CA.fingerprint(X509.Certificate.from_pem!(pem))

    assert conn |> without_cert() |> post("/builder/v1/enroll", %{"token" => token, "csr_pem" => csr_pem}) |> json_response(401) == %{"error" => "token_used"}
    assert conn |> without_cert() |> post("/builder/v1/enroll", %{"token" => "a.b.c", "csr_pem" => csr_pem}) |> json_response(401) == %{"error" => "invalid_token"}
  end

  test "a bad CSR is 422 and a missing body is 400", %{conn: conn} do
    {:ok, %{token: token}} = Builders.create_token("box-2", "admin")
    assert conn |> without_cert() |> post("/builder/v1/enroll", %{"token" => token, "csr_pem" => "garbage"}) |> json_response(422) == %{"error" => "invalid_csr"}
    assert conn |> without_cert() |> post("/builder/v1/enroll", %{}) |> json_response(400)
  end

  test "enrolment is rate limited per address", %{conn: conn} do
    for _ <- 1..10, do: conn |> without_cert() |> post("/builder/v1/enroll", %{"token" => "a.b.c", "csr_pem" => "x"})
    assert conn |> without_cert() |> post("/builder/v1/enroll", %{"token" => "a.b.c", "csr_pem" => "x"}) |> json_response(429) == %{"error" => "rate_limited"}
  end

  test "renewal needs the client certificate and the window", %{conn: conn} do
    %{builder: builder, cert_der: der} = enrolled_builder!("box-3")
    {_k, csr_pem} = csr()
    assert conn |> with_cert(der) |> post("/builder/v1/renew", %{"csr_pem" => csr_pem}) |> json_response(425) == %{"error" => "too_early"}

    builder |> Ash.Changeset.for_update(:rotate_cert, %{cert_expires_at: DateTime.add(DateTime.utc_now(), 5, :day), fingerprint: builder.fingerprint, cert_pem: builder.cert_pem}) |> Ash.update!(domain: Builders)
    assert %{"certificate_pem" => "-----BEGIN CERTIFICATE-----" <> _, "expires_at" => _} = conn |> with_cert(der) |> post("/builder/v1/renew", %{"csr_pem" => csr_pem}) |> json_response(200)

    assert conn |> without_cert() |> post("/builder/v1/renew", %{"csr_pem" => csr_pem}) |> json_response(401)
  end
end
```

`rate_limit_test.exs`:

```elixir
defmodule Portal.Builders.RateLimitTest do
  use ExUnit.Case, async: false
  alias Portal.Builders.RateLimit

  test "allows limit calls per window, then refuses, then resets" do
    key = {:test, System.unique_integer()}
    assert Enum.all?(1..3, fn _ -> RateLimit.allow?(key, 3, 60_000) end)
    refute RateLimit.allow?(key, 3, 60_000)
    assert RateLimit.allow?(key, 3, 60_000, now_ms: System.system_time(:millisecond) + 60_000)
  end
end
```

`builder_endpoint_config_test.exs`:

```elixir
defmodule PortalWeb.BuilderEndpointConfigTest do
  use ExUnit.Case, async: false

  alias Portal.Builders.{CA, Listener}

  test "the listener is off without a CA and on with one" do
    refute Listener.enabled?()
    dir = Path.join(System.tmp_dir!(), "ncc-ca-#{System.unique_integer([:positive])}")
    key = Path.join(dir, "ca-key.pem")
    previous_ca = Application.get_env(:portal, CA, [])
    previous_ep = Application.get_env(:portal, PortalWeb.BuilderEndpoint, [])
    on_exit(fn -> Application.put_env(:portal, CA, previous_ca); Application.put_env(:portal, PortalWeb.BuilderEndpoint, previous_ep); File.rm_rf(dir) end)
    {:ok, _} = CA.init(key)
    Application.put_env(:portal, CA, key_path: key)
    Application.put_env(:portal, PortalWeb.BuilderEndpoint, Keyword.put(previous_ep, :server, true))
    assert Listener.enabled?()

    opts = Listener.https_options("portal.test")
    assert opts[:verify] == :verify_peer
    assert opts[:fail_if_no_peer_cert] == false
    assert opts[:cacertfile] == CA.cert_path()
    assert File.exists?(opts[:certfile]) and File.exists?(opts[:keyfile])
    assert opts[:http_2_options][:enabled] == false
    assert opts[:port] == 8443
  end
end
```

- [ ] **Step 2: Run them, expect failures (modules undefined)**

- [ ] **Step 3: Implement**

`builder_conn_case.ex`:

```elixir
defmodule PortalWeb.BuilderConnCase do
  @moduledoc "ConnCase for `PortalWeb.BuilderEndpoint` with a throwaway CA and peer certificates."
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint PortalWeb.BuilderEndpoint
      import Plug.Conn
      import Phoenix.ConnTest
      import PortalWeb.BuilderConnCase
      require Ash.Query
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Portal.Repo, shared: not tags[:async])
    dir = Path.join(System.tmp_dir!(), "ncc-ca-#{System.unique_integer([:positive])}")
    key_path = Path.join(dir, "ca-key.pem")
    previous = Application.get_env(:portal, Portal.Builders.CA, [])
    Application.put_env(:portal, Portal.Builders.CA, Keyword.put(previous, :key_path, key_path))
    {:ok, _} = Portal.Builders.CA.init(key_path)
    Portal.Builders.RateLimit.reset()

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
      Application.put_env(:portal, Portal.Builders.CA, previous)
      File.rm_rf(dir)
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  def enrolled_builder!(name, attrs \\ %{}) do
    {:ok, %{token: token}} = Portal.Builders.create_token(name, "test")
    key = X509.PrivateKey.new_ec(:secp256r1)
    csr = X509.CSR.new(key, "/CN=#{name}") |> X509.CSR.to_pem()
    {:ok, %{builder: builder, cert_pem: pem}} = Portal.Builders.enrol(token, csr, attrs)
    %{builder: builder, cert_der: pem |> X509.Certificate.from_pem!() |> X509.Certificate.to_der(), key: key}
  end

  def with_cert(conn, der), do: Plug.Test.put_peer_data(conn, %{address: {127, 0, 0, 1}, port: 4444, ssl_cert: der})
  def without_cert(conn), do: Plug.Test.put_peer_data(conn, %{address: {127, 0, 0, 1}, port: 4444, ssl_cert: nil})
end
```

`RateLimit`:

```elixir
defmodule Portal.Builders.RateLimit do
  @moduledoc "Fixed-window counters in ETS: enrol 10/min per address, claim 60/min per builder."
  use GenServer

  @table :ncc_builder_rate_limit

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec allow?(term(), pos_integer(), pos_integer(), keyword()) :: boolean()
  def allow?(key, limit, window_ms, opts \\ []) do
    now = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    window = div(now, window_ms)
    count = :ets.update_counter(@table, {key, window}, {2, 1}, {{key, window}, 0, now})
    count <= limit
  end

  @doc false
  def reset, do: :ets.delete_all_objects(@table)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.system_time(:millisecond) - :timer.minutes(5)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, :timer.minutes(1))
end
```

`Listener`:

```elixir
defmodule Portal.Builders.Listener do
  @moduledoc """
  Decides whether the mTLS listener starts and assembles its Bandit options:
  the CA-signed server certificate, the CA as the only trusted root, and
  `fail_if_no_peer_cert: false` so `/builder/v1/enroll` and `/ca.pem` are
  reachable without a certificate while `PortalWeb.Plugs.BuilderCert` demands
  one everywhere else.
  """
  require Logger
  alias Portal.Builders.CA

  @default_port 8443

  def enabled? do
    config = Application.get_env(:portal, PortalWeb.BuilderEndpoint, [])
    Keyword.get(config, :server, false) == true and match?({:ok, _}, CA.load())
  end

  def port do
    :portal |> Application.get_env(PortalWeb.BuilderEndpoint, []) |> Keyword.get(:https, []) |> Keyword.get(:port, @default_port)
  end

  def https_options(host) do
    {:ok, %{certfile: certfile, keyfile: keyfile}} = CA.ensure_server_cert(host)

    [
      port: port(),
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      certfile: certfile,
      keyfile: keyfile,
      cacertfile: CA.cert_path(),
      verify: :verify_peer,
      fail_if_no_peer_cert: false,
      cipher_suite: :strong,
      http_2_options: [enabled: false]
    ]
  end

  @doc "Install the https options into the endpoint config; call before the endpoint starts."
  def configure! do
    host = Application.get_env(:portal, PortalWeb.Endpoint, []) |> Keyword.get(:url, []) |> Keyword.get(:host, "localhost")
    config = Application.get_env(:portal, PortalWeb.BuilderEndpoint, [])
    Application.put_env(:portal, PortalWeb.BuilderEndpoint, Keyword.put(config, :https, https_options(host)))
    Logger.info("builder listener on #{port()} with CA #{CA.cert_path()}")
    :ok
  end
end
```

Application children: insert `Portal.Builders.RateLimit` before `PortalWeb.Endpoint`, and after it `if Portal.Builders.Listener.enabled?() do Portal.Builders.Listener.configure!(); children ++ [PortalWeb.BuilderEndpoint] end` (keep `Warmup` last).

`BuilderCert` plug:

```elixir
defmodule PortalWeb.Plugs.BuilderCert do
  @moduledoc "Turns the peer certificate into `conn.assigns.builder`, or refuses the request."
  import Plug.Conn
  alias Portal.Builders
  alias Portal.Builders.CA

  def init(opts), do: opts

  def call(conn, _opts) do
    case Plug.Conn.get_peer_data(conn) do
      %{ssl_cert: der} when is_binary(der) ->
        case Builders.by_fingerprint(CA.fingerprint_der(der)) do
          {:ok, builder} -> assign(conn, :builder, Builders.touch(builder, List.first(get_req_header(conn, "x-ncc-agent-version"))))
          {:error, :revoked} -> refuse(conn, 403, "builder_revoked")
          {:error, :unknown} -> refuse(conn, 403, "unknown_builder")
        end

      _ ->
        refuse(conn, 401, "client_certificate_required")
    end
  end

  defp refuse(conn, status, error) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error}))
    |> halt()
  end
end
```

Endpoint, router, controller:

```elixir
defmodule PortalWeb.BuilderEndpoint do
  @moduledoc "The mTLS listener remote builders talk to. JSON and raw bodies only; no sessions."
  use Phoenix.Endpoint, otp_app: :portal

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :builder_endpoint]

  plug Plug.Parsers,
    parsers: [:json, {:multipart, length: 80_000_000}],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    length: 8_000_000

  plug PortalWeb.BuilderRouter
end
```

```elixir
defmodule PortalWeb.BuilderRouter do
  use PortalWeb, :router

  pipeline :open do
    plug :accepts, ["json"]
  end

  pipeline :builder_api do
    plug :accepts, ["json"]
    plug PortalWeb.Plugs.BuilderCert
  end

  scope "/builder/v1", PortalWeb.Builder do
    pipe_through :open
    get "/ca.pem", EnrolmentController, :ca
    post "/enroll", EnrolmentController, :enroll
  end

  scope "/builder/v1", PortalWeb.Builder do
    pipe_through :builder_api
    post "/renew", EnrolmentController, :renew
    post "/status", EnrolmentController, :status
  end
end
```

```elixir
defmodule PortalWeb.Builder.EnrolmentController do
  use PortalWeb, :controller

  alias Portal.Builders
  alias Portal.Builders.{CA, RateLimit}

  @enrol_per_minute 10

  def ca(conn, _params) do
    case CA.cert_pem() do
      {:ok, pem} -> conn |> put_resp_content_type("application/x-pem-file") |> send_resp(200, pem)
      {:error, _} -> error(conn, 503, "no_ca")
    end
  end

  def enroll(conn, %{"token" => token, "csr_pem" => csr}) when is_binary(token) and is_binary(csr) do
    if RateLimit.allow?({:enrol, conn.remote_ip}, @enrol_per_minute, :timer.minutes(1)) do
      attrs = %{agent_version: string(conn.params["agent_version"]), slots: slots(conn.params["slots"])}

      case Builders.enrol(token, csr, attrs) do
        {:ok, %{builder: builder, cert_pem: pem, expires_at: expires}} ->
          conn |> put_status(201) |> json(%{certificate_pem: pem, builder_id: builder.id, name: builder.name, expires_at: DateTime.to_iso8601(expires)})

        {:error, reason} when reason in [:invalid_token, :token_used, :token_expired] -> error(conn, 401, reason)
        {:error, :invalid_csr} -> error(conn, 422, "invalid_csr")
        {:error, :name_taken} -> error(conn, 409, "name_taken")
        {:error, :no_ca} -> error(conn, 503, "no_ca")
        {:error, _} -> error(conn, 500, "enrolment_failed")
      end
    else
      error(conn, 429, "rate_limited")
    end
  end

  def enroll(conn, _params), do: error(conn, 400, "bad_request")

  def renew(conn, %{"csr_pem" => csr}) when is_binary(csr) do
    case Builders.renew(conn.assigns.builder, csr) do
      {:ok, %{cert_pem: pem, expires_at: expires}} -> json(conn, %{certificate_pem: pem, expires_at: DateTime.to_iso8601(expires)})
      {:error, :too_early} -> error(conn, 425, "too_early")
      {:error, :revoked} -> error(conn, 403, "revoked")
      {:error, _} -> error(conn, 422, "invalid_csr")
    end
  end

  def renew(conn, _params), do: error(conn, 400, "bad_request")

  def status(conn, params) do
    egress = if params["egress"] in ["ok", "missing"], do: params["egress"], else: "unknown"
    {:ok, _} = Builders.set_egress(conn.assigns.builder, egress)
    json(conn, %{ok: true})
  end

  defp slots(n) when is_integer(n) and n in 1..16, do: n
  defp slots(n) when is_binary(n), do: (case Integer.parse(n) do {i, ""} when i in 1..16 -> i; _ -> nil end)
  defp slots(_), do: nil

  defp string(v) when is_binary(v), do: String.slice(v, 0, 64)
  defp string(_), do: nil

  defp error(conn, status, reason), do: conn |> put_status(status) |> json(%{error: to_string(reason)})
end
```

Config: `apps/portal/config/config.exs`:

```elixir
config :portal, PortalWeb.BuilderEndpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  server: false,
  render_errors: [formats: [json: PortalWeb.ErrorJSON], layout: false],
  pubsub_server: Portal.PubSub
```

`apps/portal/config/test.exs` and `dev.exs`: `config :portal, PortalWeb.BuilderEndpoint, secret_key_base: "<same literal as PortalWeb.Endpoint there>", server: false`. `config/runtime.exs` (portal block): `config :portal, PortalWeb.BuilderEndpoint, https: [port: String.to_integer(System.get_env("NCC_BUILDER_PORT", "8443"))]`; `if System.get_env("PHX_SERVER") && System.get_env("NCC_BUILDER_CA_KEY"), do: config(:portal, PortalWeb.BuilderEndpoint, server: true)`; in the `:prod` block `config :portal, PortalWeb.BuilderEndpoint, secret_key_base: secret_key_base, url: [host: host, port: 8443, scheme: "https"]`.

- [ ] **Step 4: Run all five test files, expect PASS**

Run: `source ~/toolchain/env.sh && mix test apps/portal/test/portal_web/builder apps/portal/test/portal_web/plugs/builder_cert_test.exs apps/portal/test/portal/builders/rate_limit_test.exs apps/portal/test/portal_web/builder_endpoint_config_test.exs apps/portal/test/portal_web/endpoint_config_test.exs`

- [ ] **Step 5: Commit**

```bash
git add apps/portal/lib/portal_web/builder_endpoint.ex apps/portal/lib/portal_web/builder_router.ex apps/portal/lib/portal_web/plugs/builder_cert.ex apps/portal/lib/portal/builders apps/portal/lib/portal_web/controllers/builder apps/portal/lib/portal/application.ex apps/portal/config config/runtime.exs apps/portal/test/support/builder_conn_case.ex apps/portal/test/portal_web apps/portal/test/portal/builders
git commit -m "Add the mTLS builder endpoint with enrolment, renewal and status

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Leases, the `:remote` queue worker, claim and heartbeat

**Files:**
- Create: `apps/portal/lib/portal/builders/leases.ex`, `apps/portal/lib/portal/workers/remote_build.ex`, `apps/portal/lib/portal_web/controllers/builder/job_controller.ex` (claim, heartbeat; Task 8 adds files/complete)
- Modify: `apps/portal/lib/portal_web/builder_router.ex`, `apps/portal/lib/portal/builders/upload.ex` does not exist yet (Task 8); claim response caps come from `Portal.Builders.Upload.caps/0` which Task 8 creates — in this task define `Portal.Builders.Leases.upload_caps/0` reading `Application.get_env(:portal, Portal.Builders.Upload, [])` with defaults `max_file_bytes: 268_435_456, max_total_bytes: 2_147_483_648, max_batch_bytes: 536_870_912, max_files: 20_000`, and Task 8 reuses it.
- Modify: `apps/portal/config/config.exs` (Oban: nothing — queues come from runtime), `config/runtime.exs` (default `OBAN_QUEUES` gains `remote: 2` after `toolchain: 1`), `apps/portal/lib/portal/workers/build.ex` (none; `scope_args/3` is already public)
- Test: `apps/portal/test/portal/builders/leases_test.exs`, `apps/portal/test/portal/workers/remote_build_test.exs`, `apps/portal/test/portal_web/builder/job_controller_claim_test.exs`

**Interfaces:**
- `Portal.Builders.Leases`:
  - `@topic "builders:leases"`; `subscribe/0`; `enqueue(attrs) :: {:ok, Lease.t()}` where `attrs` has `package, version, image_name, image_digest, args, scan_request_id, priority`; broadcasts `{:lease_queued, lease.id}` on the topic and `Portal.AdminEvents.broadcast(:builders)` (add `builders: "admin:builders"` to `Portal.AdminEvents` `@topics` and the `topic()` type).
  - `claim(builder) :: {:ok, Lease.t()} | :none` — one SQL statement, `FOR UPDATE SKIP LOCKED`, respects `slots`, sets `run_id` to `"rb-<package>-<version>-<ms>"`.
  - `claim_or_wait(builder, timeout_ms) :: {:ok, Lease.t()} | :none` — subscribe, claim, else wait for one broadcast within `timeout_ms` then claim once more; drains any `{:lease_queued, _}` left in the mailbox before returning.
  - `held(lease_id, builder_id) :: {:ok, Lease.t()} | {:error, :not_held}` — state in `[:leased, :uploading]` and matching builder.
  - `heartbeat(lease_id, builder_id, phase, log_tail) :: {:ok, Lease.t()} | {:error, :not_held}` — `heartbeat_at` now, `phase` in `["pulling", "building", "uploading"]` (anything else stored as `"building"`), `log_tail` last 4096 bytes; `"uploading"` moves state to `:uploading`; broadcasts `Progress.broadcast(scan_request_id, :building, %{remote: true, phase: phase})`.
  - `complete(lease, exit_code) :: {:ok, :done | :requeued | :failed | :rejected, Lease.t()}` — 0 → `:done`; 11 → `:failed` with `error: "non-Hex dep"` and `Progress.mark(scan_request_id, :rejected, error_reason: "non-Hex dep")`; anything else → attempt < max → back to `:queued` (builder cleared), else `:failed` + `Progress.mark(:error, error_reason: "worker/runner exit N")`.
  - `requeue(lease) :: {:ok, Lease.t()}` (admin: a `:failed` lease back to `:queued`, attempt reset to 0, error cleared).
  - `add_bytes(lease, n) :: {:ok, Lease.t()}`.
  - `reap(now \\ DateTime.utc_now()) :: %{requeued: n, failed: n}` — `:leased` with `heartbeat_at < now - 10 min` or `leased_at < now - (2 h + 30 min)`, `:uploading` with `heartbeat_at < now - 60 min`: attempt < max → `:queued` (attempt kept), else `:failed` (`error: "builder went silent"`, `Progress.mark(:error)`).
  - `counts/0 :: %{queued: n, leased: n, uploading: n, done: n, failed: n}`, `recent(limit) :: [Lease.t()]` (newest first), `open/0` (queued/leased/uploading), `failed/0`.
- `Portal.Workers.RemoteBuild`: `use Oban.Worker, queue: :remote, max_attempts: 3, unique: [period: 60, fields: [:worker, :queue, :args], keys: [:package, :version, :image_digest, :force, :scan_request_id, :scope, :systems]]`. `perform/1`: `ToolingSkip.tooling?` → `ToolingSkip.record/3` exactly as `Build` does; registry image from `Portal.Builders.Images.worker_image/0` (nil → `{:cancel, :no_registry_image}` and the request marked error); dedup with `(package, version, registry digest)` unless `force`; `Build.scope_args/3`; `Leases.enqueue(%{package, version, image_name, image_digest, args: %{"systems_filter" => ..., "mode" => ..., "argus" => Portal.Settings.worker_argus(Portal.Settings.get()), "force" => force}, scan_request_id, priority: job.priority})`; `Progress.broadcast(scan_request_id, :queued, %{remote: true})`; `:ok`.
- `PortalWeb.Builder.JobController.claim/2`: body `{"agent_version","free_slots","egress"}`; rate limit `{:claim, builder.id}` 60/min → 429; `egress != "ok"` → `Builders.set_egress(builder, "missing")` and 409 `{"error":"egress_missing"}`; `free_slots` ≤ 0 → 204; else `Leases.claim_or_wait(builder, 25_000)`: `:none` → 204; `{:ok, lease}` → 200 with:

```json
{"lease_id": "...", "run_id": "rb-jason-1.4.4-1761400000000",
 "image": {"name": "ghcr.io/tomhoenderdos/ncc-worker", "digest": "sha256:..."},
 "input": {... Portal.Builder.worker_input/1 ...},
 "timeout_sec": 7200,
 "upload": {"max_file_bytes": 268435456, "max_total_bytes": 2147483648, "max_batch_bytes": 536870912, "max_files": 20000},
 "min_agent_version": "1761400000.abcdefabcdef" | null,
 "agent_releases": {"x86_64": {"url": "...", "sha256": "..."}} | {},
 "warm_allowlist": ["nerves_system_rpi4", ...],
 "egress_required": true}
```

  `input` = `Portal.Builder.worker_input(%{run_id: lease.run_id, image_name: lease.image_name, image_digest: lease.image_digest, package: %{"name" => lease.package, "version" => lease.version, "source" => "hex"}, systems_filter: lease.args["systems_filter"], mode: lease.args["mode"], argus: lease.args["argus"]})`. `timeout_sec` = `div(Portal.Builder.total_timeout_ms(), 1000)`. `warm_allowlist` = `Portal.Builders.WarmAllowlist.names/0` (new small module: the official Nerves systems and toolchains the `nerves` Hex account owns — `Portal.Catalog.ToolingSkip`'s lists if it exports them, else `Portal.BulkRebuild.targets()` plus the kiosk systems and `nerves_toolchain_*` names it hard-codes; comment that `Portal.HexPm.owners/1` from the isolation branch replaces this list once it lands).
- `heartbeat/2`: body `{"phase","log_tail"}` → 200 `{"ok":true}` or 409 `{"error":"lease_not_held"}`.
- Routes under `:builder_api`: `post "/jobs/claim"`, `post "/jobs/:lease_id/heartbeat"`.

- [ ] **Step 1: Write the failing leases test**

```elixir
defmodule Portal.Builders.LeasesTest do
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.Builders.{Builder, Lease, Leases}

  defp builder!(name, slots \\ 1) do
    Builder
    |> Ash.Changeset.for_create(:enrol, %{name: name, fingerprint: "fp-#{name}", cert_pem: "p", cert_expires_at: DateTime.utc_now(), slots: slots, enrolled_at: DateTime.utc_now()})
    |> Ash.create!(domain: Portal.Builders)
  end

  defp queued!(package \\ "jason", priority \\ 5) do
    {:ok, lease} = Leases.enqueue(%{package: package, version: "1.4.4", image_name: "i", image_digest: "sha256:d", args: %{}, scan_request_id: nil, priority: priority})
    lease
  end

  test "enqueue broadcasts and claim takes the highest priority oldest lease" do
    Leases.subscribe()
    low = queued!("a", 9)
    high = queued!("b", 1)
    assert_receive {:lease_queued, _}
    assert_receive {:lease_queued, _}

    b = builder!("one")
    assert {:ok, %Lease{id: id, state: :leased, attempt: 1, run_id: "rb-b-1.4.4-" <> _}} = Leases.claim(b)
    assert id == high.id
    assert {:ok, %Lease{id: id2}} = Leases.claim(builder!("two"))
    assert id2 == low.id
    assert :none = Leases.claim(builder!("three"))
  end

  test "a builder holds at most slots leases" do
    queued!("a")
    queued!("b")
    b = builder!("one", 1)
    assert {:ok, _} = Leases.claim(b)
    assert :none = Leases.claim(b)
    assert {:ok, _} = Leases.claim(builder!("two", 1))
  end

  test "claim is atomic across two concurrent claimants" do
    queued!("only")
    b1 = builder!("c1")
    b2 = builder!("c2")
    parent = self()

    tasks =
      for b <- [b1, b2] do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Portal.Repo, parent, self())
          Leases.claim(b)
        end)
      end

    results = Task.await_many(tasks, 10_000)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == :none)) == 1
  end

  test "the long poll wakes on a broadcast" do
    b = builder!("w")
    task = Task.async(fn ->
      Ecto.Adapters.SQL.Sandbox.allow(Portal.Repo, self(), self())
      Leases.claim_or_wait(b, 5_000)
    end)
    Ecto.Adapters.SQL.Sandbox.allow(Portal.Repo, self(), task.pid)
    _ = :sys.get_state(Portal.PubSub)
    queued!("late")
    assert {:ok, %Lease{package: "late"}} = Task.await(task, 6_000)
    assert :none = Leases.claim_or_wait(builder!("w2"), 50)
  end

  test "heartbeat, held and complete drive the state machine" do
    lease = queued!()
    b = builder!("h")
    other = builder!("o")
    {:ok, leased} = Leases.claim(b)
    assert {:error, :not_held} = Leases.heartbeat(leased.id, other.id, "building", "x")
    assert {:ok, %Lease{phase: "building", log_tail: "tail"}} = Leases.heartbeat(leased.id, b.id, "building", "tail")
    assert {:ok, %Lease{state: :uploading}} = Leases.heartbeat(leased.id, b.id, "uploading", "")
    assert {:ok, %Lease{}} = Leases.held(leased.id, b.id)
    assert {:error, :not_held} = Leases.held(leased.id, other.id)

    assert {:ok, :requeued, %Lease{state: :queued, builder_id: nil, attempt: 1}} = Leases.complete(Ash.get!(Lease, lease.id, domain: Portal.Builders), 10)
    {:ok, again} = Leases.claim(b)
    assert {:ok, :done, %Lease{state: :done}} = Leases.complete(again, 0)
  end

  test "a policy violation fails the lease without retry and exhausted attempts fail it" do
    lease = queued!()
    {:ok, leased} = Leases.claim(builder!("p"))
    assert {:ok, :rejected, %Lease{state: :failed, error: "non-Hex dep"}} = Leases.complete(leased, 11)

    lease2 = queued!("z")
    b = builder!("z")
    {:ok, l} = Leases.claim(b)
    {:ok, :requeued, _} = Leases.complete(l, 21)
    {:ok, l} = Leases.claim(b)
    {:ok, :requeued, _} = Leases.complete(l, 20)
    {:ok, l} = Leases.claim(b)
    assert {:ok, :failed, %Lease{state: :failed, attempt: 3}} = Leases.complete(l, 10)
    assert {:ok, %Lease{state: :queued, attempt: 0}} = Leases.requeue(Ash.get!(Lease, lease2.id, domain: Portal.Builders))
    assert lease.id != lease2.id
  end

  test "the reaper requeues silent leases and fails exhausted ones" do
    b = builder!("r", 4)
    {:ok, fresh} = Leases.claim(queued!("fresh") && b)
    {:ok, silent} = Leases.claim(b)
    {:ok, old_upload} = Leases.claim(b)
    {:ok, exhausted} = Leases.claim(b)

    now = DateTime.utc_now()
    set = fn lease, attrs -> lease |> Ash.Changeset.for_update(:update, attrs) |> Ash.update!(domain: Portal.Builders) end
    set.(silent, %{heartbeat_at: DateTime.add(now, -11, :minute)})
    set.(old_upload, %{state: :uploading, heartbeat_at: DateTime.add(now, -61, :minute)})
    set.(exhausted, %{heartbeat_at: DateTime.add(now, -11, :minute), attempt: 3})
    set.(fresh, %{heartbeat_at: DateTime.add(now, -9, :minute)})

    assert %{requeued: 2, failed: 1} = Leases.reap(now)
    assert Ash.get!(Lease, fresh.id, domain: Portal.Builders).state == :leased
    assert Ash.get!(Lease, silent.id, domain: Portal.Builders).state == :queued
    assert Ash.get!(Lease, old_upload.id, domain: Portal.Builders).state == :queued
    assert %Lease{state: :failed, error: "builder went silent"} = Ash.get!(Lease, exhausted.id, domain: Portal.Builders)
  end
end
```

(In the reaper test replace `Leases.claim(queued!("fresh") && b)` with two statements: `queued!("fresh")` then `Leases.claim(b)`, and queue three more before the other claims; the type checker rejects the `&&` form.)

- [ ] **Step 2: Write the failing RemoteBuild and claim tests**

`remote_build_test.exs`:

```elixir
defmodule Portal.Workers.RemoteBuildTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query

  alias Portal.Builders.{Images, Lease}
  alias Portal.Workers.RemoteBuild

  setup do
    path = Path.join(System.tmp_dir!(), "images-#{System.unique_integer([:positive])}.json")
    File.write!(path, ~s({"commit":"c","images":{"ncc-worker":{"name":"ghcr.io/x/ncc-worker","tag":"c","digest":"sha256:#{String.duplicate("a", 64)}"}}}))
    previous = Application.get_env(:portal, Images, [])
    Application.put_env(:portal, Images, Keyword.put(previous, :path, path))
    on_exit(fn -> Application.put_env(:portal, Images, previous); File.rm(path) end)
    :ok
  end

  test "writes a lease carrying the registry image and the worker input args" do
    {:ok, request} = Portal.ScanRequests.create_once(%{package_name: "jason", version: "1.4.4", source: :hex_owner, status: :accepted})
    Portal.Workers.Progress.broadcast(request.id, :noop, %{})
    assert :ok = perform_job(RemoteBuild, %{"package" => "jason", "version" => "1.4.4", "scan_request_id" => request.id}, priority: 2)

    assert [%Lease{} = lease] = Ash.read!(Lease, domain: Portal.Builders)
    assert lease.package == "jason" and lease.version == "1.4.4" and lease.state == :queued
    assert lease.image_name == "ghcr.io/x/ncc-worker" and lease.image_digest == "sha256:" <> String.duplicate("a", 64)
    assert lease.scan_request_id == request.id and lease.priority == 2
    assert Map.has_key?(lease.args, "argus")
  end

  test "dedups on an existing run at the registry digest unless forced" do
    digest = "sha256:" <> String.duplicate("a", 64)
    {:ok, _} = Portal.Catalog.Ingestion.ingest(%{"package" => %{"name" => "jason", "version" => "1.4.4"}, "finished_at" => "2026-10-10T10:00:00Z", "systems" => %{"host" => %{"status" => "pass"}}}, %{run_id: "r", image_digest: digest, files_dir: System.tmp_dir!()})
    assert :ok = perform_job(RemoteBuild, %{"package" => "jason", "version" => "1.4.4"})
    assert [] = Ash.read!(Lease, domain: Portal.Builders)
    assert :ok = perform_job(RemoteBuild, %{"package" => "jason", "version" => "1.4.4", "force" => true})
    assert [_] = Ash.read!(Lease, domain: Portal.Builders)
  end

  test "tooling is recorded as skipped, never leased" do
    assert :ok = perform_job(RemoteBuild, %{"package" => "nerves_system_rpi4", "version" => "1.0.0"})
    assert [] = Ash.read!(Lease, domain: Portal.Builders)
    assert [_run] = Ash.read!(Portal.Catalog.Run, domain: Portal.Catalog)
  end

  test "without a registry image the job cancels and the request errors" do
    File.rm!(Images.path())
    {:ok, request} = Portal.ScanRequests.create_once(%{package_name: "jason", version: "1.4.4", source: :hex_owner, status: :accepted})
    assert {:cancel, :no_registry_image} = perform_job(RemoteBuild, %{"package" => "jason", "version" => "1.4.4", "scan_request_id" => request.id})
    {:ok, updated} = Portal.ScanRequests.get_request(request.id)
    assert updated.status == :error
  end
end
```

(Remove the stray `Progress.broadcast(... :noop ...)` line; it is not needed. `ScanRequests.create_once/1` with `status: :accepted` enqueues a Build job; with `testing: :manual` that only inserts a job row, which is fine.)

`job_controller_claim_test.exs`:

```elixir
defmodule PortalWeb.Builder.JobControllerClaimTest do
  use PortalWeb.BuilderConnCase, async: false

  alias Portal.Builders.{Lease, Leases}

  defp queued!(package \\ "jason") do
    {:ok, lease} = Leases.enqueue(%{package: package, version: "1.4.4", image_name: "ghcr.io/x/ncc-worker", image_digest: "sha256:#{String.duplicate("b", 64)}", args: %{"mode" => nil, "systems_filter" => nil, "argus" => nil}, scan_request_id: nil, priority: 5})
    lease
  end

  @claim %{"agent_version" => "1.a", "free_slots" => 1, "egress" => "ok"}

  test "claim hands out the lease with the worker input and caps", %{conn: conn} do
    %{cert_der: der} = enrolled_builder!("c1")
    lease = queued!()
    body = conn |> with_cert(der) |> post("/builder/v1/jobs/claim", @claim) |> json_response(200)
    assert body["lease_id"] == lease.id
    assert body["run_id"] =~ ~r/^rb-jason-1\.4\.4-\d+$/
    assert body["image"] == %{"name" => "ghcr.io/x/ncc-worker", "digest" => "sha256:" <> String.duplicate("b", 64)}
    assert body["input"]["package"] == %{"name" => "jason", "version" => "1.4.4", "source" => "hex"}
    assert body["input"]["run_id"] == body["run_id"]
    assert body["input"]["paths"]["files_dir"] == "/files"
    assert body["timeout_sec"] == 7200
    assert body["upload"]["max_files"] == 20_000
    assert body["egress_required"] == true
    assert is_list(body["warm_allowlist"])
  end

  test "nothing to do is 204 and a short poll returns quickly", %{conn: conn} do
    %{cert_der: der} = enrolled_builder!("c2")
    Application.put_env(:portal, Portal.Builders.Leases, long_poll_ms: 50)
    on_exit(fn -> Application.delete_env(:portal, Portal.Builders.Leases) end)
    assert conn |> with_cert(der) |> post("/builder/v1/jobs/claim", @claim) |> response(204)
  end

  test "a missing egress ruleset is refused and recorded", %{conn: conn} do
    %{builder: builder, cert_der: der} = enrolled_builder!("c3")
    queued!()
    assert conn |> with_cert(der) |> post("/builder/v1/jobs/claim", %{@claim | "egress" => "missing"}) |> json_response(409) == %{"error" => "egress_missing"}
    {:ok, b} = Portal.Builders.get_builder(builder.id)
    assert b.egress_status == "missing"
    assert [%Lease{state: :queued}] = Ash.read!(Lease, domain: Portal.Builders)
  end

  test "heartbeat updates the lease and refuses another builder", %{conn: conn} do
    %{cert_der: der} = enrolled_builder!("c4")
    %{cert_der: other} = enrolled_builder!("c5")
    queued!()
    %{"lease_id" => id} = conn |> with_cert(der) |> post("/builder/v1/jobs/claim", @claim) |> json_response(200)
    assert conn |> with_cert(der) |> post("/builder/v1/jobs/#{id}/heartbeat", %{"phase" => "building", "log_tail" => "compiling"}) |> json_response(200) == %{"ok" => true}
    assert Ash.get!(Lease, id, domain: Portal.Builders).log_tail == "compiling"
    assert conn |> with_cert(other) |> post("/builder/v1/jobs/#{id}/heartbeat", %{"phase" => "building"}) |> json_response(409) == %{"error" => "lease_not_held"}
  end
end
```

- [ ] **Step 3: Run the three files, expect failures**

- [ ] **Step 4: Implement `Portal.Builders.Leases`**

```elixir
defmodule Portal.Builders.Leases do
  @moduledoc """
  The remote job queue: `builder_leases` rows and their state machine.

  `queued → leased → uploading → done`, with `queued` re-entered on a failed
  attempt and `failed` after `max_attempts`. Claim is one `UPDATE ... FOR
  UPDATE SKIP LOCKED`, so two builders never hold the same lease and a
  builder never exceeds its `slots`. The claim long-poll wakes on the
  `builders:leases` broadcast `enqueue/1` sends, not on a database poll.
  """
  require Ash.Query
  require Logger
  import Ecto.Query, only: [from: 2]

  alias Portal.Builders.{Builder, Lease}
  alias Portal.Repo
  alias Portal.Workers.Progress

  @topic "builders:leases"
  @domain Portal.Builders
  @leased_silence_minutes 10
  @uploading_silence_minutes 60
  @lease_ceiling_minutes 150
  @log_tail_bytes 4096
  @phases ~w(pulling building uploading)
  @default_long_poll_ms 25_000

  def topic, do: @topic
  def subscribe, do: Phoenix.PubSub.subscribe(Portal.PubSub, @topic)

  def long_poll_ms, do: :portal |> Application.get_env(__MODULE__, []) |> Keyword.get(:long_poll_ms, @default_long_poll_ms)

  def upload_caps do
    config = Application.get_env(:portal, Portal.Builders.Upload, [])

    %{
      max_file_bytes: Keyword.get(config, :max_file_bytes, 268_435_456),
      max_total_bytes: Keyword.get(config, :max_total_bytes, 2_147_483_648),
      max_batch_bytes: Keyword.get(config, :max_batch_bytes, 536_870_912),
      max_files: Keyword.get(config, :max_files, 20_000)
    }
  end

  def enqueue(attrs) do
    with {:ok, lease} <- Lease |> Ash.Changeset.for_create(:create, Map.put(attrs, :state, :queued)) |> Ash.create(domain: @domain) do
      Phoenix.PubSub.broadcast(Portal.PubSub, @topic, {:lease_queued, lease.id})
      Portal.AdminEvents.broadcast(:builders)
      {:ok, lease}
    end
  end

  def claim(%Builder{id: builder_id, slots: slots}) do
    ms = System.system_time(:millisecond)

    sql = """
    UPDATE builder_leases SET state = 'leased', builder_id = $1, leased_at = now(), heartbeat_at = now(),
      attempt = attempt + 1, phase = NULL, run_id = 'rb-' || package || '-' || version || '-' || $3::text,
      updated_at = now()
    WHERE id = (
      SELECT id FROM builder_leases WHERE state = 'queued' ORDER BY priority ASC, inserted_at ASC
      FOR UPDATE SKIP LOCKED LIMIT 1)
    AND (SELECT count(*) FROM builder_leases WHERE builder_id = $1 AND state IN ('leased', 'uploading')) < $2
    RETURNING id
    """

    case Repo.query!(sql, [Ecto.UUID.dump!(builder_id), slots, Integer.to_string(ms)]) do
      %{rows: [[id]]} ->
        lease = Ash.get!(Lease, Ecto.UUID.load!(id), domain: @domain)
        Portal.AdminEvents.broadcast(:builders)
        {:ok, lease}

      %{rows: []} ->
        :none
    end
  end

  def claim_or_wait(builder, timeout_ms) do
    subscribe()

    result =
      case claim(builder) do
        {:ok, lease} ->
          {:ok, lease}

        :none ->
          receive do
            {:lease_queued, _id} -> claim(builder)
          after
            timeout_ms -> :none
          end
      end

    Phoenix.PubSub.unsubscribe(Portal.PubSub, @topic)
    drain()
    result
  end

  defp drain do
    receive do
      {:lease_queued, _} -> drain()
    after
      0 -> :ok
    end
  end

  def held(lease_id, builder_id) do
    with {:ok, id} <- Ecto.UUID.cast(lease_id),
         %Lease{builder_id: ^builder_id, state: state} = lease when state in [:leased, :uploading] <-
           Ash.get!(Lease, id, domain: @domain, error?: false) do
      {:ok, lease}
    else
      _ -> {:error, :not_held}
    end
  end

  def heartbeat(lease_id, builder_id, phase, log_tail) do
    with {:ok, lease} <- held(lease_id, builder_id) do
      phase = if phase in @phases, do: phase, else: "building"
      tail = if is_binary(log_tail), do: binary_part(log_tail, max(byte_size(log_tail) - @log_tail_bytes, 0), min(byte_size(log_tail), @log_tail_bytes)), else: nil
      state = if phase == "uploading", do: :uploading, else: lease.state

      with {:ok, lease} <- update(lease, %{heartbeat_at: DateTime.utc_now(), phase: phase, log_tail: tail, state: state}) do
        Progress.broadcast(lease.scan_request_id, :building, %{remote: true, phase: phase})
        {:ok, lease}
      end
    end
  end

  def complete(%Lease{} = lease, 0) do
    with {:ok, lease} <- update(lease, %{state: :done, phase: nil}), do: {:ok, :done, lease}
  end

  def complete(%Lease{} = lease, 11) do
    with {:ok, lease} <- update(lease, %{state: :failed, error: "non-Hex dep"}) do
      Progress.mark(lease.scan_request_id, :rejected, error_reason: "non-Hex dep")
      Progress.broadcast(lease.scan_request_id, :rejected, %{reason: "non-Hex dep"})
      {:ok, :rejected, lease}
    end
  end

  def complete(%Lease{} = lease, exit_code), do: retry_or_fail(lease, "worker/runner exit #{exit_code}")

  defp retry_or_fail(%Lease{attempt: attempt, max_attempts: max} = lease, reason) when attempt < max do
    with {:ok, lease} <- update(lease, %{state: :queued, builder_id: nil, leased_at: nil, heartbeat_at: nil, phase: nil, error: reason}) do
      Phoenix.PubSub.broadcast(Portal.PubSub, @topic, {:lease_queued, lease.id})
      {:ok, :requeued, lease}
    end
  end

  defp retry_or_fail(lease, reason) do
    with {:ok, lease} <- update(lease, %{state: :failed, error: reason}) do
      Progress.mark(lease.scan_request_id, :error, error_reason: reason, error_log: lease.log_tail)
      Progress.broadcast(lease.scan_request_id, :error, %{reason: reason})
      {:ok, :failed, lease}
    end
  end

  def requeue(%Lease{} = lease) do
    with {:ok, lease} <- update(lease, %{state: :queued, builder_id: nil, leased_at: nil, heartbeat_at: nil, phase: nil, attempt: 0, error: nil}) do
      Phoenix.PubSub.broadcast(Portal.PubSub, @topic, {:lease_queued, lease.id})
      {:ok, lease}
    end
  end

  def add_bytes(%Lease{} = lease, n), do: update(lease, %{bytes_uploaded: lease.bytes_uploaded + n})

  def reap(now \\ DateTime.utc_now()) do
    leased_cutoff = DateTime.add(now, -@leased_silence_minutes, :minute)
    ceiling = DateTime.add(now, -@lease_ceiling_minutes, :minute)
    uploading_cutoff = DateTime.add(now, -@uploading_silence_minutes, :minute)

    Lease
    |> Ash.Query.filter(
      (state == :leased and (heartbeat_at < ^leased_cutoff or leased_at < ^ceiling)) or
        (state == :uploading and heartbeat_at < ^uploading_cutoff)
    )
    |> Ash.read!(domain: @domain)
    |> Enum.reduce(%{requeued: 0, failed: 0}, fn lease, acc ->
      case retry_or_fail(lease, "builder went silent") do
        {:ok, :requeued, _} -> Map.update!(acc, :requeued, &(&1 + 1))
        {:ok, :failed, _} -> Map.update!(acc, :failed, &(&1 + 1))
        {:error, reason} -> (Logger.error("reaper could not update lease #{lease.id}: #{inspect(reason)}"); acc)
      end
    end)
  end

  def counts do
    Repo.all(from(l in "builder_leases", group_by: l.state, select: {l.state, count()}))
    |> Map.new(fn {state, n} -> {String.to_existing_atom(state), n} end)
    |> then(&Map.merge(%{queued: 0, leased: 0, uploading: 0, done: 0, failed: 0}, &1))
  end

  def recent(limit \\ 50), do: Lease |> Ash.Query.sort(inserted_at: :desc) |> Ash.Query.limit(limit) |> Ash.read!(domain: @domain)
  def open, do: Lease |> Ash.Query.filter(state in [:queued, :leased, :uploading]) |> Ash.Query.sort(priority: :asc, inserted_at: :asc) |> Ash.read!(domain: @domain)
  def failed, do: Lease |> Ash.Query.filter(state == :failed) |> Ash.Query.sort(updated_at: :desc) |> Ash.read!(domain: @domain)

  defp update(lease, attrs) do
    with {:ok, lease} <- lease |> Ash.Changeset.for_update(:update, attrs) |> Ash.update(domain: @domain) do
      Portal.AdminEvents.broadcast(:builders)
      {:ok, lease}
    end
  end
end
```

`retry_or_fail/2` for the reaper keeps `attempt` (the claim incremented it), which is the spec's rule; `complete/2` with a failing exit also keeps it. `Progress.mark/3` is a no-op for a nil request id.

- [ ] **Step 5: Implement `Portal.Workers.RemoteBuild` and the controller actions**

```elixir
defmodule Portal.Workers.RemoteBuild do
  @moduledoc """
  Oban worker (queue `:remote`, web host) that turns a build job into a
  `builder_leases` row for a remote builder to claim. It never runs Docker:
  the lease table is the remote queue, and `Portal.Workers.Ingest` with
  `source: "remote"` finishes the job once the builder has uploaded.
  """
  use Oban.Worker,
    queue: :remote,
    max_attempts: 3,
    unique: [period: 60, fields: [:worker, :queue, :args], keys: [:package, :version, :image_digest, :force, :scan_request_id, :scope, :systems]]

  require Ash.Query
  require Logger

  alias Portal.Builders.{Images, Leases}
  alias Portal.Catalog.{Run, ToolingSkip}
  alias Portal.Workers.{Build, Progress}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, priority: priority, attempt: attempt, max_attempts: max}) do
    package = args["package"]
    version = args["version"]
    scan_request_id = args["scan_request_id"]
    force = args["force"] == true

    cond do
      ToolingSkip.tooling?(package) ->
        case ToolingSkip.record(package, version, scan_request_id) do
          {:ok, run} ->
            Progress.mark(scan_request_id, :built, run_id: run.id)
            Progress.broadcast(scan_request_id, :done, %{run_id: run.id, status: run.overall_status})
            :ok

          {:error, reason} ->
            if attempt >= max, do: Progress.mark(scan_request_id, :error, error_reason: "tooling skip failed: #{inspect(reason)}")
            {:error, reason}
        end

      true ->
        case Images.worker_image() do
          nil ->
            Logger.error("RemoteBuild for #{package} #{version}: no registry image in images.json")
            Progress.mark(scan_request_id, :error, error_reason: "no registry image for remote build")
            Progress.broadcast(scan_request_id, :error, %{reason: "no registry image"})
            {:cancel, :no_registry_image}

          %{name: name, digest: digest} ->
            if not force and run_exists?(package, version, digest) do
              Progress.mark(scan_request_id, :built)
              Progress.broadcast(scan_request_id, :done, %{deduped: true})
              :ok
            else
              scope = Build.scope_args(package, version, args)

              lease_args = %{
                "systems_filter" => scope.systems_filter,
                "mode" => scope.mode,
                "argus" => Portal.Settings.worker_argus(Portal.Settings.get()),
                "force" => force
              }

              with {:ok, _lease} <- Leases.enqueue(%{package: package, version: version, image_name: name, image_digest: digest, args: lease_args, scan_request_id: scan_request_id, priority: priority}) do
                Progress.broadcast(scan_request_id, :queued, %{remote: true})
                :ok
              end
            end
        end
    end
  end

  defp run_exists?(package, version, digest) do
    Run
    |> Ash.Query.filter(version_tested == ^version and image_digest == ^digest and package.name == ^package)
    |> Ash.read!(domain: Portal.Catalog)
    |> Enum.any?()
  end
end
```

Controller:

```elixir
defmodule PortalWeb.Builder.JobController do
  use PortalWeb, :controller

  alias Portal.Builders
  alias Portal.Builders.{Images, Leases, RateLimit, WarmAllowlist}

  @claims_per_minute 60

  def claim(conn, params) do
    builder = conn.assigns.builder

    cond do
      not RateLimit.allow?({:claim, builder.id}, @claims_per_minute, :timer.minutes(1)) ->
        error(conn, 429, "rate_limited")

      params["egress"] != "ok" ->
        {:ok, _} = Builders.set_egress(builder, "missing")
        error(conn, 409, "egress_missing")

      free_slots(params) < 1 ->
        send_resp(conn, 204, "")

      true ->
        {:ok, _} = Builders.set_egress(builder, "ok")

        case Leases.claim_or_wait(builder, Leases.long_poll_ms()) do
          :none -> send_resp(conn, 204, "")
          {:ok, lease} -> json(conn, claim_body(lease))
        end
    end
  end

  defp claim_body(lease) do
    input =
      Portal.Builder.worker_input(%{
        run_id: lease.run_id,
        image_name: lease.image_name,
        image_digest: lease.image_digest,
        package: %{"name" => lease.package, "version" => lease.version, "source" => "hex"},
        systems_filter: lease.args["systems_filter"],
        mode: lease.args["mode"],
        argus: lease.args["argus"]
      })

    agent = Images.agent()

    %{
      lease_id: lease.id,
      run_id: lease.run_id,
      image: %{name: lease.image_name, digest: lease.image_digest},
      input: input,
      timeout_sec: div(Portal.Builder.total_timeout_ms(), 1000),
      upload: Leases.upload_caps(),
      min_agent_version: agent && agent.version,
      agent_releases: (agent && agent.releases) || %{},
      warm_allowlist: WarmAllowlist.names(),
      egress_required: true
    }
  end

  def heartbeat(conn, %{"lease_id" => id} = params) do
    case Leases.heartbeat(id, conn.assigns.builder.id, params["phase"], params["log_tail"]) do
      {:ok, _lease} -> json(conn, %{ok: true})
      {:error, :not_held} -> error(conn, 409, "lease_not_held")
    end
  end

  defp free_slots(%{"free_slots" => n}) when is_integer(n), do: n
  defp free_slots(_), do: 1

  defp error(conn, status, reason), do: conn |> put_status(status) |> json(%{error: reason})
end
```

`Portal.Builders.WarmAllowlist.names/0` returns a sorted list of the official Nerves system and toolchain package names (read `apps/portal/lib/portal/catalog/tooling_skip.ex`; if it exports its lists, use them, otherwise copy its `nerves_system_*`, kiosk and `nerves_toolchain_*` names into a module attribute with a comment pointing at `ToolingSkip` as the source). Routes under `:builder_api`: `post "/jobs/claim", JobController, :claim` and `post "/jobs/:lease_id/heartbeat", JobController, :heartbeat`. `Portal.AdminEvents`: add `builders: "admin:builders"`. `config/runtime.exs`: default queues `[builds: 1, ingest: 2, intake: 5, maintenance: 1, toolchain: 1, remote: 2]`.

- [ ] **Step 6: Run the three test files plus `oban_config_test.exs`, expect PASS**

- [ ] **Step 7: Commit**

```bash
git add apps/portal/lib/portal/builders apps/portal/lib/portal/workers/remote_build.ex apps/portal/lib/portal_web/controllers/builder apps/portal/lib/portal_web/builder_router.ex apps/portal/lib/portal/admin_events.ex config/runtime.exs apps/portal/test
git commit -m "Lease remote builds: the :remote queue, atomic claim, heartbeat and reaper rules

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Uploads: `files/missing`, verified tar batches, `complete`

**Files:**
- Create: `apps/portal/lib/portal/builders/tar_stream.ex`, `apps/portal/lib/portal/builders/upload.ex`
- Modify: `apps/portal/lib/portal_web/controllers/builder/job_controller.ex` (`missing/2`, `files/2`, `complete/2`), `apps/portal/lib/portal_web/builder_router.ex`, `apps/portal/config/config.exs` + `test.exs` (`Portal.Builders.Upload` root and caps)
- Test: `apps/portal/test/portal/builders/tar_stream_test.exs`, `apps/portal/test/portal/builders/upload_test.exs`, `apps/portal/test/portal_web/builder/job_controller_upload_test.exs`

**Interfaces:**
- `Portal.Builders.TarStream`: a streaming ustar reader for plain tars whose entries are regular files. `new(callbacks)` where callbacks is a map `%{start: (name, size -> {:ok, acc} | {:skip, reason}), data: (acc, bin -> acc), finish: (acc -> any)}`; `feed(state, chunk) :: {:ok, state} | {:error, reason}`; `finish(state) :: {:ok, results :: [any]} | {:error, :truncated}`. Only typeflag `"0"` and `"\0"` entries are accepted; any other typeflag (symlink, directory, pax header, long name) returns `{:error, {:unsupported_entry, name}}`. Two zero blocks end the archive; trailing bytes after them are ignored. Names are the 100-byte field trimmed at the first NUL (prefix field must be empty, else `{:error, {:unsupported_entry, name}}`).
- `Portal.Builders.Upload`: `root/0` (config `:portal, Portal.Builders.Upload, root:`, default `~/.ncc-uploads`, test tmp), `caps/0` = `Leases.upload_caps/0` plus `max_result_bytes: 8_388_608`, `max_logs_bytes: 67_108_864`; `lease_dir(lease_id)`, `files_dir(lease_id)`, `out_dir(lease_id)`; `missing(lease_id, shas) :: {:ok, [sha]} | {:error, :too_many | :invalid_sha}` (filters `ArtifactStore.present?/1` and `<files_dir>/<sha>` regular files; refuses more than `max_files`); `receive_batch(lease, read_chunk, opts) :: {:ok, %{stored: [sha], bad: [sha], bytes: n}} | {:error, :batch_too_large | :total_exceeded | :insufficient_disk | {:unsupported_entry, name} | :truncated}` where `read_chunk` is `(-> {:ok, bin} | {:more, bin} | :done)` style function the controller builds over `Plug.Conn.read_body/2`, and `opts` has `:content_length`; each entry: name must match `~r/\A[0-9a-f]{64}\z/` else the whole batch is `{:error, {:unsupported_entry, name}}`; size over `max_file_bytes` → skip entry, listed under `bad`; bytes stream into `<files_dir>/.incoming-<sha>-<rand>` while hashing; on entry end rename to `<files_dir>/<sha>` when the hash matches, else delete and list under `bad`; `bytes` counts every byte received; refuses up front when `content_length > max_batch_bytes` (`:batch_too_large`), when `lease.bytes_uploaded + content_length > max_total_bytes` (`:total_exceeded`), or when `Portal.Builder.free_bytes(root()) < Portal.Builder.min_free_bytes()` (`:insufficient_disk`; nil free bytes passes, like `check_free_space`); `write_outputs(lease_id, %{result: Plug.Upload.t(), logs: Plug.Upload.t() | nil, runner_log: Plug.Upload.t() | nil}) :: :ok | {:error, :result_too_large | :result_unparsable | :logs_too_large | :logs_invalid}` — copies `result.json` to `<out>/result.json` after `Jason.decode` succeeds, extracts `logs.tar.gz` entries named `*.log` (no `/`) into `<out>/logs/` via `:erl_tar.extract(path, [:compressed, {:cwd, logs_dir}, {:files, names}])` after `:erl_tar.table(path, [:compressed])` filtered to acceptable names (anything else in the table → `:logs_invalid`), copies `runner.log` to `<out>/runner.log`; `load_run(lease_id) :: {:ok, Portal.Builder.build_result()} | {:error, :missing_result_json}` — same shape as `Portal.Builder.load_run/1` (`exit_code: 0`, `result`, `files_dir`, `output_dir`, `log` = last 1 MiB of `runner.log`, `""` when absent); `cleanup(lease_id) :: :ok`.
- Controller: `missing/2` body `{"shas": [...]}` → 200 `{"missing": [...]}`, 409 `lease_not_held`, 422 `too_many_files` / `invalid_sha`; `files/2` (PUT, `Content-Type: application/x-tar`, `Content-Length` required) → 200 `{"stored": [...], "bad": [], "bytes": n}`, 422 `{"error":"bad_entries","bad":[...]}` when `bad != []` (the good ones are kept), 413 `batch_too_large` / `total_exceeded`, 507 `insufficient_disk`, 409 `lease_not_held`, 400 `missing_content_length` / `unsupported_entry` / `truncated`; `complete/2` multipart parts `result` (file), `logs` (file, optional), `runner_log` (file, optional), `exit_code` (string) → 202 `{"accepted": true, "outcome": "done"|"requeued"|"failed"|"rejected"}`, 409 `lease_not_held`, 422 `result_unparsable`, 413 `result_too_large`/`logs_too_large`. On `:done` it enqueues `Portal.Workers.Ingest` with `%{"source" => "remote", "lease_id" => lease.id, "run_id" => lease.run_id, "image_digest" => lease.image_digest, "scan_request_id" => lease.scan_request_id, "builder_id" => builder.id}` on queue `:remote` (`Ingest.new(args, queue: :remote)`), and broadcasts `Progress.broadcast(scan_request_id, :ingesting, %{run_id: lease.run_id})`; on any other outcome it calls `Upload.cleanup(lease.id)`. Every call first does `Leases.held(lease_id, builder.id)`; `files` and `complete` also heartbeat (`Leases.heartbeat(..., "uploading", nil)`) so the lease is `:uploading` while bytes flow.
- Routes under `:builder_api`: `post "/jobs/:lease_id/files/missing", JobController, :missing`, `put "/jobs/:lease_id/files", JobController, :files`, `post "/jobs/:lease_id/complete", JobController, :complete`.

- [ ] **Step 1: Write the failing `TarStream` test**

```elixir
defmodule Portal.Builders.TarStreamTest do
  use ExUnit.Case, async: true

  alias Portal.Builders.TarStream

  defp tar(entries) do
    dir = Path.join(System.tmp_dir!(), "tar-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    files = for {name, bytes} <- entries do
      path = Path.join(dir, name)
      File.write!(path, bytes)
      {String.to_charlist(name), String.to_charlist(path)}
    end
    out = Path.join(dir, "out.tar")
    :ok = :erl_tar.create(String.to_charlist(out), files)
    bin = File.read!(out)
    File.rm_rf!(dir)
    bin
  end

  defp collect(bin, chunk) do
    callbacks = %{
      start: fn name, size -> {:ok, {name, size, []}} end,
      data: fn {name, size, acc}, data -> {name, size, [data | acc]} end,
      finish: fn {name, size, acc} -> {name, size, acc |> Enum.reverse() |> IO.iodata_to_binary()} end
    }

    bin
    |> :binary.bin_to_list()
    |> Enum.chunk_every(chunk)
    |> Enum.map(&:binary.list_to_bin/1)
    |> Enum.reduce_while({:ok, TarStream.new(callbacks)}, fn piece, {:ok, state} ->
      case TarStream.feed(state, piece) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, state} -> TarStream.finish(state)
      error -> error
    end
  end

  test "reads erl_tar output entry by entry whatever the chunking" do
    bin = tar([{"aa", "hello"}, {"bb", String.duplicate("x", 1000)}, {"cc", ""}])

    for chunk <- [1, 7, 512, 513, 4096, byte_size(bin)] do
      assert {:ok, [{"aa", 5, "hello"}, {"bb", 1000, _}, {"cc", 0, ""}]} = collect(bin, chunk)
    end
  end

  test "a skipped entry's bytes are not delivered" do
    bin = tar([{"skip", "zzz"}, {"keep", "k"}])
    callbacks = %{start: fn "skip", _ -> {:skip, :nope}; name, size -> {:ok, {name, size}} end, data: fn acc, _ -> acc end, finish: fn acc -> acc end}
    state = TarStream.new(callbacks)
    {:ok, state} = TarStream.feed(state, bin)
    assert {:ok, [{:skipped, "skip", :nope}, {"keep", 1}]} = TarStream.finish(state)
  end

  test "symlinks, directories and long names are refused" do
    dir = Path.join(System.tmp_dir!(), "tar-link-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "target"), "t")
    File.ln_s!("target", Path.join(dir, "link"))
    out = Path.join(dir, "out.tar")
    :ok = :erl_tar.create(String.to_charlist(out), [{~c"link", String.to_charlist(Path.join(dir, "link"))}], [:dereference] |> Enum.reject(&(&1 == :dereference)))
    bin = File.read!(out)
    File.rm_rf!(dir)
    assert {:error, {:unsupported_entry, "link"}} = collect(bin, 512)

    long = tar([{String.duplicate("n", 120), "x"}])
    assert {:error, {:unsupported_entry, _}} = collect(long, 512)
  end

  test "a truncated archive is reported" do
    bin = tar([{"aa", String.duplicate("y", 2000)}])
    assert {:error, :truncated} = collect(binary_part(bin, 0, 1024), 512)
  end
end
```

(`:erl_tar.create/2` without `:dereference` stores the symlink as a link entry; drop the odd `Enum.reject` and pass `[]`.)

- [ ] **Step 2: Write the failing `Upload` and controller tests**

`upload_test.exs`:

```elixir
defmodule Portal.Builders.UploadTest do
  use Portal.DataCase, async: false

  alias Portal.ArtifactStore
  alias Portal.Builders.{Lease, Leases, Upload}

  setup do
    root = Path.join(System.tmp_dir!(), "uploads-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:portal, Upload, [])
    Application.put_env(:portal, Upload, Keyword.merge(previous, root: root, max_file_bytes: 1000, max_total_bytes: 5000, max_batch_bytes: 4096))
    on_exit(fn -> Application.put_env(:portal, Upload, previous); File.rm_rf(root) end)
    {:ok, lease} = Leases.enqueue(%{package: "jason", version: "1.4.4", image_name: "i", image_digest: "sha256:d", args: %{}, scan_request_id: nil, priority: 5})
    %{lease: lease}
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp tar(entries) do
    dir = Path.join(System.tmp_dir!(), "utar-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    files = for {name, bytes} <- entries, do: (File.write!(Path.join(dir, name), bytes); {String.to_charlist(name), String.to_charlist(Path.join(dir, name))})
    out = Path.join(dir, "b.tar")
    :ok = :erl_tar.create(String.to_charlist(out), files)
    bin = File.read!(out)
    File.rm_rf!(dir)
    bin
  end

  defp reader(bin, chunk \\ 700) do
    {:ok, agent} = Agent.start_link(fn -> bin end)
    fn ->
      Agent.get_and_update(agent, fn
        "" -> {:done, ""}
        rest when byte_size(rest) <= chunk -> {{:ok, rest}, ""}
        rest -> {{:more, binary_part(rest, 0, chunk)}, binary_part(rest, chunk, byte_size(rest) - chunk)}
      end)
    end
  end

  test "missing filters the store and the lease's own files", %{lease: lease} do
    present = sha("already")
    tmp = Path.join(System.tmp_dir!(), present)
    File.write!(tmp, "already")
    {:ok, _} = ArtifactStore.put(present, tmp)
    mine = sha("mine")
    File.mkdir_p!(Upload.files_dir(lease.id))
    File.write!(Path.join(Upload.files_dir(lease.id), mine), "mine")
    wanted = sha("wanted")
    assert {:ok, [^wanted]} = Upload.missing(lease.id, [present, mine, wanted])
    assert {:error, :invalid_sha} = Upload.missing(lease.id, ["../x"])
    Application.put_env(:portal, Upload, Keyword.put(Application.get_env(:portal, Upload), :max_files, 2))
    assert {:error, :too_many} = Upload.missing(lease.id, [present, mine, wanted])
  end

  test "a bad sha is discarded, the batch is 422-shaped, the good entry stays", %{lease: lease} do
    good = sha("good bytes")
    bad = sha("something else")
    bin = tar([{good, "good bytes"}, {bad, "not those bytes"}])
    assert {:ok, %{stored: [^good], bad: [^bad], bytes: n}} = Upload.receive_batch(lease, reader(bin), content_length: byte_size(bin))
    assert n == byte_size(bin)
    assert File.read!(Path.join(Upload.files_dir(lease.id), good)) == "good bytes"
    refute File.exists?(Path.join(Upload.files_dir(lease.id), bad))
    assert [] = Path.wildcard(Path.join(Upload.files_dir(lease.id), ".incoming-*"))
    assert Ash.get!(Lease, lease.id, domain: Portal.Builders).bytes_uploaded == n
  end

  test "an entry that is not a sha refuses the batch; a too-large entry is bad, not fatal", %{lease: lease} do
    bin = tar([{"README", "x"}])
    assert {:error, {:unsupported_entry, "README"}} = Upload.receive_batch(lease, reader(bin), content_length: byte_size(bin))
    big = String.duplicate("b", 1500)
    bin = tar([{sha(big), big}, {sha("ok"), "ok"}])
    assert {:ok, %{stored: [_], bad: [_]}} = Upload.receive_batch(lease, reader(bin), content_length: byte_size(bin))
  end

  test "batch and total caps and the free-space floor are enforced before reading", %{lease: lease} do
    assert {:error, :batch_too_large} = Upload.receive_batch(lease, reader(""), content_length: 5000)
    {:ok, lease} = Leases.add_bytes(lease, 4900)
    assert {:error, :total_exceeded} = Upload.receive_batch(lease, reader(""), content_length: 200)
    previous = Application.get_env(:portal, Portal.Builder, [])
    Application.put_env(:portal, Portal.Builder, Keyword.put(previous, :min_free_disk_gb, 1_000_000))
    on_exit(fn -> Application.put_env(:portal, Portal.Builder, previous) end)
    assert {:error, :insufficient_disk} = Upload.receive_batch(lease, reader(""), content_length: 10)
  end

  test "a re-sent batch is idempotent", %{lease: lease} do
    good = sha("twice")
    bin = tar([{good, "twice"}])
    assert {:ok, %{stored: [^good]}} = Upload.receive_batch(lease, reader(bin), content_length: byte_size(bin))
    assert {:ok, %{stored: [^good]}} = Upload.receive_batch(Ash.get!(Lease, lease.id, domain: Portal.Builders), reader(bin), content_length: byte_size(bin))
    assert {:ok, []} = Upload.missing(lease.id, [good])
  end

  test "outputs are written and loaded in Portal.Builder.load_run/1's shape", %{lease: lease} do
    dir = Path.join(System.tmp_dir!(), "parts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "logs"))
    File.write!(Path.join(dir, "result.json"), ~s({"run_id":"rb-1","systems":{}}))
    File.write!(Path.join(dir, "logs/host.log"), "host log")
    File.write!(Path.join(dir, "logs/evil"), "nope")
    File.write!(Path.join(dir, "runner.log"), "runner says hi")
    :ok = :erl_tar.create(String.to_charlist(Path.join(dir, "logs.tar.gz")), [{~c"host.log", String.to_charlist(Path.join(dir, "logs/host.log"))}], [:compressed])
    :ok = :erl_tar.create(String.to_charlist(Path.join(dir, "bad.tar.gz")), [{~c"evil", String.to_charlist(Path.join(dir, "logs/evil"))}], [:compressed])
    upload = fn name -> %Plug.Upload{path: Path.join(dir, name), filename: name, content_type: "application/octet-stream"} end

    assert {:error, :logs_invalid} = Upload.write_outputs(lease.id, %{result: upload.("result.json"), logs: upload.("bad.tar.gz"), runner_log: nil})
    assert :ok = Upload.write_outputs(lease.id, %{result: upload.("result.json"), logs: upload.("logs.tar.gz"), runner_log: upload.("runner.log")})
    assert {:ok, %{exit_code: 0, result: %{"run_id" => "rb-1"}, files_dir: files, output_dir: out, log: "runner says hi"}} = Upload.load_run(lease.id)
    assert files == Upload.files_dir(lease.id) and File.read!(Path.join(out, "logs/host.log")) == "host log"
    File.write!(Path.join(dir, "result.json"), "{nope")
    assert {:error, :result_unparsable} = Upload.write_outputs(lease.id, %{result: upload.("result.json"), logs: nil, runner_log: nil})
    assert :ok = Upload.cleanup(lease.id)
    refute File.exists?(Upload.lease_dir(lease.id))
    assert {:error, :missing_result_json} = Upload.load_run(lease.id)
  end
end
```

`job_controller_upload_test.exs`:

```elixir
defmodule PortalWeb.Builder.JobControllerUploadTest do
  use PortalWeb.BuilderConnCase, async: false
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Builders.{Lease, Leases, Upload}

  setup do
    root = Path.join(System.tmp_dir!(), "uploads-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:portal, Upload, [])
    Application.put_env(:portal, Upload, Keyword.put(previous, :root, root))
    Application.put_env(:portal, Leases, long_poll_ms: 50)
    on_exit(fn -> Application.put_env(:portal, Upload, previous); Application.delete_env(:portal, Leases); File.rm_rf(root) end)
    %{builder: builder, cert_der: der} = enrolled_builder!("u1")
    {:ok, request} = Portal.ScanRequests.create_once(%{package_name: "jason", version: "1.4.4", source: :hex_owner, status: :accepted})
    {:ok, lease} = Leases.enqueue(%{package: "jason", version: "1.4.4", image_name: "i", image_digest: "sha256:#{String.duplicate("c", 64)}", args: %{}, scan_request_id: request.id, priority: 5})
    {:ok, lease} = Leases.claim(builder)
    %{der: der, lease: lease, builder: builder, request: request}
  end

  defp sha(b), do: :crypto.hash(:sha256, b) |> Base.encode16(case: :lower)

  defp tar(entries) do
    dir = Path.join(System.tmp_dir!(), "ctar-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    files = for {name, bytes} <- entries, do: (File.write!(Path.join(dir, name), bytes); {String.to_charlist(name), String.to_charlist(Path.join(dir, name))})
    :ok = :erl_tar.create(String.to_charlist(Path.join(dir, "b.tar")), files)
    bin = File.read!(Path.join(dir, "b.tar"))
    File.rm_rf!(dir)
    bin
  end

  defp put_tar(conn, der, lease_id, bin) do
    conn |> with_cert(der) |> put_req_header("content-type", "application/x-tar") |> put_req_header("content-length", Integer.to_string(byte_size(bin))) |> put("/builder/v1/jobs/#{lease_id}/files", bin)
  end

  test "missing, upload and complete hand the run to Ingest on the remote queue", %{conn: conn, der: der, lease: lease, builder: builder} do
    good = sha("beam")
    assert %{"missing" => [^good]} = conn |> with_cert(der) |> post("/builder/v1/jobs/#{lease.id}/files/missing", %{"shas" => [good]}) |> json_response(200)
    assert %{"stored" => [^good], "bad" => []} = put_tar(conn, der, lease.id, tar([{good, "beam"}])) |> json_response(200)
    assert Ash.get!(Lease, lease.id, domain: Portal.Builders).state == :uploading

    result = Jason.encode!(%{"run_id" => lease.run_id, "package" => %{"name" => "jason", "version" => "1.4.4"}, "systems" => %{"host" => %{"status" => "pass"}}})
    result_path = Path.join(System.tmp_dir!(), "result-#{System.unique_integer([:positive])}.json")
    File.write!(result_path, result)

    conn = conn |> with_cert(der) |> post("/builder/v1/jobs/#{lease.id}/complete", %{"exit_code" => "0", "result" => %Plug.Upload{path: result_path, filename: "result.json", content_type: "application/json"}})
    assert %{"accepted" => true, "outcome" => "done"} = json_response(conn, 202)

    assert [job] = all_enqueued(worker: Portal.Workers.Ingest)
    assert job.queue == "remote"
    assert job.args["source"] == "remote" and job.args["lease_id"] == lease.id and job.args["builder_id"] == builder.id and job.args["run_id"] == lease.run_id
    assert File.exists?(Path.join(Upload.out_dir(lease.id), "result.json"))
  end

  test "a bad entry answers 422 and keeps the good one", %{conn: conn, der: der, lease: lease} do
    good = sha("g")
    bad = sha("b")
    assert %{"error" => "bad_entries", "bad" => [^bad]} = put_tar(conn, der, lease.id, tar([{good, "g"}, {bad, "x"}])) |> json_response(422)
    assert File.exists?(Path.join(Upload.files_dir(lease.id), good))
  end

  test "another builder gets 409 everywhere", %{conn: conn, lease: lease} do
    %{cert_der: other} = enrolled_builder!("u2")
    assert conn |> with_cert(other) |> post("/builder/v1/jobs/#{lease.id}/files/missing", %{"shas" => []}) |> json_response(409)
    assert put_tar(conn, other, lease.id, tar([])) |> json_response(409)
    assert conn |> with_cert(other) |> post("/builder/v1/jobs/#{lease.id}/complete", %{"exit_code" => "0"}) |> json_response(409)
  end

  test "a failing exit requeues and cleans up; a policy exit rejects the request", %{conn: conn, der: der, lease: lease, request: request} do
    File.mkdir_p!(Upload.files_dir(lease.id))
    assert %{"outcome" => "requeued"} = conn |> with_cert(der) |> post("/builder/v1/jobs/#{lease.id}/complete", %{"exit_code" => "10"}) |> json_response(202)
    refute File.exists?(Upload.lease_dir(lease.id))
    assert [] = all_enqueued(worker: Portal.Workers.Ingest)

    {:ok, lease} = Leases.claim(Portal.Builders.get_builder(lease.builder_id || elem(Portal.Builders.list_builders() |> List.first() |> then(&{:ok, &1}), 1).id) |> elem(1))
    assert %{"outcome" => "rejected"} = conn |> with_cert(der) |> post("/builder/v1/jobs/#{lease.id}/complete", %{"exit_code" => "11"}) |> json_response(202)
    {:ok, updated} = Portal.ScanRequests.get_request(request.id)
    assert updated.status == :rejected
  end
end
```

(Simplify the last test's re-claim: keep `builder` from setup and call `Leases.claim(builder)` after the requeue.)

- [ ] **Step 3: Run the three files, expect failures**

- [ ] **Step 4: Implement `TarStream`**

```elixir
defmodule Portal.Builders.TarStream do
  @moduledoc """
  A streaming reader for the plain ustar archives the agent uploads: regular
  files only, names in the 100-byte field. Each entry's bytes are handed to
  the caller as they arrive, so a 512 MiB batch never lives in memory and a
  bad entry can be discarded the moment its hash is known. Anything that is
  not a plain file entry refuses the archive.
  """

  @block 512

  defstruct callbacks: nil, buffer: <<>>, mode: :header, entry: nil, remaining: 0, padding: 0, results: [], done: false

  def new(callbacks), do: %__MODULE__{callbacks: callbacks}

  def feed(%__MODULE__{done: true} = state, _chunk), do: {:ok, state}
  def feed(%__MODULE__{} = state, chunk), do: step(%{state | buffer: state.buffer <> chunk})

  def finish(%__MODULE__{done: true, results: results}), do: {:ok, Enum.reverse(results)}
  def finish(%__MODULE__{mode: :header, buffer: buffer, results: results}) when byte_size(buffer) < @block, do: {:ok, Enum.reverse(results)}
  def finish(_state), do: {:error, :truncated}

  defp step(%{mode: :header, buffer: buffer} = state) when byte_size(buffer) >= @block do
    <<header::binary-size(@block), rest::binary>> = buffer

    if header == <<0::size(@block * 8)>> do
      {:ok, %{state | buffer: <<>>, done: true}}
    else
      with {:ok, name, size, typeflag, prefix} <- parse(header),
           :ok <- plain_file(typeflag, prefix, name) do
        padding = rem(@block - rem(size, @block), @block)

        case state.callbacks.start.(name, size) do
          {:ok, acc} ->
            step(%{state | buffer: rest, mode: :data, entry: {name, acc}, remaining: size, padding: padding})

          {:skip, reason} ->
            step(%{state | buffer: rest, mode: :skip, entry: {name, reason}, remaining: size, padding: padding})
        end
      end
    end
  end

  defp step(%{mode: :header} = state), do: {:ok, state}

  defp step(%{mode: mode, remaining: 0, padding: padding, buffer: buffer} = state) when mode in [:data, :skip] do
    if byte_size(buffer) >= padding do
      <<_pad::binary-size(padding), rest::binary>> = buffer
      results = finish_entry(state)
      step(%{state | buffer: rest, mode: :header, entry: nil, padding: 0, results: results})
    else
      {:ok, state}
    end
  end

  defp step(%{mode: mode, buffer: buffer, remaining: remaining} = state) when mode in [:data, :skip] and byte_size(buffer) > 0 do
    take = min(remaining, byte_size(buffer))
    <<data::binary-size(take), rest::binary>> = buffer

    entry =
      case {mode, state.entry} do
        {:data, {name, acc}} -> {name, state.callbacks.data.(acc, data)}
        {:skip, entry} -> entry
      end

    step(%{state | buffer: rest, remaining: remaining - take, entry: entry})
  end

  defp step(state), do: {:ok, state}

  defp finish_entry(%{mode: :data, entry: {_name, acc}, results: results} = state), do: [state.callbacks.finish.(acc) | results]
  defp finish_entry(%{mode: :skip, entry: {name, reason}, results: results}), do: [{:skipped, name, reason} | results]

  defp parse(<<name::binary-size(100), _mode::binary-size(8), _uid::binary-size(8), _gid::binary-size(8), size::binary-size(12), _mtime::binary-size(12), _chksum::binary-size(8), typeflag::binary-size(1), _link::binary-size(100), _magic::binary-size(6), _version::binary-size(2), _uname::binary-size(32), _gname::binary-size(32), _dev::binary-size(16), prefix::binary-size(155), _pad::binary-size(12)>>) do
    with {:ok, size} <- octal(size) do
      {:ok, cstring(name), size, typeflag, cstring(prefix)}
    end
  end

  defp plain_file(flag, "", _name) when flag in ["0", <<0>>], do: :ok
  defp plain_file(_flag, _prefix, name), do: {:error, {:unsupported_entry, name}}

  defp cstring(bin), do: bin |> :binary.split(<<0>>) |> List.first()

  defp octal(field) do
    case field |> cstring() |> String.trim() |> Integer.parse(8) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :bad_size}
    end
  end
end
```

- [ ] **Step 5: Implement `Upload`**

```elixir
defmodule Portal.Builders.Upload do
  @moduledoc """
  Where a remote builder's bytes land before ingest: `<root>/<lease id>/files/`
  (content-addressed, verified on the way in) and `<root>/<lease id>/out/`
  (`result.json`, `logs/`, `runner.log`). `load_run/1` returns exactly what
  `Portal.Builder.load_run/1` returns, so `Portal.Workers.Ingest` runs the same
  ingestion for a remote build as for a local one.
  """
  require Logger

  alias Portal.ArtifactStore
  alias Portal.Builders.{Lease, Leases, TarStream}

  @sha ~r/\A[0-9a-f]{64}\z/
  @log_tail_bytes 1024 * 1024

  def root, do: :portal |> Application.get_env(__MODULE__, []) |> Keyword.get(:root, Path.expand("~/.ncc-uploads"))

  def caps do
    config = Application.get_env(:portal, __MODULE__, [])
    Leases.upload_caps() |> Map.merge(%{max_result_bytes: Keyword.get(config, :max_result_bytes, 8_388_608), max_logs_bytes: Keyword.get(config, :max_logs_bytes, 67_108_864)})
  end

  def lease_dir(lease_id), do: Path.join(root(), lease_name(lease_id))
  def files_dir(lease_id), do: Path.join(lease_dir(lease_id), "files")
  def out_dir(lease_id), do: Path.join(lease_dir(lease_id), "out")

  defp lease_name(lease_id) do
    {:ok, uuid} = Ecto.UUID.cast(lease_id)
    uuid
  end

  def missing(lease_id, shas) when is_list(shas) do
    cond do
      length(shas) > caps().max_files -> {:error, :too_many}
      not Enum.all?(shas, &(is_binary(&1) and Regex.match?(@sha, &1))) -> {:error, :invalid_sha}
      true -> {:ok, Enum.reject(Enum.uniq(shas), fn sha -> ArtifactStore.present?(sha) or local_file?(lease_id, sha) end)}
    end
  end

  def missing(_lease_id, _shas), do: {:error, :invalid_sha}

  # Paths are the configured root, a uuid and a validated sha.
  # sobelow_skip ["Traversal.FileModule"]
  defp local_file?(lease_id, sha), do: match?({:ok, %File.Stat{type: :regular}}, File.lstat(Path.join(files_dir(lease_id), sha)))

  @doc "Receive one tar batch through `read_chunk`, verifying each entry's sha as it is written."
  # sobelow_skip ["Traversal.FileModule"]
  def receive_batch(%Lease{} = lease, read_chunk, opts) do
    caps = caps()
    length = Keyword.fetch!(opts, :content_length)

    cond do
      length > caps.max_batch_bytes -> {:error, :batch_too_large}
      lease.bytes_uploaded + length > caps.max_total_bytes -> {:error, :total_exceeded}
      disk_full?() -> {:error, :insufficient_disk}
      true ->
        dir = files_dir(lease.id)
        File.mkdir_p!(dir)
        state = TarStream.new(callbacks(dir, caps.max_file_bytes))

        with {:ok, state, bytes} <- pump(read_chunk, state, 0),
             {:ok, results} <- TarStream.finish(state) do
          {:ok, _} = Leases.add_bytes(lease, bytes)
          stored = for {:stored, sha} <- results, do: sha
          bad = for {kind, sha, _} <- results, kind in [:bad, :skipped], do: sha
          {:ok, %{stored: stored, bad: Enum.uniq(bad), bytes: bytes}}
        else
          {:error, reason} -> (sweep_incoming(dir); {:error, reason})
        end
    end
  end

  defp pump(read_chunk, state, bytes) do
    case read_chunk.() do
      {:more, chunk} -> with {:ok, state} <- TarStream.feed(state, chunk), do: pump(read_chunk, state, bytes + byte_size(chunk))
      {:ok, chunk} -> with {:ok, state} <- TarStream.feed(state, chunk), do: {:ok, state, bytes + byte_size(chunk)}
      :done -> {:ok, state, bytes}
      {:error, reason} -> {:error, reason}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp callbacks(dir, max_file_bytes) do
    %{
      start: fn name, size ->
        cond do
          not Regex.match?(@sha, name) -> throw({:unsupported_entry, name})
          size > max_file_bytes -> {:skip, :too_large}
          true ->
            tmp = Path.join(dir, ".incoming-#{name}-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}")
            fd = File.open!(tmp, [:write, :binary, :raw])
            {:ok, {name, tmp, fd, :crypto.hash_init(:sha256)}}
        end
      end,
      data: fn {name, tmp, fd, hash}, data ->
        :ok = IO.binwrite(fd, data)
        {name, tmp, fd, :crypto.hash_update(hash, data)}
      end,
      finish: fn {name, tmp, fd, hash} ->
        File.close(fd)
        actual = hash |> :crypto.hash_final() |> Base.encode16(case: :lower)

        if actual == name do
          File.chmod!(tmp, 0o644)
          File.rename!(tmp, Path.join(dir, name))
          {:stored, name}
        else
          File.rm(tmp)
          {:bad, name, :checksum_mismatch}
        end
      end
    }
  end

  # The `throw` above crosses TarStream; catch it at the boundary.
  # sobelow_skip ["Traversal.FileModule"]
  defp sweep_incoming(dir), do: dir |> Path.join(".incoming-*") |> Path.wildcard() |> Enum.each(&File.rm/1)

  defp disk_full? do
    case Portal.Builder.free_bytes(root()) do
      nil -> false
      free -> free < Portal.Builder.min_free_bytes()
    end
  end

  @doc "Write `result.json`, the per-system logs and the runner log for ingest."
  # sobelow_skip ["Traversal.FileModule"]
  def write_outputs(lease_id, %{result: %Plug.Upload{} = result} = parts) do
    caps = caps()
    out = out_dir(lease_id)
    File.mkdir_p!(Path.join(out, "logs"))

    with :ok <- size_ok(result.path, caps.max_result_bytes, :result_too_large),
         {:ok, bytes} <- File.read(result.path),
         {:ok, _} <- decode(bytes),
         :ok <- File.write(Path.join(out, "result.json"), bytes),
         :ok <- write_logs(Map.get(parts, :logs), Path.join(out, "logs"), caps.max_logs_bytes),
         :ok <- write_runner_log(Map.get(parts, :runner_log), Path.join(out, "runner.log")) do
      :ok
    end
  end

  defp decode(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, :result_unparsable}
    end
  end

  defp size_ok(path, max, error) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= max -> :ok
      {:ok, _} -> {:error, error}
      {:error, _} -> {:error, :result_unparsable}
    end
  end

  defp write_logs(nil, _dir, _max), do: :ok

  # sobelow_skip ["Traversal.FileModule"]
  defp write_logs(%Plug.Upload{path: path}, dir, max) do
    with :ok <- size_ok(path, max, :logs_too_large),
         {:ok, entries} <- :erl_tar.table(String.to_charlist(path), [:compressed]),
         names = Enum.map(entries, &to_string/1),
         true <- Enum.all?(names, &Regex.match?(~r/\A[A-Za-z0-9_.\-]+\.log\z/, &1)) || {:error, :logs_invalid},
         :ok <- :erl_tar.extract(String.to_charlist(path), [:compressed, {:cwd, String.to_charlist(dir)}, {:files, Enum.map(names, &String.to_charlist/1)}]) do
      :ok
    else
      {:error, :logs_too_large} -> {:error, :logs_too_large}
      _ -> {:error, :logs_invalid}
    end
  end

  defp write_runner_log(nil, _path), do: :ok
  # sobelow_skip ["Traversal.FileModule"]
  defp write_runner_log(%Plug.Upload{path: src}, dest), do: File.cp(src, dest)

  @doc "The uploaded run in `Portal.Builder.load_run/1`'s shape."
  # sobelow_skip ["Traversal.FileModule"]
  def load_run(lease_id) do
    out = out_dir(lease_id)
    path = Path.join(out, "result.json")

    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, result} <- decode(bytes) do
      {:ok, %{exit_code: 0, result: result, files_dir: files_dir(lease_id), output_dir: out, log: read_tail(Path.join(out, "runner.log"))}}
    else
      _ -> {:error, :missing_result_json}
    end
  end

  defp read_tail(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
         {:ok, fd} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        case :file.pread(fd, max(size - @log_tail_bytes, 0), min(size, @log_tail_bytes)) do
          {:ok, content} -> content
          _ -> ""
        end
      after
        :file.close(fd)
      end
    else
      _ -> ""
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  def cleanup(lease_id) do
    _ = File.rm_rf(lease_dir(lease_id))
    :ok
  end
end
```

In `receive_batch/3`, wrap the `with` in `try ... catch {:unsupported_entry, name} -> sweep_incoming(dir); {:error, {:unsupported_entry, name}}` (the `start` callback throws for a non-sha name so the whole batch is refused, as the spec requires).

Controller additions:

```elixir
  alias Portal.Builders.Upload
  alias Portal.Workers.{Ingest, Progress}

  def missing(conn, %{"lease_id" => id} = params) do
    with {:ok, lease} <- Leases.held(id, conn.assigns.builder.id),
         {:ok, missing} <- Upload.missing(lease.id, params["shas"] || []) do
      json(conn, %{missing: missing})
    else
      {:error, :not_held} -> error(conn, 409, "lease_not_held")
      {:error, :too_many} -> error(conn, 422, "too_many_files")
      {:error, :invalid_sha} -> error(conn, 422, "invalid_sha")
    end
  end

  def files(conn, %{"lease_id" => id}) do
    with {:ok, lease} <- Leases.held(id, conn.assigns.builder.id),
         {:ok, length} <- content_length(conn),
         {:ok, _} <- Leases.heartbeat(lease.id, lease.builder_id, "uploading", nil) do
      reader = body_reader(conn)

      case Upload.receive_batch(lease, reader.read, content_length: length) do
        {:ok, %{bad: []} = summary} -> json(reader.conn.(), summary)
        {:ok, %{bad: bad} = summary} -> reader.conn.() |> put_status(422) |> json(%{error: "bad_entries", bad: bad, stored: summary.stored, bytes: summary.bytes})
        {:error, :batch_too_large} -> error(conn, 413, "batch_too_large")
        {:error, :total_exceeded} -> error(conn, 413, "total_exceeded")
        {:error, :insufficient_disk} -> error(conn, 507, "insufficient_disk")
        {:error, {:unsupported_entry, _name}} -> error(reader.conn.(), 400, "unsupported_entry")
        {:error, :truncated} -> error(reader.conn.(), 400, "truncated")
        {:error, _} -> error(reader.conn.(), 400, "bad_body")
      end
    else
      {:error, :not_held} -> error(conn, 409, "lease_not_held")
      {:error, :missing_content_length} -> error(conn, 400, "missing_content_length")
    end
  end

  # `Plug.Conn.read_body/2` returns a new conn each time; keep it in the
  # process so the response is sent on the conn that finished reading.
  defp body_reader(conn) do
    Process.put(:ncc_upload_conn, conn)

    %{
      read: fn ->
        case Plug.Conn.read_body(Process.get(:ncc_upload_conn), length: 1_048_576, read_length: 262_144, read_timeout: 60_000) do
          {:ok, chunk, conn} -> (Process.put(:ncc_upload_conn, conn); {:ok, chunk})
          {:more, chunk, conn} -> (Process.put(:ncc_upload_conn, conn); {:more, chunk})
          {:error, reason} -> {:error, reason}
        end
      end,
      conn: fn -> Process.get(:ncc_upload_conn) end
    }
  end

  defp content_length(conn) do
    with [value] <- get_req_header(conn, "content-length"), {n, ""} <- Integer.parse(value) do
      {:ok, n}
    else
      _ -> {:error, :missing_content_length}
    end
  end

  def complete(conn, %{"lease_id" => id} = params) do
    builder = conn.assigns.builder

    with {:ok, lease} <- Leases.held(id, builder.id),
         {:ok, exit_code} <- exit_code(params["exit_code"]),
         :ok <- write_outputs(lease, exit_code, params) do
      {:ok, outcome, lease} = Leases.complete(lease, exit_code)

      if outcome == :done do
        args = %{"source" => "remote", "lease_id" => lease.id, "run_id" => lease.run_id, "image_digest" => lease.image_digest, "scan_request_id" => lease.scan_request_id, "builder_id" => builder.id}

        case args |> Ingest.new(queue: :remote) |> Oban.insert() do
          {:ok, _job} -> Progress.broadcast(lease.scan_request_id, :ingesting, %{run_id: lease.run_id})
          {:error, reason} -> (Logger.error("Could not enqueue remote ingest for #{lease.id}: #{inspect(reason)}"); {:ok, _, _} = Leases.complete(lease, 10); Upload.cleanup(lease.id))
        end
      else
        Upload.cleanup(lease.id)
      end

      conn |> put_status(202) |> json(%{accepted: true, outcome: outcome})
    else
      {:error, :not_held} -> error(conn, 409, "lease_not_held")
      {:error, :bad_exit_code} -> error(conn, 400, "bad_exit_code")
      {:error, :result_unparsable} -> error(conn, 422, "result_unparsable")
      {:error, :result_too_large} -> error(conn, 413, "result_too_large")
      {:error, :logs_too_large} -> error(conn, 413, "logs_too_large")
      {:error, :logs_invalid} -> error(conn, 422, "logs_invalid")
    end
  end

  # A failing exit needs no result.json; a success needs one.
  defp write_outputs(_lease, exit_code, _params) when exit_code != 0, do: :ok
  defp write_outputs(lease, 0, %{"result" => %Plug.Upload{} = result} = params), do: Upload.write_outputs(lease.id, %{result: result, logs: upload(params["logs"]), runner_log: upload(params["runner_log"])})
  defp write_outputs(_lease, 0, _params), do: {:error, :result_unparsable}

  defp upload(%Plug.Upload{} = u), do: u
  defp upload(_), do: nil

  defp exit_code(v) when is_integer(v) and v >= 0, do: {:ok, v}
  defp exit_code(v) when is_binary(v), do: (case Integer.parse(v) do {n, ""} when n >= 0 -> {:ok, n}; _ -> {:error, :bad_exit_code} end)
  defp exit_code(_), do: {:error, :bad_exit_code}
```

(Add `require Logger`.) Config: `apps/portal/config/config.exs` `config :portal, Portal.Builders.Upload, root: Path.expand("~/.ncc-uploads")`; `test.exs` `root: Path.join(System.tmp_dir!(), "ncc-test-uploads")`; `config/runtime.exs` `if root = System.get_env("NCC_UPLOAD_ROOT"), do: config(:portal, Portal.Builders.Upload, root: root)`.

- [ ] **Step 6: Run the three test files, expect PASS**

- [ ] **Step 7: Commit**

```bash
git add apps/portal/lib/portal/builders apps/portal/lib/portal_web apps/portal/config config/runtime.exs apps/portal/test
git commit -m "Receive remote build files as verified tar batches and complete leases

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Remote loader in `Ingest`, `builder_id` on runs, publishing gate, `LeaseReaper`

**Files:**
- Modify: `apps/portal/lib/portal/workers/ingest.ex`, `apps/portal/lib/portal/catalog/ingestion.ex` (already writes `builder_id` from Task 5; confirm), `apps/portal/lib/portal/catalog.ex` (`precompiled_runs/1`, `packages_with_precompiled_files/0`), `apps/portal/config/config.exs` (cron entry)
- Create: `apps/portal/lib/portal/workers/lease_reaper.ex`
- Test: `apps/portal/test/portal/workers/ingest_remote_test.exs`, `apps/portal/test/portal/catalog/publishing_gate_test.exs`, `apps/portal/test/portal/workers/lease_reaper_test.exs`, extend `apps/portal/test/portal/oban_config_test.exs`

**Interfaces:**
- `Portal.Workers.Ingest.perform/1` on main already has a first clause for `%{"kind" => "toolchain"}` and a `safe_ingest/3`; leave those as they are. The run clause with `args["source"] == "remote"`: loader `Portal.Builders.Upload.load_run(args["lease_id"])`, `ingest_opts` gains `builder_id: args["builder_id"]`, cleanup is `Upload.cleanup(lease_id)` (both on success and on the last failed attempt), and on `{:error, :missing_result_json}` the lease is marked failed (`Leases.complete(lease, 10)` semantics are wrong here; call `Portal.Builders.Leases.fail(lease, "upload missing")` — add `fail/2`: state `:failed`, error, `Progress.mark(:error)`). Local path unchanged. Refactor: `loader(args)` returns `{load_fun, cleanup_fun}`.
- `Portal.Catalog.precompiled_runs/1` adds `|> Ash.Query.filter(is_nil(builder_id) or (builder.publishing == true and builder.status == :enrolled))` — it feeds both `precompiled_manifest/1` and `precompiled_manifest_v2/1`; grep `catalog.ex` for every other reader of runs for publication (`toolchain_backlog` reads pass runs to decide what to build locally and is deliberately not gated: a remote run is a real verdict). `packages_with_precompiled_files/0` SQL gains `LEFT JOIN builders rb ON rb.id = r.builder_id LEFT JOIN builders bb ON bb.id = b.builder_id` and `AND (r.builder_id IS NULL OR (rb.publishing AND rb.status = 'enrolled')) AND (s.carried_from_run_id IS NULL OR b.builder_id IS NULL OR (bb.publishing AND bb.status = 'enrolled'))`. `revoked_run_ids/1` unchanged (revocation already revokes the runs).
- `Portal.Workers.LeaseReaper`: `use Oban.Worker, queue: :maintenance, max_attempts: 1, unique: [period: :infinity, states: :incomplete]`; `perform/1` logs and returns `:ok` after `Leases.reap/0`. Cron `{"*/5 * * * *", Portal.Workers.LeaseReaper}`, with a comment that it carries `:maintenance` (web host) like `RequestSync`.

- [ ] **Step 1: Write the failing tests**

`ingest_remote_test.exs`:

```elixir
defmodule Portal.Workers.IngestRemoteTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query

  alias Portal.Builders.{Builder, Lease, Leases, Upload}
  alias Portal.Catalog.Run
  alias Portal.Workers.Ingest

  setup do
    root = Path.join(System.tmp_dir!(), "uploads-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:portal, Upload, [])
    Application.put_env(:portal, Upload, Keyword.put(previous, :root, root))
    on_exit(fn -> Application.put_env(:portal, Upload, previous); File.rm_rf(root) end)
    builder = Builder |> Ash.Changeset.for_create(:enrol, %{name: "ing", fingerprint: "fp-ing", cert_pem: "p", cert_expires_at: DateTime.utc_now(), enrolled_at: DateTime.utc_now()}) |> Ash.create!(domain: Portal.Builders)
    {:ok, request} = Portal.ScanRequests.create_once(%{package_name: "jason", version: "1.4.4", source: :hex_owner, status: :accepted})
    {:ok, _} = Leases.enqueue(%{package: "jason", version: "1.4.4", image_name: "i", image_digest: "sha256:#{String.duplicate("e", 64)}", args: %{}, scan_request_id: request.id, priority: 5})
    {:ok, lease} = Leases.claim(builder)
    {:ok, :done, lease} = Leases.complete(lease, 0)
    %{builder: builder, lease: lease, request: request}
  end

  defp seed_outputs!(lease, result) do
    File.mkdir_p!(Upload.files_dir(lease.id))
    File.mkdir_p!(Upload.out_dir(lease.id))
    File.write!(Path.join(Upload.out_dir(lease.id), "result.json"), Jason.encode!(result))
    File.write!(Path.join(Upload.out_dir(lease.id), "runner.log"), "remote runner log")
  end

  defp args(lease, builder), do: %{"source" => "remote", "lease_id" => lease.id, "run_id" => lease.run_id, "image_digest" => lease.image_digest, "scan_request_id" => lease.scan_request_id, "builder_id" => builder.id}

  test "ingests the uploaded run with its builder and cleans the upload dir", %{builder: builder, lease: lease, request: request} do
    sha = :crypto.hash(:sha256, "beam") |> Base.encode16(case: :lower)
    File.mkdir_p!(Upload.files_dir(lease.id))
    File.write!(Path.join(Upload.files_dir(lease.id), sha), "beam")
    result = @fixture_result |> put_in(["run_id"], lease.run_id)
    seed_outputs!(lease, result)

    assert :ok = perform_job(Ingest, args(lease, builder))
    run = Run |> Ash.Query.filter(run_id == ^lease.run_id) |> Ash.read_one!(domain: Portal.Catalog)
    assert run.builder_id == builder.id and run.image_digest == lease.image_digest
    assert run.log == "remote runner log"
    {:ok, updated} = Portal.ScanRequests.get_request(request.id)
    assert updated.status == :built and updated.run_id == run.id
    refute File.exists?(Upload.lease_dir(lease.id))
  end

  test "a missing upload fails the lease and the request", %{builder: builder, lease: lease, request: request} do
    assert {:cancel, _} = perform_job(Ingest, args(lease, builder))
    assert %Lease{state: :failed} = Ash.get!(Lease, lease.id, domain: Portal.Builders)
    {:ok, updated} = Portal.ScanRequests.get_request(request.id)
    assert updated.status == :error
  end

  @fixture_result Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"]) |> File.read!() |> Jason.decode!()
end
```

(Move the `@fixture_result` attribute above its first use.) `result.json`'s fixture `beam_scan` sha is `ce51ace1...` — write that sha's blob into the files dir instead of a fresh one so the artifact is stored; assert `Portal.ArtifactStore.present?/1` on it.

`publishing_gate_test.exs`:

```elixir
defmodule Portal.Catalog.PublishingGateTest do
  use Portal.DataCase, async: false

  alias Portal.Builders
  alias Portal.Builders.Builder
  alias Portal.Catalog

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])
  @sha "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"

  defp builder!(name), do: Builder |> Ash.Changeset.for_create(:enrol, %{name: name, fingerprint: "fp-#{name}", cert_pem: "p", cert_expires_at: DateTime.utc_now(), enrolled_at: DateTime.utc_now()}) |> Ash.create!(domain: Builders)

  defp ingest!(builder_id, run_id) do
    dir = Path.join(System.tmp_dir!(), "gate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, @sha), "precompiled-beam")
    _ = File.rm(Portal.ArtifactStore.blob_path(@sha))
    result = @fixture |> File.read!() |> Jason.decode!() |> Map.put("run_id", run_id)
    {:ok, run} = Catalog.Ingestion.ingest(result, %{run_id: run_id, image_digest: "sha256:#{run_id}", files_dir: dir, builder_id: builder_id})
    run
  end

  test "publication follows the builder's publishing flag" do
    builder = builder!("gate")
    _remote = ingest!(builder.id, "remote-1")
    assert Catalog.precompiled_manifest("jason") == nil
    assert Catalog.packages_with_precompiled_files() == []

    {:ok, _} = Builders.set_publishing(builder, true)
    assert %{versions: %{"1.4.1" => _}} = Catalog.precompiled_manifest("jason")
    assert Catalog.packages_with_precompiled_files() == ["jason"]

    {:ok, _} = Builders.revoke(builder)
    assert Catalog.precompiled_manifest("jason") == nil
  end

  test "a local run of the same package publishes regardless" do
    builder = builder!("gate2")
    _remote = ingest!(builder.id, "remote-2")
    _local = ingest!(nil, "local-1")
    assert %{versions: %{"1.4.1" => _}} = Catalog.precompiled_manifest("jason")
    assert Catalog.packages_with_precompiled_files() == ["jason"]
  end
end
```

`lease_reaper_test.exs`: perform the job with one `:leased` lease silent for 11 minutes and assert it is `:queued` afterwards; assert `Portal.Workers.LeaseReaper.__opts__()[:queue] == :maintenance`. In `oban_config_test.exs` add a test that the cron has `{"*/5 * * * *", Portal.Workers.LeaseReaper}`.

- [ ] **Step 2: Run them, expect failure**

- [ ] **Step 3: Implement**

In `Ingest.perform/1`:

```elixir
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max_attempts}) do
    run_id = args["run_id"]
    image_digest = args["image_digest"]
    scan_request_id = args["scan_request_id"]
    source = source(args)

    with {:ok, run} <- Portal.Catalog.committed_run(run_id) do
      case run do
        nil -> load_and_ingest(source, run_id, image_digest, scan_request_id, attempt, max_attempts)
        run -> complete(source, run, scan_request_id, run.package.name)
      end
    end
  end

  # Where the run's output lives and how to drop it: a local build's scratch
  # dir on this node, or a remote builder's upload dir on the web host.
  defp source(%{"source" => "remote", "lease_id" => lease_id, "builder_id" => builder_id}),
    do: %{kind: :remote, lease_id: lease_id, builder_id: builder_id}

  defp source(_args), do: %{kind: :local}

  defp load(%{kind: :remote, lease_id: lease_id}, _run_id), do: Portal.Builders.Upload.load_run(lease_id)
  defp load(%{kind: :local}, run_id), do: builder().load_run(run_id)

  defp cleanup(%{kind: :remote, lease_id: lease_id}, _run_id), do: Portal.Builders.Upload.cleanup(lease_id)
  defp cleanup(%{kind: :local}, run_id), do: Builder.cleanup(run_id)
```

Thread `source` through `load_and_ingest/6`, `ingest/7` (add `builder_id: Map.get(source, :builder_id)` to `ingest_opts`) and `complete/4` (use `cleanup(source, run.run_id)`). In `load_and_ingest`'s `{:error, reason}` branch for `:remote`, also `Portal.Builders.Leases.fail_by_id(lease_id, "upload missing")` (add to `Leases`: loads the lease, calls the failing update, marks the request). `Ingestion.ingest/2`: confirm `builder_id: Map.get(opts, :builder_id)` is in `create_run/7` and in the `ingest_opts` type.

`Catalog.precompiled_runs/1`: add the filter line after `is_nil(revoked_at)`. `packages_with_precompiled_files/0`: the two `LEFT JOIN`s and the two `AND` clauses above.

`LeaseReaper`:

```elixir
defmodule Portal.Workers.LeaseReaper do
  @moduledoc """
  Every five minutes (`:maintenance`, the web host): a `:leased` lease silent
  for 10 minutes or older than the job timeout plus 30 minutes, or an
  `:uploading` lease silent for 60 minutes, goes back to `:queued`; past
  `max_attempts` it is `:failed` and its request errored. Rows only, so any
  node could run it; the web host's queue keeps it off the build boxes.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1, unique: [period: :infinity, states: :incomplete]

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    %{requeued: requeued, failed: failed} = Portal.Builders.Leases.reap()
    if requeued + failed > 0, do: Logger.info("Lease reaper: requeued #{requeued}, failed #{failed}")
    :ok
  end
end
```

- [ ] **Step 4: Run the new tests plus `catalog_api_controller_test.exs`, `precompiled` tests and `ingest_queue_test.exs`, expect PASS**

Run: `source ~/toolchain/env.sh && mix test apps/portal/test/portal/workers/ingest_remote_test.exs apps/portal/test/portal/catalog/publishing_gate_test.exs apps/portal/test/portal/workers/lease_reaper_test.exs apps/portal/test/portal/oban_config_test.exs apps/portal/test/portal/precompiled apps/portal/test/portal_web/controllers/catalog_api_controller_test.exs apps/portal/test/portal/workers/build_test.exs`

- [ ] **Step 5: Commit**

```bash
git add apps/portal/lib apps/portal/config apps/portal/test
git commit -m "Ingest remote uploads on the web host, gate publication on the builder, reap silent leases

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: `Portal.Builders.Routing`, consulted by every enqueuer

**Files:**
- Create: `apps/portal/lib/portal/builders/routing.ex`
- Modify: `apps/portal/lib/portal/scan_requests.ex` (`insert_build_job/4`), `apps/portal/lib/portal/log_backfill.ex` (`enqueue/2`), `apps/portal/lib/portal/admin.ex` (`@build_worker` → `@build_workers ["Portal.Workers.Build", "Portal.Workers.RemoteBuild"]` in `build_job/1` and `queue_positions/1`), `apps/portal/lib/portal/workers/request_sync.ex` (`@job_workers` gains `Portal.Workers.RemoteBuild`), `apps/portal/lib/portal/bulk_rebuild.ex` (`tally/4` treats `"Portal.Workers.RemoteBuild"` like `Build`)
- Test: `apps/portal/test/portal/builders/routing_test.exs`, plus one assertion in `apps/portal/test/portal/scan_requests` (a request routed remote inserts a `RemoteBuild` job)

**Interfaces:**
- `Portal.Builders.Routing.queue_for(args :: map(), opts :: keyword()) :: :builds | :remote` — `:builds` when `args["mode"] in ["toolchain", "warm_nerves"]` or `get_in(opts, [:meta, :pin_local]) == true` (meta keys may be atoms or strings), when `remote_enabled?/0` is false, when `Images.worker_image/0` is nil, or when `local_backlog/0 <= threshold`; else `:remote`.
- `remote_enabled?/0`: `Settings.get().remote_mode` `:on` → true, `:off` → false, `:auto` → `auto_enabled?/0`: any enrolled builder with `last_seen_at >= now - 5 min` → true (and persist `remote_auto_on: true` when it changed); none within 15 min → false (persist false when changed); otherwise the stored `remote_auto_on`.
- `local_backlog/0`: count of `oban_jobs` with `worker = 'Portal.Workers.Build'`, `queue = 'builds'`, `state in ('available','scheduled','retryable')`.
- `threshold/0`: `Settings.get().remote_backlog_threshold`.
- `build_job(args, opts) :: Oban.Job.changeset()` — `opts` as `Build.new/2` takes (`:priority`, `:meta`, `:scheduled_at`, `:schedule_in`); returns `Portal.Workers.RemoteBuild.new(args, opts)` or `Portal.Workers.Build.new(args, opts)` according to `queue_for/2`. Every enqueuer of `Build` calls this instead of `Build.new/2`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Portal.Builders.RoutingTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Builders.{Builder, Images, Routing}
  alias Portal.Workers.{Build, RemoteBuild}

  setup do
    path = Path.join(System.tmp_dir!(), "images-#{System.unique_integer([:positive])}.json")
    File.write!(path, ~s({"commit":"c","images":{"ncc-worker":{"name":"ghcr.io/x/ncc-worker","tag":"c","digest":"sha256:#{String.duplicate("a", 64)}"}}}))
    previous = Application.get_env(:portal, Images, [])
    Application.put_env(:portal, Images, Keyword.put(previous, :path, path))
    on_exit(fn -> Application.put_env(:portal, Images, previous); File.rm(path) end)
    :ok
  end

  defp seen!(name, minutes_ago) do
    Builder
    |> Ash.Changeset.for_create(:enrol, %{name: name, fingerprint: "fp-#{name}", cert_pem: "p", cert_expires_at: DateTime.utc_now(), enrolled_at: DateTime.utc_now()})
    |> Ash.create!(domain: Portal.Builders)
    |> Ash.Changeset.for_update(:touch, %{last_seen_at: DateTime.add(DateTime.utc_now(), -minutes_ago, :minute)})
    |> Ash.update!(domain: Portal.Builders)
  end

  defp backlog!(n), do: for(i <- 1..n, do: Oban.insert!(Build.new(%{package: "p#{i}", version: "1.0.0"})))

  test "stays local by default and when forced off" do
    assert Routing.queue_for(%{"package" => "jason"}, []) == :builds
    {:ok, _} = Portal.Settings.save(%{remote_mode: :off})
    seen!("a", 1)
    backlog!(12)
    assert Routing.queue_for(%{"package" => "jason"}, []) == :builds
  end

  test "goes remote only above the backlog threshold when a builder is around" do
    {:ok, _} = Portal.Settings.save(%{remote_backlog_threshold: 2})
    seen!("a", 1)
    assert Routing.queue_for(%{"package" => "jason"}, []) == :builds
    backlog!(3)
    assert Routing.queue_for(%{"package" => "jason"}, []) == :remote
    assert Routing.queue_for(%{"package" => "jason"}, meta: %{pin_local: true}) == :builds
    assert Routing.queue_for(%{"package" => "jason", "mode" => "toolchain"}, []) == :builds
    assert Routing.queue_for(%{"package" => "jason", "mode" => "warm_nerves"}, []) == :builds
  end

  test "forced on routes remote with any backlog; no registry image keeps it local" do
    {:ok, _} = Portal.Settings.save(%{remote_mode: :on})
    assert Routing.remote_enabled?()
    backlog!(1)
    {:ok, _} = Portal.Settings.save(%{remote_backlog_threshold: 0})
    assert Routing.queue_for(%{"package" => "jason"}, []) == :remote
    File.rm!(Images.path())
    assert Routing.queue_for(%{"package" => "jason"}, []) == :builds
  end

  test "auto flips on within 5 minutes and off after 15, holding in between" do
    refute Routing.remote_enabled?()
    seen!("a", 1)
    assert Routing.remote_enabled?()
    assert Portal.Settings.get().remote_auto_on
    Portal.Builders.list_builders() |> Enum.each(fn b -> b |> Ash.Changeset.for_update(:touch, %{last_seen_at: DateTime.add(DateTime.utc_now(), -10, :minute)}) |> Ash.update!(domain: Portal.Builders) end)
    assert Routing.remote_enabled?()
    Portal.Builders.list_builders() |> Enum.each(fn b -> b |> Ash.Changeset.for_update(:touch, %{last_seen_at: DateTime.add(DateTime.utc_now(), -16, :minute)}) |> Ash.update!(domain: Portal.Builders) end)
    refute Routing.remote_enabled?()
    refute Portal.Settings.get().remote_auto_on
  end

  test "build_job picks the worker, and every enqueuer goes through it" do
    {:ok, _} = Portal.Settings.save(%{remote_mode: :on, remote_backlog_threshold: 0})
    backlog!(1)
    assert %Ecto.Changeset{changes: %{worker: "Portal.Workers.RemoteBuild", queue: "remote", priority: 2}} = Routing.build_job(%{package: "jason", version: "1.4.4"}, priority: 2)
    {:ok, _} = Portal.ScanRequests.create_once(%{package_name: "jason", version: "1.4.4", source: :hex_owner, status: :accepted})
    assert [_] = all_enqueued(worker: RemoteBuild)
    {:ok, _} = Portal.Settings.save(%{remote_mode: :off})
    {:ok, _} = Portal.ScanRequests.create_once(%{package_name: "decimal", version: "2.0.0", source: :hex_owner, status: :accepted})
    assert [_] = all_enqueued(worker: Build, args: %{package: "decimal"})
  end
end
```

`ScanRequests.create_once/1` resolves the version through `Portal.HexPm` unless `:package_version_resolver` is configured; set `Application.put_env(:portal, :package_version_resolver, StubVersions)` in setup as `Portal.Workers.BuildTest` does.

- [ ] **Step 2: Run, expect failure**

- [ ] **Step 3: Implement `Routing` and rewire the enqueuers**

```elixir
defmodule Portal.Builders.Routing do
  @moduledoc """
  Decides, at enqueue time, whether a build job runs on the local `:builds`
  queue or becomes a remote lease through the `:remote` queue. A job already
  on `:builds` is never moved.

  Local wins whenever remote could not do the job or should not: toolchain
  and warm jobs (they write host caches), jobs pinned local (a revoked
  builder's rebuilds), no builder seen lately, no registry image to name,
  or a local backlog still under the threshold.
  """
  import Ecto.Query, only: [from: 2]
  require Ash.Query

  alias Portal.Builders.{Builder, Images}
  alias Portal.Repo
  alias Portal.Workers.{Build, RemoteBuild}

  @seen_on_minutes 5
  @seen_off_minutes 15
  @local_modes ["toolchain", "warm_nerves"]

  @spec queue_for(map(), keyword()) :: :builds | :remote
  def queue_for(args, opts \\ []) do
    cond do
      mode(args) in @local_modes -> :builds
      pinned?(opts) -> :builds
      not remote_enabled?() -> :builds
      is_nil(Images.worker_image()) -> :builds
      local_backlog() > threshold() -> :remote
      true -> :builds
    end
  end

  @spec build_job(map(), keyword()) :: Ecto.Changeset.t()
  def build_job(args, opts \\ []) do
    case queue_for(stringify(args), opts) do
      :remote -> RemoteBuild.new(args, opts)
      :builds -> Build.new(args, opts)
    end
  end

  def remote_enabled? do
    settings = Portal.Settings.get()

    case settings.remote_mode do
      :on -> true
      :off -> false
      :auto -> auto_enabled?(settings)
    end
  end

  defp auto_enabled?(settings) do
    now = DateTime.utc_now()
    latest = latest_seen()

    decision =
      cond do
        latest && DateTime.diff(now, latest, :minute) < @seen_on_minutes -> true
        is_nil(latest) or DateTime.diff(now, latest, :minute) >= @seen_off_minutes -> false
        true -> settings.remote_auto_on
      end

    if decision != settings.remote_auto_on, do: Portal.Settings.save(%{remote_auto_on: decision})
    decision
  end

  defp latest_seen do
    Builder
    |> Ash.Query.filter(status == :enrolled and not is_nil(last_seen_at))
    |> Ash.Query.sort(last_seen_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(domain: Portal.Builders)
    |> case do
      [%Builder{last_seen_at: seen}] -> seen
      [] -> nil
    end
  end

  def threshold, do: Portal.Settings.get().remote_backlog_threshold

  def local_backlog do
    Repo.one(from(j in "oban_jobs", where: j.worker == "Portal.Workers.Build" and j.queue == "builds" and j.state in ["available", "scheduled", "retryable"], select: count()))
  end

  defp mode(args), do: args["mode"] || args[:mode]

  defp pinned?(opts) do
    meta = Keyword.get(opts, :meta) || %{}
    Map.get(meta, :pin_local) == true or Map.get(meta, "pin_local") == true
  end

  defp stringify(args), do: Map.new(args, fn {k, v} -> {to_string(k), v} end)
end
```

Rewire: `ScanRequests.insert_build_job/4` → `Routing.build_job(args, priority: priority(source), meta: meta)`; `LogBackfill.enqueue/2` → `Routing.build_job(%{package: name, version: version, force: true}, priority: 9)`; `Admin`: `@build_workers ~w(Portal.Workers.Build Portal.Workers.RemoteBuild)` and `where: j.worker in @build_workers`; `RequestSync.@job_workers` adds `Portal.Workers.RemoteBuild`; `BulkRebuild.tally/4` adds clauses for `"Portal.Workers.RemoteBuild"` identical to the `Build` ones (`@build_workers` list and `when worker in @build_workers`).

- [ ] **Step 4: Run the routing test plus `scan_requests`, `admin_test.exs`, `bulk_rebuild_test.exs`, `log_backfill_test.exs`, `request_sync_test.exs`, expect PASS**

- [ ] **Step 5: Commit**

```bash
git add apps/portal/lib apps/portal/test
git commit -m "Route builds remote above a local backlog threshold while a builder is around

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: Admin Builders tab

**Files:**
- Create: `apps/portal/lib/portal_web/live/admin/builders_live.ex`
- Modify: `apps/portal/lib/portal_web/router.ex` (`live "/builders", PortalWeb.Admin.BuildersLive, :index` in the admin `live_session`), `apps/portal/lib/portal_web/components/admin_components.ex` (`{:builders, "Builders", "/admin/builders"}` after Queue), `apps/portal/lib/portal/admin.ex` (`create_builder_token/2`, `revoke_builder/2`, `set_builder_publishing/3`, `requeue_lease/1`, `update_remote_settings/1`, each checking the admin as `update_argus_settings/1` does and logging through `Portal.AdminEvents` where that exists), `apps/portal/lib/portal_web/admin_messages.ex` (error strings for `:no_ca`, `:not_found`)
- Test: `apps/portal/test/portal_web/live/admin_builders_live_test.exs`, update `apps/portal/test/portal_web/controllers/admin_sections_test.exs` `@tabs`

**Interfaces:**
- Route `/admin/builders` renders `<.admin_layout section={:builders} title="Builders">` with: a "Remote routing" card (`id="remote-settings"`: a form `id="remote-settings-form"` with `remote_mode` select auto/on/off, `remote_backlog_threshold` number, showing `Routing.remote_enabled?/0`, `Routing.local_backlog/0`, whether `Images.worker_image/0` is known with its digest); a "New enrolment token" form (`id="new-token-form"`, field `name`) whose result is shown once in `<code id="enrolment-token">` with the sentence "Copy it now; it is not stored."; a builders table `id="builders"` with one `<tr id={"builder-#{b.id}"}>` per builder: name, status badge, slots, last seen, agent version, egress status, publishing toggle button (`phx-click="toggle_publishing" phx-value-id`), cert expiry, runs count (from `Portal.Builders.runs_count/0` returning `%{builder_id => n}`; add it), revoke button (`phx-click="revoke" phx-value-id` with `data-confirm` text from `revoke_preview/1`: "Revoke <name>? <n> runs will be revoked and <m> packages rebuilt locally."); a leases table `id="leases"` of `Leases.recent(50)`: package, version, state badge, phase, builder name, attempt/max, bytes uploaded (`Float.round(bytes / 1_048_576, 1)` MiB), heartbeat age, `log_tail` in a `<details>`, and a "Requeue" button for `:failed` (`phx-click="requeue" phx-value-id`); a throughput line per builder for the last 24 h (`Portal.Builders.throughput_24h/0 :: %{builder_id => %{done: n, failed: n}}` from `builder_leases` `updated_at > now - 24h` grouped by builder and state; add it).
- Live updates: `mount/3` subscribes to `Portal.AdminEvents` `:builders` when connected and refetches through `AdminEvents.throttle/3` on `{:admin_changed, :builders}` and `{:admin_refresh, :builders}`.
- Every event re-checks the admin like `UsersLive` does (`RequireAdmin.check/2` on a freshly loaded user from `session["user_id"]`/`session["login_method"]`), and reports through `put_flash`.

- [ ] **Step 1: Write the failing LiveView test**

```elixir
defmodule PortalWeb.Admin.BuildersLiveTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Portal.Test.AccountsFixtures, only: [add_test_passkey: 1]

  alias Portal.Builders
  alias Portal.Builders.{CA, Lease, Leases}

  @pw "correct horse battery staple"

  setup %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "ncc-ca-#{System.unique_integer([:positive])}")
    key_path = Path.join(dir, "ca-key.pem")
    previous = Application.get_env(:portal, CA, [])
    Application.put_env(:portal, CA, Keyword.put(previous, :key_path, key_path))
    {:ok, _} = CA.init(key_path)
    on_exit(fn -> Application.put_env(:portal, CA, previous); File.rm_rf(dir) end)
    {:ok, admin} = Portal.Accounts.seed_admin_user("builders_admin", @pw)
    admin = add_test_passkey(admin)
    %{conn: init_test_session(conn, user_id: admin.id, login_method: :passkey)}
  end

  defp enrol!(name) do
    {:ok, %{token: token}} = Builders.create_token(name, "test")
    csr = X509.CSR.new(X509.PrivateKey.new_ec(:secp256r1), "/CN=x") |> X509.CSR.to_pem()
    {:ok, %{builder: builder}} = Builders.enrol(token, csr, %{})
    builder
  end

  test "lists builders and leases and mints a token shown once", %{conn: conn} do
    builder = enrol!("box-ui")
    {:ok, _} = Leases.enqueue(%{package: "jason", version: "1.4.4", image_name: "i", image_digest: "sha256:d", args: %{}, scan_request_id: nil, priority: 5})
    {:ok, view, _html} = live(conn, ~p"/admin/builders")
    assert has_element?(view, "#builders #builder-#{builder.id}")
    assert has_element?(view, "#leases", "jason")
    assert has_element?(view, "#remote-settings")

    view |> form("#new-token-form", %{"name" => "box-new"}) |> render_submit()
    assert has_element?(view, "#enrolment-token")
    token = view |> element("#enrolment-token") |> render() |> Floki.parse_fragment!() |> Floki.text() |> String.trim()
    assert [_, _, _] = String.split(token, ".")
  end

  test "toggles publishing, revokes, requeues and saves the routing policy", %{conn: conn} do
    builder = enrol!("box-act")
    {:ok, _} = Leases.enqueue(%{package: "jason", version: "1.4.4", image_name: "i", image_digest: "sha256:d", args: %{}, scan_request_id: nil, priority: 5})
    {:ok, lease} = Leases.claim(builder)
    {:ok, :rejected, lease} = Leases.complete(lease, 11)

    {:ok, view, _} = live(conn, ~p"/admin/builders")
    view |> element("#builder-#{builder.id} button[phx-click=toggle_publishing]") |> render_click()
    assert {:ok, %{publishing: true}} = Builders.get_builder(builder.id)

    view |> element("#lease-#{lease.id} button[phx-click=requeue]") |> render_click()
    assert Ash.get!(Lease, lease.id, domain: Builders).state == :queued

    view |> form("#remote-settings-form", %{"remote" => %{"remote_mode" => "on", "remote_backlog_threshold" => "4"}}) |> render_submit()
    assert %{remote_mode: :on, remote_backlog_threshold: 4} = Portal.Settings.get()

    view |> element("#builder-#{builder.id} button[phx-click=revoke]") |> render_click()
    assert {:ok, %{status: :revoked}} = Builders.get_builder(builder.id)
  end
end
```

(Use `LazyHTML` instead of Floki if Floki is not a dependency: `LazyHTML.from_fragment(html) |> LazyHTML.text()`.)

- [ ] **Step 2: Run, expect failure**

- [ ] **Step 3: Implement the LiveView**

Model `BuildersLive` on `UsersLive`: `mount/3` assigns `user_id`, `login_method`, `token: nil`, loads `builders`, `leases`, `counts`, `runs`, `throughput`, `settings`, `remote: %{enabled?: Routing.remote_enabled?(), backlog: Routing.local_backlog(), image: Images.worker_image()}`, `remote_form: to_form(%{"remote_mode" => ..., "remote_backlog_threshold" => ...}, as: :remote)`, `token_form: to_form(%{"name" => ""})`, and subscribes `Portal.AdminEvents.subscribe(:builders)` when connected. Events: `"new_token"` → `Portal.Admin.create_builder_token(name, admin)` → assign `token`; `"toggle_publishing"` → `Portal.Admin.set_builder_publishing(id, not current, admin)`; `"revoke"` → `Portal.Admin.revoke_builder(id, admin)` and flash "Revoked <name>: <n> runs revoked, <m> packages queued for a local rebuild."; `"requeue"` → `Portal.Admin.requeue_lease(id)`; `"save_remote"` → `Portal.Admin.update_remote_settings(params)` (casts `remote_mode` with `String.to_existing_atom` guarded by `in ~w(auto on off)`, threshold with `Integer.parse`). `handle_info({:admin_changed, :builders}, socket)` and `({:admin_refresh, :builders}, socket)` reload. Render with `<.admin_layout ...>`, Tailwind/daisyUI classes as the other admin pages, every actionable element with an id named above. `Portal.Admin` functions take the admin user and run `RequireAdmin.check/2`-style re-authorisation the way the existing `as_admin_bulk` helpers do; keep each a thin wrapper around `Portal.Builders`/`Portal.Builders.Leases`/`Portal.Settings.save/1`.

- [ ] **Step 4: Run the LiveView test and `admin_sections_test.exs` (add `{"/admin/builders", "Builders"}` to its `@tabs`), expect PASS**

- [ ] **Step 5: Commit**

```bash
git add apps/portal/lib apps/portal/test
git commit -m "Admin Builders tab: tokens, publishing, revoke, leases and remote routing policy

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: The agent app skeleton: config, version, token, identity (enrol/renew) and the mTLS client

**Files:**
- Create: `apps/ncc_agent/mix.exs`, `apps/ncc_agent/.formatter.exs`, `apps/ncc_agent/README.md`, `apps/ncc_agent/lib/ncc_agent.ex`, `apps/ncc_agent/lib/ncc_agent/application.ex`, `apps/ncc_agent/lib/ncc_agent/config.ex`, `apps/ncc_agent/lib/ncc_agent/version.ex`, `apps/ncc_agent/lib/ncc_agent/token.ex`, `apps/ncc_agent/lib/ncc_agent/identity.ex`, `apps/ncc_agent/lib/ncc_agent/client.ex`
- Create test support: `apps/ncc_agent/test/test_helper.exs`, `apps/ncc_agent/test/support/fake_portal.ex` (a Bandit HTTPS server with a test CA, mTLS, and a Plug router that fakes `/builder/v1/*`), `apps/ncc_agent/test/support/test_ca.ex`
- Modify: root `mix.exs` (`releases:` gains `ncc_agent: [applications: [compatibility: :permanent, ncc_agent: :permanent], include_executables_for: [:unix], include_erts: true]`), `.github/workflows/sobelow.yml` matrix (add `ncc_agent` with `--no-router`) — the sobelow gate list in this plan gains `mix sobelow --root apps/ncc_agent --no-router --private --skip --strict --exit low`
- Test: `apps/ncc_agent/test/ncc_agent/config_test.exs`, `token_test.exs`, `version_test.exs`, `identity_test.exs`, `client_test.exs`

**Interfaces:**
- `apps/ncc_agent/mix.exs`: app `:ncc_agent`, `elixir: "~> 1.19"`, umbrella child paths (`build_path: "../../_build"`, `config_path: "../../config/config.exs"`, `deps_path: "../../deps"`, `lockfile: "../../mix.lock"`), `elixirc_paths(:test)` adds `test/support`, `mod: {NccAgent.Application, []}`, `extra_applications: [:logger, :crypto, :ssl, :public_key, :inets]`, deps `{:compatibility, in_umbrella: true}`, `{:req, "~> 0.7"}`, `{:x509, "~> 0.9"}`, `{:jason, "~> 1.2"}`, `{:bandit, "~> 1.5", only: :test}`, `{:plug, "~> 1.16", only: :test}`. All are already in `mix.lock`; `mix deps.get` from the root must leave the lock unchanged (`git diff --exit-code mix.lock`).
- `NccAgent.Config.load/0 :: {:ok, config} | {:error, [String.t()]}` reading env: `NCC_PORTAL_URL` (required, `https://host:8443`), `NCC_ENROLMENT_TOKEN` (optional), `NCC_SLOTS` (default 1, 1..16), `NCC_CPUS`, `NCC_MEMORY` (optional strings), `NCC_DATA_DIR` (default `/srv/ncc`), `NCC_BUILD_USER` (default `"<own uid>:<own gid>"` from `id -u`/`id -g`), `NCC_DOCKER_BIN` (default `"docker"`), `NCC_EGRESS_SCRIPT` (default `Path.join(:code.priv_dir(:ncc_agent), "egress.sh")`), `NCC_BUILD_CONCURRENCY` (optional). `NccAgent.Config.put/1` stores it in `:persistent_term`; `NccAgent.Config.get/0` reads it. Paths: `data_dir/ca.pem`, `data_dir/client.pem`, `data_dir/client-key.pem`, `data_dir/scratch`, `data_dir/nerves-cache`, `data_dir/hex-cache`, `data_dir/releases` via `NccAgent.Config.path(config, :ca | :cert | :key | :scratch | :nerves_cache | :hex_cache | :releases)`.
- `NccAgent.Version.current/0 :: String.t()` = `System.get_env("NCC_AGENT_VERSION")` captured at **compile time** (`@version System.get_env("NCC_AGENT_VERSION") || "0.dev"`); `NccAgent.Version.newer?(candidate, current) :: boolean()` compares the integer before the first `.` (`"0.dev"` → 0; a dev build is never updated, see Task 13).
- `NccAgent.Token.parse(token) :: {:ok, %{id: String.t(), secret: String.t(), ca_prefix: String.t()}} | :error` (three dot-separated parts, prefix 16 lowercase hex).
- `NccAgent.Client`: `fetch_ca(portal_url) :: {:ok, pem} | {:error, term()}` (TLS without verification: the token's prefix is what authenticates the CA); `verify_ca(pem, prefix) :: :ok | {:error, :ca_mismatch}` (sha256 of the DER, hex, `String.starts_with?`); `enroll(portal_url, ca_path, token, csr_pem, version, slots) :: {:ok, %{cert_pem, expires_at, builder_id, name}} | {:error, term()}` (Req with `cacertfile` only); `new(config) :: Req.Request.t()` (mTLS: `connect_options: [transport_opts: [verify: :verify_peer, cacertfile:, certfile:, keyfile:, server_name_indication: host_charlist, depth: 2]]`, `retry: false`, `receive_timeout: 60_000`); `renew(req, csr_pem)`, `status(req, egress, free_slots)`, `claim(req, free_slots, egress) :: {:ok, claim_map} | :none | {:error, term()}` (`receive_timeout: 40_000`, 204 → `:none`, 409 `egress_missing` → `{:error, :egress_missing}`), `heartbeat(req, lease_id, phase, log_tail)`, `missing(req, lease_id, shas) :: {:ok, [sha]} | {:error, _}`, `upload(req, lease_id, tar_path) :: {:ok, %{"stored" => _, "bad" => _}} | {:error, {:bad_entries, [sha]} | term()}` (`PUT`, `Content-Type: application/x-tar`, `Content-Length` = file size, `body: File.stream!(tar_path, 262_144)`), `complete(req, lease_id, exit_code, parts) :: {:ok, map} | {:error, term()}` (`form_multipart: [exit_code: Integer.to_string(code), result: {File.stream!(path), filename: "result.json"}, logs: ..., runner_log: ...]`, omitting absent parts). Every request sets header `x-ncc-agent-version`.
- `NccAgent.Identity` (GenServer, name `NccAgent.Identity`): `ensure/0 :: {:ok, Req.Request.t()} | {:error, term()}` — if `client.pem` is missing: parse `NCC_ENROLMENT_TOKEN`, fetch and verify `ca.pem`, write it (0644), generate a P-256 key (0600) and CSR, `Client.enroll`, write `client.pem`, log the builder name. Then if the certificate expires within 30 days: new key+CSR, `Client.renew`, write both files atomically (`.tmp` + rename) and rebuild the Req. Returns the Req. `Identity.client/0` is the cached Req (rebuilt after a renewal); `Identity.cert_expires_at/0`.

- [ ] **Step 1: Write the test support (fake portal) and the failing tests**

`test/support/test_ca.ex`:

```elixir
defmodule NccAgent.Test.CA do
  @moduledoc "A throwaway CA, server certificate and client issuer for agent tests."

  def new(dir) do
    File.mkdir_p!(dir)
    key = X509.PrivateKey.new_ec(:secp256r1)
    cert = X509.Certificate.self_signed(key, "/CN=test CA", template: :root_ca)
    File.write!(Path.join(dir, "ca.pem"), X509.Certificate.to_pem(cert))
    server_key = X509.PrivateKey.new_ec(:secp256r1)
    server = X509.Certificate.new(X509.PublicKey.derive(server_key), "/CN=localhost", cert, key, template: :server, extensions: [subject_alt_name: X509.Certificate.Extension.subject_alt_name(["localhost"])])
    File.write!(Path.join(dir, "server.pem"), X509.Certificate.to_pem(server))
    File.write!(Path.join(dir, "server-key.pem"), X509.PrivateKey.to_pem(server_key))
    %{dir: dir, key: key, cert: cert, prefix: cert |> X509.Certificate.to_der() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower) |> String.slice(0, 16)}
  end

  def issue(%{key: key, cert: cert}, csr_pem, name, days \\ 365) do
    csr = X509.CSR.from_pem!(csr_pem)
    X509.Certificate.new(X509.CSR.public_key(csr), "/CN=#{name}", cert, key, template: :server, validity: days) |> X509.Certificate.to_pem()
  end
end
```

`test/support/fake_portal.ex`: a Plug router started under Bandit with `scheme: :https`, `port: 0`, `certfile`/`keyfile`/`cacertfile` from the CA, `verify: :verify_peer`, `fail_if_no_peer_cert: false`; the test process is told the port via `Bandit`'s `ThousandIsland.listener_info/1` (or `start_link` with `port: 0` then `ThousandIsland.listener_info(pid)`). The router records every request as `{:portal_request, method, path, body_or_params, peer_fingerprint}` to a `:test_pid` it is started with, and answers from a `script` kept in an `Agent`: `GET /builder/v1/ca.pem` → the CA PEM; `POST /enroll` → 201 with a certificate issued from the CSR, or the scripted error; `POST /renew` → 200 with a new certificate (requires a peer cert); `POST /jobs/claim` → the next scripted claim or 204; `POST /jobs/:id/heartbeat` → 200; `POST /jobs/:id/files/missing` → scripted missing list (default: all); `PUT /jobs/:id/files` → reads the body and answers 200 `{"stored": [...names from the tar...], "bad": []}` (use `:erl_tar.table({:binary, body})`); `POST /jobs/:id/complete` → 202. Helper `NccAgent.Test.FakePortal.start(ca, test_pid, script)` returns `%{url: "https://localhost:<port>", pid: pid}`.

`token_test.exs`:

```elixir
defmodule NccAgent.TokenTest do
  use ExUnit.Case, async: true
  alias NccAgent.Token

  test "parses the three parts" do
    assert {:ok, %{id: "0f2b", secret: "c2VjcmV0", ca_prefix: "0123456789abcdef"}} = Token.parse("0f2b.c2VjcmV0.0123456789abcdef")
  end

  test "rejects anything else" do
    assert :error = Token.parse("a.b")
    assert :error = Token.parse("a.b.NOTHEX0123456789")
    assert :error = Token.parse("")
  end
end
```

`version_test.exs`:

```elixir
defmodule NccAgent.VersionTest do
  use ExUnit.Case, async: true
  alias NccAgent.Version

  test "compares the leading integer and never updates a dev build" do
    assert Version.newer?("1761400001.abc", "1761400000.def")
    refute Version.newer?("1761400000.abc", "1761400000.def")
    refute Version.newer?("1761400001.abc", "0.dev")
    refute Version.newer?(nil, "1761400000.def")
    refute Version.newer?("garbage", "1.a")
  end

  test "current is a string" do
    assert is_binary(Version.current())
  end
end
```

`config_test.exs`:

```elixir
defmodule NccAgent.ConfigTest do
  use ExUnit.Case, async: false
  alias NccAgent.Config

  setup do
    saved = System.get_env()
    on_exit(fn -> for {k, _} <- System.get_env(), String.starts_with?(k, "NCC_"), do: System.delete_env(k); for {k, v} <- saved, String.starts_with?(k, "NCC_"), do: System.put_env(k, v) end)
    for {k, _} <- System.get_env(), String.starts_with?(k, "NCC_"), do: System.delete_env(k)
    :ok
  end

  test "requires the portal url and defaults the rest" do
    assert {:error, [msg]} = Config.load()
    assert msg =~ "NCC_PORTAL_URL"
    System.put_env("NCC_PORTAL_URL", "https://portal.test:8443")
    System.put_env("NCC_DATA_DIR", "/tmp/ncc-x")
    assert {:ok, config} = Config.load()
    assert config.portal_url == "https://portal.test:8443" and config.slots == 1 and config.docker_bin == "docker"
    assert config.build_user =~ ~r/^\d+:\d+$/
    assert Config.path(config, :cert) == "/tmp/ncc-x/client.pem"
    assert Config.path(config, :nerves_cache) == "/tmp/ncc-x/nerves-cache"
    assert String.ends_with?(config.egress_script, "egress.sh")
  end

  test "slots must be 1..16 and the url https" do
    System.put_env("NCC_PORTAL_URL", "http://portal.test")
    System.put_env("NCC_SLOTS", "40")
    assert {:error, errors} = Config.load()
    assert Enum.any?(errors, &(&1 =~ "NCC_SLOTS")) and Enum.any?(errors, &(&1 =~ "https"))
  end
end
```

`identity_test.exs` (uses the fake portal):

```elixir
defmodule NccAgent.IdentityTest do
  use ExUnit.Case, async: false

  alias NccAgent.{Config, Identity}
  alias NccAgent.Test.{CA, FakePortal}

  setup do
    dir = Path.join(System.tmp_dir!(), "agent-#{System.unique_integer([:positive])}")
    ca = CA.new(Path.join(dir, "ca"))
    %{url: url} = FakePortal.start(ca, self(), %{})
    config = %{Config.defaults() | portal_url: url, data_dir: Path.join(dir, "data"), enrolment_token: "id.c2VjcmV0c2VjcmV0.#{ca.prefix}"}
    Config.put(config)
    on_exit(fn -> File.rm_rf(dir) end)
    %{ca: ca, config: config, dir: dir}
  end

  test "first boot fetches and verifies the CA, enrols, and stores the identity", %{config: config} do
    assert {:ok, %Req.Request{}} = Identity.ensure()
    assert_received {:portal_request, "GET", "/builder/v1/ca.pem", _, nil}
    assert_received {:portal_request, "POST", "/builder/v1/enroll", %{"token" => "id.c2VjcmV0c2VjcmV0." <> _, "csr_pem" => _}, nil}
    assert File.exists?(Config.path(config, :cert)) and File.exists?(Config.path(config, :key)) and File.exists?(Config.path(config, :ca))
    assert File.stat!(Config.path(config, :key)).mode |> Bitwise.band(0o777) == 0o600
    assert DateTime.diff(Identity.cert_expires_at(), DateTime.utc_now(), :day) > 300
    # Second call: no enrolment, the existing identity is used.
    assert {:ok, _} = Identity.ensure()
    refute_received {:portal_request, "POST", "/builder/v1/enroll", _, _}
  end

  test "a CA whose hash does not match the token's prefix is refused", %{config: config} do
    Config.put(%{config | enrolment_token: "id.c2VjcmV0c2VjcmV0.0000000000000000"})
    assert {:error, :ca_mismatch} = Identity.ensure()
    refute File.exists?(Config.path(config, :ca))
  end

  test "a certificate within 30 days of expiry is renewed and the files rotated", %{config: config, ca: ca} do
    {:ok, _} = Identity.ensure()
    short = CA.issue(ca, File.read!(Path.join(config.data_dir, "client.csr")), "box", 10)
    File.write!(Config.path(config, :cert), short)
    before = File.read!(Config.path(config, :key))
    assert {:ok, _} = Identity.ensure()
    assert_received {:portal_request, "POST", "/builder/v1/renew", %{"csr_pem" => _}, fp} when is_binary(fp)
    assert File.read!(Config.path(config, :key)) != before
    assert DateTime.diff(Identity.cert_expires_at(), DateTime.utc_now(), :day) > 300
  end
end
```

(`Identity` keeps the last CSR at `data_dir/client.csr` so the test can re-issue against the same key; `Config.defaults/0` returns a config map with every default and `portal_url: nil`.)

`client_test.exs`: with an enrolled identity (from the fake portal), assert `Client.claim/3` returns `:none` on 204 and `{:ok, %{"lease_id" => _}}` on a scripted claim, `Client.missing/3` returns the scripted list, `Client.upload/3` streams a tar made with `:erl_tar` and the fake portal records the entry names, `Client.complete/4` sends `exit_code` and the `result` part, and that every request carried a peer fingerprint (mTLS) and the `x-ncc-agent-version` header.

- [ ] **Step 2: Run, expect failures**

Run: `source ~/toolchain/env.sh && mix deps.get && git diff --exit-code mix.lock && mix test apps/ncc_agent/test/`

- [ ] **Step 3: Implement**

`Config`:

```elixir
defmodule NccAgent.Config do
  @moduledoc "The agent's configuration, from `/etc/ncc-agent.env` through the environment."

  @type t :: %{
          portal_url: String.t() | nil, enrolment_token: String.t() | nil, slots: pos_integer(),
          cpus: String.t() | nil, memory: String.t() | nil, build_concurrency: String.t() | nil,
          data_dir: Path.t(), build_user: String.t(), docker_bin: String.t(), egress_script: Path.t()
        }

  def defaults do
    %{portal_url: nil, enrolment_token: nil, slots: 1, cpus: nil, memory: nil, build_concurrency: nil,
      data_dir: "/srv/ncc", build_user: own_user(), docker_bin: "docker",
      egress_script: Path.join(to_string(:code.priv_dir(:ncc_agent)), "egress.sh")}
  end

  def load do
    config = %{
      defaults()
      | portal_url: System.get_env("NCC_PORTAL_URL"),
        enrolment_token: System.get_env("NCC_ENROLMENT_TOKEN"),
        cpus: System.get_env("NCC_CPUS"),
        memory: System.get_env("NCC_MEMORY"),
        build_concurrency: System.get_env("NCC_BUILD_CONCURRENCY"),
        data_dir: System.get_env("NCC_DATA_DIR", "/srv/ncc"),
        build_user: System.get_env("NCC_BUILD_USER") || own_user(),
        docker_bin: System.get_env("NCC_DOCKER_BIN", "docker"),
        egress_script: System.get_env("NCC_EGRESS_SCRIPT") || defaults().egress_script
    }

    {slots, slot_errors} = parse_slots(System.get_env("NCC_SLOTS", "1"))
    errors = url_errors(config.portal_url) ++ slot_errors
    if errors == [], do: {:ok, %{config | slots: slots}}, else: {:error, errors}
  end

  def put(config), do: :persistent_term.put({__MODULE__, :config}, config)
  def get, do: :persistent_term.get({__MODULE__, :config})

  def path(config, :ca), do: Path.join(config.data_dir, "ca.pem")
  def path(config, :cert), do: Path.join(config.data_dir, "client.pem")
  def path(config, :key), do: Path.join(config.data_dir, "client-key.pem")
  def path(config, :csr), do: Path.join(config.data_dir, "client.csr")
  def path(config, :scratch), do: Path.join(config.data_dir, "scratch")
  def path(config, :nerves_cache), do: Path.join(config.data_dir, "nerves-cache")
  def path(config, :hex_cache), do: Path.join(config.data_dir, "hex-cache")
  def path(config, :releases), do: Path.join(config.data_dir, "releases")

  defp url_errors(nil), do: ["NCC_PORTAL_URL is required (https://host:8443)"]
  defp url_errors("https://" <> _), do: []
  defp url_errors(_), do: ["NCC_PORTAL_URL must be an https URL"]

  defp parse_slots(value) do
    case Integer.parse(value) do
      {n, ""} when n in 1..16 -> {n, []}
      _ -> {1, ["NCC_SLOTS must be 1..16, got #{inspect(value)}"]}
    end
  end

  defp own_user do
    with {uid, 0} <- System.cmd("id", ["-u"]), {gid, 0} <- System.cmd("id", ["-g"]) do
      "#{String.trim(uid)}:#{String.trim(gid)}"
    else
      _ -> "1000:1000"
    end
  end
end
```

`Version`, `Token`, `Client` and `Identity` as specified above. In `Client`, build the Req once:

```elixir
  def new(config) do
    %URI{host: host} = URI.parse(config.portal_url)

    Req.new(
      base_url: config.portal_url,
      headers: [{"x-ncc-agent-version", NccAgent.Version.current()}],
      retry: false,
      receive_timeout: 60_000,
      connect_options: [
        transport_opts: [
          verify: :verify_peer,
          cacertfile: String.to_charlist(NccAgent.Config.path(config, :ca)),
          certfile: String.to_charlist(NccAgent.Config.path(config, :cert)),
          keyfile: String.to_charlist(NccAgent.Config.path(config, :key)),
          server_name_indication: String.to_charlist(host),
          depth: 2
        ]
      ]
    )
  end
```

(`fetch_ca/1` uses `connect_options: [transport_opts: [verify: :verify_none]]`; enrolment uses `cacertfile` only.) Finch pools are keyed on the connect options, so a renewed identity means a new `Req` struct; `Identity` rebuilds it.

`Application`: starts `NccAgent.Identity`; Tasks 13–15 add the slot supervisor and egress. If `Config.load/0` fails, log each error and `System.stop(1)` — a release without its env file must not spin.

`README.md`: what the app is, the env file keys, how to run it in dev against a local portal, pointer to `docs/REMOTE_BUILDERS.md`.

- [ ] **Step 4: Run the agent tests, `mix compile --warnings-as-errors`, `mix format`, expect PASS**

- [ ] **Step 5: Commit**

```bash
git add apps/ncc_agent mix.exs .github/workflows/sobelow.yml
git commit -m "Add the ncc_agent app: config, enrolment, renewal and the mTLS client

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 13: The agent's job loop: Docker runner, uploads, complete, slots, self-update, release files

**Files:**
- Create: `apps/ncc_agent/lib/ncc_agent/docker.ex`, `apps/ncc_agent/lib/ncc_agent/tar.ex`, `apps/ncc_agent/lib/ncc_agent/heartbeat.ex`, `apps/ncc_agent/lib/ncc_agent/job.ex`, `apps/ncc_agent/lib/ncc_agent/slot.ex`, `apps/ncc_agent/lib/ncc_agent/updater.ex`, `apps/ncc_agent/rel/ncc-agent.service`, `apps/ncc_agent/rel/ncc-agent.env.example`, `apps/ncc_agent/rel/env.sh.eex`
- Modify: `apps/ncc_agent/lib/ncc_agent/application.ex` (slot supervisor), `apps/ncc_agent/lib/ncc_agent/client.ex` if anything is missing
- Test: `apps/ncc_agent/test/ncc_agent/tar_test.exs`, `docker_test.exs`, `job_test.exs`, `updater_test.exs`, `apps/ncc_agent/test/support/fake_docker.sh`

**Interfaces:**
- `NccAgent.Tar.batches(files :: [{sha, path}], max_batch_bytes) :: [[{sha, path}]]` — greedy by size (file size via `File.stat!`), a file larger than the cap is its own batch (the portal will refuse it as `bad`, which is reported); `NccAgent.Tar.write(batch, out_path) :: :ok` via `:erl_tar.create(out, [{name_charlist, path_charlist}], [])`.
- `NccAgent.Docker.pull(config, image_ref) :: :ok | {:error, String.t()}`; `present?(config, image_ref)` (`docker image inspect`); `run(config, argv, log_path, timeout_ms) :: {:ok, exit_code} | {:error, :timeout | term()}` — `Port.open({:spawn_executable, docker_bin}, [:binary, :exit_status, :stderr_to_stdout, args: argv])`, appends output to `log_path`, kills `ncc-<run_id>` (`docker kill`) on timeout; the container name is `argv`'s `--name` value. `NccAgent.Docker.log_tail(log_path, bytes \\ 4096)`.
- `NccAgent.Heartbeat.start_link(%{req, lease_id, log_path, phase_agent})`: every 60 s posts `Client.heartbeat(req, lease_id, phase, Docker.log_tail(log_path))`; `set_phase(pid, "pulling" | "building" | "uploading")`; stopped by the job.
- `NccAgent.Job.run(req, claim, config) :: {:ok, :done | :requeued | :failed | :rejected} | {:error, term()}`: scratch at `<scratch>/<safe run_id>/{work,out,files,tmp,cache}`; `chown -R build_user` on the scratch dir when `build_user != own user` (via `System.cmd("chown", ...)`, logged on failure); writes `work/input.json` from `claim["input"]` **after** `NccAgent.NervesCache.prepare/3` (Task 14) has added the per-run farm and returns the env pairs; `image_ref = "#{image.name}@#{image.digest}"`; pull if absent (phase `pulling`); `argv = Compatibility.Builder.Argv.build(spec)` with `spec` = `%{run_id, image: image_ref, user: config.build_user, work_dir, output_dir, files_dir, nerves_cache: Config.path(config, :nerves_cache), hex_cache: Config.path(config, :hex_cache), build_cache: nil, cpus: config.cpus, memory: config.memory, build_concurrency: config.build_concurrency, nerves_cache_mode: :readonly, hardening: true, tmp_dir, cache_dir, extra_env: NervesCache env}` (phase `building`); `Docker.run` with `claim["timeout_sec"] * 1000`; then phase `uploading`: list `files/` (regular files whose names are 64-hex; cap at `upload.max_files`), `Client.missing`, `Tar.batches` over the missing ones with `upload.max_batch_bytes`, `Client.upload` each (a `{:error, {:bad_entries, bad}}` is logged and continues), then `Client.complete(req, lease_id, exit_code, %{result: out/result.json if present, logs: logs.tar.gz built from out/logs/*.log with `:erl_tar.create(..., [:compressed])` if any, runner_log: out/runner.log})`; after a 0 exit, `NervesCache.warm/4` (Task 14) with `result.json`'s misses and `claim["warm_allowlist"]`; finally `File.rm_rf(scratch)`. A `Docker.run` timeout completes the lease with exit code 20. Everything is wrapped so an exception still removes the scratch dir and completes with exit 20.
- `NccAgent.Slot` (GenServer, one per slot, `id: {NccAgent.Slot, n}`): loop `:tick` → `NccAgent.Egress.verify/0` (Task 15; until then a module attribute `@egress_module` defaulting to `NccAgent.Egress`, which Task 15 creates — in this task create a stub `NccAgent.Egress.verify/0` returning `:ok` and `install/0` returning `:ok`, replaced in Task 15) → `:ok` → `Identity.ensure()` → `Client.claim(req, 1, "ok")` → `:none` → tick again immediately; `{:ok, claim}` → `Updater.maybe_update(claim)` then `Job.run`; `{:error, _}` → `Client.status(req, "ok"|"missing", 0)` when egress failed, then tick after 30 s backoff (doubling to 5 min on repeated errors).
- `NccAgent.Updater.maybe_update(claim, config) :: :ok | {:updating, version}` — when `Version.newer?(claim["min_agent_version"], Version.current())` and `claim["agent_releases"][arch]` exists (arch from `:erlang.system_info(:system_architecture)`: starts with `"x86_64"` → `"x86_64"`, `"aarch64"` → `"aarch64"`): download to `<releases>/<version>.tar.gz` with Req (plain HTTPS, system CAs), verify sha256, extract to `<releases>/<version>/` (`:erl_tar.extract(..., [:compressed, {:cwd, dir}])`, then the release lives at `<releases>/<version>/ncc_agent`), replace the symlink `<releases>/current -> <version>/ncc_agent` (`File.ln_s` to a temp name + `File.rename`), log, and `System.stop(0)` so systemd restarts into the new release. A failed download or hash mismatch is logged and the job continues on the current version.
- `rel/ncc-agent.service`:

```ini
[Unit]
Description=Nerves compatibility remote builder agent
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=exec
User=root
EnvironmentFile=/etc/ncc-agent.env
Environment=HOME=/srv/ncc
ExecStart=/srv/ncc/releases/current/bin/ncc_agent start
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

  `rel/ncc-agent.env.example` lists `NCC_PORTAL_URL`, `NCC_ENROLMENT_TOKEN`, `NCC_SLOTS`, `NCC_CPUS`, `NCC_MEMORY`, `NCC_DATA_DIR`, `NCC_BUILD_USER` with one comment each. `rel/env.sh.eex` sets `RELEASE_DISTRIBUTION=none` and `RELEASE_NODE=ncc_agent` (no distribution on the VM).
- The umbrella release config (root `mix.exs`) names `rel/` under the agent app: `releases: [..., ncc_agent: [applications: [...], include_executables_for: [:unix], include_erts: true, path: ..., rel_templates_path: "apps/ncc_agent/rel"]]`.

- [ ] **Step 1: Write the fake docker and the failing tests**

`test/support/fake_docker.sh` (executable): a shell script standing in for `docker`. `image inspect` → exit 0 if `$FAKE_DOCKER_IMAGE_PRESENT=1` else 1; `pull` → exit 0 and echo; `run ...` → parses `--mount` arguments to find the `/out` and `/files` sources, writes `$FAKE_DOCKER_RESULT` (a JSON string from the env) to `<out>/result.json`, writes `<out>/logs/host.log`, writes a file named by its own sha256 into `<files>` with content `$FAKE_DOCKER_FILE_CONTENT`, prints `fake build output`, and exits `$FAKE_DOCKER_EXIT` (default 0); `kill` → exit 0; anything else → echo and exit 0.

`tar_test.exs`: `batches/2` splits by size (three 400-byte files at cap 1000 → two batches) and a 2000-byte file is alone; `write/2` produces a tar `:erl_tar.table/1` lists with the sha names.

`docker_test.exs`: with `docker_bin: fake_docker.sh`, `run/4` writes the output to the log and returns `{:ok, 0}`; with `FAKE_DOCKER_EXIT=10` returns `{:ok, 10}`; `present?/2` follows the env flag; a tiny timeout against a `sleep`ing fake returns `{:error, :timeout}` (make the fake `sleep 5` when `FAKE_DOCKER_SLEEP=1`).

`job_test.exs`: start the fake portal with a scripted claim (`lease_id`, `run_id "rb-jason-1.4.4-1"`, `image %{name: "ghcr.io/x/ncc-worker", digest: "sha256:aa.."}`, `input` with `paths`, `timeout_sec 60`, `upload` caps, `warm_allowlist []`), an enrolled identity, `docker_bin` = fake, `FAKE_DOCKER_RESULT` = a minimal result with `nerves_cache: %{misses: []}`; call `Job.run(req, claim, config)` and assert: the fake portal received `heartbeat` (at least one, immediately on start), `files/missing` with the one sha, a `PUT files` whose tar contained that sha, and `complete` with `exit_code "0"` and a `result` part; the scratch dir is gone; the recorded `docker run` argv (the fake appends `$@` to `$FAKE_DOCKER_ARGV_LOG`) contains `--read-only`, `type=bind,source=<data>/nerves-cache,target=/nerves-cache,readonly`, `--user <build_user>`, `NERVES_ARTIFACTS_DIR=/work/nerves/artifacts`, `NERVES_DL_DIR=/work/nerves/dl` and ends with `ghcr.io/x/ncc-worker@sha256:aa..`. A second test with `FAKE_DOCKER_EXIT=10` asserts `complete` carried `exit_code "10"` and no `files` upload happened.

`updater_test.exs`: a claim whose `min_agent_version` is newer and `agent_releases` points at a file served by the fake portal (add a `GET /releases/:name` route serving a prepared tarball) with the right sha → `maybe_update/2` extracts and swaps the symlink (inject `stop_fun` so the test does not stop the VM); a wrong sha → `:ok` and nothing swapped; a dev build (`NCC_AGENT_VERSION` unset) → `:ok`.

- [ ] **Step 2: Run, expect failures**

- [ ] **Step 3: Implement the modules as specified**

Key pieces of `Job`:

```elixir
  def run(req, claim, config) do
    run_id = claim["run_id"]
    lease_id = claim["lease_id"]
    scratch = Path.join(Config.path(config, :scratch), Argv.safe_name(run_id))
    dirs = %{work: Path.join(scratch, "work"), out: Path.join(scratch, "out"), files: Path.join(scratch, "files"), tmp: Path.join(scratch, "tmp"), cache: Path.join(scratch, "cache")}
    Enum.each(Map.values(dirs), &File.mkdir_p!/1)
    {:ok, hb} = Heartbeat.start_link(%{req: req, lease_id: lease_id, log_path: Path.join(dirs.out, "runner.log")})

    try do
      exit_code = build(req, claim, config, dirs, hb)
      Heartbeat.set_phase(hb, "uploading")
      if exit_code == 0, do: upload_files(req, lease_id, dirs.files, claim["upload"])
      outcome = complete(req, lease_id, exit_code, dirs.out)
      if exit_code == 0, do: NervesCache.warm(config, dirs, claim)
      outcome
    rescue
      e ->
        Logger.error("job #{run_id} crashed: #{Exception.message(e)}")
        complete(req, lease_id, 20, dirs.out)
    after
      Heartbeat.stop(hb)
      File.rm_rf(scratch)
    end
  end
```

`build/5`: `prepare` the nerves farm (Task 14; until then `NervesCache.prepare/3` returns `%{env: [{"NERVES_ARTIFACTS_DIR", "/work/nerves/artifacts"}, {"NERVES_DL_DIR", "/work/nerves/dl"}]}` and creates `work/nerves/dl` + an empty `work/nerves/artifacts` — implement that minimal version here and let Task 14 replace it with the symlink farm), write `input.json`, chown, pull if needed (phase `pulling`), run (phase `building`), map `{:error, :timeout}` → 20 and `{:error, _}` → 20.

`upload_files/4`: list, `Client.missing`, batches, upload each into a temp tar under the scratch `tmp`, delete each tar after sending.

- [ ] **Step 4: Run the agent tests; `mix compile --warnings-as-errors`; `mix format`; `MIX_ENV=prod mix release ncc_agent --overwrite` builds (then `rm -rf _build/prod/rel/ncc_agent`)**

- [ ] **Step 5: Commit**

```bash
git add apps/ncc_agent mix.exs
git commit -m "ncc_agent: claim, build with the shared argv, upload, complete, self-update

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 14: Agent isolation piece 1 — per-run Nerves-cache symlink farm and allowlisted warm (isolation design section 1)

**Files:**
- Create: `apps/ncc_agent/lib/ncc_agent/nerves_cache.ex`
- Modify: `apps/ncc_agent/lib/ncc_agent/job.ex` (call `NervesCache.prepare/3` and `warm/3`)
- Test: `apps/ncc_agent/test/ncc_agent/nerves_cache_test.exs`

**Interfaces (from the isolation spec, section 1, and the remote spec, section 5):**
- `NccAgent.NervesCache.prepare(config, work_dir) :: %{env: [{String.t(), String.t()}], artifacts_dir: Path.t(), dl_dir: Path.t()}` — ensures `<data>/nerves-cache/artifacts` exists; creates `<work>/nerves/artifacts/` with one **symlink per entry** of `<nerves-cache>/artifacts/` pointing at `/nerves-cache/artifacts/<entry>` (the container path, since the link is resolved inside the container), and an empty `<work>/nerves/dl/`; returns env `NERVES_ARTIFACTS_DIR=/work/nerves/artifacts`, `NERVES_DL_DIR=/work/nerves/dl` (passed as container env **and** written into `input.json` under `paths.nerves_artifacts_dir`/`paths.nerves_dl_dir`, so the worker of either generation finds them).
- `NccAgent.NervesCache.misses(result :: map()) :: [%{name: String.t(), version: String.t()}]` — `result["nerves_cache"]["misses"]` entries with string `name` and `version`, deduplicated, at most 4 (the isolation design's `@warm_pairs_per_run`), empty when the key is absent.
- `NccAgent.NervesCache.allowed(misses, allowlist :: [String.t()]) :: [pair]` — only names in the allowlist (the portal's list from the claim; the agent never has its own).
- `NccAgent.NervesCache.warm(config, claim, result) :: :ok | :skipped | {:error, term()}` — pairs = `allowed(misses(result), claim["warm_allowlist"])`; `[]` → `:skipped`; else a second container run with `mode: "warm_nerves"` and `nerves_packages: pairs` in `input.json`, the cache mounted **read-write** (`nerves_cache_mode: :readwrite`, `hardening: true`), its own scratch under `<scratch>/<run_id>-warm`, the same `NERVES_*` env pointing the worker at `/nerves-cache/staging/<run_id>/...` is the worker's business (it reads `mode`); a 2 h timeout; exit code logged; scratch removed. Never warms a miss outside the allowlist.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule NccAgent.NervesCacheTest do
  use ExUnit.Case, async: false

  alias NccAgent.{Config, NervesCache}

  setup do
    dir = Path.join(System.tmp_dir!(), "nc-#{System.unique_integer([:positive])}")
    config = %{Config.defaults() | data_dir: dir, portal_url: "https://x"}
    File.mkdir_p!(Path.join([dir, "nerves-cache", "artifacts", "nerves_system_rpi4-1.30.0"]))
    File.write!(Path.join([dir, "nerves-cache", "artifacts", "nerves_system_rpi4-1.30.0", ".fingerprint"]), "fp")
    on_exit(fn -> File.rm_rf(dir) end)
    %{config: config, dir: dir}
  end

  test "builds a symlink farm pointing at the container path and an empty dl dir", %{config: config, dir: dir} do
    work = Path.join(dir, "work")
    assert %{env: env, artifacts_dir: artifacts, dl_dir: dl} = NervesCache.prepare(config, work)
    assert env == [{"NERVES_ARTIFACTS_DIR", "/work/nerves/artifacts"}, {"NERVES_DL_DIR", "/work/nerves/dl"}]
    assert File.dir?(dl) and File.ls!(dl) == []
    assert {:ok, "/nerves-cache/artifacts/nerves_system_rpi4-1.30.0"} = File.read_link(Path.join(artifacts, "nerves_system_rpi4-1.30.0"))
    # Removing the link (Nerves' fingerprint-mismatch path) leaves the cache untouched.
    File.rm_rf!(Path.join(artifacts, "nerves_system_rpi4-1.30.0"))
    assert File.exists?(Path.join([dir, "nerves-cache", "artifacts", "nerves_system_rpi4-1.30.0", ".fingerprint"]))
  end

  test "misses are bounded and filtered by the portal's allowlist" do
    result = %{"nerves_cache" => %{"misses" => [%{"name" => "nerves_system_rpi4", "version" => "1.30.0"}, %{"name" => "evil_system", "version" => "1.0.0"}, %{"name" => "nerves_system_rpi4", "version" => "1.30.0"}, %{"name" => "a", "version" => "1"}, %{"name" => "b", "version" => "1"}, %{"name" => "c", "version" => "1"}, %{"name" => "d", "version" => "1"}]}}
    misses = NervesCache.misses(result)
    assert length(misses) == 4
    assert NervesCache.allowed(misses, ["nerves_system_rpi4", "a"]) == [%{name: "nerves_system_rpi4", version: "1.30.0"}, %{name: "a", version: "1"}]
    assert NervesCache.misses(%{}) == []
  end

  test "warm runs the worker read-write in warm_nerves mode only for allowed pairs", %{config: config, dir: dir} do
    fake = Path.expand("../support/fake_docker.sh", __DIR__)
    argv_log = Path.join(dir, "argv.log")
    System.put_env("FAKE_DOCKER_ARGV_LOG", argv_log)
    System.put_env("FAKE_DOCKER_RESULT", ~s({"scope":"warm_nerves"}))
    config = %{config | docker_bin: fake}
    claim = %{"run_id" => "rb-jason-1.4.4-1", "image" => %{"name" => "ghcr.io/x/ncc-worker", "digest" => "sha256:" <> String.duplicate("a", 64)}, "input" => %{"run_id" => "rb-jason-1.4.4-1", "image" => %{}, "package" => %{}, "paths" => %{}}, "warm_allowlist" => ["nerves_system_rpi4"], "timeout_sec" => 60}

    assert :skipped = NervesCache.warm(config, claim, %{"nerves_cache" => %{"misses" => [%{"name" => "evil", "version" => "1"}]}})
    refute File.exists?(argv_log)

    assert :ok = NervesCache.warm(config, claim, %{"nerves_cache" => %{"misses" => [%{"name" => "nerves_system_rpi4", "version" => "1.30.0"}]}})
    argv = File.read!(argv_log)
    assert argv =~ "type=bind,source=#{Path.join(dir, "nerves-cache")},target=/nerves-cache "
    refute argv =~ "target=/nerves-cache,readonly"
    [input] = Path.wildcard(Path.join(dir, "scratch/*/work/input.json")) |> Enum.map(&File.read!/1) |> Enum.map(&Jason.decode!/1)
    assert input["mode"] == "warm_nerves" and input["nerves_packages"] == [%{"name" => "nerves_system_rpi4", "version" => "1.30.0"}]
  end
end
```

(The fake docker must keep the input.json readable after exit for the last assertion; have `warm/3` leave the warm scratch until after the input is written and only remove it at the end — the test reads the argv log and the input before `warm/3` returns? No: make `warm/3` accept `keep_scratch: true` in a fourth `opts` argument used only by the test.)

- [ ] **Step 2: Run, expect failure**

- [ ] **Step 3: Implement `NervesCache` and wire `Job`**

The warm container's argv: same `spec` as the build with `run_id: "#{run_id}-warm"`, `nerves_cache_mode: :readwrite`, `hardening: true`, the warm scratch's `work/out/files/tmp/cache` dirs, and `extra_env` from `prepare/2`. `input.json` = `claim["input"]` with `"mode" => "warm_nerves"`, `"nerves_packages" => pairs` (string keys), `"run_id" => "#{run_id}-warm"`, and without `systems_filter`/`argus`.

- [ ] **Step 4: Run `mix test apps/ncc_agent/test/`, expect PASS**

- [ ] **Step 5: Commit**

```bash
git add apps/ncc_agent
git commit -m "ncc_agent: per-run Nerves-cache symlink farm and allowlisted warm

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 15: Agent isolation piece 2 — egress ruleset in `DOCKER-USER`, verified before every claim (isolation design section 3)

**Files:**
- Create: `apps/ncc_agent/priv/egress.sh`, `apps/ncc_agent/lib/ncc_agent/egress.ex` (replacing the Task 13 stub)
- Modify: `apps/ncc_agent/lib/ncc_agent/slot.ex` (verify before claim; report `egress: missing` through `Client.status/3` and do not claim), `apps/ncc_agent/lib/ncc_agent/application.ex` (`Egress.install/0` on start, logged), `.github/workflows/deploy.yml` (validation list gains `apps/ncc_agent/priv/egress.sh`)
- Test: `apps/ncc_agent/test/ncc_agent/egress_test.exs`, `apps/ncc_agent/test/support/fake_iptables.sh`

**Interfaces:**
- `priv/egress.sh install` creates chain `NCC-EGRESS` in the `filter` table (if missing), flushes it, adds in order: `-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT` is **not** added (the rules apply to container-originated traffic only; return traffic is handled by Docker's own chains); `-p udp --dport 53 -j ACCEPT`; `-p tcp --dport 53 -j ACCEPT`; `-d 10.0.0.0/8 -j DROP`; `-d 172.16.0.0/12 -j DROP`; `-d 192.168.0.0/16 -j DROP`; `-d 100.64.0.0/10 -j DROP`; `-d 169.254.0.0/16 -j DROP`; `-d 127.0.0.0/8 -j DROP`; `-p tcp --dport 443 -j ACCEPT`; `-p tcp --dport 80 -j ACCEPT`; `-j DROP`; then ensures `-I DOCKER-USER 1 -j NCC-EGRESS` is present exactly once (`iptables -C DOCKER-USER -j NCC-EGRESS || iptables -I DOCKER-USER 1 -j NCC-EGRESS`). The DNS accepts are placed **before** the RFC1918 drops on purpose: the VM's resolver is usually a private address (`127.0.0.53`, the VPC resolver); DNS is the one private destination a build needs. The same with `ip6tables` when `ip6tables -S DOCKER-USER` succeeds: drop `fc00::/7`, `fe80::/10`, `::1/128`, accept 53 and tcp 80/443, drop the rest. Uses `$IPTABLES`/`$IP6TABLES` env overrides (default `iptables`/`ip6tables`) so tests can stub them. `priv/egress.sh verify` exits 0 only when `iptables -S DOCKER-USER` contains `-j NCC-EGRESS` and `iptables -S NCC-EGRESS` contains `-d 169.254.0.0/16 -j DROP` and `-d 10.0.0.0/8 -j DROP`; exits 1 otherwise, printing why. `set -euo pipefail`, shellcheck-clean.
- `NccAgent.Egress.install/0 :: :ok | {:error, String.t()}` runs `[config.egress_script, "install"]`; `verify/0 :: :ok | {:error, String.t()}` runs `[config.egress_script, "verify"]` (both via `System.cmd` with `stderr_to_stdout`, 30 s timeout through a Task); `status/0 :: "ok" | "missing"`.
- `Slot`: before every claim `Egress.verify/0`; on `{:error, why}` it logs, tries `Egress.install/0` once, verifies again, and if still failing posts `Client.status(req, "missing", 0)` and waits 60 s without claiming. The claim is made only after a passing verify.
- The spec's `ops/builder-egress-docker-user.nft` is replaced by this `iptables` script (ruling, see the PR body): Docker on Ubuntu 24.04 programs `DOCKER-USER` through iptables-nft, and an `nft` ruleset in a separate table does not sit in Docker's chain order; `iptables` is what Docker itself requires on the host, so it is always present.

- [ ] **Step 1: Write the fake iptables and the failing test**

`test/support/fake_iptables.sh`: records every invocation to `$FAKE_IPTABLES_LOG`; keeps chain state in `$FAKE_IPTABLES_STATE` (a directory: one file per chain holding its `-S` output lines); implements `-N`, `-F`, `-A`, `-I`, `-C`, `-S`, `-D` well enough for the script (`-C` greps the chain file; `-S CHAIN` prints `-N CHAIN` then the rules; a missing chain exits 1). Pre-seed `DOCKER-USER` when `$FAKE_IPTABLES_DOCKER_USER=1`.

```elixir
defmodule NccAgent.EgressTest do
  use ExUnit.Case, async: false

  alias NccAgent.{Config, Egress}

  @script Path.expand("../../priv/egress.sh", __DIR__)
  @fake Path.expand("../support/fake_iptables.sh", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "egress-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "state"))
    System.put_env("IPTABLES", @fake)
    System.put_env("IP6TABLES", "/bin/false")
    System.put_env("FAKE_IPTABLES_LOG", Path.join(dir, "log"))
    System.put_env("FAKE_IPTABLES_STATE", Path.join(dir, "state"))
    File.write!(Path.join([dir, "state", "DOCKER-USER"]), "-N DOCKER-USER\n-A DOCKER-USER -j RETURN\n")
    Config.put(%{Config.defaults() | portal_url: "https://x", egress_script: @script, data_dir: dir})
    on_exit(fn -> File.rm_rf(dir); for k <- ~w(IPTABLES IP6TABLES FAKE_IPTABLES_LOG FAKE_IPTABLES_STATE), do: System.delete_env(k) end)
    %{dir: dir}
  end

  test "verify fails before install and passes after; install is idempotent", %{dir: dir} do
    assert {:error, why} = Egress.verify()
    assert why =~ "NCC-EGRESS"
    assert :ok = Egress.install()
    assert :ok = Egress.verify()
    rules = File.read!(Path.join([dir, "state", "NCC-EGRESS"]))
    assert rules =~ "-d 169.254.0.0/16 -j DROP"
    assert rules =~ "-d 100.64.0.0/10 -j DROP"
    assert rules =~ "-p tcp --dport 443 -j ACCEPT"
    assert String.ends_with?(String.trim(rules), "-j DROP")
    dns_index = rules |> String.split("\n") |> Enum.find_index(&(&1 =~ "--dport 53"))
    drop_index = rules |> String.split("\n") |> Enum.find_index(&(&1 =~ "10.0.0.0/8"))
    assert dns_index < drop_index
    assert :ok = Egress.install()
    assert length(Regex.scan(~r/-j NCC-EGRESS/, File.read!(Path.join([dir, "state", "DOCKER-USER"])))) == 1
    assert Egress.status() == "ok"
  end

  test "a rule removed after install fails verify again", %{dir: dir} do
    :ok = Egress.install()
    File.write!(Path.join([dir, "state", "NCC-EGRESS"]), "-N NCC-EGRESS\n")
    assert {:error, _} = Egress.verify()
    assert Egress.status() == "missing"
  end
end
```

Also a `Slot` test (in `slot_test.exs`, with the fake portal): when `egress_script` points at a script that always exits 1, the slot posts `/builder/v1/status` with `"egress" => "missing"` and never calls `/jobs/claim`; when it exits 0, a claim follows.

- [ ] **Step 2: Run, expect failure**

- [ ] **Step 3: Implement the script and the module; wire `Slot` and `Application`; run `shellcheck -x apps/ncc_agent/priv/egress.sh`**

- [ ] **Step 4: Run `mix test apps/ncc_agent/test/`, expect PASS**

- [ ] **Step 5: Commit**

```bash
git add apps/ncc_agent .github/workflows/deploy.yml
git commit -m "ncc_agent: install and verify the DOCKER-USER egress ruleset before every claim

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 16: Agent isolation piece 3 — the post-isolation argv parity fixture

**Files:**
- Create: `apps/ncc_agent/test/ncc_agent/argv_parity_test.exs`, `apps/ncc_agent/test/fixtures/post_isolation_argv.txt`

**Interfaces:**
- `NccAgent.Job.argv_spec(config, claim, dirs, env) :: Compatibility.Builder.Argv.spec()` is extracted from `Job.build/5` (pure) so the fixture test can call it without Docker.
- The fixture is the exact argv (one argument per line) for `claim` = `%{"run_id" => "rb-jason-1.4.4-1700000000000", "image" => %{"name" => "ghcr.io/tomhoenderdos/ncc-worker", "digest" => "sha256:" <> String.duplicate("a", 64)}}`, `config` with `data_dir: "/srv/ncc"`, `build_user: "1001:1001"`, `cpus: "4"`, `memory: "8g"`, `build_concurrency: nil`, dirs under `/srv/ncc/scratch/rb-jason-1.4.4-1700000000000/`, and the `NERVES_*` env from Task 14. It must contain, in this order after the base flags: `--read-only`, `--pids-limit 4096`, `--cpus 4 --memory 8g`, the `/work`, `/out`, `/files` binds, the `/tmp` and `/home/nerves/.cache` scratch binds, `type=bind,source=/srv/ncc/nerves-cache,target=/nerves-cache,readonly`, the `/hex-cache` bind, **no** `/build-cache` bind (the agent never promotes into a build cache), the standard env, the CPU env for 4, the two `NERVES_*` env pairs, and finally `ghcr.io/tomhoenderdos/ncc-worker@sha256:aaaa…`.

- [ ] **Step 1: Write the fixture and the test**

```elixir
defmodule NccAgent.ArgvParityTest do
  @moduledoc """
  The argv the agent runs is the post-isolation argv of the sandbox design:
  read-only Nerves cache at /nerves-cache, read-only root with the scratch
  binds, pids limit. When `Portal.Builder` switches to
  `Compatibility.Builder.Argv` with the same options (feat/sandbox-isolation),
  this fixture and `Portal.BuilderArgvParityTest` describe the same argv.
  """
  use ExUnit.Case, async: true

  alias NccAgent.{Config, Job}

  @fixture Path.expand("../fixtures/post_isolation_argv.txt", __DIR__)

  test "the agent's argv equals the post-isolation fixture" do
    config = %{Config.defaults() | portal_url: "https://x", data_dir: "/srv/ncc", build_user: "1001:1001", cpus: "4", memory: "8g"}
    claim = %{"run_id" => "rb-jason-1.4.4-1700000000000", "image" => %{"name" => "ghcr.io/tomhoenderdos/ncc-worker", "digest" => "sha256:" <> String.duplicate("a", 64)}}
    scratch = "/srv/ncc/scratch/rb-jason-1.4.4-1700000000000"
    dirs = %{work: "#{scratch}/work", out: "#{scratch}/out", files: "#{scratch}/files", tmp: "#{scratch}/tmp", cache: "#{scratch}/cache"}
    env = [{"NERVES_ARTIFACTS_DIR", "/work/nerves/artifacts"}, {"NERVES_DL_DIR", "/work/nerves/dl"}]

    argv = Job.argv_spec(config, claim, dirs, env) |> Compatibility.Builder.Argv.build()
    expected = @fixture |> File.read!() |> String.split("\n", trim: true)
    assert argv == expected
    refute Enum.any?(argv, &String.contains?(&1, "/build-cache"))
    refute Enum.any?(argv, &String.contains?(&1, "/home/nerves/.nerves"))
  end
end
```

Generate the fixture from the implementation once, read it line by line against the list above, and commit it; from then on the fixture is the contract.

- [ ] **Step 2: Run, expect PASS (after extracting `argv_spec/4`)**

- [ ] **Step 3: Commit**

```bash
git add apps/ncc_agent
git commit -m "ncc_agent: pin the post-isolation docker argv as a fixture

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 17: End-to-end tests, operator docs, final gates

**Files:**
- Create: `apps/portal/test/portal/builders/agent_e2e_test.exs` (tag `:e2e`, fake docker, runnable here), `apps/portal/test/portal/builders/remote_integration_test.exs` (tag `:integration`, real Docker, not runnable here), `docs/REMOTE_BUILDERS.md`
- Modify: `apps/portal/test/test_helper.exs` (`exclude: [:integration, :e2e]`), `Makefile` (`test-remote-e2e`, `test-remote-integration`), `CLAUDE.md` (routes, queues, agent app row, how a remote job flows), `DEPLOY.md` (env table: `NCC_BUILDER_CA_KEY`, `NCC_BUILDER_PORT`, `NCC_IMAGES_JSON`, `NCC_UPLOAD_ROOT`, `OBAN_QUEUES` `remote:2` on the web host), `ops/README.md` (images-sync timer, 8443), `apps/ncc_worker/README.md` (nothing changes in the worker contract: note that `paths.nerves_artifacts_dir`/`nerves_dl_dir` may appear in `NCC_INPUT` from a remote agent and are informational until the isolation branch reads them)

**Interfaces:**
- `agent_e2e_test.exs`: in one test: configure a temp CA, start `PortalWeb.BuilderEndpoint` listening on an ephemeral port (`Application.put_env(:portal, PortalWeb.BuilderEndpoint, server: true, https: Portal.Builders.Listener.https_options("localhost") |> Keyword.put(:port, 0))`, then `Supervisor.start_child(Portal.Supervisor, PortalWeb.BuilderEndpoint)` and read the port from `Bandit.PhoenixAdapter.bandit_pid/2` + `ThousandIsland.listener_info/1`; stop it in `on_exit`), mint a token, enqueue a lease for `jason 1.4.4` (through `RemoteBuild.perform` with a temp `images.json`), spawn the agent as an OS process: `Port.open({:spawn_executable, mix}, args: ["run", "--no-halt"], cd: "apps/ncc_agent", env: NCC_PORTAL_URL/NCC_ENROLMENT_TOKEN/NCC_DATA_DIR/NCC_DOCKER_BIN=fake_docker.sh/NCC_EGRESS_SCRIPT=<a stub that exits 0>/FAKE_DOCKER_RESULT=<the result.json fixture with run_id replaced>/FAKE_DOCKER_FILE_CONTENT="precompiled-beam" ...)`, with `MIX_ENV=test` (it uses the compiled umbrella build; `mix run` inside a child app is allowed — only `deps.*` tasks are not); wait (poll `Lease` state via the sandbox-shared connection, up to 120 s) for the lease to reach `:done` and an `Ingest` job to be enqueued; run it with `Oban.Testing.perform_job` (args from the job row); assert the `Run` exists with `builder_id`, the artifact `ce51ace1…` is present in the store, `Catalog.precompiled_manifest("jason")` is nil (publishing false) and non-nil after `Builders.set_publishing(builder, true)`; kill the agent port. Shared sandbox: `Ecto.Adapters.SQL.Sandbox.mode(Portal.Repo, {:shared, self()})` is already what `async: false` gives through `start_owner!`; the endpoint's request processes need the connection too — `use Portal.DataCase, async: false` suffices.
- `remote_integration_test.exs`: same shape against real Docker: `docker_bin` real, `images.json` naming `ncc-worker:local` with its local `Builder.image_digest/1` (local image; the agent's `image_ref` logic must use the bare name when the name has no `/`, exactly as `Portal.Builder.image_ref/1` does — add that rule to `Job`), real egress stub (`NCC_EGRESS_SCRIPT` = a script exiting 0, because the laptop has no `DOCKER-USER` chain; documented), 30 min timeout, asserts as the local `build_integration_test.exs` does plus `builder_id` and the manifest gate.
- `docs/REMOTE_BUILDERS.md` sections: What it is; Portal setup (`mix portal.builder_ca.init` / `bin/portal eval`, `NCC_BUILDER_CA_KEY`, `NCC_BUILDER_PORT`, firewall 8443, `OBAN_QUEUES` on the web host gains `remote:2`, `NCC_UPLOAD_ROOT`, `NCC_IMAGES_JSON` and the `ncc-images-sync.timer` unit text calling `ops/images-sync.sh "$(cd /opt/nerves_compatibility/src && git rev-parse HEAD)"` every 10 min); Enrolling a builder (admin tab → token → cloud-init); the cloud-init (`#cloud-config`: `apt` docker.io + iptables + curl, `users: ncc-build` (system user), `write_files: /etc/ncc-agent.env` mode 0600 with the env keys, `runcmd`: `mkdir -p /srv/ncc/releases`, download `ncc-agent-$(uname -m).tar.gz` from the release URL in `images.json`, verify the sha256 from `images.json`, extract to `/srv/ncc/releases/<version>/`, `ln -sfn` `current`, install `ncc-agent.service` from `/srv/ncc/releases/current/ncc_agent/rel/ncc-agent.service` (the release copies `rel/*.service`; add `apps/ncc_agent/rel/overlays/` so `mix release` ships the unit and the env example), `systemctl enable --now ncc-agent`); What the agent does (loop, isolation: farm, egress, argv); Operating (publishing flip after inspecting first runs, revoke and what it triggers, requeue a failed lease, the reaper's timings, remote routing policy); Troubleshooting (403 unknown_builder after CA rotation, 409 egress_missing, 507 insufficient_disk, 425 too_early); Manual deploy steps summarised.

- [ ] **Step 1: Write both tests and the docs**

- [ ] **Step 2: Run the e2e test**

Run: `source ~/toolchain/env.sh && mix test apps/portal/test/portal/builders/agent_e2e_test.exs --only e2e`
Expected: PASS (fake docker). Record the output for the PR body. The `:integration` test is not run here (no Docker); say so.

- [ ] **Step 3: Full gates**

```bash
source ~/toolchain/env.sh
mix format --check-formatted
mix compile --warnings-as-errors
mix credo
mix test
mix sobelow --root apps/portal --private --skip --strict --exit low; echo "portal sobelow $?"
mix sobelow --root apps/ncc_worker --no-router --private --skip --strict --exit low; echo "worker sobelow $?"
mix sobelow --root apps/compatibility --private --skip --strict --exit low; echo "compat sobelow $?"
mix sobelow --root apps/ncc_agent --no-router --private --skip --strict --exit low; echo "agent sobelow $?"
mix do deps.loadpaths + deps.audit
mix hex.audit
bash -n ops/deploy.sh ops/wait-for-checks.sh ops/builder-deploy.sh ops/ssh-deploy.sh ops/images-sync.sh apps/ncc_agent/priv/egress.sh
shellcheck -x ops/deploy.sh ops/wait-for-checks.sh ops/builder-deploy.sh ops/ssh-deploy.sh ops/images-sync.sh apps/ncc_agent/priv/egress.sh
python3 -m unittest discover -s ops -p 'test_*.py'
python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('.github/workflows/*.yml')]"
git diff --exit-code mix.lock
```

Every exit code 0.

- [ ] **Step 4: Commit**

```bash
git add -A apps docs CLAUDE.md DEPLOY.md Makefile ops
git commit -m "Remote builders: end-to-end tests, operator guide, cloud-init

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Rulings made in this plan (to be listed in the PR body with their cost if wrong)

1. `Portal.Builder.build_docker_args/4` is left untouched; `Compatibility.Builder.Argv` reproduces it and the parity test pins them. Cost if wrong: one more edit when `feat/sandbox-isolation` lands (switch `Portal.Builder` to `Argv.build/1`); no runtime risk.
2. Remote ingests run on the `:remote` queue (web host), not the shared `:ingest` queue a build host could take. Cost if wrong: an operator who omits `remote:2` from the web host's `OBAN_QUEUES` sees leases complete but never ingest (visible on the admin tab as `done` leases without a run).
3. The agent runs as root (it drives rootful Docker and iptables) and builds as `NCC_BUILD_USER` (an unprivileged uid created by cloud-init). Cost if wrong: if the uid cannot write the chowned scratch, builds fail with exit 10 visibly; no isolation regression.
4. Egress rules through `iptables` into `DOCKER-USER` (script `priv/egress.sh`), not an `nft` file. Cost if wrong: on a host where Docker uses native nftables (`--firewall-backend nftables`, Docker 28+ opt-in), `DOCKER-USER` may not exist and the agent refuses to claim (fail closed), which the admin tab shows as `egress: missing`.
5. The warm allowlist served in the claim comes from the portal's static list of official Nerves packages (`Portal.Builders.WarmAllowlist`, sourced from `ToolingSkip`), to be replaced by `Portal.HexPm.owners/1` when the isolation branch provides it. Cost if wrong: a name missing from the list is simply never warmed remotely (slower builds, no risk).
6. The agent never mounts a build cache (`build_cache: nil`). Cost if wrong: remote builds compile dependencies cold; correctness unaffected.
7. `NERVES_ARTIFACTS_DIR`/`NERVES_DL_DIR` are passed both as container env and under `input.paths`. Cost if wrong: if the isolation branch picks another input key, the env still steers Nerves; the worker's own setting (when it lands) takes precedence inside the container.
8. Agent version = `<commit unix seconds>.<12-char sha>`, compared on the integer; dev builds never self-update. Cost if wrong: none for correctness; a non-monotonic clock on the CI runner could skip an update until the next commit.
9. `remote_mode` auto hysteresis persists its last decision in `settings.remote_auto_on`. Cost if wrong: a stale `true` between 5 and 15 minutes after the last builder vanished routes a few jobs remote that wait in `queued` until a builder returns or the admin requeues; the reaper never touches `queued`, so those leases are visible and recoverable from the admin tab.
10. `images.json` reaches the web host through `ops/images-sync.sh` (deploy best-effort + a systemd timer), not through the deploy workflow itself. Cost if wrong: remote routing stays local until the file appears; nothing breaks.
11. A test-only `NCC_EGRESS_SCRIPT` override exists so the e2e tests can run without `DOCKER-USER`. Cost if wrong: an operator could point production at a stub; documented as test-only, and the admin tab shows the builder's egress status as reported.
