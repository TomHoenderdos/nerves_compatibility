# Catalog JSON API (schema version 2)

This document describes the JSON served by the Nerves Compatibility Tracker's
catalog API.

| Endpoint | Shape |
| --- | --- |
| `GET /api/packages` | [Packages](#packages) for every package in the catalog |
| `GET /api/packages/:name` | [Packages](#packages) holding only `:name`; `404` with `{"error": "package not found"}` when unknown |
| `GET /api/stats` | [Stats](#stats) |
| `GET /api/failing` | [Failing](#failing) packages ranked by hex.pm downloads (own `schema: 1`) |

The same endpoints are described as an OpenAPI 3 document at
`GET /api/openapi.json`, and rendered as a page at `/api/docs`.

Conventions:
- All timestamps are ISO 8601 strings (e.g., `"2025-12-23T10:30:00Z"`)
- Status values are one of: `pass`, `fail`, `error`, `skipped`, `unknown`

---

## Packages

The latest test results for each package across all systems.

### Schema

```json
{
  "schema": 2,
  "generated_at": "<iso8601>",
  "packages": {
    "<package_name>": {
      "description": "<string>",
      "latest_version": "<string>",
      "last_run_at": "<iso8601>",
      "native_components": { ... } | null,
      "systems": {
        "<system_pkg>@<system_version>": {
          "system_pkg": "<string>",
          "system_version": "<string>",
          "status": "<pass|fail|error|skipped|unknown>",
          "firmware_size_bytes": <integer> | null,
          "hex_version_tested": "<string>",
          "run_id": "<string>",
          "log_path": "<relative_path>"
        }
      }
    }
  }
}
```

### Fields

- **schema**: Integer schema version (currently 2)
- **generated_at**: Timestamp when this response was generated
- **packages**: Map of package name to package data
  - **description**: Human-readable package description
  - **latest_version**: Latest version from Hex.pm
  - **last_run_at**: Timestamp of most recent test run for this package
  - **native_components**: What native code the package carries, or `null`.
    `compatibility_basis` is set for assessed results (see below)
  - **systems**: Map of system key to the result of the package's latest run
    - **Key format**: `"<system_pkg>@<system_version>"`
    - **system_pkg**: Name of the Nerves system package, or an assessment
      entry (`host`, `pure_elixir`, `registry_deps`, `nerves_tooling`)
    - **system_version**: Version of the Nerves system
    - **status**: Test result status
    - **firmware_size_bytes**: Firmware image size, when one was built
    - **hex_version_tested**: Version of the hex package that was tested
    - **run_id**: Identifier of the run that produced this result
    - **log_path**: Relative path to the test log file

An entry may be carried from an earlier build of the same version: a
partial run (argus only, or a subset of targets) rebuilds only some
systems, and ingestion copies the rest from the previous run of that
version. The copy belongs to the latest run, so its `run_id` is that run's.

### Example

```json
{
  "schema": 2,
  "generated_at": "2025-12-23T10:30:00Z",
  "packages": {
    "phoenix": {
      "description": "Web framework for Elixir",
      "latest_version": "1.7.14",
      "last_run_at": "2025-12-23T09:15:00Z",
      "native_components": null,
      "systems": {
        "nerves_system_rpi4@1.26.1": {
          "system_pkg": "nerves_system_rpi4",
          "system_version": "1.26.1",
          "status": "pass",
          "firmware_size_bytes": 41287680,
          "hex_version_tested": "1.7.14",
          "run_id": "run_001_phoenix_rpi4",
          "log_path": "logs/phoenix_rpi4_1.7.14.log"
        }
      }
    }
  }
}
```

---

## Stats

Aggregate statistics over every stored system result, except results carried
from an earlier build (see [Packages](#packages)): those are copies
of a result already counted.

### Schema

```json
{
  "schema": 2,
  "generated_at": "<iso8601>",
  "counts": {
    "total": <integer>,
    "pass": <integer>,
    "fail": <integer>,
    "error": <integer>,
    "skipped": <integer>,
    "unknown": <integer>
  },
  "by_system": {
    "<system_pkg>@<system_version>": {
      "pass": <integer>,
      "fail": <integer>,
      "error": <integer>,
      "skipped": <integer>,
      "unknown": <integer>
    }
  },
  "last_run_finished_at": "<iso8601>"
}
```

### Fields

- **schema**: Integer schema version (currently 2)
- **generated_at**: Timestamp when this response was generated
- **counts**: Global counts across all systems
  - **total**: Total number of results
  - **pass, fail, error, skipped, unknown**: Counts per status
- **by_system**: Map of system key to counts for that system
  - **Key format**: `"<system_pkg>@<system_version>"`
  - Assessment entries (`pure_elixir`, `registry_deps`, `nerves_tooling`; see below) are not
    Nerves systems and are omitted here. They still count in **counts**.
  - **pass, fail, error, skipped, unknown**: Counts per status
- **last_run_finished_at**: Timestamp of the most recently completed run

### Example

```json
{
  "schema": 2,
  "generated_at": "2025-12-23T10:30:00Z",
  "counts": {
    "total": 4,
    "pass": 3,
    "fail": 1,
    "error": 0,
    "skipped": 0,
    "unknown": 0
  },
  "by_system": {
    "nerves_system_rpi4@1.26.1": {
      "pass": 2,
      "fail": 0,
      "error": 0,
      "skipped": 0,
      "unknown": 0
    }
  },
  "last_run_finished_at": "2025-12-23T09:20:15Z"
}
```

---

## Failing

Packages whose latest run has at least one `fail` or `error` target, ranked by
hex.pm downloads: the failures whose fix helps the most projects. The same list
is rendered at `/failing`. "Latest run" is the run [Packages](#packages) shows.

This endpoint versions independently of the schema-v2 documents above.

### Parameters

All optional. An invalid value falls back to its default rather than erroring.

- **sort**: `recent` (hex.pm 90-day downloads, default) or `all` (all-time)
- **limit**: number of packages, `1`..`200` (default `50`; out-of-range values are clamped)
- **system**: a system package name, e.g. `nerves_system_rpi4`; only packages
  failing on that target

### Schema

```json
{
  "schema": 1,
  "generated_at": "<iso8601>",
  "sort": "recent" | "all",
  "packages": [
    {
      "name": "<string>",
      "description": "<string>" | null,
      "latest_version": "<string>" | null,
      "version_tested": "<string>" | null,
      "last_run_at": "<iso8601>" | null,
      "downloads_recent": <integer> | null,
      "downloads_all": <integer> | null,
      "status": "fail" | "error",
      "failing_targets": [
        {
          "system": "<system_pkg>@<system_version>",
          "status": "fail" | "error",
          "failure_category": "<string>" | null
        }
      ],
      "failing_count": <integer>,
      "total_targets": <integer>
    }
  ]
}
```

### Fields

- **packages**: Ordered by the chosen download count, highest first; packages
  hex.pm has no count for come last; ties by name
  - **downloads_recent / downloads_all**: hex.pm download counts, refreshed weekly
  - **status**: `error` if any failing target errored, otherwise `fail`
  - **failing_targets**: Only the `fail` / `error` targets of the latest run
  - **failing_count / total_targets**: Failing targets out of all targets in that run

---

## Assessed results

### Pure-Elixir compatibility assessment

Packages that pass host compilation and whose resolved dependency closure is
identified as pure Elixir may have a `pure_elixir` system entry with `status: "pass"`.
This means **assumed compatible**, not a successful firmware build. The entry has
no system version, firmware size, or precompiled artifacts; the separate `host`
entry records the actual compile result. Package metadata exposes
`native_components.compatibility_basis: "pure_elixir"` for these assessments.
Native code, Nerves-specific packages, failed host compiles, and incomplete
inspection keep the firmware build path.

### Registry dependency assessment

Packages seeded in bulk may instead carry a single `registry_deps` system entry
with `status: "pass"`. This means **assumed compatible from registry data
alone**: the package was assessed from registry metadata without a build.
Nothing was compiled, not even on the host. Package metadata
exposes `native_components.compatibility_basis: "registry_deps"`. A requested
scan of the package replaces the assessment with a real build.

### Nerves tooling

Nerves' own tooling is not checked: `nerves`, `nerves_bootstrap`,
`nerves_systems`, and every `nerves_system_*`, `nerves_toolchain*` and
`kiosk_system_*` package. Building these into a Nerves project for every target
fails for reasons that say nothing about whether they work. Their runs carry a
single `nerves_tooling` system entry with `status: "skipped"`, and package
metadata exposes `native_components.compatibility_basis: "nerves_tooling"`.
Their badge reads "not checked". A requested scan records the same skip again.

## Status values

- **pass**: Test completed successfully
- **fail**: Test ran but failed (e.g., dependency conflict, compilation error)
- **error**: Test encountered an unexpected error
- **skipped**: Test was intentionally skipped
- **unknown**: Status could not be determined
