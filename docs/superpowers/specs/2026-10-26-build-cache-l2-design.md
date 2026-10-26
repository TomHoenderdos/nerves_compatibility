# Build cache L2: a shared S3 layer behind the local build cache

Date: 2026-10-26. Base: `main` at `f9d6894`.

## 1. Goal

A dependency compiled once on one home build host is restored on the others.
Today the dependency build cache (`NCC_BUILD_CACHE`, the isolation spec's
section 2) is a directory on each build host. Each host fills its own; a
second host compiles `ash` again from scratch.

This adds a second, shared layer: an S3-compatible bucket served by Garage on
`box-b`. Every home build host reads from it before a build and writes to it
after a promotion. The local directory stays exactly what it is, and is the
only thing a build container ever sees.

Out of scope: remote builders (`apps/ncc_agent`) keep `build_cache: nil` and
never touch the bucket; Contabo and any read-only key; pruning the bucket;
any change to `apps/ncc_worker`.

## 2. Decisions taken by the operator (not reopened here)

* L1 stays: the local directory, bind-mounted read-only at `/build-cache`,
  as today. The worker does not change.
* L2 is an S3-compatible bucket. Object name `<image-digest-slug>/<key>.tar.gz`,
  object metadata `x-amz-meta-sha256` = SHA-256 of the tarball bytes.
* The tarball holds exactly one cache entry (`ebin`, `priv`, `.mix` and
  whatever else Promotion admitted), relative paths only, no hardlinks, no
  device nodes, and no symlink that leaves the entry other than Mix's own
  `priv`/`include` links (section 5.1 explains why that exception exists).
* Writer: `Portal.BuildCache.Promotion`, after the local rename succeeds,
  best effort. Reader: `Portal.Builder`, before `docker run`, bounded to
  2 GiB and 5 minutes per build. A failed GET, timeout or mismatch is logged
  and the build proceeds.
* Only hosts holding the read-write key upload; a tarball is re-checked
  structurally on extract. Config via `NCC_BUILD_CACHE_S3_*` env, all
  optional; unset endpoint means off and behaviour identical to today.
* Staging names carry the hostname; `Portal.Workers.Sweep` on host A never
  prunes host B's in-flight staging.
* Admin: one section on the Maintenance tab; no tables, no migrations.
* Tests: unit tests against an in-process S3 stub; the Docker integration
  test gets a promote-then-restore case.
* Ops: `DEPLOY.md` documents the env and the Garage setup; the NixOS module
  for `box-b` and the `garage` CLI commands go into `docs/BUILD_CACHE_L2.md`.

## 3. Decisions taken in this design

### 3.1 What the reader fetches: the slug listing, not a build plan

The operator's brief says the reader fetches "every key of the build plan
that is missing locally". The host has no such plan. Cache keys are
computed by `NccWorker.BuildCache.plan/6` inside the container, after
`mix deps.get`, from `mix deps.tree` and the final lock; the portal cannot
compute them without resolving and loading the package's `mix.exs`, which
is exactly the untrusted code the container exists to isolate. The worker
must not change, and the container cannot reach the tailnet (the egress
filter allows only DNS and TCP 80/443 to public addresses).

So the reader syncs instead. Before `docker run` it lists the bucket under
`<slug>/` and downloads, newest first, every object whose key is absent
from the local slug directory, until the per-build budget (2 GiB, 5 min)
runs out. The local directory converges to the bucket over a few builds, and
a key uploaded by another host is present locally for every later build.
The budget is per build, so a fresh host spends at most five minutes per
build catching up. Keys are 64 hex characters; a key that does not look like
one is ignored.

Consequence to document: hosts share entries only under the same slug, and
the slug is the worker image digest. Home hosts running the registry image
by digest share; a host running a locally built `ncc-worker:local` has its
own slug and shares nothing until it runs the same digest.

### 3.2 Tarball format: gzip through `:erl_tar`, no new dependency

`.tar.gz` written and read with OTP's `:erl_tar` (`:compressed`). zstd would
compress faster but needs a NIF package (`ezstd`) in the portal release for
a few megabytes per entry; the win is not worth a native dependency in the
web app. Object names end in `.tar.gz` and the format is pinned by the name.

### 3.3 SigV4: Req's own step; an independent verifier in tests

`req` 0.7 ships `Req.Steps.put_aws_sigv4` (`aws_sigv4: [access_key_id,
secret_access_key, service: :s3, region]`), so no `req_s3` and no new
dependency. The test S3 stub verifies every request with its own SigV4
implementation (`Portal.Test.FakeS3.SigV4`), which is itself tested against
two published vectors: the AWS SigV4 test suite's `get-vanilla` case and the
S3 developer guide's "GET object" example. A request Req signs must verify
under the stub's independent code, which is the cross-check the brief asked
for.

### 3.4 Structural rules, identical on both ends

`Portal.BuildCache.Tree` holds the walker Promotion already uses (step 7 of
its moduledoc: directories, regular files with link count 1, Mix's own
top-level `priv`/`include` symlinks, UTF-8 names, nothing else), extracted
so the upload and download paths run the very same code. The uploader walks
the local entry with the package name bound; the downloader does not know
the package, so it binds the link target's package component to any
`[a-z][a-z0-9_]*`. Both ends pre-screen the tar table before anything is
extracted (section 5.2).

### 3.5 Staging names and the Sweep rule

Every staging name under a slug becomes `<key>.tmp.<host>.<hex>` (the
in-flight tarball of a download is `<key>.tmp.<host>.<hex>.tar.gz`), where
`host` is the node's hostname restricted to `[A-Za-z0-9-]` and `hex` is 16
random hex characters. Promotion's staging adopts the same shape. Sweep
prunes a staging name only when its host part is absent (the pre-L2
`<key>.tmp.<hex>` form) or equals the sweeping node's own hostname, and
only once its mtime is older than the scratch max age (3 h by default). The
age bound is new: today Sweep removes any `.tmp.` name on sight, which could
race a promotion copy in flight; with downloads taking up to five minutes
that race is no longer acceptable.

### 3.6 Counters are per node, since boot

`Portal.BuildCache.L2.Stats` is a small GenServer owning an ETS table:
uploads and downloads (ok, failed, refused), bytes each way, the time of the
last successful upload and download, and two working sets (keys claimed by
an in-flight download on this node; keys that failed verification, skipped
for 24 h). Nothing is persisted. On a split deployment the Maintenance tab
shows the web node's numbers, which are zero: the line says which node it
describes.

### 3.7 One-time push of an existing cache

`mix portal.build_cache.push` (module `Portal.BuildCache.L2.Push`, also
runnable with `bin/portal eval` on a deployed host) walks every
`<root>/<slug>/<64hex>` entry, skips objects a HEAD finds present (that is
what makes it resumable), uploads the rest through the same code Promotion
uses, and stops at `--limit N` entries or `--max-gb G` uploaded bytes. The
name follows the repo's `portal.*` task convention rather than the brief's
`ncc.cache.push` suggestion.

## 4. Components

```
Portal.BuildCache.L2            enabled?/0, object_key/2, upload/4, prefetch/2, status/0
Portal.BuildCache.L2.Config     config/0 from Application env; nil when off or incomplete
Portal.BuildCache.L2.Client     head/2, get/4, put/4, list/2 over Req + aws_sigv4
Portal.BuildCache.L2.Tarball    pack/3, unpack/2 with the structural rules
Portal.BuildCache.L2.Stats      GenServer + ETS: counters, claims, bad keys
Portal.BuildCache.L2.Push       the one-time push; Mix.Tasks.Portal.BuildCache.Push wraps it
Portal.BuildCache.Tree          check/2, strip_modes/1, name_string/1 (moved out of Promotion)
Portal.BuildCache.Staging       name/1, host/0, parse/1, ours?/2 (shared by Promotion, L2, Sweep)
Portal.Test.FakeS3              Plug router on Bandit, in-memory bucket, SigV4 verifier, fault knobs
```

### 4.1 Config (`Portal.BuildCache.L2.Config`)

`config/runtime.exs` maps the env into `config :portal, Portal.BuildCache.L2`:

| Env | Key | Notes |
| --- | --- | --- |
| `NCC_BUILD_CACHE_S3_ENDPOINT` | `endpoint` | `http://` or `https://`, host and optional port, no path. Unset: L2 off |
| `NCC_BUILD_CACHE_S3_BUCKET` | `bucket` | required when the endpoint is set |
| `NCC_BUILD_CACHE_S3_REGION` | `region` | default `garage` |
| `NCC_BUILD_CACHE_S3_ACCESS_KEY` | `access_key` | required |
| `NCC_BUILD_CACHE_S3_SECRET_KEY` | `secret_key` | required |
| `NCC_BUILD_CACHE_S3_READ_ONLY` | `read_only` | `1` reads and never uploads |

`config/0` returns a `%Config{}` only when endpoint, bucket, access key and
secret key are all non-empty and the endpoint parses as an http(s) URL with
a host; otherwise `nil`. A set-but-incomplete configuration is logged once
at boot as a warning (`L2.log_state/0`, called from `Portal.Application`
beside the egress-state line) and treated as off. L2 is also off whenever
`Portal.Builder.build_cache/0` is nil: without an L1 there is nowhere to
restore into.

### 4.2 Client (`Portal.BuildCache.L2.Client`)

Path-style URLs, `#{endpoint}/#{bucket}/#{object}`, signed with
`aws_sigv4: [access_key_id, secret_access_key, service: :s3, region]`.
`retry: false`, `redirect: false`, `connect_options: [timeout: 10_000]`.

* `head(cfg, object)` → `{:ok, %{size, sha256}}` (`sha256` nil when the
  header is absent) | `{:error, :not_found}` | `{:error, term}`. Receive
  timeout 30 s.
* `get(cfg, object, path, opts)` streams the body into `path` through a
  `Req` `into:` collector that writes chunks, hashes them, and halts with
  `{:error, :too_large}` past `opts[:max_bytes]`. Returns
  `{:ok, %{bytes, sha256_computed, sha256_header}}`. Receive (inactivity)
  timeout 60 s; the caller bounds total time with `opts[:timeout_ms]` by
  running the request in a task and killing it on expiry. A 404 is
  `{:error, :not_found}`; any other non-2xx is `{:error, {:status, n}}`.
  A partial file is removed on every error.
* `put(cfg, object, path, sha256)` reads `path` whole (the caller has
  capped it), sends it with `content-type: application/gzip` and
  `x-amz-meta-sha256`. Receive timeout 120 s. `:ok` on 2xx.
* `list(cfg, prefix)` → `{:ok, [%{key, size, last_modified}]}` over
  ListObjectsV2 (`list-type=2`, `prefix`, `continuation-token`, max 1000 per
  page, at most 50 pages). The XML is read with a small, fixed extraction of
  `<Contents>` blocks (`Key`, `Size`, `LastModified`, plus `IsTruncated` and
  `NextContinuationToken`); keys are our own hex names and never need
  unescaping, and anything that does not parse is dropped. No xmerl, no
  XML dependency. Receive timeout 30 s per page.

Errors are logged by the callers, never here, with the object name and a
bounded `inspect` of the reason.

### 4.3 Tarball (`Portal.BuildCache.L2.Tarball`)

* `pack(entry_dir, tar_path, package)`: `Tree.check(entry_dir, package:
  package)` first; refuses any top-level name that is not a directory,
  regular file or allowed link; writes `tar_path` with `:erl_tar.create/3`
  from `{name, Path.join(entry_dir, name)}` pairs for each top-level name
  (no `:dereference`, so Mix links stay links), `:compressed`; refuses if the
  result is over `@max_object_bytes` (512 MiB); returns
  `{:ok, %{sha256, bytes}}`.
* `unpack(tar_path, staging_dir)`: reads the table (`:erl_tar.table/2`,
  `:verbose`, `:compressed`) and refuses before extracting anything if any
  entry has a type other than `regular`, `directory` or `symlink` (so no
  `link`, `char`, `block`, `fifo`), a name that is empty, absolute, has a
  `.`/`..` component, a NUL, invalid UTF-8 or more than 64 path components;
  then `:erl_tar.extract/2` into `staging_dir` (which erl_tar itself guards
  with `safe_relative_path`, refusing unsafe paths and unsafe symlinks); then
  `Tree.check(staging_dir, package: :any)` and `Tree.strip_modes/1`. Any
  refusal returns `{:error, reason}` and the caller removes the staging dir.
  An empty tarball is refused.

**Amendment (2026-10-26, during implementation).** `:erl_tar.extract/2`
refuses a symlink member whose target leaves the extraction directory, and
Mix's `priv -> ../../../../deps/<pkg>/priv` does. Rather than parse tar
headers ourselves to recreate such links (new hostile-input surface), the
tarball carries no symlink members at all. `pack/3` writes the entry's
top-level Mix links (already proven Mix-shaped by `Tree.check` with the
package bound) into one regular member, `.ncc-links.json`, a JSON object of
link name to target, and omits the links themselves. `unpack/2` refuses any
member that is not `regular` or `directory`, refuses an archive whose
summed member sizes exceed 2 GiB (a gzip bomb never reaches the disk),
extracts, and then, if a top-level `.ncc-links.json` exists, requires it to
be at most 4096 bytes, a JSON object whose keys are exactly `priv` or
`include`, whose values match
`../../../../deps[_<target>]/<package>/<same name>` with the final
component equal to the key, and whose link names do not yet exist; it
creates the links, deletes the manifest, and runs the same `Tree.check` and
`strip_modes` as before. The operator's "no symlinks" rule (section 2) now
holds literally for the archive; the Mix exception lives in the manifest.

**Amendment (2026-10-26, final review).** `:erl_tar.table/2` inflates the
whole stream and builds the full member list before any size check can run,
so the 2 GiB member-size check bounded nothing. `unpack/3` now first
pre-scans the file with `:zlib` (`inflateInit(z, 31)`, 1 MiB input chunks
through `safeInflate/2`), counting decompressed bytes and refusing with
`:too_large` past `max_extracted_bytes/0`, now 1 GiB; a stream that does not
inflate is `{:gzip, reason}`. Everything after it (table, screen, extract,
`strip_modes`, manifest, `Tree.check`) runs in
`Portal.BuildCache.L2.Bounded.run/2`, an unlinked monitored process with a
512 MiB heap cap and a deadline (`timeout_ms:`, default 120 s), whose
timeout and kill come back as `{:unpack, :timeout | :killed}`. Modes are
stripped before the walk, and `strip_modes/1` adds owner read/write (and
search on directories), so an archive-applied 0o000 can be walked and
removed. An extraction holding no regular file is `:empty_entry`. The
result is `{:ok, %{extracted_bytes: n}}`. The table is refused above
100,000 members (`:too_many_members`), and inside the bounded process the
summed member sizes must stay within the pre-scanned size, since `:erl_tar`
reports a GNU sparse member at its real size (`:too_large`).

### 4.4 Tree and Staging

`Portal.BuildCache.Tree.check(dir, package: name | :any)` is Promotion's
`walk/3` moved verbatim with the one parameterisation; `strip_modes/1` and
`name_string/1` move with it. Promotion delegates and keeps `name_string/1`
as a public alias for its existing tests.

`Portal.BuildCache.Staging.name(dest)` → `dest <> ".tmp." <> host() <> "." <>
hex16`; `host/0` sanitises `:inet.gethostname/0` to `[A-Za-z0-9-]` (empty or
unavailable → `"host"`), at most 63 characters; `parse(name)` →
`{:ok, %{host: String.t() | nil, download?: boolean}}` for a staging name, or
`:error`; `ours?(name, host)` is true for a parsed name whose host is nil or
equals `host`.

### 4.5 Upload path (Promotion → L2)

In `Promotion.finish/5`, after `File.rename(staging, dest)` succeeds and the
promotion is logged, call `ctx.l2.(dest, Path.basename(ctx.cache), key,
ctx.package)`. `ctx.l2` defaults to `&Portal.BuildCache.L2.upload/4`;
`opts[:l2]` is the test seam (a 4-arity function or `false`). The return
value is ignored there; `upload/4` logs its own outcome. Promotion's
return counts do not change.

`L2.upload(entry_dir, slug, key, package)`:

1. `:skipped` when L2 is off or read-only.
2. `Tarball.pack` into `entry_dir <> ".tmp.<host>.<hex>.tar.gz"` beside the
   entry (same filesystem; the slug dir is host-private), refusing on any
   structural problem.
3. `Client.put` with the computed sha256.
4. Remove the tarball in every case; record `upload_ok`/`upload_failed`
   with bytes in Stats; log one info line on success, one warning on
   failure. Returns `:ok | {:error, term}`; never raises past its boundary
   (`rescue` → `{:error, {:exception, msg}}`).

**Amendment (2026-10-26, final review).** The seam is 5-arity,
`fn dir, slug, key, package, opts`, and `upload/5` takes `timeout_ms:`,
passed to `Client.put/5`, which bounds the whole request (send included) in
a killed task. One `promote/6` call shares one upload deadline
(`l2_upload_budget_ms/0`, 120 s); the first upload that times out, crashes,
meets a transport error or a 5xx ends the uploads for that call, and the
remaining entries are promoted locally only. Only slugs matching
`sha256_<64 hex>` (not all zeros) are uploaded (`L2.shareable_slug?/1`).

### 4.6 Download path (Builder → L2)

`Portal.Builder.build/2` gains one step after `ensure_directories` and
before `write_worker_input`: `:ok <- prefetch_build_cache(job)`, which
always returns `:ok`. It resolves the slug dir the way `build_cache_dir/1`
does (creating it) and calls `L2.prefetch(slug_dir, slug)` when L2 is
enabled, logging the returned counts in one line.

`L2.prefetch(slug_dir, slug, opts)` with opts `budget_bytes` (default
2 GiB), `budget_ms` (default 5 min), `max_object_bytes` (default 512 MiB),
`now` (for tests):

1. `Client.list(cfg, slug <> "/")`. On error: log, count `list_failed`,
   return.
2. Local names: `File.ls(slug_dir)` as a set. Candidates: objects whose key
   is `<slug>/<64hex>.tar.gz`, whose hex is not a local name, not in Stats'
   bad set, and whose size is at most `max_object_bytes`; sorted by
   `last_modified` descending.
3. For each candidate while `bytes_used + size <= budget_bytes` and the
   deadline has not passed: skip unless `Stats.claim(key)` succeeds (another
   build on this node is fetching it); `download_one`; `Stats.release(key)`.
   A candidate over the remaining byte budget is skipped, not a stop, so
   small entries behind a large one still arrive. The first `:connect` or
   `:timeout` class error stops the loop for this build.
4. `download_one`: `staging = Staging.name(dest)`, `tar = staging <>
   ".tar.gz"`; `Client.get` with `max_bytes: size` and `timeout_ms:
   min(remaining, 120_000)`; refuse unless `sha256_header` is present and
   equals `sha256_computed`; `Tarball.unpack(tar, staging)`; delete `tar`;
   if `File.lstat(dest)` now succeeds, remove the staging dir and count
   `discarded`; else `File.rename(staging, dest)` and count `downloaded`.
   Every error removes `tar` and the staging dir, logs one warning naming
   the object and reason, and counts `failed`; a verification failure
   (sha mismatch, missing header, structural refusal, too large, truncated
   archive) also `Stats.mark_bad(key)` so the object is not retried for 24 h.
5. Returns `%{listed, candidates, downloaded, discarded, failed, skipped,
   bytes, extracted_bytes}`; records downloads and bytes in Stats.

**Amendment (2026-10-26, final review).** The counts also carry
`extracted_bytes` (the sum of the pre-scanned sizes) and `list_failed`. The extraction gets
`timeout_ms: min(remaining, 120_000)` too, so it counts against the
budget; an extraction killed or timed out by its bound is a refusal, except
one whose timeout the build's budget cut short (`:budget_spent`, which
stops the loop without marking the object bad). Extraction is budgeted at
4 GiB per build (`extracted_budget_bytes:`), charged with each object's
pre-scanned size. Free space on the slug dir's filesystem is checked before
every object against `Portal.Builder.prefetch_min_free_bytes/0`, stopping
the loop with one warning. A body longer than the listed size is an object
replaced after the listing (`:larger_than_listed`, a plain failure), and
`{:tar, :eacces | :eperm}` is a refusal. A slug that is not shareable is
not listed. `Prefetch.budget_ms/0` and the upload budget are exposed for
`oban_config_test.exs`, which keeps Lifeline's `rescue_after` above the
build ceiling plus both.

### 4.7 Admin

`PortalWeb.PageController.admin_assigns(:maintenance)` adds
`build_cache_l2: Portal.BuildCache.L2.status()`:

```
%{state: :off | :on | :incomplete, endpoint: String.t() | nil, bucket:, read_only?: boolean,
  node: String.t(), last_upload: DateTime.t() | nil, last_download: DateTime.t() | nil,
  counters: %{uploads: n, upload_failures: n, downloads: n, download_failures: n,
              refused: n, bytes_up: n, bytes_down: n}}
```

A card "Build cache L2" on the Maintenance tab shows the state badge, the
endpoint and bucket (never the keys), read-only when set, last upload and
download, and the counters since boot, with "on this node (`<node>`)".

### 4.8 Push (`Portal.BuildCache.L2.Push`)

`run(opts)` with `root` (default `Portal.Builder.build_cache/0`), `slug`
(restrict to one), `limit` (entries, default unlimited), `max_bytes`
(default unlimited), `dry_run`. For each `<root>/<slug>/<64hex>` directory
(skipping staging names): `Client.head`; present → `:present`; else
`L2.upload/4` with the package bound to `:any`, the same relaxation the
download side uses: every entry under the root already passed Promotion
with its package name bound, and the entry itself does not record the name
(`.mix/compile.elixir_scm` is binary term data and not worth parsing for
this). Prints one line
per entry and a summary; returns the summary map. Refuses to run in
read-only mode or with L2 off, with a clear message. `Application.ensure_all_started(:req)`
first, so it works under `bin/portal eval`.

### 4.9 Sweep

`sweep_staging/3` keeps its listing but filters with
`Staging.ours?(name, Staging.host())` and an mtime older than the scratch
max age. Both the in-flight tarball and the directory forms count. The
moduledoc gets the rule and why (section 3.5).

### 4.10 Boot

`Portal.Application.start/2` calls `Portal.BuildCache.L2.log_state/0` after
the supervisor starts: one info line "Build cache L2 off" / "Build cache L2
on: <endpoint>/<bucket> (read-only)" / one warning for an incomplete config.
`Portal.BuildCache.L2.Stats` is a child before Oban.

## 5. Trust argument

### 5.1 Why an extracted entry is trusted

An L1 entry is trusted because Promotion checked it: the key was
recomputed, the lock's outer checksum matched Hex, the tree was copied in a
sealed container and walked on the host-private copy. L2 adds no check of
that kind on the download side, because the downloader cannot recompute a
key or ask Hex for a tree it did not build. It trusts the bucket instead,
and the bucket is trustworthy exactly as far as its writers are: only hosts
holding the read-write key can PUT, and every such host runs this
Promotion. So the integrity of L2 is the integrity of the write key.
Documented, with the key split (read-write for home hosts, read-only for
anything else, ever), in `docs/BUILD_CACHE_L2.md`.

What the downloader still checks is what a compromised or faulty transport
could change without the key: the tarball's SHA-256 against the metadata
the uploader wrote, and the structure of what was extracted, re-walked with
the same rules Promotion applies, so that even a wrong object cannot plant
a symlink, a hardlink, a device, a setuid file or an escaping path into the
slug. The Mix `priv`/`include` links are allowed because a flat ban would
refuse most of the cache (Promotion's moduledoc, "Symlinks"); they point at
`../../../../deps[_<target>]/<package>/<same name>`, a path that resolves
inside the worker's own project tree, never outside the container.

**Amendment (2026-10-26, final review).** The SHA-256 in
`x-amz-meta-sha256` arrives in the same response as the body, so it detects
corruption, not tampering: over plain `http` anything on the path can
replace both, and "a compromised transport" above holds only for a path
that is itself protected. `http://` is acceptable only on the tailnet,
which encrypts it; any other endpoint must be `https://`.
`Config.insecure_endpoint?/1` is true for plain `http` to a host outside
loopback and `100.64.0.0/10` (a hostname other than `localhost` counts as
outside), and `L2.log_state/0` logs a warning for it at boot. The
structural checks still hold against any transport.

### 5.2 Why the table is screened before extraction

`:erl_tar.extract/2` refuses escaping paths and symlinks, ignores hard-link
entries, but writes device and fifo entries as empty regular files, which
the post-walk could not tell from real files. Screening the table first
turns those into a refusal, and bounds the name shapes we are willing to
pass to the extractor at all.

### 5.3 What a hostile bucket could still do

Serve an entry whose beams are wrong for its key. That is the write-key
compromise case above, and it is the same power a compromised home host
has over its own L1 today. The mitigation is operational: the key lives
only on the home hosts and the Garage admin token only on `box-b`.

## 6. Failure handling

| Where | Failure | Outcome |
| --- | --- | --- |
| Config | endpoint set, something missing | warning at boot, L2 off |
| Upload | pack refusal, PUT error, timeout | warning, counted, build result untouched |
| Prefetch | list fails / endpoint down | warning, counted, build runs with L1 only |
| Prefetch | GET error, mismatch, bad archive | warning, counted, key marked bad 24 h, loop continues (connect/timeout stops it) |
| Prefetch | budget exhausted | info, loop stops, build runs |
| Prefetch | entry appeared locally | staging discarded, counted |
| Push | any | printed, continues to the next entry |

Nothing in L2 raises into a caller: `upload/4` and `prefetch/3` rescue and
return.

## 7. Tests

Unit (all against `Portal.Test.FakeS3`, async off where they share config):

* Client: head/get/put/list round trip; list pagination; 404 → not_found;
  unsigned or wrongly signed request is refused by the stub (401); the stub's
  verifier passes the two published SigV4 vectors.
* Tarball: pack/unpack round trip preserving Mix links and modes; refuses
  `../`, absolute, device, hard link, non-Mix symlink, symlink out of the
  entry, invalid UTF-8 name, empty archive, oversize.
* Upload: Promotion calls the seam only after a successful rename; `upload/4`
  stores the object with the right name and metadata; read-only mode skips;
  endpoint down is logged and returns an error; a structural refusal uploads
  nothing.
* Prefetch: restores a missing key; skips keys present locally; sha
  mismatch, truncated tarball, `../` member, absolute member, symlink out of
  the entry each refuse and mark bad; entry appearing locally during the
  download is discarded; byte budget and time budget stop the loop; endpoint
  down returns with `list_failed`; read-only mode still downloads; a claimed
  key is skipped.
* Builder: with a fake `docker` on PATH and L2 configured, `build/2`
  prefetches into the slug dir before running the container.
* Sweep: prunes own-host and legacy staging past the age, keeps younger
  ones, keeps other hosts' at any age.
* Staging: name shape, host sanitising, parse round trip.
* Admin: the Maintenance tab renders the L2 card off and on.
* Push: dry run lists, HEAD-present entries are skipped, limit and byte cap
  stop it.

Integration (`:integration`, needs Docker; cannot run in this environment):
build jason with L1 at tmp A and the stub as L2; assert the promoted key's
object exists with a matching sha; build jason again with an empty L1 at
tmp B; assert `<slugB>/<key>` exists after the build with the same file
list and contents as A's, and that the run's `runner.log` carries the
prefetch line reporting one download, which places the restore before the
container ran.

## 8. Docs

* `DEPLOY.md`: six env rows in the build-host table; a "Shared build cache
  (L2)" subsection: what it does, the slug caveat, the key split, the push.
* `docs/BUILD_CACHE_L2.md`: operator guide. The NixOS module for `box-b`
  (`services.garage`, single node, S3 API on the tailnet address `:3900`,
  data under `/srv/garage`, `replication_factor = 1`), the `garage` CLI
  commands for layout, bucket and the two keys, the env for each home host,
  the push, verification, and what to do when rotating keys.
* `CLAUDE.md`: one paragraph under "Container / Caching Details".
* `ops/README.md`: a pointer under "Hosts".
* `Portal.Workers.Sweep` moduledoc: the staging rule.

## 9. Gates

From the umbrella root: `mix format --check-formatted`, `mix compile
--warnings-as-errors --force`, `mix credo`, `mix test`, the four sobelow
lines (`--private --skip --strict --exit low`, portal with no flag, the
others `--no-router`), `mix do deps.loadpaths + deps.audit`, `mix hex.audit`,
`bash -n` per ops script, `shellcheck -x ops/*.sh apps/ncc_agent/priv/egress.sh`,
`python3 -m unittest discover -s ops -p 'test_*.py'`. No new Hex
dependency is added.
