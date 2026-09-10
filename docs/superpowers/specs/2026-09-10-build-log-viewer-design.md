# Build log viewer

Status: design approved, not implemented
Date: 2026-09-10

## Problem

When a build fails, the portal shows a `log_tail` — the last 4096 bytes of the
per-system log — and nothing else. That cap is not a formality: 5769 of 9463
system results are truncated at it (61%), including 222 of 466 failures. A
maintainer looking at a failed build sees the last four kilobytes of the story
and has no way to get the rest. The full log exists on the build host for a few
minutes and is then deleted with the scratch directory.

The ask is that the full log be saved and readable, and searchable in the sense
of Ctrl-F within one log — not a search engine over all logs.

## Scope

In scope:

- Per-system build logs (`out/logs/<system>.log`), **failures only**.
- A run-level fallback for builds that die before producing any per-system log.
- A deep-linkable page per log with a client-driven line filter.

Out of scope, by decision:

- Search across logs. One log at a time.
- Live streaming while a build runs.
- Logs for passing builds. Stated cost of that exclusion is recorded below.
- A raw `curl`-able log endpoint.
- A history UI for older runs' logs. Rows for superseded runs stay in the
  table — nothing prunes them — but no route reaches them.
- Trimming or migrating the existing `catalog_runs.log` column.
- Warning extraction. That is phase 2 and has its own spec — see
  "Phase 2: warnings" below.

## Why failures only, and what it costs

Measured on production, `runner.log` by run status:

```
pass     2235 runs   262 MB   (97% of the bytes)
fail       61 runs   7466 kB
skipped   279 runs    451 kB
```

Passing logs are almost all of the volume and almost none of the value. The
accepted cost is that a package that builds today but produces a deprecation
warning leaves no record of it. That gap is real, and it is what phase 2
addresses — by extracting the warning lines rather than by storing the log.

Storage added by this feature is small. 466 failed system results exist today;
per-system logs sample at roughly 5 KB and failures run larger, so the initial
population is single-digit megabytes logical and less after TOAST compression.
For comparison, `catalog_system_results` is 843 MB, 82% of a 1024 MB database,
almost entirely `dependency_scans`.

## Data model

New Ash resource `Portal.Catalog.SystemLog`, table `catalog_system_logs`:

| attribute | type | notes |
|---|---|---|
| `system_result_id` | `belongs_to :system_result` | `allow_nil? false`, unique index — 1:1 with a failed system result |
| `body` | `:string` | sanitized log text |
| `byte_size` | `:integer` | size **before** truncation, so the UI can say what was dropped |
| `truncated` | `:boolean` | |

A separate table, not columns on `SystemResult`. `apps/portal/lib/portal/catalog.ex:19`
already documents why: the dashboard reads `catalog_system_results` whole, and
loading blob columns it does not render is what drove a page load to gigabytes
and OOM'd the node. Log bodies must never be reachable from a `/packages`,
badge, or JSON API query. A separate table makes that structural rather than a
rule someone has to remember.

For the run-level fallback, a new `error_log` attribute on
`Portal.ScanRequests.ScanRequest` — a `:string`, capped at 16 KB. Not a new
table: it is one short excerpt per request, read only on the request page.

## Capture

**No changes to `apps/ncc_worker`.** This is load-bearing, not a convenience.
`image_digest` is part of the `Portal.Workers.Build` dedup key; rebuilding the
worker image changes the digest and makes all 2506 known packages look un-built,
re-queueing every one of them. The worker already writes
`out/logs/#{system.name}.log` (`worker.ex:475`), keyed by the same name that
`result.json` uses as its system key — verified against a real artifact
(`manual-jason-1.4.5/out/logs/nerves_system_rpi0.log` ↔ result key
`nerves_system_rpi0`).

### Per-system logs

`Portal.Builder.load_run/1` already returns `output_dir`, so no new transport is
needed. `Portal.Workers.Ingest` adds `output_dir: build.output_dir` to
`ingest_opts`. `Ingestion.create_system_result/5` then reads
`Path.join([output_dir, "logs", "#{system_pkg}.log"])` when the parsed status is
`:fail` or `:error`, sanitizes it, and inserts one `SystemLog` row.

A missing or unreadable file logs a warning and continues. It must never fail
the ingest: a failed ingest burns an Oban attempt and, at exhaustion, throws
away a completed multi-gigabyte build.

### Run-level fallback

Builds that die before writing `result.json` produce no per-system logs at all,
and today produce no database row either — every such path calls
`Builder.cleanup(run_id)` and returns without creating a `Run`. Independent
confirmation: the run-status breakdown in production returns only
`pass`/`skipped`/`fail` and **zero** `error` rows.

The fallback captures a sanitized 16 KB tail of `runner.log` into
`ScanRequest.error_log`, written in `Portal.Workers.Build` **before**
`Builder.cleanup/1` on each failure path:

- `handle_outcome(:retry, build, ctx)` — worker exit 10/11; `build.log` is in hand
- `handle_outcome(:ingest, ...)` with `result: nil` — exit 0, no `result.json`
- the `{:error, reason}` branch of `do_build/7` — docker unavailable, scratch
  setup, wall-clock timeout; no `build` map, so read from disk via a new
  `Builder.read_runner_log/1` before cleanup
- `crash_cleanup/5` — same, wrapped in the existing `safely/2`

**Rejected alternative:** creating a `Run` row for these failures. `run_exists?/3`
dedups on `(package, version, image_digest)` with no status filter, so a failure
row would permanently suppress every future rebuild of that package version.

**Known accepted hole:** maintenance-triggered builds have no `ScanRequest`, so
they lose the log. This is inverted from where it matters — a user-submitted
request is the case where someone is waiting for an answer, and an operator
chasing a maintenance build has `journalctl` on the build host.

## Sanitizing

New module `Portal.Catalog.LogSanitizer`. Log content is compile output from
unreviewed third-party Hex packages; it is attacker-influenced input.

1. **Invalid UTF-8 → replacement character.** This is a real crash path, not
   defensive coding: Postgres rejects invalid UTF-8 in a `text` column, so a
   package emitting a stray byte would crash the ingest through all five
   attempts and discard the build.
2. **Strip ANSI CSI sequences and C0 control characters**, keeping `\n` and
   `\t`. Build output is colorized; raw escapes render as garbage.
3. **Truncate**, with an explicit elision marker, to a caller-supplied budget:
   head 400 KB + tail 400 KB for a per-system log, and tail-only 16 KB for the
   `runner.log` excerpt. Both ends of a system log carry signal — dependency
   resolution at the head, the error at the tail — whereas the runner excerpt
   only ever needs the end. `byte_size` records the original size either way.
4. **For `runner.log` only, strip the `Portal.Builder.log_command/2` header
   explicitly.** That header contains the full `docker run` argv and host mount
   paths. Relying on the tail excerpt to skip it is not good enough; a short
   log makes the header part of the tail. (The container environment itself is
   clean — `build_docker_args/4` passes only `NCC_INPUT`, `LANG`, `HOME`,
   `HEX_HOME`, `TAR_OPTIONS`, and the build-tuning vars. No secrets.)

## Viewing

Route: `live "/packages/:name/log/:system", LogLive, :show`. Deep-linkable, so a
maintainer can paste the URL into an issue. It resolves to the log for the
package's **latest** run — the same run the package page renders. There is no
run identifier in the URL, which is what keeps "no history UI" out of scope
while leaving the door open to add one later.

- A filter input, `phx-change` with `phx-debounce="150"`, filtering lines
  server-side by case-insensitive substring.
- **No regex on user input.** A user-supplied pattern is a ReDoS against the
  LiveView process.
- Line numbers, `<pre>` with its own `overflow-x`, and a banner when the log was
  truncated stating the original size.
- **No `raw/1`, no `innerHTML`, anywhere on this page.** The content is hostile
  by construction.

The per-system log is linked from the existing failure display on the package
page. The `runner.log` excerpt is shown on the request page.

`SystemResult.log_path` is currently dead — ingestion always writes `nil`. It is
removed as part of this change rather than left as a decoy next to a column that
now means something.

## Tests

- A `:fail` system result creates a `SystemLog` row; a `:pass` one does not.
- Truncation records the pre-truncation `byte_size` and inserts the marker.
- A log containing invalid UTF-8 ingests cleanly. **Non-vacuity:** drop the
  scrub and confirm this test fails.
- A missing log file ingests cleanly and creates no row.
- The filter narrows the rendered lines.
- ANSI escapes are stripped.
- A log containing `<script>` renders escaped.
- The `runner.log` excerpt does not contain the docker command header.
- Each failure path in `Workers.Build` writes `error_log` before cleanup.

## Backfill

Not part of shipping this. Rows for the 466 existing failed system results
cannot be recovered — their scratch directories are gone. Backfilling the 2235
passing `runner.log` bodies is explicitly not wanted. Any later backfill gets
its own go/no-go and a `VACUUM FULL` window.

## Phase 2: warnings

Measured on production, counting only the last 4096 bytes of each system log:

```
                total   contains "warning:"
  pass           8718   5397   (62%)
  fail            466    208
  skipped         279      0

  Logger.add_backend/1 is deprecated          3046
  unused require Logger                        223
  the following clause is redundant             178
  "xref: [exclude: ...]" is deprecated          107
  single-quoted charlists are deprecated         77
  use Bitwise is deprecated                      42
```

These are real deprecations against modern Elixir and OTP — the compatibility
signal this site exists to report — and the true counts are higher, since this
only counts warnings that happened to land in the last 4 KB.

Warnings are a different feature at every layer and belong in their own spec:
they apply to **passing** builds, which this spec deliberately excludes from log
storage; they are many rows per system result rather than one; they need a
parser with its own corpus; and their UI is a cross-package aggregate, not a log
page. `PortalWeb.WarningsLive` already exists as a placeholder waiting for
exactly this data, unrouted per `router.ex:38`.

Phase 2 reuses the `output_dir` plumbing this spec adds, and likewise needs no
worker change.

**Unrelated bug found while measuring, worth fixing separately:** every
`runner.log` carries ~35 lines of `warning: found quoted keyword "..." but the
quotes are not required`. These come from our own `Code.eval_string` on
`mix.lock` content in `NccWorker.LockPolicy` (`lock_policy.ex:20`) and
`NccWorker.Worker` (`worker.ex:993`), not from the package under test. They land
in `runner.log`, never in a per-system log, so they do not pollute phase 2's
input — but they are noise in the fallback excerpt.
