# Remote builders: landing notes

Date: 2026-10-26. The 44 commits of `feat/remote-builders` (built from
`docs/superpowers/specs/2026-10-25-remote-builders-design.md` v2 and
`docs/superpowers/plans/2026-10-25-remote-builders.md`) rebased onto
`main` at `5d41ee0` ("Bump ash to 3.37.2 past this morning's advisory"),
reconciled with the sandbox-isolation work main carries, gated, reviewed
adversarially in four layers, and fixed. Nothing here is merged or
deployed; the laptop session lands it.

## Rebase: what conflicted and how it was resolved

`main` had moved 34 commits past the branch's base `9ddcad3`, carrying its
own `Compatibility.Builder.Argv`, the read-only Nerves cache with the
worker-side per-run symlink farm, the host-side egress filter
(`ops/builder-egress*.nft`, `Portal.EgressCheck`), `ops/deploy-builders.sh`
and two Ash advisory bumps. Five files conflicted (the task note said
three; `ops/deploy.sh` and `.github/workflows/deploy.yml` were the other
two). Each was touched by exactly one branch commit, so each was resolved
once, at that commit:

| File | Conflict | Resolution |
| --- | --- | --- |
| `apps/compatibility/lib/compatibility/builder/argv.ex` | add/add: two independent implementations | **main's module is the base**, byte for byte (production runs it). Added only `safe_name/1` and `container_name/1`, which the agent needs for its scratch and container names. The branch's `:legacy`/`:readwrite` modes, `hardening:`, `extra_env:` and flat `work_dir`/`output_dir` spec shape were not ported: on main every build is hardened and the spec carries `paths`. |
| `apps/compatibility/test/compatibility/builder/argv_test.exs` | add/add | main's test plus one test for the two name helpers. |
| `ops/README.md` | both sides extended the script table | both kept: main's `deploy-builders.sh`, `builder-egress-load.sh`, `*.nft` rows and the branch's `images-sync.sh` row; main's "Egress filter" section and the branch's "Remote builders" section both stay. |
| `ops/deploy.sh` | both appended a tail block after `sleep_until_up` | one `if builder / else` block: builder deploys run main's `builder_check_running_egress`, portal deploys run the branch's best-effort `images-sync.sh`. |
| `.github/workflows/deploy.yml` | both extended the "Validate deployment scripts" list | the branch's one-file-per-call `bash -n` loop over the union of both lists (main's `builder-egress-load.sh`, `deploy-builders.sh` plus `images-sync.sh` and `apps/ncc_agent/priv/egress.sh`), same union for `shellcheck -x`. Hit again at the egress-ruleset commit; kept the merged list. |

Auto-merged but checked by hand: `apps/portal/lib/portal/application.ex`
(main's `WarmNerves.with_local_queue` and the ETS tables next to the
branch's `RateLimit` child and `Listener.configure/0`),
`apps/portal/lib/portal/workers/build.ex` (uniqueness `fields: [:args]`
on top of main's warm request), `apps/portal/lib/portal/workers/ingest.ex`
(the remote source next to main's toolchain path), `config/runtime.exs`,
`apps/portal/config/*.exs`, `mix.lock`.

### Follow-up commits after the rebase

1. **Reconcile the agent with main's Argv and Nerves cache** (`dde009a`).
   The branch was written ahead of the isolation work and did host-side what
   main's worker now does in the container:
   - `NccAgent.Job.argv_spec/3` builds main's spec (`container_name`,
     `paths`, `nerves_cache_mode: :readonly`, `build_cache: nil`).
   - The agent no longer builds a symlink farm or passes
     `NERVES_ARTIFACTS_DIR`/`NERVES_DL_DIR`; `input.json` is the claim's
     `input` (`Portal.Builder.worker_input/1`) verbatim. `NccWorker.NervesCache`
     lays out the farm inside the container.
   - The warm decision moved to the portal, as on the local host: the
     `complete` answer carries `warm`, computed by
     `Portal.NervesCache.warm_pairs/2` over the uploaded `result.json`
     (named by the run's lock, owned by the `nerves` Hex user, at most
     four). The agent re-checks the shape and runs exactly those pairs with
     the cache mounted `:warm`. `Portal.Builders.WarmAllowlist`, the static
     list the claim carried (its own moduledoc called it a placeholder for
     `Portal.HexPm.owners/1`), is gone, and so is `warm_allowlist` from the
     claim body. This is a deliberate deviation from spec section 5 ("the
     allowlist travels in the claim response"), in the spec's own
     direction: the portal decides, the agent has no policy.
   - `NccAgent.ArgvParityTest` checks against the shared fixture
     `apps/compatibility/test/fixtures/argv/post_isolation.exs` minus the
     build-cache pair; the branch's own fixture and the portal's duplicate
     parity test are deleted (main's `Portal.BuilderTest` "argv parity"
     covers the portal). `Portal.Builder.safe_name/1` delegates to
     `Argv.safe_name/1`.
   - `docs/REMOTE_BUILDERS.md` loses its "Depends on feat/sandbox-isolation"
     section; the worker README's informational-paths paragraph is reverted.
2. **MAKEFLAGS** (`b8b8913`). `feat/makeflags-libnl` was not on main when
   fetched, so per the task note `"-e", "MAKEFLAGS=-j#{quota}"` follows
   `NCC_SQUASHFS_PROCESSORS` in `Argv.cpu_env/1`, in the fixture and in every
   parity test. **Note for the landing:** main's module carried a comment
   and a `Portal.BuilderTest` test ("make runs serially, as it does for a
   user") deliberately *not* setting it, citing circuits_spi 2.1.0 on rpi4;
   both were rewritten to pin the bound instead. If `feat/makeflags-libnl`
   lands first with a different position or wording, expect a small
   conflict in `argv.ex`, the fixture, `argv_test.exs` and
   `builder_test.exs`; the branch's version should then yield to main's.
3. Fake-portal clause grouping (`5aca9f5`), found by the forced compile gate.

## Gates

Run from the umbrella root on OTP 28.5.0.8 / Elixir 1.20.0 / PostgreSQL 17.4
(the CI versions), after the three follow-up commits above:

| Gate | Result |
| --- | --- |
| `mix format --check-formatted` | exit 0 |
| `mix compile --warnings-as-errors --force` | exit 0 (first run exit 1: `defp route/4` clauses split by a helper in `test/support/fake_portal.ex`; fixed in `5aca9f5`) |
| `mix credo` | exit 0, "3999 mods/funs, found no issues" |
| `mix test` | exit 0: compatibility 24, ncc_worker 270, portal 1616 (9 excluded: `:integration`, `:e2e`), ncc_agent 86; all passed |
| `mix sobelow --root apps/portal --private --skip --strict --exit low` | exit 0 |
| `mix sobelow --root apps/ncc_worker --no-router --private --skip --strict --exit low` | exit 0 |
| `mix sobelow --root apps/compatibility --private --skip --strict --exit low` | exit 0 |
| `mix sobelow --root apps/ncc_agent --no-router --private --skip --strict --exit low` | exit 0 |
| `mix do deps.loadpaths + deps.audit` | exit 0, "No vulnerabilities found" |
| `mix hex.audit` | exit 0, "No retired or security advisory packages found" |
| `bash -n` on every `ops/*.sh` and `apps/ncc_agent/priv/egress.sh` | all parse |
| `shellcheck ops/*.sh apps/ncc_agent/priv/egress.sh` | exit 0 |
| `python3 -m unittest discover -s ops -p 'test_*.py'` | 56 tests OK (1 skipped) |
| `make test-remote-e2e` (real `ncc_agent` process, fake docker, tag `:e2e`) | 1 passed |

Not run: `make test-integration` and `make test-remote-integration` (need
Docker and the `ncc-worker:local` image; this box has neither). Run them
on a build host before going live, as `CLAUDE.md` asks after any change to
the Docker invocation.

`.github/workflows/sobelow.yml` already lists `ncc_agent` in its matrix;
`credo.yml` runs umbrella-wide. Migrations `20261025204639_remote_builders`
and `20261025233114_run_builder_index` only create tables, columns and new
indexes; no existing unique index is touched.

## Adversarial review

Four reviewers, fresh context each, one layer each, with the spec section
and the diff of their files only. Findings per layer, with what was fixed
or why not, follow.

Severities are the reviewers'. "Fixed" means in commits `77d935f` (portal)
and `7d18312` (agent) plus the re-review follow-ups; every fix was re-read by
the same reviewer with the diff of the fix.

### Layer 1: CA, certificates, enrolment tokens, the mTLS endpoint, revocation

No critical or high findings. Confirmed correct by the reviewer: peer
certificate from the TLS layer only, `verify_peer` really active on the
socket (real-handshake test), trust anchor the portal CA alone on both
sides, CSR subject ignored, `CA:false` client certs, fingerprint lookup with
the 24 h overlap, token hashing and constant-time compare, atomic key
writes, revocation covering old fingerprints and racing completes,
additive-only migration.

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| 1 | medium | An unwritable CA dir (owner, disk full, cert within 30 days of expiry) raised inside `Listener.configure/0` at boot and took the public site down with it. | Fixed: `CA.issue_server_cert/5` rescues `File.Error`/`MatchError` into `{:error, {:server_cert, _}}`; the listener runs without its port. Test with a read-only CA dir. |
| 2 | low | Any CSR key type was signed (RSA-512, odd curves). | Fixed: P-256 only, the key the agent generates. Tests for P-384 and RSA-1024. |
| 3 | low | Server certificate carried `extKeyUsage: serverAuth, clientAuth`. | Fixed: `serverAuth` only, asserted by OID. |
| 4 | low | `x-ncc-agent-version` header stored unbounded in `builders.last_version`. | Fixed: sliced to 64 chars in the plug. |
| 5 | low | Token single use enforced only transitively by the builder name's unique index. | Fixed: `spend_token/1`, a conditional `UPDATE ... WHERE used_at IS NULL`, first in the enrolment transaction. |
| 6 | low | Unauthenticated `GET /ca.pem` read and parsed the CA private key per request, unlimited. | Fixed: reads `ca.pem` only; 30/min per IP. |
| 7 | info | Rate limiter keyed per exact IP (IPv6 /64 gives many keys). | Not changed: memory bounded by request rate × 60 s. |
| 8 | info | The token's 64-bit CA prefix. | Not changed: the spec sets 16 hex chars; noted for a later token format. |
| 9-11 | info | Unreachable 403 branch on renew; `.prev` key kept; IP in `PHX_HOST` yields a DNS SAN. | Not changed. |
| re-review | low | `stage/3` ignored `IO.binwrite/2`'s result: an ENOSPC short write could rename a truncated key into place. | Fixed: `:ok = IO.binwrite`, `:ok = File.close`, inside the rescued body. |

Spec deviations noted: `POST /builder/v1/status` (egress status) is an
extension; `cipher_suite: :strong` makes 8443 TLS 1.3 only; JSON body limit
is 8,000,000 bytes rather than 8 MiB.

### Layer 2: leases, claim atomicity, heartbeat, reaper, requeue, RequestSync

No critical or high findings. Confirmed correct: the single `UPDATE ... FOR
UPDATE SKIP LOCKED` claim with the slot check in its `WHERE` behind a
per-builder advisory lock; every later transition guarded on state,
builder and `run_id`; `done` + `Ingest` in one transaction; long poll
subscribed before the first attempt and holding no DB connection; heartbeat
tail bounded server-side; reaper thresholds and attempt counting; exit code
mapping; routing policy and hysteresis; Oban uniqueness across `Build` and
`RemoteBuild`; RequestSync treating `queued|leased|uploading` as holding a
request and `done|failed` as not; admin actions behind the admin pipeline.

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| 1 | medium | `lease_in_flight?` ignored `:done`, so a second lease could be written for the same build between `complete` and ingest. | Fixed: `:done` counts as in flight. Test. |
| 2 | medium | A `queued` lease nobody will claim (dead or absent builders) stranded its request for good; no admin path out. | Fixed: "Requeue locally" accepts `queued` leases (`Leases.mark_requeued_locally/1` moves it to `failed`/"requeued locally" and enqueues a pinned local build). Test. |
| 3 | medium-low | The `:remote` queue runs with limit 2 and the dedup was read-then-write. | Fixed: advisory lock on the build around the dedup checks and the insert. Queue limit left at 2 (ingests share it). |
| 4 | low | A stale attempt from the same builder (reaped, then reclaimed by the same builder with `slots > 1`) is accepted as the current one. | Not changed: same builder, same package/version/digest, attempt bookkeeping only; would need `run_id` in every agent request. Noted. |
| 5 | low | A failing `complete` deleted the upload dir on requeue and discarded the runner log. | Fixed: dir kept on `:requeued`; the runner log part's tail becomes the request's `error_log` when the lease fails. `bytes_uploaded` is now per lease (kept by the claim, zeroed by fail/requeue). Tests. |
| 6 | low | The 150-min lease ceiling could reap a live run (30 min pull + 2 h build). | Fixed: 180 min. |
| 7 | low | Revoke's requeue did not wake waiting claimants; a `done` lease of the revoked builder whose ingest had not run was dropped by Ingest without a rebuild. | Fixed: broadcast per requeued lease; `done` leases without a run fail and their packages join the rebuild. |
| 8 | low | No index on `builder_leases.scan_request_id`; a text cast defeats indexes in `BulkRebuild.remote_lease_counts/1`. | Not changed: performance only, bounded by the bulk's job count; a later migration. |
| 9-13 | info | Advisory-lock keyspace shared with Oban; admin broadcast before commit; requeue offered for exit-11 leases; `BulkRebuild.cancel` does not cancel leases; orphaned `leased` rows after an agent restart. | #11 fixed (button hidden for `non-Hex dep`); the rest noted. |

Spec deviations noted: backlog counts `retryable` too; the first `:building`
broadcast is the first heartbeat.

### Layer 3: uploads, tar verification, ingest on the web host, publication

Confirmed correct: tar parsing accepts only plain regular entries named by
a 64-hex sha (PAX/GNU/long names, links, directories, devices, separators,
uppercase all refuse the batch); sha256 over exactly the written bytes with
an exclusive temp file renamed only on match; byte reservation before the
read and settlement after, also on raise/exit; `Content-Length` handling and
the never-buffered body; result.json decoded as an object before write;
logs inflated chunkwise with per-entry and total caps on inflated bytes;
atomic log names; `load_run` shape; Ingestion re-hashing every blob; the
manifests, `packages_with_precompiled_files`, batches and `root.json`
gated on the builder; no error-response leaks.

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| 1 | **high** | result.json's `package.name`/`version` were never bound to the lease: an enrolled builder (publishing or not) could write a run, latest version and stats for *any* package. | Fixed: `complete` refuses a mismatch with 422 `result_mismatch` and the lease stays held; `Upload.load_run/1` checks again against the lease and Ingest fails the lease. Tests at both levels. |
| 2 | medium | `/api/precompiled/files/:sha256` served any blob with an `Artifact` row, so a non-publishing or revoked builder's bytes stayed fetchable by sha. | Fixed: `Catalog.published_sha256?/1`, the manifests' join, gates the blob endpoint. Test. |
| 3 | medium | No cap on the *number* of uploaded files per lease (`max_files` bounded `missing` only): inode exhaustion and O(n²) sweeps. | Fixed: per-batch entry budget of `max_files` minus what the dir holds; 422 `too_many_files`. Test. |
| 4 | low | The runner.log part was uncapped on disk. | Fixed: 2 MiB cap, 413 `runner_log_too_large`. |
| 5 | low | Free-space floor checked once per batch and not for `write_outputs`. | Fixed: checked before `write_outputs` and every 64 MiB inside a batch. |
| 6 | low | Upload dir persisted across reaper requeues while `bytes_uploaded` reset per attempt. | Fixed: the quota is per lease; the claim keeps the count, fail/requeue zero it with the dir. |
| 7 | low | The `warm` computation could hold `complete` for up to 16 sequential Hex lookups. | Fixed: 10 s deadline in a task; `[]` past it. |
| 8 | low | `Images.agent/0` did not validate release `url`/`sha256`. | Fixed: https only, 64-hex sha256. Test. |
| 9-12 | info | Tar checksum unverified; `missing` is a presence oracle; two concurrent `complete`s on one lease (self-inflicted); result-derived strings in `error_reason`. | Not changed. |

Spec deviations noted: `runner_log` is an extra multipart part (now capped).

### Layer 4: the agent (egress, Nerves cache, self-update, argv parity, the container's reach)

Confirmed correct: `/files` listing by sha regex and lstat; result.json and
logs read only as regular files, `erl_tar` without dereference; `rm_rf` and
`chown -h` as root; `prepare_cache` replacing a symlinked cache root without
following it; `pairs/1` shape check and the worker's own gate on warm input;
argv parity with the shared fixture and no shell; kill by name on timeout;
egress rule order (conntrack, DNS, IMDS and private drops before the 80/443
accepts) and fail-closed on any verify failure; self-update sha check,
`erl_tar` path safety, atomic `current` swap; identity file modes; client
TLS; heartbeat and slot shutdown; images.yml pinned and scoped.

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| 1 | high | `/hex-cache` is mounted read-write by every build (locally too); a package can leave `hex.config`/`cache.ets` for later builds to trust. | Mitigated: `NccAgent.HexCache.prepare/1` removes `hex.config` and `cache.ets` before every run; the next build fetches a registry Hex verifies against its built-in key and a planted tarball fails its checksum. The full fix (read-only mount with host-side promotion, as the build cache has) belongs to the worker and the local host alike; documented. Test. |
| 2 | **high** | The agent ignored the claim's `max_file_bytes`/`max_total_bytes`; a sparse file in `/files` would be tarred dense and fill the builder's disk. | Fixed: `list_files` drops entries over `max_file_bytes` (or over what fits one batch) and stops at `max_total_bytes`, before anything is tarred. Test. |
| 3 | medium/high | `logs.tar.gz` bounded per file and by compressed size only: unbounded count and inflated total. | Fixed: at most 64 logs and 64 MiB together, by lstat before gzip. Test. |
| 4 | medium | Outputs read with path-based calls while the container could still be alive (CLI died or detached): symlink swap between lstat and read. | Fixed: `Docker.gone?/2` after `docker run` (inspect, `rm -f`, inspect); if the container cannot be shown gone the lease completes with 20 and nothing is read. Test. |
| 5 | medium | The container ran as root unless `NCC_BUILD_USER` was set. | Fixed: `Config.load/0` refuses an unset-as-root or `0:*` build user. Test. |
| 6 | medium | `verify` checked two drops and the jump's presence only. | Fixed: the jump must be the first rule of `DOCKER-USER`, `FORWARD` must jump to `DOCKER-USER`, and the chain must be exactly the policy in order (match modules and state order normalised). Tests. |
| 7 | medium | IPv6 failed open when ip6tables had no `DOCKER-USER` chain. | Fixed: then the default bridge must have `EnableIPv6: false` (`docker network inspect`), else verify fails. Test. |
| 8 | medium | Container-to-host (INPUT) traffic unfiltered. | Fixed: chain `NCC-INPUT` first in `INPUT`: conntrack, DNS to the resolvers, drop NEW from `docker0`/`br-+`, then `RETURN` (an earlier draft ended it in DROP, which would have cut the operator's ssh; caught before commit). Test. |
| 9 | low | mTLS client followed redirects; release download uncapped. | Fixed: `redirect: false`; download stops at 512 MiB. |
| 10 | low | A bare image name is run/pulled as-is. | Not changed: the portal only leases registry images; the integration test uses `ncc-worker:local`. Noted. |
| 11 | low | A job task dying abnormally did not hand its lease back. | Fixed: `:DOWN` kills the container and completes with 20. |
| 12 | low | Self-update trusts whatever `images.json` names; "newer" is the leading integer. | Portal side validates URL/sha (layer 3 #8); signing of releases and pruning noted as later work. |
| 13 | low | Install window: `-F` then re-add left the chain empty for a moment. | Fixed: build `NCC-EGRESS-NEW`, insert its jump, remove the old, rename. Test. |
| 14 | low | No re-verification during a build. | Not changed: noted as a follow-up (heartbeat could verify and kill). |
| 15-19 | info | Staging leftovers; `workflow_dispatch` from any branch; `NCC_EGRESS_SCRIPT`/`NCC_DOCKER_BIN` honoured in prod; `safe_name` collisions; 64-bit CA prefix. | Not changed. |

Spec deviations noted: the egress ruleset is iptables (`DOCKER-USER`)
rather than the `nft` file the spec names; the bridge subnet is dropped
through `172.16.0.0/12` only; the farm is the worker's and the warm list
comes back at `complete`, as described above.

RE_REVIEW_PLACEHOLDER


## What an operator still has to do by hand to go live

In order, on the web host unless said otherwise. `docs/REMOTE_BUILDERS.md`
has the commands and unit files.

1. **Deploy** this branch (merged to `main`) through the normal CI deploy;
   `ops/deploy.sh` runs the migration. Nothing changes behaviour yet: the
   listener only starts with a CA key, routing stays local without
   `images.json`.
2. **Create the CA key** as `ncc`, outside the checkout, with the portal
   env sourced: `install -d -o ncc -g ncc -m 0700 /etc/ncc-portal/builder-ca`
   then `bin/portal eval 'Portal.Builders.CA.init("/etc/ncc-portal/builder-ca/ca-key.pem")'`.
   It refuses to overwrite. Back the key up: losing it means re-enrolling
   every builder.
3. **Env file** `/etc/ncc-portal/portal.env`: `NCC_BUILDER_CA_KEY`,
   `NCC_UPLOAD_ROOT` (a filesystem with room for 2 GiB per in-flight
   lease), `OBAN_QUEUES=intake:5,maintenance:1,remote:2` (`remote` is
   required on the web host: remote ingests run there), optionally
   `NCC_BUILDER_PORT` (default 8443) and `NCC_IMAGES_JSON`.
4. **Firewall**: open TCP 8443 to the world on the web host (the client
   certificate is the gate; only `ca.pem` and `enroll` answer without one).
   Apache is not involved; Bandit terminates this TLS itself.
5. **images.yml**: needs no extra secrets (`GITHUB_TOKEN` with
   `packages: write` for GHCR and `contents: write` for the `agent-<sha>`
   release). Check the repository's Actions settings allow workflow write
   permissions, run the workflow once by hand (`workflow_dispatch`) to prove
   the GHCR push, the two release tarballs and `images.json` land, then set
   the GHCR packages to public.
6. **images.json on the web host**: install and enable
   `ncc-images-sync.timer` (unit texts in `docs/REMOTE_BUILDERS.md`); until
   the file names an `ncc-worker` digest every job stays local.
7. **Restart the portal**; the log should say `builder listener on 8443`.
8. **Enrol the first builder**: `/admin/builders` → New enrolment token
   (24 h, shown once) → boot an Ubuntu 24.04 VM with the cloud-init from
   `docs/REMOTE_BUILDERS.md` (`PORTAL_HOST`, `TOKEN`, `COMMIT` filled in).
   It appears on the tab with `publishing` off and `egress: ok`.
9. **Rehearse** per spec: from a real build on that VM probe
   `http://169.254.169.254/latest/meta-data/` and a tailnet address and
   assert both are refused; run a pinned job; revoke the builder and see its
   run revoked and the version re-enqueued locally. Re-enrol with a new
   token.
10. **Turn remote building on** (`remote_mode` auto or on, backlog
    threshold) and, after inspecting the first runs, flip `publishing` per
    builder.
