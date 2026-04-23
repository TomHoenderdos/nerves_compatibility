# Precompiled Package API

The Nerves Compatibility site publishes precompiled package artifacts as a content-addressed HTTP API.

## Overview

The API consists of:
- **Manifest files** — JSON listing available versions and their per-system file manifests.
- **Archive files** — The actual compiled files (BEAM bytecode, NIFs, priv files) stored by SHA256 hash.

## Base URL

`https://compatibility.embedded-elixir.com/`

See `DEPLOY.md` for how the manifests and files bases can be configured independently.

## Endpoints

### GET /manifests/{package_name}.json

Returns the manifest for a package: all available versions and systems.

**Example:** `/manifests/circuits_gpio.json`

**Response:**
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
          },
          {
            "path": "ebin/circuits_gpio.app",
            "sha256": "...",
            "size": 523,
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
      },
      "nerves_system_x86_64": {
        "ebin": [...],
        "priv": [...]
      }
    },
    "2.1.2": {
      "nerves_system_rpi4": {...}
    }
  },
  "updated_at": "2026-01-04T15:23:45Z"
}
```

**Response fields:**
- `versions` — map of version strings to system data
- `versions[version][system]` — file manifest for a specific version/system combination
  - `ebin` — array of compiled BEAM files and app files
  - `priv` — array of priv directory files (NIFs, resources, etc.)
- Each file entry contains:
  - `path` — relative path within the package (e.g., `ebin/myapp.beam`)
  - `sha256` — SHA256 of the file (lowercase hex)
  - `size` — file size in bytes
  - `mode` — Unix file mode
- `updated_at` — ISO 8601 timestamp of last manifest update

**Status codes:**
- `200` — manifest found
- `404` — package has no precompiled manifest

### GET /files/{sha256}

Returns the file content by SHA256.

**Example:** `/files/96b613f9050e8e3fba6639d9695a65386c699ccac6608d2e972f9e25a4fc81a7`

**Response:** binary file content.

**Status codes:**
- `200` — file found
- `404` — file not available

## Deduplication

Files are content-addressed, so they deduplicate naturally:
- Files with identical content across packages, versions, or systems share a single `/files/<sha256>` object.
- Multiple versions of a package often share most of their files.

## Limitations

- Only packages built after the precompiled system was deployed have manifests.
- Not every Nerves system is available for every package.
- Artifacts come only from successful builds — failed builds have no precompiled files.

## Format notes

- SHA256 values are lowercase hexadecimal (64 characters).
- `mode` is a decimal integer (e.g., `33188` for `0644`, `33261` for `0755`).
- All paths use forward slashes and are relative to the package root (`ebin/…` or `priv/…`).
