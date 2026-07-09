# Precompiled Package API

The Phoenix portal publishes precompiled package artifacts as a content-addressed HTTP API backed by `Portal.Catalog.Artifact` rows and the artifact store on disk.

## Overview

The API consists of:

- **Manifest files** — JSON listing available package versions and their per-system file manifests.
- **Artifact files** — compiled files (BEAM bytecode, NIFs, priv files) served by SHA256 hash.

## Base URL

`https://compatibility.embedded-elixir.com/`

## Endpoints

### GET /api/precompiled/manifests/{package_name}.json

Returns the manifest for a package: all available versions and systems with archived files.

Example: `/api/precompiled/manifests/circuits_gpio.json`

Response:

```json
{
  "versions": {
    "2.1.3": {
      "nerves_system_rpi4": {
        "ebin": [
          {
            "path": "ebin/Elixir.Circuits.GPIO.beam",
            "sha256": "96b613f9050e8e3fba6639d9695a65386c699ccac6608d2e972f9e25a4fc81a7",
            "size": 1234,
            "mode": 33188
          }
        ],
        "priv": [
          {
            "path": "priv/gpio_nif.so",
            "sha256": "...",
            "size": 45678,
            "mode": 33261
          }
        ]
      }
    }
  },
  "updated_at": "2026-01-04T15:23:45Z"
}
```

Status codes:

- `200` — manifest found
- `404` — package has no precompiled manifest

### GET /api/precompiled/files/{sha256}

Returns artifact content by SHA256.

Example: `/api/precompiled/files/96b613f9050e8e3fba6639d9695a65386c699ccac6608d2e972f9e25a4fc81a7`

Response: binary file content with `content-type: application/octet-stream`.

Status codes:

- `200` — file found on disk
- `404` — artifact row or blob file not available

## Response fields

- `versions` — map of version strings to system data.
- `versions[version][system]` — file manifest for a specific version/system combination.
  - `ebin` — compiled BEAM files and app files.
  - `priv` — priv directory files such as NIFs/resources.
- Each file entry contains:
  - `path` — relative path within the package, e.g. `ebin/myapp.beam`.
  - `sha256` — lowercase hexadecimal SHA256 of the file.
  - `size` — file size in bytes when reported by the worker.
  - `mode` — Unix file mode when reported by the worker.
- `updated_at` — ISO 8601 timestamp of the newest run represented in the manifest.

## Deduplication

Files are content-addressed, so identical files across packages, versions, or systems share a single artifact blob.

## Limitations

- Only packages built after artifact archiving was enabled have manifests.
- Not every Nerves system is available for every package.
- Artifacts come only from successful builds with BEAM scan manifests.
