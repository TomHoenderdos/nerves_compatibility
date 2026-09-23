# Precompiled Package API

The Phoenix portal publishes precompiled package artifacts as a content-addressed HTTP API backed by `Portal.Catalog.Artifact` rows and the artifact store on disk.

## Overview

The API consists of:

- **Manifest files** — JSON listing available package versions and their per-system file manifests.
- **Artifact files** — compiled files (BEAM bytecode, NIFs, priv files) served by SHA256 hash.

## Base URL

`https://compatibility.nerves-project.org/`

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

The portal verifies each uploaded blob's SHA256 before atomically publishing it.
Mismatched blobs are rejected and are not registered for that build's manifest.
When ingestion retries after a source file has been moved, the stored blob is
verified before it is reused. This does not retroactively audit existing files;
clients should also verify downloaded bytes against the manifest digest.

A `.beam` is very often byte-identical across Nerves targets, which makes this
sharing the common case rather than the exception. Storage and publication are
therefore two separate records: `catalog_artifacts` holds one row per distinct
SHA256 saying the bytes are on disk, and `catalog_artifact_memberships` holds one
row per (system result, SHA256) saying that system's build produced that file.
The same `sha256` will legitimately appear under several systems in one manifest,
and `GET /api/precompiled/files/{sha256}` serves the one shared blob for all of
them.

## Limitations

- Only packages built after artifact archiving was enabled have manifests.
- Not every Nerves system is available for every package.
- Artifacts come only from successful builds with BEAM scan manifests.
- Manifests list the package's own files. Its dependencies' blobs are stored but
  are not published, because their per-file manifests are deliberately not
  retained.
- Manifests do not yet state the Elixir/OTP versions the files were compiled
  against. A `.beam` is only safely reusable against a matching OTP major, so
  this has to be published before anything consumes these files automatically.
  Runs record it as of 2026-09-16; earlier runs have no toolchain stored.
