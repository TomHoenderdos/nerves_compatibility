# Precompiled Package API

The Phoenix portal publishes precompiled package artifacts as a content-addressed HTTP API.

## Overview

The API consists of:

- **Manifest files** — JSON listing available package versions and their per-system file manifests.
- **Artifact files** — compiled files (BEAM bytecode, NIFs, priv files) served by SHA256 hash.

## Base URL

`https://compatibility.nerves-project.org/`

## Endpoints

### GET /api/precompiled/manifests/{package_name}.json

Manifest format 1, kept for existing clients. New clients use format 2
(`/api/precompiled/v2/manifests`, below), which also lists the toolchain builds
format 1 cannot express.

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

### GET /api/precompiled/v2/manifests/{package_name}.json

Manifest format 2: see "Manifest format 2" below for the shape and how a
client matches a build.

Status codes:

- `200` — manifest found
- `404` — package has no build that format 2 can publish

### GET /api/precompiled/files/{sha256}

Returns artifact content by SHA256.

Example: `/api/precompiled/files/96b613f9050e8e3fba6639d9695a65386c699ccac6608d2e972f9e25a4fc81a7`

Response: binary file content with `content-type: application/octet-stream`.

Status codes:

- `200` — file found
- `404` — no published file with that SHA256

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
- `404` — no root document is published

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
  },
  "manifests_v2": {
    "circuits_gpio": "1f0c...",
    "jason": "8a2e..."
  }
}
```

`manifests` names format-1 manifests and `manifests_v2` format-2 ones
(served at `/api/precompiled/v2/manifests/<package>.json`). `version` stays
`1`: format 2 is an added map, not a new batch format, so clients that only
know `manifests` keep verifying. A package can be in one map and not the
other: a run without a recorded toolchain, dependency lock or package checksum
is format 1 only, and a toolchain build is format 2 only. A batch signed before
format 2 has no `manifests_v2`; a client falls back to `manifests`.

An `etag` header of `"batch-<sequence>"` is set.

Status codes:

- `200` — a batch has been signed
- `503` — no batch available yet

### GET /api/precompiled/batches/{sequence}.json

Returns a past batch by its sequence number, in the same envelope shape as `batch.json`. Used to audit history, or to re-verify a manifest that was fetched against an older batch.

Status codes:

- `200` — batch found
- `404` — no batch with that sequence

## Response fields (format 1, kept for existing clients)

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
      for a package with no dependencies. `deps` is per entry: the worker
      resolves the package's own optional dependencies too, when they build
      (decimal under jason, jason under ecto), for a `pure_elixir` entry's
      host build and, after the firmware builds, per passing Nerves target of
      a firmware run; a client whose lock lacks one of them does not match,
      because the package compiled differently with it loadable. Optional dev
      tooling (igniter, ex_doc and the like) and alternatives an application
      picks one of are never added. A firmware run's targets are tried
      independently, so one target's entry can list an optional dependency
      that another target's entry (of the same run) lacks, when the pass
      failed for that target — a client should check `deps` per entry, never
      assume it is the same across a package's targets.
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
  - `mode` — the file's mode as built, published as exactly `33188` (0o100644)
    or `33261` (0o100755): 0755 when the build saw any execute bit, 0644
    otherwise. A system whose build owns a file without a usable mode or
    path is left out of the manifest whole, so a client compiles the package
    rather than installing it without that file. Manifests published before
    2026-10-25 carried 0644 for every file, executables under `priv/`
    included, until repaired or rebuilt.
- `updated_at` — ISO 8601 timestamp of the newest run represented in the manifest.

## Manifest format 2 (`/api/precompiled/v2/manifests`)

Format 1 is a map, `versions[v][target] = entry`, so it holds one entry per
target. Format 2 is a build list, which can hold one build per target *and*
toolchain:

```json
{
  "format": 2,
  "versions": {
    "1.4.5": {
      "builds": [
        {
          "target": "pure_elixir",
          "ebin": [
            {"path": "ebin/jason.beam", "sha256": "...", "size": 1234, "mode": 33188}
          ],
          "priv": [],
          "build": {
            "elixir": "1.20.3", "otp": "29", "dep_env": "prod",
            "system_version": null,
            "deps": {"decimal": {"version": "2.3.0", "checksum": "..."}},
            "compile_env": [],
            "package_checksum": "...",
            "run_id": "...", "image_digest": "sha256:..."
          }
        },
        {
          "target": "nerves_system_rpi4",
          "ebin": [...], "priv": [...],
          "build": {"elixir": "1.18.4", "otp": "27", "dep_env": "prod", "system_version": "2.2.1", "...": "..."}
        }
      ]
    }
  },
  "updated_at": "2026-10-24T10:00:00Z"
}
```

- `format` — `2`. A client that gets a higher number than it knows must fail
  rather than guess.
- `versions[version].builds` — the builds of that version. An empty or absent
  list, or a `target` the client does not know, is a miss, not an error.
- `target` — what format 1 used as the map key: a Nerves system package, or
  `pure_elixir` for files that are the same on every target.
- `ebin`, `priv` and their file entries — as in format 1.
- `build` — the format-1 `build` fields (`elixir`, `otp`, `system_version`,
  `deps`, `compile_env`, `package_checksum`, `run_id`, `image_digest`, same
  meaning) plus `dep_env`, the Mix env the package was compiled under as a
  dependency. Every build the portal makes is `"prod"`, which is what Mix
  compiles a dependency as unless the project overrides its `env:`.
- `updated_at` — the newest `finished_at` among the builds listed.

What it lists:

- Every build format 1 publishes, with `target` set to its format-1 key.
  Format 1 keeps only the newest per target; format 2 keeps each toolchain's.
- Toolchain builds: a pure-BEAM package version built on a plain Elixir/OTP
  image for `Mix.install` and non-Nerves projects, `target` `pure_elixir` and
  `system_version` `null`. Only passing, unrevoked builds whose files can all
  be served appear.
- A build whose `elixir`, `otp`, `deps`, `package_checksum` or `compile_env`
  is `null` is left out, since no client can match it (it stays in format 1).
- One build per target, toolchain (`"<elixir minor>/<otp>"`),
  `system_version` and `deps`: the newest wins. Two versions of one Nerves
  system are two builds, because a client takes a system build only at its own
  system version.

### Matching a format-2 build to a project

The client checks each build in this order, and reports the first rule a
build fails as the reason it was not used:

1. **Target** — `target` is `pure_elixir`, or equals the project's Nerves
   system with `build.system_version` equal to the system's version.
2. **Toolchain recorded** — `build.elixir` and `build.otp` are present.
3. **Elixir minor** — the running Elixir has the same major.minor as
   `build.elixir`, and its patch is at least the built patch. Code compiled on
   x.y.0 runs on x.y.N; the reverse is not promised, because a later patch's
   macros can expand to helpers an earlier one lacks.
4. **OTP major** — exactly equal. Record layouts from OTP headers
   (`Record.extract`) are baked into the BEAM at compile time and change
   between majors.
5. **Dependency compile env** — `build.dep_env` equals the env the project
   compiles the dependency under (`env:` on the dep, `prod` when unset).
6. **Package checksum** — `build.package_checksum` equals the outer checksum
   of the project's own `mix.lock` entry for the package.
7. **Dependencies** — every dependency in `build.deps` is in the project's
   `mix.lock` with the same version and outer checksum.
8. **Declared dependencies** — every dependency the package declares in its
   own `mix.exs` (optional ones included) that is in the project's `mix.lock`
   is also in `build.deps`. A package compiles differently when an optional
   dependency is loadable, so a build made without one does not serve a
   project that has it. Extra dependencies the package does not declare do not
   matter.
9. **compile_env** — `build.compile_env` is present, and every `build.compile_env` item decodes to the value the
   project's config gives for that app and path.

Among the builds that pass, the client prefers an exact Elixir patch match,
then the closest older patch, then `pure_elixir` over a system build, then the
newest `run_id`.

## Trust

A manifest or file is only as trustworthy as the chain that names it: `root.json`
says which key may sign a batch; a batch, signed by that key, names the SHA256
of every package's manifest bytes; `manifests/{package}.json` (and
`v2/manifests/{package}.json` for `manifests_v2`) serves exactly those bytes, so a client can hash what it downloaded and compare it to the
batch entry instead of trusting the connection; `files/{sha256}` is
content-addressed, so each file is its own proof once its manifest entry is
trusted. A client that skips this chain (today's install script) can still use
`manifests/{package}.json` directly — it is served from the same stored bytes,
just without the batch to check them against.

- **Envelope** — every signed document (`root.json`, `batch.json`,
  `batches/{sequence}.json`) is `{"payload": base64url(bytes), "signatures":
  [{"keyid": hex, "sig": base64url}]}`, Ed25519 over the raw payload bytes. A
  client verifies the signature before decoding the payload.
- **Keys and thresholds** — `root.json` lists the Ed25519 keys allowed to sign
  each role and how many signatures each needs (`roles.root.threshold` and
  `roles.batch.threshold`). A client accepts a document only when it carries at
  least that many valid signatures from the role's keys. The `keyid` is the lowercase hex SHA256 of the key's 32 public
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
- **Revocation** — there is no separate revoke endpoint. When a build is
  withdrawn, the next signed batch drops the package from `manifests` and
  `manifests_v2` or points at a different hash in each. A client that verifies
  against the newest batch stops being told to fetch the withdrawn bytes from
  the moment that batch is signed.

## Deduplication

Files are content-addressed, so identical files across packages, versions, or systems share a single artifact blob.

The portal verifies each blob's SHA256 before publishing it. Clients should
also verify downloaded bytes against the manifest digest.

A `.beam` is very often byte-identical across Nerves targets, which makes this
sharing the common case rather than the exception. The same `sha256` will legitimately appear under several systems in one manifest,
and `GET /api/precompiled/files/{sha256}` serves the one shared blob for all of
them.

## Limitations

- Only packages built after artifact archiving was enabled have manifests.
- Not every Nerves system is available for every package.
- Artifacts come only from successful builds with BEAM scan manifests.
- Manifests list the package's own files, not its dependencies'.
- Entries from runs before 2026-09-16 have no toolchain stored, so their
  `build.elixir` and `build.otp` are `null` and a client should skip them.
- Entries from runs before 2026-10-20 have no dependency lock stored, so their
  `build.deps` is `null` and a client should skip them.
- `pure_elixir` entries from runs before 2026-10-24 were built without the
  package's optional dependencies, so their `build.deps` lacks them and a
  client whose lock has them (decimal next to jason, for example) does not
  match.
- Per-system entries from firmware runs before 2026-10-27 were built
  without the package's optional dependencies for every target, the same
  as a `pure_elixir` entry from before 2026-10-24; the per-target pass
  added on 2026-10-27 only covers runs from then on, and only the targets
  it kept them for.
- Pure Elixir packages have `pure_elixir` entries only from runs after
  2026-10-20; earlier ones archived no files.
- Entries from runs before 2026-10-23 list the release copy of each BEAM,
  stripped of `debug_info`. Later runs list the target's compile output,
  `_build/<target>/lib/<package>/`, whose BEAMs keep it, so a client can
  consolidate protocols a precompiled dependency defines and Dialyzer sees
  its types. The manifest shape is the same either way.
- An entry appears only once every file it lists can be served, so a fresh
  build may be delayed; until then the manifest keeps offering that version's
  previous complete build, if it has one.
