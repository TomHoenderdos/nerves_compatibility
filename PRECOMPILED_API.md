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
        ],
        "build": {
          "elixir": "1.18.4",
          "otp": "27",
          "system_version": "1.31.0",
          "run_id": "...",
          "image_digest": "sha256:...",
          "deps": {
            "elixir_make": {"version": "0.9.0", "checksum": "..."}
          }
        }
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

### GET /api/precompiled/root.json

Returns the signed root document: which key(s) may sign batches and roots, and the thresholds. See Trust.

Response: a signed envelope wrapping:

```json
{
  "version": 1,
  "expires": "2027-01-01T00:00:00Z",
  "keys": {
    "<keyid>": {"type": "ed25519", "public": "<base64url>"}
  },
  "roles": {
    "root": {"keyids": ["<keyid>"], "threshold": 1},
    "batch": {"keyids": ["<keyid>"], "threshold": 1}
  }
}
```

Status codes:

- `200` — root document found
- `404` — no `PRECOMPILED_SIGNING_KEY` configured on this host, or
  `root.json` is missing or unreadable next to the configured key

### GET /api/precompiled/batch.json

Returns the newest signed batch: every package with precompiled files and the SHA256 of its manifest bytes. See Trust.

Response: a signed envelope wrapping:

```json
{
  "version": 1,
  "sequence": 42,
  "issued": "2026-10-21T00:00:00Z",
  "expires": "2026-10-28T00:00:00Z",
  "manifests": {
    "circuits_gpio": "96b613f9050e8e3fba6639d9695a65386c699ccac6608d2e972f9e25a4fc81a7"
  }
}
```

An `etag` header of `"batch-<sequence>"` is set.

Status codes:

- `200` — a batch has been signed
- `503` — no batch has been signed yet (no signing key configured, or the first cron run has not fired)

### GET /api/precompiled/batches/{sequence}.json

Returns a past batch by its sequence number, in the same envelope shape as `batch.json`. Used to audit history, or to re-verify a manifest that was fetched against an older batch.

Status codes:

- `200` — batch found
- `404` — no batch with that sequence

## Response fields

- `versions` — map of version strings to system data.
- `versions[version][system]` — file manifest for a specific version/system combination.
  - `ebin` — compiled BEAM files and app files.
  - `priv` — priv directory files such as NIFs/resources.
  - `build` — what the files were built with: `elixir`, `otp`, `system_version`,
    `run_id`, `image_digest`. A client should use an entry only when `elixir`
    and `otp` equal its own; `elixir` and `otp` are `null` for runs from before
    the toolchain was recorded.
    - `deps` — the dependency tree the files were compiled against: every
      package in the package's transitive dependency closure (the package
      itself excluded), as `name => {"version", "checksum"}`, where `checksum`
      is the outer Hex checksum, the last element of a `mix.lock` entry. `{}`
      for a package with no dependencies.
    - `package_checksum` — the package's own outer Hex checksum from the
      build's `mix.lock`, a string, or `null` for runs from before it was
      recorded and for argus-only runs.
    - `compile_env` — the package's `.app` file `compile_env` reads, one item
      per `{app, path, value}` triple: `app` and the elements of `path` are
      strings, and `value` is `base64url(:erlang.term_to_binary({:ok, v} |
      :error, [:deterministic]))`. `null` for runs from before it was
      recorded or when the worker could not read the `.app` file; `[]` when
      the file was read but had no `compile_env` reads of its own.
    - A carried-forward entry (a partial rebuild of the version that left this
      system out) describes the run that actually built the files, so its
      `run_id` can be older than the version's newest run.

### Matching an entry to a project

A BEAM file contains more than its package's own code: every macro it calls
from a dependency was expanded into it at compile time, with whatever that
dependency's version produced. Matching the platform (Elixir, OTP, Nerves
system) is therefore not enough, the way it is for a Python wheel; the
dependency tree has to match too. A client should use an entry only when:

1. `build.elixir` and `build.otp` equal its own, and
2. `build.deps` is not `null`, and every dependency it names is in the
   client's `mix.lock` with the same version and the same outer checksum.
3. `build.package_checksum` is non-null and equals the outer checksum of
   your own `mix.lock` entry for the package. An entry whose
   `package_checksum` is `null` never matches.
4. `build.compile_env` is non-null and every item decodes to the value
   your project's config gives for that app and path (`:error` meaning
   unset). An entry whose `compile_env` is `null` never matches.

Extra dependencies in the client's lock do not matter. A missing dependency,
a different version or a different checksum means building from source.
- `versions[version]["pure_elixir"]` — files of a package whose whole dependency
  closure is pure Elixir. No firmware is built for such a package; its files
  come from the host compile and are the same for every target, so a client
  without an entry for its own system can use this one. `system_version` is
  `null`.
- Each file entry contains:
  - `path` — relative path within the package, e.g. `ebin/myapp.beam`.
  - `sha256` — lowercase hexadecimal SHA256 of the file.
  - `size` — file size in bytes when reported by the worker.
  - `mode` — Unix file mode when reported by the worker.
- `updated_at` — ISO 8601 timestamp of the newest run represented in the manifest.

## Trust

A manifest or file is only as trustworthy as the chain that names it: `root.json`
says which key may sign a batch; a batch, signed by that key, names the SHA256
of every package's manifest bytes; `manifests/{package}.json` serves exactly
those bytes, so a client can hash what it downloaded and compare it to the
batch entry instead of trusting the connection; `files/{sha256}` is
content-addressed, so each file is its own proof once its manifest entry is
trusted. A client that skips this chain (today's install script) can still use
`manifests/{package}.json` directly — it is served from the same stored bytes,
just without the batch to check them against.

- **Envelope** — every signed document (`root.json`, `batch.json`,
  `batches/{sequence}.json`) is `{"payload": base64url(bytes), "signatures":
  [{"keyid": hex, "sig": base64url}]}`, Ed25519 over the raw payload bytes. A
  client verifies the signature before decoding the payload.
- **Key** — one online Ed25519 key signs both roots and batches, a 1-of-1
  threshold (`roles.root.threshold` and `roles.batch.threshold` in
  `root.json`). The `keyid` is the lowercase hex SHA256 of the key's 32 public
  bytes.
- **Expiry** — `root.json` expires a year after it is written; a batch expires
  7 days after it is issued. A client should refuse an expired document.
- **Sequence** — a batch's `sequence` increases by exactly one each time a new
  batch is signed. A client that has already seen a higher sequence should
  refuse a lower one.
- **Manifests are stored bytes** — a manifest entry in a batch names the
  SHA256 of the manifest JSON as it existed when that batch was built; the
  manifest endpoint serves those same stored bytes (not a fresh render) for
  as long as that is the newest batch, so the hash a client checks against
  always matches what it downloads.
- **Revocation** — there is no separate revoke endpoint. Revoking a run (or a
  newer run superseding a carried-forward one) changes what the catalog would
  render for that package; the next signed batch picks that up, dropping the
  package from `manifests` entirely or pointing at a different hash. A client
  that verifies against the newest batch stops being told to fetch the
  revoked bytes from the moment that batch is signed.

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
- Entries from runs before 2026-09-16 have no toolchain stored, so their
  `build.elixir` and `build.otp` are `null` and a client should skip them.
- Entries from runs before 2026-10-20 have no dependency lock stored, so their
  `build.deps` is `null` and a client should skip them.
- Pure Elixir packages have `pure_elixir` entries only from runs after
  2026-10-20; earlier ones archived no files.
- Entries from runs before 2026-10-23 list the release copy of each BEAM,
  stripped of `debug_info`. Later runs list the target's compile output,
  `_build/<target>/lib/<package>/`, whose BEAMs keep it, so a client can
  consolidate protocols a precompiled dependency defines and Dialyzer sees
  its types. The manifest shape is the same either way.
- An entry appears only once every file it lists can be served from this host.
  Builds run on other hosts whose blobs are copied here every few minutes, so a
  fresh build can take that long to show up; until then the manifest keeps
  offering that version's previous complete build, if it has one.
