# Index File Format Specification

This document describes the JSON schemas used by the Nerves Compatibility Tracker.

All index files use **schema version 2** and follow these conventions:
- All timestamps are ISO 8601 strings (e.g., `"2025-12-23T10:30:00Z"`)
- All `log_path` values are relative paths suitable for static hosting
- Status values are one of: `pass`, `fail`, `error`, `skipped`, `unknown`

---

## latest_by_pkg.json

Package-centric view showing the latest test results for each package across all systems.

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
      "systems": {
        "<system_pkg>@<system_version>": {
          "system_pkg": "<string>",
          "system_version": "<string>",
          "status": "<pass|fail|error|skipped|unknown>",
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
- **generated_at**: Timestamp when this index was generated
- **packages**: Map of package name to package data
  - **description**: Human-readable package description
  - **latest_version**: Latest version from Hex.pm
  - **last_run_at**: Timestamp of most recent test run for this package
  - **systems**: Map of system key to test result
    - **Key format**: `"<system_pkg>@<system_version>"`
    - **system_pkg**: Name of the Nerves system package
    - **system_version**: Version of the Nerves system
    - **status**: Test result status
    - **hex_version_tested**: Version of the hex package that was tested
    - **run_id**: Unique identifier for this test run
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
      "systems": {
        "nerves_system_rpi4@1.26.1": {
          "system_pkg": "nerves_system_rpi4",
          "system_version": "1.26.1",
          "status": "pass",
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

## latest_by_pkg_system.json

Flat index of all test results keyed by package+system combination.

### Schema

```json
{
  "schema": 2,
  "generated_at": "<iso8601>",
  "entries": {
    "<hex_pkg>@<hex_version>|<system_pkg>@<system_version>": {
      "hex_pkg": "<string>",
      "hex_version": "<string>",
      "system_pkg": "<string>",
      "system_version": "<string>",
      "status": "<pass|fail|error|skipped|unknown>",
      "run_id": "<string>",
      "log_path": "<relative_path>",
      "finished_at": "<iso8601>"
    }
  }
}
```

### Fields

- **schema**: Integer schema version (currently 2)
- **generated_at**: Timestamp when this index was generated
- **entries**: Map of composite key to test result
  - **Key format**: `"<hex_pkg>@<hex_version>|<system_pkg>@<system_version>"`
  - **hex_pkg**: Name of the Hex package
  - **hex_version**: Version of the Hex package
  - **system_pkg**: Name of the Nerves system package
  - **system_version**: Version of the Nerves system
  - **status**: Test result status
  - **run_id**: Unique identifier for this test run
  - **log_path**: Relative path to the test log file
  - **finished_at**: Timestamp when this test completed

### Example

```json
{
  "schema": 2,
  "generated_at": "2025-12-23T10:30:00Z",
  "entries": {
    "phoenix@1.7.14|nerves_system_rpi4@1.26.1": {
      "hex_pkg": "phoenix",
      "hex_version": "1.7.14",
      "system_pkg": "nerves_system_rpi4",
      "system_version": "1.26.1",
      "status": "pass",
      "run_id": "run_001_phoenix_rpi4",
      "log_path": "logs/phoenix_rpi4_1.7.14.log",
      "finished_at": "2025-12-23T09:15:00Z"
    }
  }
}
```

---

## stats.json

Aggregate statistics about test results.

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
- **generated_at**: Timestamp when this index was generated
- **counts**: Global counts across all systems
  - **total**: Total number of tests
  - **pass**: Number of passing tests
  - **fail**: Number of failing tests
  - **error**: Number of tests with errors
  - **skipped**: Number of skipped tests
  - **unknown**: Number of tests with unknown status
- **by_system**: Map of system key to counts for that system
  - **Key format**: `"<system_pkg>@<system_version>"`
  - **pass, fail, error, skipped, unknown**: Counts per status
- **last_run_finished_at**: Timestamp of the most recently completed test

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

## Status Enum

All test results include a `status` field with one of these values:

- **pass**: Test completed successfully
- **fail**: Test ran but failed (e.g., dependency conflict, compilation error)
- **error**: Test encountered an unexpected error
- **skipped**: Test was intentionally skipped
- **unknown**: Status could not be determined

---

## Production Optimization

For production deployments, index files can be gzipped for bandwidth efficiency:

```bash
gzip -9 latest_by_pkg.json
gzip -9 latest_by_pkg_system.json
gzip -9 stats.json
```

When serving gzipped files:
- Set `Content-Type: application/json`
- Set `Content-Encoding: gzip`

For development, uncompressed files are recommended for easier debugging.
