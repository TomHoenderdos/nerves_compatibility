# Build cache L2: landing notes

Date: 2026-10-26. Branch `agent/chat-a2c8bc23e08f`, base `main` at `f9d6894`.
Nothing is merged or deployed. Spec: `docs/superpowers/specs/2026-10-26-build-cache-l2-design.md`
(with the amendments added during implementation). Plan:
`docs/superpowers/plans/2026-10-26-build-cache-l2.md`.

## 1. What landed

A second, shared layer behind the local dependency build cache: an
S3-compatible bucket (Garage on `box-b`) that every home build host reads
before `docker run` and writes after every local promotion.

| Module | Role |
| --- | --- |
| `Portal.BuildCache.L2` | `upload/5`, `prefetch/3`, `status/0`, `log_state/0`, `shareable_slug?/1` |
| `Portal.BuildCache.L2.Prefetch` | the bounded sync loop: list the slug, download what is missing, newest first |
| `Portal.BuildCache.L2.Tarball` | pack/unpack one entry; no symlink members, Mix links in `.ncc-links.json`; zlib pre-scan, heap-capped unpack |
| `Portal.BuildCache.L2.Bounded` | run a function in an unlinked process with a heap cap and a deadline |
| `Portal.BuildCache.L2.Client` | HEAD/GET/PUT/LIST over Req with its own SigV4; every call bounded in total time |
| `Portal.BuildCache.L2.Config` | the `NCC_BUILD_CACHE_S3_*` env; secret redacted from `inspect`; http-off-tailnet detection |
| `Portal.BuildCache.L2.Stats` | per-node counters, in-flight claims, keys marked bad for a day |
| `Portal.BuildCache.L2.Push` + `mix portal.build_cache.push` | bounded, resumable push of an existing local cache |
| `Portal.BuildCache.Tree` | Promotion's structural walker, extracted and shared with the download side |
| `Portal.BuildCache.Staging` | `<key>.tmp.<host>.<hex>` staging names, used by Promotion, L2 and Sweep |
| `Portal.Test.FakeS3` | in-process S3 stub on Bandit with an independent SigV4 verifier (two AWS vectors pinned) |

Touched: `Portal.BuildCache.Promotion` (delegates to Tree/Staging; L2 upload
hook after the rename, one upload deadline per call), `Portal.Builder`
(prefetch before `docker run`, free-space gate, prefetch line in
`runner.log`), `Portal.Workers.Sweep` (host-aware, age-bounded staging
rule), `Portal.Application` (Stats child, boot line), `config/runtime.exs`,
the admin Maintenance tab, `DEPLOY.md`, `docs/BUILD_CACHE_L2.md`,
`CLAUDE.md`, `ops/README.md`, and `build_integration_test.exs` (a new
`:integration` test that could not be run here: no Docker).

Not touched, as the brief required: `apps/ncc_worker`, `apps/ncc_agent`,
the docker argv fixture, `mix.lock` (no new dependency).

## 2. Decisions

Beyond the operator's fixed decisions, these were taken during the work.
Each is recorded in the spec; the cost if wrong is what the operator can
undo.

1. **The reader syncs the slug listing; there is no build plan on the
   host.** The worker computes cache keys inside the container after
   `mix deps.get`; the portal cannot without loading untrusted `mix.exs`.
   So `prefetch/3` lists `<slug>/` and downloads what is missing locally,
   newest first, under the budget. The local cache converges over a few
   builds. Cost: a fresh host spends up to five minutes per build catching
   up; entries a host never needs are downloaded too.
2. **gzip through `:erl_tar`, no new dependency.** zstd would need a NIF
   in the web app.
3. **Req's own SigV4; the test stub verifies independently** against the
   AWS `get-vanilla` and S3 "GET object" vectors (both matched on the
   first run).
4. **No symlink members in the tarball.** `:erl_tar.extract` refuses a
   symlink whose target leaves the extraction dir, and Mix's
   `priv -> ../../../../deps/<pkg>/priv` does. Rather than parse tar
   headers by hand (the first implementation did; rejected), the entry's
   top-level Mix links travel as a `.ncc-links.json` manifest (at most
   4096 bytes, keys `priv`/`include`, targets Mix-shaped with the final
   component equal to the key, name not yet present), recreated after
   extraction; `pack` refuses an entry that carries its own
   `.ncc-links.json`. The operator's "no symlinks" rule now holds literally
   for the archive. Cost: a link outside Mix's shape is never shared (a
   lost cache hit, never a wrong build).
5. **Staging names carry the hostname; Sweep prunes only its own host's
   (or the legacy host-less form) and only past the scratch max age.**
   Previously Sweep removed any `.tmp.` name on sight, which could race a
   promotion copy. Caveat documented in Sweep: a promotion staging dir
   inherits the source's mtime from `cp -a`, so the age bound is safe only
   while `NCC_SCRATCH_MAX_AGE_HOURS` exceeds the 2 h build ceiling.
6. **Counters are per node, since boot, in ETS.** On a split deployment
   the Maintenance tab shows the web node's (zero) counters and says which
   node it describes.
7. **The push is `mix portal.build_cache.push`** (repo convention), also
   runnable as `bin/portal eval` with the portal env sourced; a HEAD per
   entry is the resume state.
8. **Unpack is bounded before `:erl_tar.table` runs** (final review,
   Critical 1): a streaming zlib pre-scan refuses anything that inflates
   past 1 GiB (this is what bounds a single huge member, since off-heap
   binaries escape `max_heap_size`), and table/extract/manifest/check/strip
   run in an unlinked process with a 512 MiB heap cap and the remaining
   budget as deadline (this is what bounds a header flood). An unpack that
   times out with its full 120 s is marked bad; one cut short by the build
   budget stops the loop without marking the object.
9. **Uploads are bounded per PUT and per promotion call** (Critical 2):
   each PUT runs in a task killed at its deadline, with a gen_tcp
   `send_timeout`; one `promote/6` call has one 120 s upload budget and
   stops uploading after the first transport, timeout or 5xx failure. The
   Oban Lifeline invariant test now covers build timeout + prefetch budget
   + upload budget.
10. **The sha header is integrity against corruption, not tampering**
    (Important 1). Over plain http an active attacker rewrites header and
    body together. Boot warns when the endpoint is http and the host is
    outside loopback and `100.64.0.0/10`; the docs say http is for the
    tailnet only. No HMAC: the design trusts the write key and the tailnet.
11. **Only content-addressed slugs are shared** (Important 3):
    `sha256_<64 hex>` that is not the zero digest. The zero digest is what
    `Builder.image_digest/1` returns when `docker inspect` fails; the image
    name and `"unknown"` are the local fallbacks.
12. **Disk and extracted bytes are budgeted** (Important 2): free space on
    the cache root is re-checked before every object (threshold
    `NCC_MIN_FREE_GB`, config seam `:prefetch_min_free_bytes`) and the
    pre-scan's decompressed size is charged against a 4 GiB per-build
    extracted budget.

Bounds, as shipped: listing + downloads 5 min and 2 GiB compressed per
build; per object 512 MiB compressed, 1 GiB extracted, 120 s GET and 120 s
unpack; 4 GiB extracted per build; stop on 401/403/5xx, transport error,
timeout, or 5 consecutive non-refusal failures; uploads 120 s per
promotion call. Keys marked bad are skipped for 24 h (in memory only).

## 3. Process

Spec → plan → eleven tasks, each implemented by a fresh subagent and
reviewed by a fresh reviewer (spec compliance + quality), with scoped
re-reviews after fix rounds; then one adversarial whole-branch review on
the most capable model, one fix wave, one scoped re-review of the wave,
and the gates again. The ledger with every ruling and deferred finding is
in the (git-ignored) workspace `.superpowers/sdd/2026-10-26-build-cache-l2/progress.md`
while this session exists; the substance is reproduced below.

Fix rounds per task: Task 3 (1), Task 5 (2), Task 7 (1), Task 10 (1);
the rest approved first time.

## 4. Review findings and dispositions

### Per-task reviews (Important and above; all fixed and re-reviewed)

| Task | Finding | Disposition |
| --- | --- | --- |
| 3 Tarball | `pack/3` did not reserve `.ncc-links.json`: an entry's own file became the manifest, forging a link the package-bound check exists to refuse | fixed: reserved name refused, test |
| 3 Tarball | `restore_links`/`strip_modes` errors escaped the documented shapes | fixed: `{:links, _}` / `{:structure, _}` |
| 5 Client | linked `Task.async` in `get/4`: an I/O error inside the task crashed the caller and left the partial file | fixed: caught inside the task; proven by a test that fails against the pre-fix code (`/dev/full`) |
| 5 Client | sobelow skip on `put/4` not directly above the def | fixed |
| 5 Client (re-review) | `remove/2` would `File.rm` the device node under root | fixed: only regular files are removed |
| 7 Prefetch | listing ran outside the 5 min budget (up to 50 pages × 40 s) | fixed: deadline first, listing in a bounded task |
| 7 Prefetch | status-class GET failures churned through every candidate with a warning each | fixed: stop on 401/403/5xx/exit/exception, and after 5 consecutive failures |
| 10 Docs | deployed-host push shown without sourcing `/etc/ncc-portal/portal.env`, so L2 would be off | fixed in both docs, run as the cache owner |

### Final adversarial review

| Severity | Finding | Disposition |
| --- | --- | --- |
| Critical | `:erl_tar.table/2` materialises a hostile archive before any cap; unpack outside the budget; OOM crash loop | fixed (decision 8) |
| Critical | synchronous per-candidate PUTs could stall a Build job past Lifeline's 3 h rescue | fixed (decision 9) |
| Important | transport-integrity claim false over http | fixed (decision 10) |
| Important | extracted bytes unbudgeted, disk checked once | fixed (decision 12) |
| Important | non-content-addressed slugs shared | fixed (decision 11) |
| Important | throws escaped the task boundaries; upload did not catch exits | fixed: `catch kind, reason` at every boundary |
| Minor, fixed | stale comments in `Tree`; Sweep `cp -a` mtime caveat; `strip_modes` floors 0o700/0o600; archive-applied `eacces`/`eperm` are refusals; unpack mirrors `:empty_entry`; an object grown after listing is a plain failure; the push task refuses unknown options; two test-compile warnings in touched files | fixed |

### Scoped re-review of the fix wave

Verdict: all findings addressed, no new Critical or Important breakage.
The re-reviewer measured the new bounds (a 2 M-header flood killed in
about 9 s under the 512 MiB heap cap; the sparse case below) and
confirmed `send_timeout` reaches `gen_tcp` through Req, Finch and Mint.
Residual minors and their dispositions:

| Finding | Disposition |
| --- | --- |
| GNU sparse members: the table's size exceeds the pre-scanned stream (2 KB stream → 50 MB file), so the extracted budget under-charges and the moduledoc's claim was false for sparse | fixed in the follow-up commit: refused when the table sum exceeds the pre-scanned bytes; claim corrected |
| `Bounded.run` timeout path did not wait for `:DOWN` after the kill (stray result message; a file op could finish after `rm_rf`) | fixed in the follow-up commit |
| member count uncapped (about 600k empty members pass under the heap cap; 600k inodes) | fixed in the follow-up commit: 100 000 members max |
| spec §4.6 omitted `extracted_bytes` | fixed in the follow-up commit |
| `Tarball.pack` runs outside the per-promotion upload deadline (overshoot by one pack) | parked: packing a 512 MiB entry takes seconds |
| the http warning is stricter than its description (it also fires for MagicDNS names and Tailscale's IPv6 range) | parked: the safe direction |
| Promotion's container copies (60 s each) are not in the Lifeline arithmetic | parked: about 53 min of margin remain |
| `strip_modes` floors also apply to L1 promotion copies (0o444 → 0o644) | parked: the cache is mounted read-only |

Follow-up commit `9c110cb` (controller ruling, read by the controller;
focused tests 169 passed): the table's summed member sizes must stay
within both the 1 GiB cap and the pre-scanned inflated size (closes the
sparse hole; `pack` never writes sparse members); more than 100 000
members is `{:error, :too_many_members}` (a refusal); `Bounded.run` waits
for the killed process's `:DOWN` and drains a late result; spec §4.6 lists
`extracted_bytes` and `list_failed`. Not independently re-reviewed beyond
the controller's read of the diff; the gates were run again on it (section 5).

The reviewer's "declined to judge" lines (NixOS evaluation, the Docker
test, worker behaviour on an unreadable entry, bucket pruning,
same-hostname shared roots, a local-user race in the extract window, the
pre-existing L1 slug-fallback inconsistency, admin styling) were accepted
as out of scope.

### Deferred (minor, not fixed; worth a later pass)

- `Stats.claim/1` stale-holder race (two callers both see a dead holder; worst case a duplicate download, which `publish` handles).
- `Stats` bad rows never expire from the table (negligible growth); the bad set is in memory only.
- `FakeS3`: `{:list, :no_token}` fault does not truncate a one-key prefix; XML unescaped (hex keys only); no negative tests for a tampered body or missing `x-amz-date`.
- `Client`: no 50-page-cap test; the "down quickly" test has no time bound; listing values not XML-unescaped; the `/dev/full` test passes vacuously where the device is absent.
- `Promotion`: `upload_to_l2` has no catch-all clause for an `l2:` seam value that is neither `false` nor a function.
- `Prefetch`: time-budget test margin on a slow CI host; sleep-based "newest first" test; prefetch also runs for `warm_nerves`/`argus_only`/`toolchain` runs; `df` in `free_bytes/1` is unbounded (pre-existing); many corrupt objects are bounded by time and the extracted budget, not by compressed bytes.
- `Push`: a mistyped `--root` yields zero entries rather than an error; dry run never HEADs; no tests for a HEAD error, a symlinked entry, `--max-gb` conversion.
- Admin: the on-test does not reset `Stats` in `on_exit`; weak "Off" assertion; a stray space before the read-only comma.
- Integration test: a failing assertion before `Ingest.perform` leaves the scratch dir and the Ingest row (same as its neighbours).
- Tree tests: no non-UTF-8 name, nested `priv` link, or `include` link cases (Promotion's suite covers some).

## 5. Gates

Run from the umbrella root after `source /home/agent/toolchain/env.sh`
(Elixir 1.20.4 / OTP 28.5.0.8 and Postgres 17.11 installed under the home
directory for this session; the host had no Elixir, Docker, shellcheck or
Postgres). Docker is absent, so the `:integration` and `:e2e` tests were
not run; the new integration test compiles and is excluded by default.

Run 2, on the final head `063af3b` (log kept at `/home/agent/toolchain/gates-run2.log` for this session):

| Gate | Exit |
| --- | --- |
| `format` | 0 |
| `compile` | 0 |
| `credo` | 0 |
| `test` | 0 |
| `sobelow-portal` | 0 |
| `sobelow-ncc_worker` | 0 |
| `sobelow-compatibility` | 0 |
| `sobelow-ncc_agent` | 0 |
| `deps-audit` | 0 |
| `hex-audit` | 0 |
| `bash-n ops/build-release.sh` | 0 |
| `bash-n ops/builder-deploy.sh` | 0 |
| `bash-n ops/builder-egress-load.sh` | 0 |
| `bash-n ops/deploy-builders.sh` | 0 |
| `bash-n ops/deploy.sh` | 0 |
| `bash-n ops/images-sync.sh` | 0 |
| `bash-n ops/ssh-deploy.sh` | 0 |
| `bash-n ops/wait-for-checks.sh` | 0 |
| `bash-n apps/ncc_agent/priv/egress.sh` | 0 |
| `shellcheck` | 0 |
| `python` | 0 |

`mix test` per app: compatibility 24 passed; ncc_worker 270 passed; portal 1765 passed, 10 excluded (the `:integration` and `:e2e` tests, Docker); ncc_agent 97 passed.
`mix.lock` unchanged. The test compile prints 15 warnings, all in test
files this branch did not write (quoted-keyword fixture warnings, a type
warning in `builder_test.exs` present at the base, and others); the two in
files this branch touched were removed in the fix wave. The lib compile
with `--warnings-as-errors --force` is clean.

Run 1 (before the fix wave, head `3b5f7ab`) had the same result.

Run 3, on the follow-up head `9c110cb`: every gate exit 0 except `mix test`,
where one portal test failed, `PortalWeb.AdminUsersLiveTest` "revoke admin
another admin, with a fresh confirmation" with "expected async processes to
finish within 100ms". That file and the LiveView it tests are untouched by
this branch; the test passed in runs 1 and 2 and passed twice more when the
file was rerun in isolation afterwards (23/23 both times). It is a timing
flake, not a regression. `mix.lock` unchanged in all three runs.

## 6. Operator steps to switch it on

1. **Garage on box-b.** Paste the NixOS module from
   `docs/BUILD_CACHE_L2.md` ("Garage on box-b"), with `rpc_secret` and
   the admin token in `/etc/garage/secrets.env` (outside the store), data
   under `/srv/garage`, S3 API on the tailnet address `:3900`,
   `replication_factor = 1`. Rebuild, then run the `garage` CLI block
   from the same doc: `garage status`, `garage layout assign -z home -c
   500G <node-id>`, `garage layout apply --version 1`, `garage bucket
   create ncc-build-cache`, `garage key create ncc-build-cache-rw`,
   `garage key create ncc-build-cache-ro`, the two `garage bucket allow`
   lines, and `garage key info ... --show-secret` for the key material.
   The module was written against NixOS 25.05 / `pkgs.garage_1` and was
   not evaluated here.
2. **Each home build host.** Add to `/etc/ncc-portal/portal.env`:
   `NCC_BUILD_CACHE_S3_ENDPOINT=http://<box-b tailnet ip>:3900`,
   `NCC_BUILD_CACHE_S3_BUCKET=ncc-build-cache`,
   `NCC_BUILD_CACHE_S3_REGION=garage`, `NCC_BUILD_CACHE_S3_ACCESS_KEY=<rw
   key id>`, `NCC_BUILD_CACHE_S3_SECRET_KEY=<rw secret>`. `NCC_BUILD_CACHE`
   must already be set (L2 is off without an L1). Restart the portal and
   look for `Build cache L2 on: http://…:3900/ncc-build-cache` in the log
   (a warning instead means an incomplete config, or http outside the
   tailnet). The Maintenance tab shows the card.
3. **Same image digest everywhere.** Hosts share entries only under the
   same slug, which is the worker image digest: run the registry image by
   digest (`images.json`), not a locally built `ncc-worker:local`.
4. **One-time push of the existing cache**, as the user owning
   `NCC_BUILD_CACHE`, with the env sourced:
   `cd /var/lib/ncc && sudo -u ncc -H env RELEASE_TMP=/var/lib/ncc/tmp bash -c 'set -a; . /etc/ncc-portal/portal.env; set +a; /opt/nerves_compatibility/portal/bin/portal eval "Portal.BuildCache.L2.Push.run(limit: 500) |> IO.inspect()"'`
   (or `mix portal.build_cache.push --limit 500 --max-gb 20` from a
   checkout). Rerun until it reports `uploaded: 0`; every run skips what a
   HEAD finds present. `--dry-run` lists first.
5. **Verify.** After a build on host A promotes a package, host B's next
   build log shows `Build cache L2 prefetch for <run>: N downloaded`, and
   `garage bucket info ncc-build-cache` shows the objects.
6. **Rollback.** Unset `NCC_BUILD_CACHE_S3_ENDPOINT` and restart: behaviour
   is identical to before this branch. `NCC_BUILD_CACHE_S3_READ_ONLY=1`
   keeps reading without uploading (for a host holding the read-only key).

## 7. Rulings made on the operator's behalf

In order; each with what it costs if wrong.

1. Treated the task message as the design approval and proceeded through spec → plan → implementation without a review pause (the session is autonomous). Cost: a design the operator would have changed before implementation.
2. Dispatched the next task's implementer while the previous task's read-only review ran, when the files were disjoint (Tasks 2, 3, 4, 5, 6, 8; 9 and 10 together with 11 during Task 7's fix round). Cost: an index-lock retry or a stray `mix format` on another task's uncommitted file; none materialised.
3. Tarballs carry no symlink members; Mix links travel as a validated manifest (decision 4). Cost: a non-Mix link is never shared.
4. Amended Task 7's commit message to carry the required `Co-Authored-By: Claude Fable 5.1` trailer (the implementer had written another model name). Cost: none; the amended commit is the one on the branch.
5. The fix-wave rulings in decisions 8 to 12, and `catch kind, reason` at every task boundary. Costs as stated there.
6. One follow-up commit after the fix wave's re-review (sparse members, member cap, `:DOWN` wait) instead of parking those three, because the sparse hole contradicted the security claim the Critical-1 fix rests on; it had no reviewer of its own beyond the controller's read and the gates. Cost: a defect in those ~60 lines would have no independent review on record.
7. Parked the remaining residuals (pack outside the upload deadline; the http warning stricter than its description; container copies outside the Lifeline arithmetic; `strip_modes` floors on L1 copies) and deferred the minor findings listed in section 4. Cost: those items remain open.
8. The budgets' numbers (5 min, 2 GiB, 512 MiB object, 1 GiB extracted, 4 GiB per build, 512 MiB heap, 120 s per GET/unpack/promotion upload, 100 000 members, 24 h bad marks) are the spec's and the reviews' values; none was measured against a real bucket. Cost: tuning on the live hosts.
