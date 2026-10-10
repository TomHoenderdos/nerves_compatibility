# Catalog JSON API (schema version 2)

This document describes the JSON served by the Nerves Compatibility Tracker's
catalog API. `PortalWeb.CatalogApiController` serves it from
`Portal.Catalog.latest_by_pkg_json/1` and `Portal.Catalog.stats_json/0`.

| Endpoint | Shape |
| --- | --- |
| `GET /api/packages` | [Packages](#packages) for every package in the catalog |
| `GET /api/packages/:name` | [Packages](#packages) holding only `:name`; `404` with `{"error": "package not found"}` when unknown |
| `GET /api/stats` | [Stats](#stats) |

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
      entry (`host`, `pure_elixir`, `registry_deps`)
    - **system_version**: Version of the Nerves system
    - **status**: Test result status
    - **firmware_size_bytes**: Firmware image size, when one was built
    - **hex_version_tested**: Version of the hex package that was tested
    - **run_id**: Identifier of the run that produced this result
    - **log_path**: Relative path to the test log file

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

Aggregate statistics over every stored system result.

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
  - Assessment entries (`pure_elixir`, `registry_deps`; see below) are not
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
alone**: no package in the release's transitive dependency closure on hex.pm
depends on native build tooling (`elixir_make`, `rustler`,
`rustler_precompiled`, `zigler`, `cc_precompiler`, `unifex`, `bundlex`) or is a
`nerves*` package. Nothing was compiled, not even on the host. Package metadata
exposes `native_components.compatibility_basis: "registry_deps"`. A requested
scan of the package replaces the assessment with a real build.

## Status values

- **pass**: Test completed successfully
- **fail**: Test ran but failed (e.g., dependency conflict, compilation error)
- **error**: Test encountered an unexpected error
- **skipped**: Test was intentionally skipped
- **unknown**: Status could not be determined
