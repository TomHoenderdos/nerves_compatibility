# Queue filter: classify pure-Elixir packages from registry dependencies

Status: approved design, not yet implemented. Not to be deployed until reviewed.
Date: 2026-09-30.

## Problem

Hex carries ~22,500 packages; the catalogue tracks 3,597. The gap is not a
filter. `Portal.CatalogSeed` queued every untracked package on 2026-09-21/22,
about 1,090 were built, and the remaining 18,588 `Build` jobs were cancelled by
hand on 2026-09-22 19:39 UTC (their scan requests are `rejected` with "automatic
catalog-seeding backlog cleared; package compatibility was not assessed").

Every package in that sweep cost a Docker run, a `mix deps.get` and a host
compile, even though #36 (`NccWorker.BuildSelection`) then skips the firmware
builds for pure-Elixir packages. The skip happens inside the container, after the
expensive part. There is no filter before the queue, and re-running the seed
today would queue the same 18.5k builds again.

The predicate was approved on 2026-09-18: a package can only fail a Nerves build
in an interesting way if native code appears somewhere in its transitive
dependency closure. That closure is computable from `repo.hex.pm` alone.

## Scope

In:

- Classify bulk-intake packages (`catalog_seed`, `backfill` sources) from
  registry dependency data before any `Build` job is created.
- Record pure packages in the catalogue as `pass` with an explicit
  `registry_deps` basis, without Docker.
- Re-classify, rather than rebuild, a registry-assessed package when
  `UpdateCheck` sees a new release of it.
- A dry-run entry point for measuring the 18.5k before anything is written.
- Feature flag, default off.

Out:

- Human-initiated requests (`admin_manual`, `hex_owner`, `github_repo`,
  `anonymous_*`): unchanged, always the normal build path.
- `update_check` for packages with a real build history: unchanged.
- A cheap host-only compile for registry-classified packages. Possible later;
  not part of this change.
- Re-queueing the 18,588 rejected packages. An operator step after deploy.
- Deploying. The branch is built and reviewed, not shipped.

## Decisions

**Status is `pass`, basis `registry_deps`.** Same shape as the existing
`pure_elixir` assessment from #36: green badge, and
`native_components.compatibility_basis` tells API consumers what the pass rests
on. It claims more than was checked (no compile of any kind), and that is
accepted: the site already treats "no native code" as assumed compatible, and a
human request replaces the assessment with a real build.

**Bulk sources only.** A person asking for a package gets a real host compile.
The known blind spot (below) then only touches packages nobody asked for.

**Registry, not the hex.pm API.** Hex's team asked the project to poll the
CDN-backed repository, not the API. `Portal.HexRegistry` already follows this;
the per-package resource is the same protocol.

**CDN failure retries, never falls through to Docker.** A registry outage during
a seed must not turn into thousands of builds.

## Known blind spot

Registry dependency lists carry no file listing. A package that ships its own
`c_src/` with a hand-rolled Mix compiler and no marker dependency is classified
pure. So is pure Elixir that shells out to a tool missing from a Nerves image
(`System.cmd`, `System.find_executable`), which is what Frank Hunleth flagged.
`NccWorker.BuildSelection` catches both, but only when the package is actually
built, i.e. when a human requests it.

## Components

All new code runs on the web host, in the `:intake` queue.

### `Portal.HexDeps`

Fetches `https://repo.hex.pm/packages/<name>` and decodes it with
`:hex_registry.unpack_package/4`, verifying the signature against hex.pm's public
key. Same `Req` options as `Portal.HexRegistry` (`compressed: false`,
`decode_body: false`) for the same reason: `:hex_core` gunzips itself.

Returns `{:ok, releases}` where each release is
`%{version: String.t(), retired?: boolean(), deps: [%{package, requirement, optional, repository}]}`,
or `{:error, :hex_registry_unavailable}` (HTTP/transport failure) or
`{:error, :hex_registry_undecodable}` (bad signature, bad gzip, wrong
repo/name).

Decoded results are cached in a named ETS table with a one-hour TTL, matching
the resource's `cache-control`. A sweep resolves the same shared dependencies
(`jason`, `telemetry`, `plug`, ...) thousands of times; the cache makes that one
request each. Errors are not cached. The client and public key are injectable
exactly as in `HexRegistry.snapshot/1`, so tests use a locally signed resource.

### `Portal.NativeClosure`

`classify(name, version)` returns `:pure` or `{:native, reason}`.

Walks the dependency closure breadth-first from `name@version`:

- The root's own name matching `nerves*` is native (`{:nerves, name}`).
- Each non-optional dependency resolves to the newest non-retired release
  satisfying its requirement (`Version.match?/2`), falling back to the newest
  retired one if nothing else matches, as `mix deps.get` would.
- A dependency named in the marker list is native (`{:marker, dep}`):
  `elixir_make rustler rustler_precompiled zigler cc_precompiler unifex bundlex`.
- A dependency named `nerves*` is native (`{:nerves, dep}`).
- Visited set by name, so cycles terminate.

Fails closed. Each of these is `{:native, reason}`, so the package takes the
normal build path:

- the root version is not in the registry resource;
- no release satisfies a requirement, or a requirement does not parse;
- a dependency's `repository` is anything other than `hexpm`;
- `HexDeps` returns `:hex_registry_undecodable` for any package in the closure;
- the closure exceeds 500 packages.

`HexDeps` returning `:hex_registry_unavailable` is **not** native: `classify/2`
returns `{:error, :hex_registry_unavailable}` and the caller retries.

`dry_run(names)` classifies each name at its latest version, writes nothing,
and returns `%{pure: n, native: n, errors: n, reasons: %{reason_kind => n}}`.
Intended for `bin/portal eval` on production against the rejected names, to
size the effect and to supply numbers for the talk.

### `Portal.Catalog.RegistryAssessment`

`record(name, version, scan_request_id)` builds a `result.json`-shaped map and
passes it to `Portal.Catalog.Ingestion.ingest/2`:

- `package`: name, version, `description: nil` (the registry resource carries
  none; `Portal.HexMetaBackfill` fills links and owners later as for any
  package), `native_components: %{"compatibility_basis" => "registry_deps"}`;
- `systems`: `%{"registry_deps" => %{"status" => "pass", "log_tail" => "Assumed compatible: no native code in the dependency closure on hex.pm. Nothing was compiled."}}`;
- opts: `run_id: "registry-<name>-<version>"`, `image_digest: "registry"`,
  `files_dir` an empty scratch dir, no `output_dir`.

No blobs, no logs, one transaction. Package pages, badges and the schema-v2 API
read it like any other run.

### `Portal.Workers.Backfill` (modified)

When `NCC_QUEUE_FILTER` is on, the source is `catalog_seed` or `backfill`, and
the package has never been built (no run, or not in the catalogue) or its
latest run has `image_digest == "registry"`:

1. Resolve the version via `Portal.HexPm` (as `create_once` does today).
2. `NativeClosure.classify(name, version)`:
   - `:pure`: create the scan request with status `built`, call
     `RegistryAssessment.record/3`. No `Build` job.
   - `{:native, _}`: today's `ScanRequests.create_once/1` path, unchanged.
   - `{:error, :hex_registry_unavailable}`: return `{:error, _}`; Oban retries.

When the source is `update_check` and the package's latest run has
`image_digest == "registry"`, step 2 applies as well: a new release of a
registry-assessed package is re-classified, and only goes to Docker if it gained
native code. Packages with any real build keep today's `update_check`
behaviour. Without this, ~18k newly tracked packages would feed every minor and
major release into Docker through `UpdateCheck`.

A package whose latest run is a real build is never classified, whatever the
source. `Portal.UpstreamBackfill` enqueues `backfill` for ~2,850 names that are
mostly already tracked with real Docker builds, and a human may build a package
during a seed's stagger; a registry run recorded on top would supersede the
real result (a failing package would flip green) and overwrite the package's
description and `native_components`.

All other sources, and every source when the flag is off, behave exactly as
today.

### Flag

`NCC_QUEUE_FILTER`, read in `config/runtime.exs` with the same
`1/true/yes` / `0/false/no` / else-leave-default parsing as `NCC_UPDATE_CHECK`.
Compile-time default: off. A deploy of this branch changes nothing until the
variable is set.

### Presentation

- `PortalWeb.PackageLive`: label `registry_deps` as "Pure Elixir (dependency
  check)" and hide the system version column for it, as for `pure_elixir`;
  summary sentence "assumed Nerves-compatible: no native code in its dependency
  closure on hex.pm; not compiled."
- `docs/INDEX_FORMAT.md`: one paragraph next to the `pure_elixir` one describing
  `registry_deps`.

## Operating it (after review, not part of this change)

1. Deploy with the flag off. Nothing changes.
2. `bin/portal eval 'Portal.NativeClosure.dry_run(<rejected names>)'`; review
   the pure/native split and the reason counts.
3. Set `NCC_QUEUE_FILTER=1`, restart.
4. Re-run `Portal.CatalogSeed.run()`. The rejected rows are not open requests,
   so new requests are created. Pure packages land in the catalogue within the
   seed's one-per-second stagger (~5 hours for 18.5k); native ones queue at
   priority 9 as before.

## Testing

TDD throughout.

- `HexDeps`: decodes a locally signed package resource; bad signature is
  `:hex_registry_undecodable`; HTTP 500 is `:hex_registry_unavailable`; a second
  call inside the TTL does not hit the client; errors are not cached.
- `NativeClosure`: pure closure; direct marker; marker three levels down;
  optional marker ignored; `nerves*` root and dependency; newest matching
  release chosen over a newer non-matching one; retired release skipped when a
  live one matches; cycle terminates; unparseable or unsatisfiable requirement
  is native; non-hexpm repository is native; size cap is native; unavailable
  registry is `{:error, _}`, not native.
- `Backfill`: flag on + `catalog_seed` + pure writes a `registry_deps` pass run
  and inserts no `Build` job; native inserts a `Build` job; `admin_manual` never
  classifies; flag off is today's behaviour; unavailable registry returns an
  error and inserts no `Build` job; `update_check` on a registry-assessed
  package re-classifies; `update_check` on a Docker-built package enqueues a
  build.
- `RegistryAssessment`: the ingested run appears in `Portal.Catalog` reads, the
  badge is passing, and the API exposes `compatibility_basis: "registry_deps"`.
- `PackageLive`: renders the label and summary.
