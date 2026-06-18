# Portal Consolidation — Design

**Date:** 2026-06-18
**Status:** Approved (design); pending implementation plan
**Branch context:** `dynamic_site`

## Problem

The repo is 6 independent Mix projects (`compat`, `beam_scanner`, `worker`, `runner`, `orchestrator`, `site`) plus a Cloudflare Pages Functions directory (`functions/`). The scan-request intake + Hex/GitHub auth logic is **triplicated** across `functions/` (JS), `portal/` (Phoenix), and `orchestrator/` (Elixir). The static site is generated into `public/site/` and served by Cloudflare Pages.

Now that an always-on Phoenix backend (`portal/`, Ash + `ash_sqlite`) exists, most of this can collapse into it.

## Goal

Collapse to the **smallest sensible Mix footprint**: one umbrella, three apps. Serve the compatibility site **dynamically** from Phoenix (no static gen, no Cloudflare Pages). Keep the worker↔container reproducibility boundary exactly as-is.

## Decisions (locked)

- **Deployment topology:** single host with Docker. Phoenix + Oban + Docker all on one box; the web process drains the build queue itself.
- **Database / queue:** SQLite (`ash_sqlite`) + **Oban Lite** engine. Single node, so a file DB is fine.
- **Project structure:** **umbrella**, 3 apps.
- **Site rendering:** **fully dynamic**, Phoenix-served. No static gen, no Cloudflare Pages, no `wrangler.toml`, no `public/site/`.
- **Scan triggers:** keep **all four** — Hex owner request, GitHub repo request, anonymous + Turnstile, Hex firehose poller.
- **Rename:** `compat` → `compatibility` (drop the abbreviation).

---

## Section 1 — Target structure

```
nerves_compatibility/          umbrella root: mix.exs, config/, one mix.lock, one deps/, one _build/
├── apps/
│   ├── compatibility/         shared contract (renamed from compat/)
│   │                          Compatibility.Types — status enum pass|fail|error|skipped|unknown
│   │                          result.json validators + package_metadata overrides
│   │                          used by BOTH worker and portal
│   ├── worker/                runs INSIDE the Docker container
│   │                          creates Nerves project, builds firmware per system, emits result.json
│   │                          absorbs beam_scanner (BEAM NIF/port/app-env scan)
│   │                          deps: compatibility + jason — NEVER depends on portal
│   └── portal/                Phoenix + Ash + ash_sqlite + Oban + Req
│                              absorbs orchestrator + runner + site + functions
├── apps/worker/Dockerfile     builds the worker escript only (see Section 5)
└── Makefile                   thinned: build image · run one package · dev server
```

**Deleted entirely:** `orchestrator/`, `runner/`, `site/`, `functions/`, `beam_scanner/` (folded into `worker`), `wrangler.toml`, `public/site/`.

**Renamed:** `compat/` → `apps/compatibility/`; app `:compat` → `:compatibility`; modules `Compat.*` → `Compatibility.*`; update all dependents.

**Unchanged (load-bearing reproducibility boundary):** the worker↔container JSON contract (`worker/README.md`, `docs/INDEX_FORMAT.md`), exit codes (worker `0`/`10`/`11`), `LockPolicy` (reject git/path deps), and the `ncc-worker:local` image.

**`compatibility` role shrinks:**

| Part | Fate |
| --- | --- |
| `Compatibility.Types` | **Stays** — worker emits / portal ingests, same enum |
| `Compatibility.Index.*` (JSON loaders) | **Retired** — results live in SQLite; Ash queries replace JSON reads |
| `Compatibility.PackageMetadata` (overrides) | **Stays** as contract; data moves to a `PackageOverride` Ash resource |

**Container-bloat avoidance:** `apps/worker/mix.exs` depends only on `compatibility` (in-umbrella) + minimal hex deps (`jason`), never on `portal`. The worker escript's dep closure stays tiny even though the build is unified.

---

## Section 2 — Ash domain model (SQLite)

Four Ash domains. Two exist (`Portal.Accounts.User`, `Portal.ScanRequests.ScanRequest`), two are new.

```
Portal.Accounts        User          (exists)
Portal.ScanRequests    ScanRequest   (exists, + link to Run)
Portal.Catalog  NEW    Package, Run, SystemResult, Artifact, PackageOverride
Oban (oban_jobs)       replaces DETS queue + checked.dets
```

### Portal.Catalog — compatibility data (replaces the 3 index JSONs)

| Resource | Grain | Replaces | Key attributes |
| --- | --- | --- | --- |
| `Package` | one per Hex pkg | `latest_by_pkg.json` top level | `name` (unique), `description`, `latest_version`, `last_run_at` |
| `Run` | one scan execution | `result.json` envelope | `run_id`, `package_id→`, `version_tested`, `image_digest`, `overall_status`, `footprint` (json), `log` (text/path), `started_at`, `finished_at`, `scan_request_id→` (nullable) |
| `SystemResult` | pkg × system × run | `latest_by_pkg_system.json` rows | `run_id→`, `system_pkg`, `system_version`, `status` (`Compatibility.Types` enum), `firmware_size_bytes`, `hex_version_tested`, `beam_scan` (json), `dependency_scans` (json), `log_path` |
| `Artifact` | content-addressed file | precompiled-API manifest + `files_dir` | `sha256` (unique), `byte_size`, `disk_path`, `system_result_id→` |
| `PackageOverride` | one per pkg | `package_metadata.json` | `package_name`, `forced_status`, `allow_systems`, `deny_systems`, `notes` — admin-editable in UI |

### Derived, not stored

- **`stats.json`** → Ash aggregates/calculations over `SystemResult` (`count_by_status`, etc.), optionally cached in a tiny `Stat` row refreshed by a maintenance Oban job. No bespoke table.
- **"Latest result for package X"** → a `Run` query ordered by `finished_at`. The `latest_by_*` split disappears — it was denormalization for static files; SQL gives it for free.

### Queue (replaces DETS)

- `Orchestrator.Queue` priority ranks → Oban job `priority` (0–9).
- `checked.dets` dedupe → Oban `unique: [keys: [:package, :version, :image_digest]]` **plus** a natural DB check ("does a `Run` for this (pkg, version, digest) already exist?").
- No queue table of our own — `oban_jobs` is it.

### ScanRequest tweak

Add `run_id` (nullable) linking a request to the `Run` it produced. Status flow `pending → accepted → queued → built | rejected` mirrors the Oban job lifecycle.

### Storage decisions

1. **Artifact blobs on disk** (`disk_path`, served by Phoenix); DB holds metadata only. Avoids SQLite BLOB bloat.
2. **`PackageOverride` as a DB resource** (vs the `package_metadata.json` file) — admin-editable live; one-time import of the existing JSON during cutover.

### Ingestion

The builder Oban job is the **only writer** of catalog data: `docker run` → read `result.json` → upsert `Package` + insert `Run` + N×`SystemResult` + M×`Artifact` in one transaction.

---

## Section 3 — Oban topology + end-to-end flow

### Queues (all on the one box)

| Queue | Concurrency | Job | Notes |
| --- | --- | --- | --- |
| `builds` | 1–2 | `Workers.Build` — heavy `docker run` | Low concurrency on purpose: builds are minutes-long and share the `~/.ncc-*` caches |
| `intake` | ~5 | `Workers.Enqueue` (optional) | Light; web request usually enqueues directly |
| `maintenance` | 1 | `Workers.DiscoverReleases` (cron), `Workers.RefreshStats` (cron) | Firehose poll + cached aggregate refresh |

### Priority map (old DETS rank → Oban `priority`, 0 = runs first)

```
hex_owner   0   → 0      anonymous(Turnstile) 50 → 3
github_repo 10  → 1      poller/normal       100 → 6
                         pending_review      200 → (held, not enqueued)
```

### Flow — four triggers converge on one `builds` queue

```
A. Hex owner      Phoenix form → Portal.HexPm device flow → verify_owner ✓
B. GitHub repo    Phoenix form → Portal.GitHub device flow → verify_access ✓
C. Anon+Turnstile public form + Turnstile token → siteverify (Req) ✓
D. Firehose       maintenance cron → DiscoverReleases → Hex.pm new releases
        │ A/B/C create a ScanRequest (status: accepted)   │ D has no ScanRequest (source: hex_poll)
        ▼                                                  ▼
   enqueue Workers.Build
     unique: [package, version, image_digest]   priority per table above
        ▼   builds queue, picks lowest priority#
   ① dedupe: Run exists for (pkg, version, current image digest)? → skip, mark request built
   ② Portal.Builder (was runner): docker run ncc-worker:local
        mounts /work /out ~/.ncc-nerves-cache ~/.ncc-hex-cache, --user uid:gid
        worker builds firmware/system → /out/result.json + logs + artifacts
   ③ read exit code + result.json (mapping below)
   ④ INGEST (one txn): upsert Package · insert Run · N×SystemResult · M×Artifact
        + move content-addressed blobs into portal artifact store
   ⑤ ScanRequest → built (or rejected + reason) · broadcast PubSub "request:<id>"
        ▼
   RENDER — live, no job:
     /packages/:name   LiveView  ← Package + latest Run + SystemResults
     /requests/:id     LiveView  ← live status via PubSub
     /badge/:name.svg  controller ← computed SVG
     /api/*.json       Ash queries (keep schema-v2 shape for existing consumers)
```

### Exit-code → Oban outcome (preserves the contract)

| Source | Code | Oban result |
| --- | --- | --- |
| worker | `0` | success → ingest |
| worker | `11` policy (git/path dep) | `{:discard}` — permanent, request `rejected: "non-Hex dep"`, no retry |
| worker | `10` internal | retry (backoff, `max_attempts: 3`) |
| runner→docker | `20` runner / `21` container | retry; exhausted → request `error` |
| n/a | unknown package | `{:cancel}` at enqueue, request `rejected` |

### Live status

`Workers.Build` broadcasts progress to `"request:<id>"`; the request LiveView shows queued → building → per-system results streaming in. No polling, no static regen.

---

## Section 4 — Phoenix surface

Portal already has the **intake + auth + admin** routes (`PageController`). The merge **adds the public browse surface** (the old static site) and **re-homes the Turnstile check** from the deleted Cloudflare function.

```
BROWSE (new, public, LiveView)          ← replaces static site/generator.ex output
  live "/"                IndexLive       package list + search/filter
  live "/packages/:name"  PackageLive     detail: latest Run + per-system results
  live "/requests/:id"    RequestLive     live status via PubSub

BADGES + API (controllers, CDN-cacheable)
  get  "/badge/:name.svg"     compute SVG from latest SystemResults
  get  "/api/packages"        ┐
  get  "/api/packages/:name"  ├ Ash queries; KEEP schema-v2 JSON shape
  get  "/api/stats"           ┘  so existing badge/API consumers don't break
  get  "/api/precompiled/*"   precompiled manifest + content-addressed Artifact serve

INTAKE + AUTH (exists today — mostly unchanged)
  get/post "/request-scan", "/auth/hex/*", "/auth/github/*", "/requests/anonymous"
  CHANGE: anonymous_request verifies Turnstile server-side (Req → siteverify);
          Turnstile widget embedded in the request form  ← was functions/api/scan-requests.js
  CHANGE: intake handlers enqueue Workers.Build instead of forward_to_orchestrator

ADMIN (exists + add)
  approve/reject anonymous requests (exists)
  + PackageOverride CRUD (live-editable overrides, was package_metadata.json)
  + re-queue / force-rescan button
```

`functions/` deletes entirely — Turnstile verify + Hex OAuth proxy are now native Phoenix. `/` flips from the request form to the **compatibility home**; the form moves to `/request-scan`.

---

## Section 5 — Worker / Docker boundary

**Unchanged (reproducibility contract):** worker reads `NCC_INPUT`, builds firmware per system, writes `result.json`, exit codes `0/10/11`, `LockPolicy`. Image name `ncc-worker:local`.

**`runner` → `Portal.Builder`:** `runner/lib/ncc_runner/docker.ex` becomes a plain module in `apps/portal`. Same `docker run` invocation — mounts `/work /out ~/.ncc-nerves-cache ~/.ncc-hex-cache`, `--user uid:gid`. Called by `Workers.Build`. The runner escript disappears; its logic lives on.

**`apps/worker/Dockerfile` — umbrella gotcha (must get right):**

```dockerfile
# context = umbrella root (Makefile: docker build -f apps/worker/Dockerfile .)
COPY mix.exs mix.lock ./
COPY config ./config
COPY apps/compatibility ./apps/compatibility   # renamed from compat/
COPY apps/worker        ./apps/worker          # beam_scanner folded in
#   ⚠️ do NOT copy apps/portal
RUN mix deps.get && cd apps/worker && mix escript.build
ENTRYPOINT ["/app/apps/worker/ncc_worker"]
```

**Why it works:** in an umbrella, `mix deps.get` only fetches deps for apps it discovers under `apps/`. Copying only `compatibility` + `worker` means Mix never sees `portal`, so phoenix/ash/oban are never pulled into the container image. That keeps the worker image small despite the unified build.

Caveats: the shared `mix.lock` carries portal's locked versions (unused entries aren't fetched — fine); keep `config/config.exs` from hard-`import`-ing portal-only config, or guard it so the worker build doesn't choke on a missing app.

---

## Section 6 — Cutover order

Incremental — `mix compile` + tests green after **every** phase. The **Docker integration test is the invariant gate** throughout.

| # | Phase | Deliverable | Gate |
| --- | --- | --- | --- |
| 1 | **Umbrella scaffold + rename** | root `mix.exs` (`apps_path`), move `compat`→`apps/compatibility` (`Compat`→`Compatibility`), `worker`→`apps/worker` (fold `beam_scanner`), `portal`→`apps/portal`. Fix `worker/Dockerfile` paths. | worker + compatibility unit tests + docker build/integration pass |
| 2 | **Catalog + Oban schema** | Ash resources Package/Run/SystemResult/Artifact/PackageOverride + migrations; Oban + `oban_jobs`. No behavior change. | resource tests |
| 3 | **Builder + Build worker** | port `docker.ex`→`Portal.Builder`; `Workers.Build` runs docker → parses `result.json` → ingests. | new integration test: one pkg → docker → DB rows (replaces runner's integration test) |
| 4 | **Triggers** | `Workers.DiscoverReleases` cron; wire Hex/GitHub/Turnstile intake → enqueue `Build` (drop `forward_to_orchestrator`); Turnstile siteverify in-app. Delete `functions/`. | intake tests; manual Turnstile check |
| 5 | **Dynamic site** | LiveViews (`/`, `/packages/:name`, `/requests/:id`), badge + `/api` controllers from Catalog (schema-v2 JSON). Port `site/generator.ex` render logic into views. | view/LiveView tests; badge/API snapshot |
| 6 | **Demolition** | delete `orchestrator/`, `runner/`, `site/`, `wrangler.toml`, `public/site/`; thin `Makefile`; one-time import `package_metadata.json`→`PackageOverride`. | full suite green |

Each phase is independently shippable. Phases 1 and 3 are the risky ones (they touch the Docker boundary); 4–6 are additive/subtractive on the web side.

---

## Out of scope / non-goals

- Multi-node / split web-vs-builder topology (would require Postgres). Single host only for now.
- Keeping Cloudflare Pages / static generation.
- Changing the worker↔container JSON contract, exit codes, or `LockPolicy`.
- Distributed Oban (Oban Lite is single-node by design).

## Risks

- **Phase 1 + 3 touch the Docker boundary** — the integration test is the gate; do not proceed past either with it red.
- **Umbrella config bleed** — portal-only config must not break the worker image build (Section 5 caveat).
- **Firehose volume** — `DiscoverReleases` enqueues every new Hex release at low priority; ensure `builds` concurrency + dedupe keep it bounded.
- **Data backfill** — existing `package_metadata.json` and any prod index data need a one-time import into Catalog/PackageOverride.
