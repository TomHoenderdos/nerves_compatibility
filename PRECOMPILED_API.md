# Precompiled Package API

The Phoenix portal publishes precompiled package artifacts as a content-addressed HTTP API.

## Overview

The API consists of:

- **Manifest files** — JSON listing available package versions and their per-system file manifests.
- **Artifact files** — compiled files (BEAM bytecode, NIFs, priv files) served by SHA256 hash.

## Base URL

`https://compatibility.nerves-project.org/`

Request and response shapes are also published as an OpenAPI 3 document at
`/api/openapi.json` (rendered at `/api/docs`). This document stays the
reference for what the fields mean and how a client matches and verifies them.

Serving the content-addressed paths through a CDN: see `docs/PRECOMPILED_CDN.md`.

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

Served with `cache-control: private, max-age=60`: the bytes change with
every batch, so shared caches must not keep them. `If-None-Match` with the
`etag` answers `304`. A `404` is `no-store`.

Status codes:

- `200` — manifest found
- `304` — `If-None-Match` names the current bytes
- `404` — package has no precompiled manifest

### GET /api/precompiled/v2/manifests/{package_name}.json

Manifest format 2: see "Manifest format 2" below for the shape and how a
client matches a build.

Served with `cache-control: private, max-age=60`: the bytes change with
every batch, so shared caches must not keep them. `If-None-Match` with the
`etag` answers `304`. A `404` is `no-store`.

Status codes:

- `200` — manifest found
- `304` — `If-None-Match` names the current bytes
- `404` — package has no build that format 2 can publish

### GET /api/precompiled/manifests/by-sha/{sha256}.json and /api/precompiled/v2/manifests/by-sha/{sha256}.json

The manifest bytes whose SHA256 a signed batch named, in `manifests` (first
path) or `manifests_v2` (second path). Content-addressed: the URL never
changes meaning, so the response is `cache-control: public,
max-age=31536000, immutable` with the quoted SHA256 as `etag` (`304` on
`If-None-Match`). Any sha a batch has named since these routes exist stays
servable, so a client holding an older (still fresh) batch can fetch what it
names; a sha named only by batches signed before then answers `404` (those
batches carry no `content`, so clients never ask for it by sha). A batch that
lists `content` origins (see `batch.json`) is the signal that these paths
exist, at the source and at each content origin; the reference client tries
each content origin, then the source's by-sha path, then the per-name path,
and keeps only bytes that hash to the batch entry.

Status codes:

- `200` — the manifest bytes
- `304` — `If-None-Match` names them
- `404` — malformed digest, no batch named it in this format, or the stored
  bytes no longer hash to it; `cache-control: no-store`

### GET /api/precompiled/systems/by-sha/{sha256}.json

The systems table bytes whose SHA256 a signed batch named in `systems` (see
`batch.json`): per Nerves system and release, the toolchain, OTP and shared
libraries a native target build is matched against on a release other than
its own. Content-addressed and cached like the by-sha manifests
(`immutable`, the quoted SHA256 as `etag`, `304` on `If-None-Match`), and
served at `<origin>/systems/by-sha/<sha256>.json` by each content origin
too. The `.json` suffix is required.

```json
{
  "format": 1,
  "systems": {
    "nerves_system_rpi4": {
      "2.2.2": {
        "toolchain": {"package": "nerves_toolchain_aarch64_nerves_linux_gnu",
                      "version": "15.3.1", "series": "15.3"},
        "otp": "28.1.2",
        "libs": {"libc.so.6": ["GLIBC_2.17", "...", "GLIBC_2.41"],
                 "libstdc++.so.6": ["GLIBCXX_3.4", "...", "CXXABI_1.3.15"],
                 "libssl.so.3": ["OPENSSL_3.0.0", "OPENSSL_3.2.0"]}
      }
    }
  }
}
```

- The bytes are canonical JSON: keys sorted at every level, no whitespace,
  so equal tables have equal hashes. A client refuses a body over 4 MiB.
- `format` is `1`; a client that gets another value ignores the table.
- One entry per release the portal knows:
  - A release a build ran on has `toolchain.version` from that build's lock,
    `series` its `major.minor`, its full `otp`, and `libs`: the shared
    libraries of its root filesystem (`lib` and `usr/lib`), each with the
    symbol versions it defines. `libs` lists only the sonames published
    builds of that system need, plus the toolchain's own libraries
    (`libc.so.6`, `libc.so`, `libm.so.6`, `libpthread.so.0`, `libdl.so.2`,
    `librt.so.1`, `libgcc_s.so.1`, `libstdc++.so.6`, `ld-linux-*`,
    `ld-musl-*`).
  - A release known only from Hex (newer than the oldest one built on) has
    the system's toolchain requirement instead: `toolchain.version` is
    `null`, `series` is `X.Y` for a `~> X.Y.Z` requirement and `null` for
    any other shape, and `otp` and `libs` are `null` until the portal reads
    the release itself.
- A new release changes this table and the batch, never a manifest.

Status codes:

- `200` — the table bytes
- `304` — `If-None-Match` names them
- `404` — malformed digest, no batch named it, or the stored bytes no
  longer hash to it; `cache-control: no-store`

### GET /api/precompiled/files/{sha256}

Returns artifact content by SHA256.

Example: `/api/precompiled/files/96b613f9050e8e3fba6639d9695a65386c699ccac6608d2e972f9e25a4fc81a7`

Response: binary file content with `content-type: application/octet-stream`.

Every file is served as a download, whatever its bytes: a package's priv files
are published too, and one can be HTML or SVG. The response carries
`content-disposition: attachment; filename="<sha256>"`,
`content-security-policy: default-src 'none'; sandbox` and
`x-content-type-options: nosniff`, so a browser never renders it from this
origin.

`cache-control: public, max-age=31536000, immutable` and an `etag` of the
quoted SHA256; `If-None-Match` with it answers `304`. A `404` carries
`cache-control: no-store`, so a cache in front never remembers that a file
was missing after it arrives.

Status codes:

- `200` — file found
- `304` — `If-None-Match` names the current bytes
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
- `304` — `If-None-Match` names the current bytes
- `404` — no root document is published

An `etag` header of the SHA256 of the envelope bytes is set, with
`cache-control: public, max-age=60, must-revalidate`. A request whose
`If-None-Match` names that tag is answered `304` with no body. The reference
client, [elixir_precompiled](https://github.com/TomHoenderdos/elixir_precompiled),
ships a copy of `root.json` as its trust anchor.

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
  },
  "content": ["https://cdn.example"],
  "systems": "5d1a..."
}
```

`manifests` names format-1 manifests and `manifests_v2` format-2 ones
(served at `/api/precompiled/v2/manifests/<package>.json`). `version` stays
`1`: format 2 is an added map, not a new batch format, so clients that only
know `manifests` keep verifying. A package can be in one map and not the
other: a run without a recorded toolchain, dependency lock or package checksum
is format 1 only, and a toolchain build is format 2 only. A batch signed before
format 2 has no `manifests_v2`; a client falls back to `manifests`.

`content`, when present, lists content origins: https URLs that serve this
API's content-addressed paths under their own prefix
(`<origin>/files/<sha256>`, `<origin>/manifests/by-sha/<sha256>.json`,
`<origin>/v2/manifests/by-sha/<sha256>.json`,
`<origin>/systems/by-sha/<sha256>.json`). It is signed with the rest of
the payload, so only the portal's key can add an origin. A client may fetch
those paths there first and must fall back to the source; everything is
checked against the hashes the batch and manifests name. Its presence also
says the source serves the by-sha paths. Absent when no origin is
configured. `version` stays `1`: like `manifests_v2`, it is an added field.

`systems`, when present, is the SHA256 of the systems table bytes, served at
`/api/precompiled/systems/by-sha/<sha256>.json` (and at each content
origin's `systems/by-sha/` path). It is rendered for every batch and absent
while the portal knows no release. Another added field: `version` stays `1`,
and a client that does not know it ignores it.

An `etag` header of the SHA256 of the envelope bytes (quoted, strong) is set,
with `cache-control: public, max-age=60, must-revalidate`. Send it back as
`If-None-Match` and an unchanged batch is answered `304` with no body; the
weak form `W/"<sha>"` matches too. Tags of the old form `"batch-<sequence>"`
no longer match and get the full batch once. A `503` carries
`cache-control: no-store`.

Status codes:

- `200` — a batch has been signed
- `304` — `If-None-Match` names the current bytes
- `503` — no batch available yet

### GET /api/precompiled/batches/{sequence}.json

Returns a past batch by its sequence number, in the same envelope shape as `batch.json`. Used to audit history, or to re-verify a manifest that was fetched against an older batch.

Same `etag`, `304` and `cache-control` as `batch.json`; a `404` carries
`cache-control: no-store`.

Status codes:

- `200` — batch found
- `304` — `If-None-Match` names the current bytes
- `404` — no batch with that sequence

## Response fields (format 1, kept for existing clients)

- `versions` — map of version strings to system data.
- `versions[version][system]` — file manifest for a specific version/system combination.
  - `ebin` — compiled BEAM files and app files.
  - `priv` — priv directory files such as NIFs/resources.
  - `build` — what the files were built with: `elixir`, `otp`, `system_version`,
    `run_id`, `image_digest`. A client should use an entry only when `elixir`
    and `otp` equal its own; `elixir` and `otp` are `null` for runs from before
    the toolchain was recorded. `image_digest` names the worker image the run
    ran in; for a remote build that is the image's platform digest for the
    builder's architecture, so x86_64 and arm64 builds of the same worker
    image name different digests. It identifies the run and is no
    compatibility condition.
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
      assume it is the same across a package's targets. In format 2, a target
      the pass kept them for also publishes its first build, made without
      them under the run's lock (the build the firmware image was made
      from), with its own files, `deps` and `compile_env`, in
      `versions[v].builds_closure` only (below): a client that checks the
      env closure takes it only where Mix compiles the package without the
      optional dependencies, while a device, which ranks an installed build
      first and never refuses one for an optional dependency it has, and a
      client before 0.7.0, which compares only the dependencies it locks,
      never see it. `builds` and format 1 list only the build with them. A
      target whose own lock was unusable lists no build of its own in either
      format, rather than one under the run's lock. A target can also list,
      in `builds_closure` only, a third build: the package compiled with the
      optional dependencies, at any depth of its closure, that a default
      `mix nerves.new` app has (the `nerves` world, for example muontrap and
      nerves_time for nerves_motd, or jason, which nerves 1.x brings in), when
      that closure differs from both other builds'. It carries no `variant`
      key; a client matches it by its `deps` like any other closure build.
    - `package_checksum` — the package's own outer Hex checksum from the
      build's `mix.lock`, a string, or `null` for runs from before it was
      recorded and for argus-only runs.
    - `compile_env` — the compile-time application config the files depend
      on, one item per `{app, path, value}` triple: `app` and the elements of
      `path` are strings, and `value` is `base64url(:erlang.term_to_binary({:ok, v} |
      :error, [:deterministic]))`. It lists the package's `.app` file
      `compile_env` reads and, for builds since 2026-11 whose compile was
      traced, the package's and its dependencies' compile-time config reads
      the builder records while they compile, with
      the value the build project's config gave for that key before any
      dependency was loaded (`:error`: unset). `null` for runs from before it
      was recorded or when the worker could not read the `.app` file; `[]`
      when there are no such reads. A value a dependency or the project's own
      `mix.exs` sets with `Application.put_env` while compiling is not seen:
      the item records the config value, so such a project may match a build
      compiled without its value. Every `value` is uncompressed ETF, at most
      65,536 bytes, containing no funs, pids, ports or references
      (`Compatibility.RecordedValue.acceptable?/1`, checked by a tag-level
      walk of the raw bytes, never `binary_to_term`, so acceptance never
      depends on which atoms happen to be loaded in whichever VM decides
      it): because a client's own match (`precompiled`'s
      `Match.recorded_equals?/2`) decodes a value with
      `:erlang.binary_to_term(bin, [:safe])`, which inflates compressed ETF
      before `:safe` runs and still admits a fun of an already-loaded
      module. A value that fails this check is handled differently
      depending on where it is caught:
      - during the worker's own compile-time trace (R5), it is one of the
        read's problems, and any problem forces that `pure_elixir`
        package's whole verdict to could-not-judge: no files are published
        for it at all, not merely a dropped `compile_env`;
      - read back from a built `.app` file, or re-checked at portal ingest
        against what the container's `result.json` reported, it drops the
        whole `compile_env` list to `null` for that build or system
        instead, the same as an unreadable `.app`: the files still publish,
        but rule 4 above means no client can ever match that entry, so
        every client falls back to building it from source.
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
  `null`. Such files are published only when the builder's compile-time trace
  and its native-code checks pass; a publication the trace later refuses on
  the same toolchain, because the package's own compile read the host or
  baked the build path into its beams, is withdrawn, and its files stop
  being served.
- Each file entry contains:
  - `path` — relative path within the package, e.g. `ebin/myapp.beam`. An
    entry is published only under the key its path names: `ebin/...` under
    `ebin`, `priv/...` under `priv`. A build whose stored manifest lists an
    entry under the other key is left out whole, as one with an unsafe path
    is, so a client never installs a `priv/` file as code or a beam as data.
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
            "elixir": "1.20.3", "otp": "29", "dep_env": "prod", "mix_target": "host",
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
          "build": {"elixir": "1.18.4", "otp": "27", "dep_env": "prod", "mix_target": "rpi4", "system_version": "2.2.1", "...": "..."}
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
- `build.mix_target` — the `MIX_TARGET` the files were compiled under: the
  Nerves system's target name (`nerves_system_rpi4` → `rpi4`) or `host` for
  `pure_elixir`. A client compares it with its own target only for a
  dependency that reads `Mix.target()` at compile time. Builds signed before
  2026-11 lack it; a client then assumes that same conventional name.
- `build.variant` — optional, informational, only on a build under
  `builds_closure`: the world it was built in, such as `"world_phx"` (see
  below), or `"pinned"` for a pinned build. A client matches the build by its
  `deps` and can ignore this key.
- `build.config_variant` — optional, informational: the config variant a
  toolchain build was compiled in (see below). Absent for the default build.
  A client matches a variant by its `compile_env` like any other build, and
  can ignore this key.
- `build.declared` — optional. Every dependency the package declares, as
  `{"app", "name", "requirement", "optional"}`, optional ones included whether
  or not the build resolved them. A client uses it to tell a build made
  without an optional dependency it has (that integration is off in the
  build) from one made with it. Absent on builds made before it was recorded,
  and on builds of a package that declares no dependencies; a client that
  does not know the field ignores it. Format 1 never carries it.
- `build.manager` — optional: the manager Mix built the package with
  (`mix`, `rebar3` or `make`), from the build's compile-time trace. A client
  skips, as a miss, a build whose `manager` differs from its own
  `Mix.Dep.manager` for that dependency, and any dependency the project
  gives `:manager`, `:compile` or `:system_env` options. Toolchain builds
  only; absent on builds made before it was recorded, and a client that
  does not know the field ignores it.
- `build.native`, `build.portable`, `build.otp_full`, `build.toolchain`,
  `build.elf` — optional, Nerves system builds only, each absent while
  unknown (builds made before they were recorded). Format 1 never carries
  them, and every other key keeps its meaning.
  - `native` — whether any `priv` file is ELF; `false` for a beam-only
    build, including one with an empty `priv`.
  - `portable` — `false` when an ELF file is neither a shared object
    (`ET_DYN`: NIFs, shared libraries, PIE executables) nor an executable
    (`ET_EXEC`: ports), such as a kernel module or an object file.
  - `otp_full` — the full OTP version of the system the build ran on, such
    as `"28.1.2"`.
  - `toolchain` — `{"package", "version"}`, the Nerves toolchain the build's
    lock resolved.
  - `elf` — native builds only: `{"needs": {soname: [version]}}`, every
    library the ELF files need (`DT_NEEDED`) and the symbol versions they
    need from it (`.gnu.version_r`), over all of the build's ELF files.
    `needs` leaves out the libraries the build ships itself: an ELF file of
    its own whose `DT_SONAME` or file name is the needed soname, such as
    `priv/lib/libfoo.so.1` loaded through a `$ORIGIN` RUNPATH.
- `updated_at` — the newest `finished_at` among the builds listed.

What it lists:

- Every build format 1 publishes, with `target` set to its format-1 key.
  Format 1 keeps only the newest per target; format 2 keeps each toolchain's.
- Toolchain builds: a pure-BEAM package version built on a plain Elixir/OTP
  image for `Mix.install` and non-Nerves projects, `target` `pure_elixir` and
  `system_version` `null`. Only passing, unrevoked builds whose files can all
  be served appear. A version is queued for one once the catalog has a
  passing host compile of it or a passing registry assessment
  (`registry_deps`, which compiled nothing), and the package records no
  native code; either way the toolchain build compiles it itself and is
  judged on that compile. Older releases of popular packages are queued too,
  without a catalog run of their own, once some version of the package has
  such a pass and it records no native code: the last 10 releases of the 100
  packages with the most hex.pm recent downloads, and the last 4 of the 500
  most downloaded (retired releases and pre-releases left out; the operator
  can change the four numbers). Each is judged on its own build like any
  other. A version is built once with every optional dependency a
  fresh lock would add (as for the `deps` of other entries), and, when that
  build added any, once more without them (also when the build with them was
  skipped, whatever the reason, since it may be one of them): two builds whose `deps` differ by those
  dependencies, so a project that locks them and one that does not each
  find theirs. A toolchain build's files include the package's `priv` when it
  is static data: regular files the package's own Hex tarball carries byte
  for byte and mode for mode (no setuid, setgid or sticky bit), at most 500
  files and 10 MiB in all, from a package with no native sources. Hex unpacks
  every entry with its tar mode, so an execute bit, or native code the
  tarball ships verbatim (since 2026-11-21), is what every user has; its
  `mode` is published as below. The builder judges this inside its container, and the
  portal judges it again on the host at ingest, with the same rules, against
  the tarball it fetches itself: its SHA-256 must be the outer checksum the
  signed Hex registry lists, which must also be the build's
  `package_checksum`, and each file must hash to its manifest `sha256`. A
  priv file the package's own compile wrote into its own build `priv` (such
  as the asset archives kino writes there) is published too, when the
  compile-time trace below shows it came from the package's own compile
  alone and a second traced build wrote it byte for byte the same, or, for
  a `.tar` or `.tar.gz`, the same but for its members' times and the gzip
  header's time and OS byte (judge revision 21; the first build's bytes are
  published). Such a file is never in the tarball: the tarball must not
  carry its path at all, it must not be native code (by name or by ELF,
  Mach-O, PE or `ar` magic), it may carry an execute bit only as a script
  (bytes that start with `#!`), it counts against the caps, and the build
  lists it in its `built_priv`, by its
  manifest path, so the portal checks it against that list rather than the
  tarball. A build that fails publishes none of its files, beams included.
  A package whose `priv` is anything else gets a `skipped` toolchain build.
  The builder also recompiles the package's dependency closure under a
  compile-time trace and skips any build whose compile read the build host
  (its OS, environment, programs or files outside the dependency closure),
  wrote anything outside its own `ebin` (its own `priv` aside, as above),
  baked the build path into code or into such a priv file, or
  depends on a package whose own compile did, and any build whose trace did
  not finish; its beams are the traced compile's. A package's own compile
  reading a file its own Hex tarball ships in its `priv` (rustler embedding
  its templates) reads no host, when the package's source tree is still
  exactly that tarball's after the compile (judge revision 23). Nor does a
  Mix alias of a package's own project copying one file its tarball ships
  onto another the tarball ships with the same bytes (phoenix copying its
  `core_components.ex.eex` template into `priv`) with `File.cp/3`, in the
  process Mix runs its tasks in and while Mix builds that package, when
  the two are two files and the package's source tree is still exactly
  that tarball's after the compile (judge revision 27). What the package does at
  runtime does not count: a package that runs programs, opens ports, looks
  up executables or reads the OS type when it runs is built and served like
  any other, since those calls run the same from a precompiled build. Native
  code and Nerves still do not: a package with native sources or build
  dependencies (a native build tool it names only as an optional dependency,
  such as rustler_precompiled's rustler, does not count: judge revision 15),
  a NIF or driver load, a target read, a `nerves` name or a
  mention of Nerves in its sources, or with a dependency whose sources read
  the target or mention Nerves, gets a `skipped` toolchain build. Its
  `compile_env` lists the config reads that trace observed, so a
  project whose config sets one of those keys differently compiles the
  package itself.
- A build whose `elixir`, `otp`, `deps`, `package_checksum` or `compile_env`
  is `null` is left out, since no client can match it (it stays in format 1).
- `build.defined_modules` (optional, S10, toolchain and pinned host builds since 2026-11-26): the
  modules the build's compile defined that its `ebin` does not hold (in memory: what the package's
  `mix.exs` defines or loads, a module created at compile time outside a compiled file), from the
  builder's trace, sorted. With the entry's `ebin` beams it is the package's exact module list,
  which a client 0.10.0 or later reads for a dependency outside a probe build's closure. Absent
  when it cannot be told (a module the trace cannot attribute) or before it was recorded.
- `build.compile_inputs` (optional) lists what the build's compile read that a client checks on its
  own side (builds since 2026-11; absent before):
  - `{"kind": "env", "name", "value", "set_by": "host"}`: an environment variable, `value` being
    `base64url(:erlang.term_to_binary(:error | {:ok, binary}, [:deterministic]))` or
    `"unrecordable"`;
  - `{"kind": "env", "name", "value", "set_by": "build", "inputs": "recorded" | "unknown"}`: a
    variable the build set itself before reading it;
  - `{"kind": "env_all"}`: the whole environment was read;
  - `{"kind": "config_unrecorded"}`: the config reads were not all recorded;
  - `{"kind": "config_order", "app", "path": [key], "reader", "default", "seen"}`: the compile of
    `reader` read the unset key outside its own dependency tree, so whether it saw `app`'s `.app`
    default depends on the consumer's compile order. `default` is that `.app` env default at the
    locked version (`:error` when it declares none), `seen` what the read returned, both recorded
    like `value` or `"unrecordable"`;
  - `{"kind": "platform_define", "regex": <string>, "matched": <boolean>}` (judge revision 9 and
    later): a rebar3 `platform_define` in the closure (the package's or a dependency's) whose regex
    the OTP major alone does not decide, such as hackney's `"R14"`. `regex` is the regex string
    rebar3 hands `re:run/3`, as written in `rebar.config` with its escapes resolved (ASCII only,
    1 to 1024 bytes), and `matched` whether
    `re:run(Arch, Regex, [{capture, none}])` matched on the builder, `Arch` being
    `rebar_utils:get_arch/0`'s `<OTP version>-<system_architecture>-<wordsize in bits>`: the OTP
    version is the contents of `<code:root_dir()>/releases/<otp_release>/OTP_VERSION` cut before
    the first `**` when it has one, otherwise with every trailing `\n` trimmed (rebar3 3.22 to
    3.28, `rebar_utils:otp_release1/1`), or the major alone when that file cannot be read; the wordsize is `8 * erlang:system_info({wordsize, external})`. Each distinct regex is
    listed once. A regex the builder's `re` cannot compile, or one that is not ASCII, is recorded as
    `config_unrecorded` instead. A regex the OTP major does decide is not listed, as before.
  - `{"kind": "endian", "value": "little" | "big"}` (judge revision 13 and later): the closure
    read the byte order at compile time (`:erlang.system_info(:endian)`, `System.endianness/0`),
    such as nx choosing its float layouts. `value` is the byte order the build's compile ran with.
    Listed once, however many reads there were.
  - `{"kind": "os_type", "family": "unix" | "win32", "name": "linux" | ...}` (judge revision 17
    and later): the closure read the OS type at compile time (`:os.type/0`), such as kino's
    `Kino.JS` hook clearing its asset dir with `File.rm_rf!/1`. `family` and `name` are the
    build's `:os.type/0`. `name` is left out when every read was one only the family can reach
    (Elixir's own `File.rm_rf/1`). Listed once, however many reads there were.
  - `{"kind": "env", "name", "set_by": "nerves", "value": [segments]}` (judge revision 19 and
    later, firmware builds only): the compile read a variable whose value holds where the Nerves
    toolchain or system sits on the builder, such as circuits_i2c's `mix.exs` reading
    `CROSSCOMPILE`. `value` is that value cut at every occurrence of the builder's
    `NERVES_TOOLCHAIN` and `NERVES_SYSTEM` paths, leftmost first and, of two that start at the same
    byte, the longer: each cut is `{"root": "NERVES_TOOLCHAIN" | "NERVES_SYSTEM"}` and the text
    between cuts a non-empty string, never two strings in a row, at least one cut. The published
    files never hold either path (the firmware build-root rule withholds them).
  - `{"kind": "mix_target", "value": <target>}` (judge revision 19 and later, firmware builds
    only): the compile read `Mix.target/0`; `value` is the `MIX_TARGET` it was built for.
  - `{"kind": "config_all", "app", "entries": [{"key", "value"}]}` (builds since 2026-11-21): the
    closure read `app`'s whole env at compile time (`Application.get_all_env/1`, tz's
    `Tz.CompilerRunner`), from a reader that reads its own application, one in its dependency
    tree or one Mix preloads. `entries` are every key the builder's project config set for `app`
    when the compile started, sorted by key, each once, each `value` recorded like an `env`
    item's (`{:ok, value}`) or `"unrecordable"`; at most 128. An empty list is an app the config
    leaves alone. Listed once per app. A read the snapshot cannot give whole is
    `config_unrecorded` instead.
  - `{"kind": "probe", "of": "module", "name", "answer": "absent", "definers": [name]}` (S10, builds
    since 2026-11-22): the closure asked at compile time whether the module `name` is there
    (`Code.ensure_loaded?(Poison)`, `function_exported?/3`, `:code.which/1`), as its atom renders
    (`Elixir.Poison`, `cowboy_websocket`), and nothing in the build defines it. `definers` are the
    Hex package and application names known to define it, sorted, each once, at most 64: the
    declared packages the judge found, and every package with 1,000 or more recent downloads the
    portal's module index shows (`Portal.Catalog.ModuleIndex.settle_inputs/1`, at ingest; a build
    with such an item is refused while the index is not complete, and a served one whose item misses
    a definer the index later shows is withheld by the index's recheck).
  - `{"kind": "probe", "of": "app", "name", "answer": "absent"}`: the same for an application
    (`Application.spec/1,2`, `Application.load/1`, `:code.where_is_file/1` of its `.app`) that is no
    package of the build.
  - `{"kind": "probe", "of": "otp_app", "name", "answer": "absent"}`: the same for an installed OTP
    application that no closure application lists, by module or as an application (vega_lite's
    `Code.ensure_loaded?(:wx)`): the builder's pruned code path never held it. Listed once per
    question, at most 64 probe items, else `config_unrecorded`. A firmware build never carries one.

  A firmware build (`target` a Nerves system) carries `compile_inputs` only when the worker's
  traced compile of the package's closure for the target recorded every input
  (`NccWorker.FirmwareInputs`): for a package whose own `lib/` reads the environment at module
  level, and for any package the firmware judge passed. Its `compile_env` then lists that trace's
  config reads after the `.app`'s own. Such a build's published variants carry none.

  A firmware build without `compile_inputs` (its compile was not traced, or the trace did not
  pass) lists more `compile_env` items, unless it lists them already, each with the value the
  builder's Mix VM read (`Application.fetch_env/2`), which a project that leaves the key alone reads
  too. On Elixir 1.17 to 1.20, Logger's `[compile_time_purge_matching]` (`{:ok, []}`),
  `[always_evaluate_messages]` (`{:ok, false}`) and `[compile_time_purge_level]` (`:error`): every
  `Logger` macro reads them while its caller compiles, and no `.app` lists them. Then every config
  key the package's own code read at compile time in a toolchain build of the same version (an item
  of its `compile_env` whose read the trace names the package as the owner of, by its Hex or app
  name): a key of `elixir`, `logger`, `mix`, `iex` or `ex_unit` with the value that build recorded
  on the same Elixir minor (left out when none did, or two disagree), a key of any other app unset,
  except `nerves`, which the builder's firmware project configures. So does each of its published
  variants. A version with no such toolchain build lists Logger's keys only.

  A `compile_env` value may also be `"unrecordable"`, which matches no config. A list the portal
  rejects as malformed is stored as `[{"kind": "config_unrecorded"}]` with the build's `compile_env`
  dropped, so neither format lists that build.
- A build with any input to check (anything but `set_by: "build"` with `inputs: "recorded"`) is
  listed under `versions[v].builds_with_inputs`, never under `builds`, and never in format 1. Every
  version keeps a `builds` list, possibly empty. Clients before 0.6.0 read `builds` alone: they
  do not know `compile_inputs`, so they would use such a build without comparing its environment
  or config reads, and to them it does not exist. They also refuse the whole manifest when a
  version has no `builds` key, which is why it is never left out.
- `versions[v].builds_closure` also lists pinned builds (`"variant": "pinned"`): the package
  compiled against exactly one closure from a project's `mix.lock`, whose `deps` is the lock Mix
  resolved, checked equal to that closure before it is stored; at most 8 closures per version,
  target and system version are listed, and format 1 never lists one. A pinned firmware build (a
  `nerves_system_*` target) was made on the project's exact system release and carries neither
  `portable` nor `native: false`, so a client takes it at that `system_version` only, unless the
  firmware judge passed it with its `compile_inputs` recorded: its trace ran with the Nerves
  toolchain and system at other paths and artifact names and its beams bound to the published
  ones, so it carries a system result's `native` and `portable` facts and a client applies the same
  release rules.
- `versions[v].builds_closure` — world builds, read only by clients 0.7.0 and later, which
  enforce env-closure equality: a build is taken only when the names in its whole `deps` closure
  equal the closure Mix gives the package in the project's env. A world is a named, pinned set of
  Hex package names a common application has in its prod env; `phx` is the prod set of a
  `mix phx.new` 1.8.16 app. A world build of a package is made in a plain project to which the
  builder adds, at every depth of the package's closure, each optional dependency that is a
  member of the world, until nothing changes. Its `deps` is then the closure such an app gives
  the package (jason with decimal, phoenix with bandit and jason). It carries an informational
  `build.variant` (`"world_phx"`), and is otherwise listed, picked and matched like any other
  toolchain build, its config variants included; the `builds_with_inputs` split does not apply
  to it, since its readers check `compile_inputs` anyway. The key is absent when a version has
  no world build, so a package without one renders the bytes it did before; a version with only
  world builds still has `"builds": []`. The same list also holds a firmware target's build
  without the package's optional dependencies (see `deps` above), which carries no
  `build.variant`. A world build is never listed in `builds`,
  `builds_with_inputs` or format 1: a client before 0.7.0 compares only the dependencies it
  locks, so it would take one in a project that has, say, `decimal` only in `:test`, where Mix
  compiles the package against a closure without it. A world build whose `deps` came out equal
  to the version's build with or without its optional dependencies is not listed at all.
- `versions[v].builds_host_native` — host-native builds (board #85): a NIF package built on a
  toolchain image for one glibc Linux triple, `target: "host_native"`, read only by a client
  whose project opted in (`config :precompiled, host_native: true`, clients after 0.7.1) on a
  host that is not a Nerves target. Listed only while the portal's `host_native_enabled` setting
  is on; absent otherwise, and absent when a version has none (a version with only host-native
  builds keeps `"builds": []`). Besides the toolchain build fields, `build` carries `triple`
  (`x86_64-linux-gnu` or `aarch64-linux-gnu`), `libc` (`"glibc"`), `otp_full`, `nif_version`,
  `native: true`, `elf.needs` (every soname the priv ELF files need and the symbol versions they
  need from it, read by the portal from the stored files) and `origins`: for a package that
  downloads its NIF at compile time (rustler_precompiled, elixir_make's precompilers), each priv
  ELF file's `path`, the package's own `checksum_file`, the upstream `archive` it is a member of
  and that archive's `archive_sha256`, which both the worker and the portal verified against
  that checksum file in the package's Hex tarball. A package that compiled its own NIF in the build
  is not served: nothing checks the CPU features its build flags assumed of the builder.
  It is built without the package's optional dependencies (`deps` holds none of them).
  One per version, triple, toolchain and `deps`, the newest. A client takes one only when the
  host's normalised triple equals `triple`, its libc is glibc, the OTP major is equal and
  `otp_full` no newer than the host's (`toolchain_otp`, `toolchain_otp_minor`), `nif_version` is
  no newer than the host's (`nif_version_newer`), every soname in `elf.needs` resolves on the
  host and defines every needed version (`needed_lib_missing`, `symbol_version_missing`), every
  origin's archive is listed with that sum in its own `deps/<package>/<checksum_file>`
  (`origin_unverified`), and every rule any other build has passes (lock checksum, closure,
  `compile_env`, `compile_inputs`). Another triple or libc misses as `triple_differs`. Before it
  installs one, the client reads every staged priv ELF file back: a 64-bit library of the host's
  machine that an origin names, or it is not installed. The build
  is ABI-compatible with what the host would compile, not byte-identical to it.
- `versions[v].deterministic` — deterministic siblings: toolchain, pinned and firmware target builds
  compiled again, in the same run and on the same toolchain and lock, with
  `ERL_COMPILER_OPTIONS=deterministic`, read only by a
  client whose project's `ERL_COMPILER_OPTIONS` parses (as `compile:env_default_opts/0` parses it) to
  exactly `[deterministic]` (clients after 0.7.2), which then reads this object **in place of** the
  version's other lists and never takes a build from those. It is an object of the same lists as the
  version itself, `builds` (always present), `builds_with_inputs` and `builds_closure`, each holding
  the siblings of the builds the version lists there, split, picked (newest per key) and matched by
  the same rules. A sibling is its toolchain build's entry (the same `build` fields: `deps`,
  `compile_env`, `compile_inputs`, `run_id`, ...) with its own `ebin` and `priv` and
  `build.erl_compiler_options: ["deterministic"]`. Listed only while the portal's
  `deterministic_builds_enabled` setting is on, only beside its toolchain build while that build is
  served (so every lever that withdraws a toolchain build withdraws its sibling, and
  `Portal.Precompiled.DeterministicRevocation` withdraws a sibling alone), and only when every file
  it lists is held; absent otherwise, so a version without siblings renders the bytes it always did,
  and a version with siblings alone keeps `"builds": []`. A client before this never reads it, and
  takes no build carrying `erl_compiler_options` anyway: a deterministic build in a project without
  the option would differ from the project's own compile (`module_info(:compile)` has no `options`
  or `source`).

  The builder (`NccWorker.Deterministic`, judge revision 29) builds a sibling only after its build
  passed and when the build's own compile neither read nor set `ERL_COMPILER_OPTIONS`. It is a real
  compile of the package's whole closure with the option, in its own traced VM at its own build
  path, judged by every rule the build was judged by on the lock and source-tree snapshots the build
  was judged on, so its Erlang modules carry what the option changes there (`?FILE` and the line
  table's file names become the source's base name, which changes their literals and md5). It is
  kept only when it is the build but for what the option changes: the same lock, checksum,
  declared dependencies, manager, `compile_env`, `compile_inputs` and own-priv list, the same
  `priv` bytes, every beam compiled with the option (`CInf` without `options` and `source`), each
  Elixir module's code and md5 its build's (only `CInf`, `Dbgi`, `Docs` and `ExCk` differ) and each
  Erlang module's changes confined to `CInf`, `Dbgi`, `Docs`, `Line`, `LitT`, `Attr` and its funs'
  `old_uniq` in `FunT`, which the compiler takes from the module's md5
  (`Compatibility.DeterministicBeams`). The portal checks all of it again at ingest on the blobs it
  stores (`Portal.Deterministic.Ingest`), its `priv` as for the build. Host-native builds have no
  siblings.

  A firmware target's build (a run's target, and a pinned firmware build's one target) has a
  sibling too, its entry its build's (the same `target`, `system_version`, `deps`, ABI facts,
  `compile_inputs`, `run_id`, ...) with its own files and `erl_compiler_options`, in the
  `deterministic` list its build is in (a pinned firmware build's in `builds_closure`). It is served
  only beside that build while the build is served and is the one the version lists for its key:
  the result neither withdrawn (`Portal.Precompiled.FirmwareRefusal`,
  `Portal.Precompiled.FirmwareBuildPathWithdrawal`) nor withheld, of an unrevoked run whose builder
  publishes, and its own build the entry `builds` or `builds_with_inputs` picked. A newer run of
  the same key that brought no sibling withdraws the older one's, as a toolchain rebuild does; a
  carried copy of a result has none. The builder (`NccWorker.FirmwareDeterministic`) compiles the
  package alone for the target with the option, in the target's build env and build tree over the
  closure its firmware build compiled without it. A dependency's own beams therefore keep what the
  option would change in them (compile metadata and, for an Erlang dependency, its source paths,
  md5 and default `vsn`); the package can embed any of that only through dependency code it runs at
  compile time. In practice that is a bare dependency source path, which every published build may
  already hold; a package that embedded a dependency's md5, `vsn` or compile info would differ too,
  and none is known. A toolchain build's sibling compiles the whole closure with the option instead. It
  keeps the sibling only when the target passed and publishes its own build
  (R2 did not withhold it), the build was made against the run's lock and the optional pass did not
  touch the target (a target that kept its optional dependencies, or that the pass tried and dropped,
  leaving the closure's builds rebuilt with them, gets none), its recorded `compile_inputs` read neither
  `ERL_COMPILER_OPTIONS` nor the whole environment, and the sibling lists the build's `ebin` and
  `priv` paths and modes, has its `priv` bytes, passes the same `ebin` comparison, and passes R2 on
  its own beams. The portal checks the closure, paths, priv bytes, beams and R2 outcome again at
  ingest (`Portal.Deterministic.Ingest.firmware_candidate/3`).
- `build.erl_compiler_options` — only on a build under `versions[v].deterministic`:
  `["deterministic"]`, the `ERL_COMPILER_OPTIONS` it was compiled with.
- `versions[v].foreign_priv` — foreign priv builds: toolchain and pinned toolchain builds of a
  package whose compile wrote Kino.JS asset archives into kino's build `priv` (each module's
  `__before_compile__/1` packs its assets into `<kino priv>/assets/<Module_Name>/<hash>.tar.gz`),
  let through by the reviewed rule `kino_js_v1` (kino 0.19.1's `lib/kino/js.ex`), and kino's own
  builds. Read only by clients 0.8.0 and later, after the version's other lists missed; no client
  up to 0.7.3 reads this key at the version level or inside `deterministic`, so to them a writer
  whose only builds are here shows `MISS not built`. It is an object of the same lists as the
  version itself, `builds` (always present), `builds_with_inputs` and `builds_closure`, split,
  picked (newest per key) and matched by the same rules, and it is never in format 1. A writer's
  entry is its build's usual entry plus `foreign_priv`, the archives to place, each
  `{"app": "kino", "path": "priv/assets/<d>/<h>.tar.gz", "sha256", "size", "mode": 33188}` with the
  path relative to kino's build dir and the file fetched from `/api/precompiled/files/{sha256}`, and
  `build.foreign_priv_rule: "kino_js_v1"`. A build of kino itself carries
  `build.foreign_priv_target: "kino"` and no `foreign_priv`, and is listed only here, its toolchain
  builds and its run results alike: kino has no format-1 manifest at all (`manifests` in a batch
  never names it), and none of its builds is in a version's other lists. A client before 0.8.0
  replaces an installed kino whole and loses every writer's archives in it.
  `versions[v].deterministic.foreign_priv` holds the siblings of foreign builds the same way, each
  with its own archives (its compile stamped other tar times; the portal checked that it holds the
  same members). Listed only while the portal's `foreign_priv_enabled` setting is on, and only when
  every file the entry lists, foreign ones included, is held; absent otherwise. While it is off,
  kino's own builds are listed nowhere, in neither format, so kino has no manifest; a version with
  no foreign build renders the bytes it did before. The worker accepts exactly the reviewed Kino.JS calls into kino's `priv/assets/<d>` for
  `d` one of the writer's own modules, proves each archive against the writer's beam (its
  `__assets_info__/0` hash and `assets_path`) and its Hex tarball's files
  (`Compatibility.KinoAssets`), and refuses any read of kino's archives during the compile; the
  portal proves each again at ingest against the tarballs it fetched itself
  (`Portal.Catalog.ToolchainForeignPriv`). Example:

  ```json
  "0.1.13": {
    "builds": [],
    "foreign_priv": {
      "builds": [],
      "builds_with_inputs": [
        {
          "target": "pure_elixir",
          "ebin": [{"path": "ebin/Elixir.Kino.VegaLite.beam", "sha256": "...", "size": 1234, "mode": 33188}],
          "priv": [],
          "foreign_priv": [
            {"app": "kino", "path": "priv/assets/Kino_VegaLite/uxwh53kfq2wszgf23hqwgkuiza.tar.gz",
             "sha256": "...", "size": 51234, "mode": 33188}
          ],
          "build": {"elixir": "1.20.3", "otp": "29", "deps": {"kino": {"version": "0.19.1", "checksum": "..."}},
                    "compile_inputs": [{"kind": "os_type", "family": "unix"}], "foreign_priv_rule": "kino_js_v1",
                    "...": "..."}
        }
      ]
    }
  }
  ```
- `build.foreign_priv_rule`, `build.foreign_priv_target` — only on a build under a
  `foreign_priv` object (above).
- `versions[v].relocated` — relocated builds: toolchain builds whose own beams hold the deps or
  build path of the compile that made them (a `__DIR__` or `Path.expand/1` literal, an Erlang
  `?FILE`, a path into the build's `priv`), each listed with `relocation`, the record of every
  such occurrence, which the client rewrites to its project's own paths at install; and builds of
  a dependent that passed only because a dependency in its closure was relocated, whose record
  names the same three roots and lists the occurrences in its own beams, often none. Read only by
  clients 0.9.0 and later, after the version's other lists (and its `foreign_priv` object)
  missed; no client up to 0.8.x reads this key, so to them a package whose only builds are here
  shows `MISS not built`. It is an object of the same lists as the version itself, `builds`
  (always present), `builds_with_inputs` and `builds_closure`, split, picked (newest per key) and
  matched by the same rules, and it is never in format 1, in a version's other lists, in
  `deterministic` (a relocated build has no sibling) or in `foreign_priv`. An entry is its
  toolchain build's usual entry, its `ebin` files the served bytes and their `sha256`, plus
  `relocation`:

  ```json
  "relocation": {
    "deps": "/work/proj/deps",
    "build": "/work/proj/_build/host",
    "second": {"deps": "/home/ncc-relocate/.cache/mix/installs/.../ncc-relocate-<n>/.../app/deps",
               "build": "/home/ncc-relocate/.cache/mix/installs/.../ncc-relocate-<n>/.../app/out.d/host-1"},
    "third": {"deps": "/Users/Ncc-Relocate <n>/Library/Mobile Documents/.../Deps vendored_d",
              "build": "/Users/Ncc-Relocate <n>/Library/Mobile Documents/.../Build-3/Host 4"},
    "files": [
      {"path": "ebin/Elixir.Fine.beam",
       "occurrences": [{"chunk": "LitT", "index": 3, "term": [], "kind": "binary",
                        "parts": ["", "deps", "/fine/c_include"]}]}
    ]
  }
  ```

  `deps` and `build` are the first compile's `Mix.Project.deps_path/0` and `build_path/0`, the
  worker's `/work/proj/deps` and `/work/proj/_build/host`; `second` the second compile's, under
  `/home/ncc-relocate/.cache/mix/installs` (`Compatibility.Relocation.second_layout/2`; under
  `/home/` but outside the container's `HOME`, which is one of the roots R2 searches), and
  `third` the third compile's, under `/Users` (`third_layout/2`), both of run token `<n>`. The
  portal stores no record whose roots are not these (`pinned_problem/1`), and client 0.9.0 holds
  every record to the same layout, copied into its own source. The layout is therefore frozen:
  every released 0.9.x client refuses a record at any other roots, so a portal that changes it
  must publish such records under a new record version (another key than `relocation`) that a
  newer client reads, and keep this one as it is. `make test-relocate-e2e` installs a record at
  these roots with the client, so a drift between the two copies fails there. Each file is a beam
  of the entry's
  `ebin`, and each occurrence names its chunk (`LitT`, `AtU8`, `Attr`, `Line`), the literal's
  index from 0, the atom's from 1 or the line table's file name's from 0, the path to the value
  inside the term (element indices of tuples and lists, a proper list's tail at its length, a map
  value's index among the map's keys in term order), its kind (`binary`, `charlist`, `atom`) and
  the value as a template, text and slot names (`deps`, `build`) in turn, the text UTF-8 and each
  value at most 4 KiB; the text after a `build` slot is Mix's own layout under a build path:
  empty, `/consolidated/...`, or `/lib/<app>/` and then `ebin`, `priv`, `include` or `.mix`,
  `<app>` an app of the build's closure (its lock's keys or its own `.app`). `files` may be empty: a dependent's build
  whose own beams need no rewrite. A record over 256 KiB of JSON is refused. Every beam of the
  entry's `ebin` was compiled from the package's dir under `deps` (`<deps>/<app>/`, `<app>` the
  entry's `.app` file's name): the portal reads each beam's `CInf` `source` at ingest
  (`Compatibility.Relocation.compiled_in_problem/3`, without making an atom) and stores a build
  that fails it as a `fail` with no files.

  The builder (`NccWorker.Portability.Relocate`) builds the package again at two more roots, for
  every build it held, a dependent's too. The three differ in length and depth,
  case, spaces, project dir name and the order of the deps and build paths, and hold between
  them the words user paths hold: a home's `.cache/mix/installs`, `/Users/`, `Library`,
  `Projects`, `projects`, `src`, `code`, `app`, `nix/store`, a dot-dir, `@` and `~`. It keeps the
  build only when, at each extra root, each held app's beams, and the package's own whether it
  was held or not, relocated to that root's paths are that build's chunk for chunk but `CInf`,
  `Dbgi` and `Docs` (`Compatibility.Relocation.prove_ebin/4`), and every closure app's source and
  build dirs list the same files as the first build's (a native build tool that split a path at
  a space and put its output elsewhere refuses, so such a build never passes with a missing
  file). A path in a built binary, a hashed, measured or sliced one, one in a map key, a protocol
  that holds one, a value a dependent took from a held app (its md5 too) and anything else the
  rewrite would not reproduce refuse. A dependent's call into a held module, its read of that
  module's beam, md5, attributes or compile info, taints it.

  The residual, what the three roots cannot show: a compile-time test of the path against a
  constant that none of the three roots contains (a prefix such as `/opt/` or `/srv/`, a word no
  root holds), or any test that answers the same at all three roots and differently at the
  user's path. For a dependent's build, that path is its relocated dependency's, and the test
  sits in the dependency's code or the dependent's. The client relocates only to paths inside the
  envelope the three roots span (below), which bounds tests of a path's length, depth and
  characters, not tests of which words it holds. Today R2 refuses every build whose beams hold
  the path, and R3 every dependent of one, so this residual is new exposure, for these builds
  only. `Dbgi` keeps the first build's paths: a tool that compiles
  a module again from its debug info (`:cover` on a dependency, the debugger) sees them, as in
  every served build.

  Two portal settings, both off by default and both on the admin Maintenance page, so turning
  either on is a setting, not a deploy: `relocate_builds_enabled` sends `judge.relocate` to the
  worker (`Portal.Builder` then also binds per-run scratch dirs at `/home/ncc-relocate` and
  `/Users`, which both worker images pre-create, for the other two roots), but only for a job
  whose image carries the label `ncc.relocate=1` (a job on an older image builds without
  relocation, the setting notwithstanding) and never for a pinned build, which ingest would store
  as a skip; and
  `relocated_enabled` serves what such builds made. Every toolchain row's
  `compile_observations.trace_stats.relocate` says how it was judged: `"off"`, `"on"` (nothing
  held), `"relocated"`, `"dependencies"` or `"refused: <why>"`. With `relocate_builds_enabled` on
  and `relocated_enabled` off, no row it makes reaches any client. The portal stores a relocated build's
  files in its own `relocated_file_manifest` column, with `file_manifest` nil, and the worker
  writes `toolchain_build.relocated_file_manifest` with `file_manifest` nil: a portal before S4
  reads `file_manifest` alone, so it lists, serves and keeps as an earlier build nothing of a
  relocated build (and its backlog builds such a pass with no files again once it is due).
  Listed only while `relocated_enabled` is on, and only when every file the entry lists is held;
  absent otherwise, so a version without relocated builds renders the bytes it always did. The
  files of a relocated build are served only while the setting is on, and its own package's name
  on the withheld list withholds it whatever it records. The coverage numbers on `/admin` count a
  relocated pass apart, not as served.

  A client takes one only on OTP 28 or later (`relocated_otp`), on a unix host whose file names
  are UTF-8, when its project's deps path and build path are absolute, normalised and real all
  the way down, no symlink in either (`relocated_paths`), printable ASCII
  (`relocated_path_ascii`), every component spelled exactly as its parent dir lists it, with no
  case folding or Unicode normalisation (`relocated_path_spelling`), and each inside the envelope
  of the record's three roots for its slot: its characters among theirs, its length and depth
  between their least and greatest (`relocated_path_envelope`). It refuses (`relocation_refused`)
  a record whose three roots are not the builder's own layout, or whose `build` slot is followed by
  anything but Mix's layout under a closure app. After staging and verifying the served files it requires every
  beam's `CInf` `source` to lie in the package's dir under the record's `deps` path, derives every
  beam's occurrences of the record's paths itself (each `build` slot again followed by Mix's
  layout) and requires them to be exactly
  the record's (none for a beam it does not name), requires every other file of the entry to hold
  no such path, and rewrites each occurrence to its own paths as its own compile would have
  written it: a changed literal is `term_to_binary(term, [{:minor_version, 2}, :deterministic])`
  in its own VM, an atom or line-table file name is rewritten in place, the module's md5 is
  `beam_lib:md5/1` of the rewritten beam (the running OTP's chunk list; OTP 29 adds `Recs` and
  `DbgB`), every fun's `old_uniq` is its first 27 bits and a default `vsn` (the old md5) becomes
  the new one. It refuses (`relocation_refused`) a record that does not match the served beams,
  a served beam whose funs' `old_uniq` is not its md5's, two literals, atoms or file names that
  would become one, an atom over 255 code points or, in a short atom table, over 255 bytes, a
  rewrite of atom 1 (the module's name), and any of the record's paths left in any chunk but
  `CInf`, `Dbgi` and `Docs`; a refusal at install, after the fetch, reports as
  `relocation_refused` too. A relocation record in any other list, or on a device, is a malformed
  entry. A record with no files installs the served beams as they are, after the same checks. The
  relocated files' hashes go into the install's provenance with the paths they were
  relocated to, so a later run keeps the install while those paths are the project's and installs
  it again, relocated anew, once they are not (a moved project).
- One build per target, toolchain (`"<elixir minor>/<otp>"`),
  `system_version`, `deps` and config variant: the newest wins. A toolchain
  build with and one without the package's optional dependencies differ in
  `deps`, so both are listed. A toolchain build whose compile read LiveView's
  compile-time config is also made in up to three config variants
  (`phx_prod`, `phx_test`, `phx_dev`: the Phoenix and LiveView config a
  `mix phx.new` app sets in each env), each listed with an informational
  `build.config_variant`. Their `compile_env` lists the values their own
  compile read, so at most one of them matches a project; a client needs no
  rule for them. Two versions of one Nerves
  system are two builds: a client prefers the build made on its own system
  version (see below). A toolchain build rebuilt because a dependency
  released a newer version (the portal's closure-drift rebuilds) keeps the
  build it replaced listed, up to three earlier `deps` per build: a project
  still locked at the older dependency matches that one, a fresh project the
  new one. A client needs no rule for them either.

### Matching a format-2 build to a project

The client checks each build in this order, and reports the first rule a
build fails as the reason it was not used:

1. **Target** — `target` is `pure_elixir`, or equals the project's Nerves
   system with `build.system_version` equal to the system's version, or one
   that may be used on the project's release (below).
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
   matter. A client that cannot read the package's `mix.exs` (one installing
   without Mix, for example) takes the list from `build.declared`; a build
   without it gives no list, so such a client treats every dependency in its
   lock as one the package may declare.
9. **compile_env** — `build.compile_env` is present, and every `build.compile_env` item decodes to the value the
   project's config gives for that app and path.
10. **compile_inputs** (clients 0.6.0 and later; they read `builds` and `builds_with_inputs`, and
    0.7.0 and later on a Mix project also `builds_closure`) —
    every item holds:
    - an `env` item with `set_by: "host"` decodes to what the project's environment gives for
      `name` (`:error` when unset, `{:ok, value}`), else `env_differs`;
    - `set_by: "build"` with `inputs: "recorded"` is not compared, with `"unknown"` it is
      `env_differs`;
    - `env_all` and `config_unrecorded` never match;
    - a `config_order` item holds when the client's prediction equals `seen`: the project's config
      for the key when set, otherwise `default` when `app` compiles (and loads) before `reader` in
      the project's `mix deps.compile` order, otherwise `:error`. Else `config_order_differs`;
    - a `platform_define` item holds when the client, computing its own arch string the way
      rebar3 does (above) under the OTP it would compile with, gets the same `matched` for
      `regex`. Else `platform_define_differs`, with the regex as its argument. A client that
      cannot compute the arch string treats the item as differing;
    - an `endian` item holds when `value` is the client's own `System.endianness/0`, else
      `endian_differs`, with the build's and the client's byte order as its arguments. A client
      that does not know the kind treats the item as malformed: a miss;
    - an `os_type` item holds when `family` is the first element of the client's own
      `:os.type/0` and, when the item has `name`, `name` is the second. Else `os_type_differs`,
      with the build's and the client's OS type (`unix:linux`, or the family alone for an item
      without `name`) as its arguments. A client that does not know the kind treats the item as
      malformed: a miss;
    - a `set_by: "nerves"` `env` item holds when the project's environment sets `name` and its
      value, cut the same way at the project's own `NERVES_TOOLCHAIN` and `NERVES_SYSTEM`, is
      `value`; else `env_differs`;
    - a `mix_target` item holds when `value` is the target Mix compiles for, else `rule8_target`,
      with the build's and the project's target as its arguments;
    - a `config_all` item (clients 0.9.0 and later) holds when `app`'s env in the project, read
      before any dependency compiles, has exactly the keys of `entries` with the values they
      decode to: an app not loaded yet holds its config alone; a loaded one is compared only when
      its `.app` declares no env, else the item differs. So an item for an app Mix loads before
      every compile (`elixir`, `mix`, `ex_unit`, `iex`, `logger`), each of whose `.app` declares
      env, never holds: such a build is listed but no client takes it. Else `config_all_differs`, with `app` as
      its argument. A client that does not know the kind treats the item as malformed: a miss;
    - a `probe` item (clients 0.10.0 and later) holds when nothing in the project can supply what
      the build's closure asked for, as the builder could not. For a module: no dependency the
      project's Mix loads in its env and target (every `mix.lock` entry when the dependencies did
      not load), by app or Hex package name, is in `definers`; the module is in the exact module
      list of no such dependency outside the build's `deps` (and not the package itself); and the
      client's code path holds no `<name>.beam` and its VM has no such module loaded. A
      dependency's exact module list is that of its own served build that matches the project
      by every rule here (the build's probe items left unread: such a build gives no list): the
      beams of its `ebin` and its `build.defined_modules`. A dependency Mix loads that is no Hex
      dependency (path or git, or a closure dependency switched to one with `override: true`), a
      release with no matching build, or a build without `defined_modules` is `probe_unknown`.
      Else `probe_definer`, with the module and the dependency (or `code_path`) as its
      arguments. For an application: no dependency is that application, and no `<name>.app` is
      on the code path, under OTP's or Elixir's lib dir, or loaded; else `probe_definer`. For an
      OTP application: it is installed nowhere on the client's side, and no dependency has its
      name; else `probe_otp_app`. Under Mix.install the project is the install's. A client that
      does not know the kind treats the item as malformed: a miss.

    On a device, a `config_order` item holds only when `app` and `reader` are both present or both
    being installed, `default` is `:error`, and the device's value for the key equals `seen`.
    On a device, an `env` item recorded unset holds, one recorded set or `set_by: "nerves"` is
    `env_set_at_build`, an `endian` item is `endian_differs`, an `os_type` item
    `os_type_differs` and a `mix_target` item `rule8_target` (the device cannot check the machine
    its firmware was compiled on, nor its target), a `config_all` item `config_all_differs`, and a
    `probe` item `probe_unknown` (a device cannot check the project its firmware was compiled in). A
    client never prints the project's value. A build that carries `compile_inputs` is exempt
    from the source scan's environment-variable rule (`rule8_env`).

Among the builds that pass, the client prefers an exact Elixir patch match,
then the closest older patch, then `pure_elixir` over a system build, then the
newest `run_id`.

#### Using a system build on another release

A build for the project's Nerves system made on another release of it is
used when:

- **Beam-only** (`build.native` is `false`): always, unless its compile read
  the Nerves system itself, which bakes the system version into a beam
  (`system_bound_compile`).
- **Native** (`build.native` `true` and `build.portable` `true`), when every
  one of these holds against the systems table entry for the project's
  release (`systems` in the batch):
  - the same toolchain package, and the same series: the build's from
    `build.toolchain.version` (`major.minor`), the release's from the table
    (`system_version_abi`);
  - the same OTP major, with the built `build.otp_full` no newer than the
    release's `otp` (`toolchain_otp_minor`);
  - every soname in `build.elf.needs` present in the release's `libs`
    (`needed_lib_missing`);
  - every needed symbol version a client can read (`GLIBC_2.38`,
    `GLIBCXX_3.4.32`, `CXXABI_1.3.15`, `OPENSSL_3.0.0`) among that
    library's definitions (`symbol_version_missing`). Names it cannot read,
    such as `GLIBC_PRIVATE`, are skipped.

  A native build without `build.elf` misses on another release as a build
  that predates the field (`build_predates`, `["elf"]`), and is used on its
  own release as before.

  A release missing from the table, or one whose `otp` or `libs` is still
  `null` (a release the portal knows only from its Hex requirement), matches
  only builds made on it, and misses as `system_unknown` before its series
  or OTP is compared. One whose `series` is `null` matches only builds made
  on it too, and misses as `system_version_abi`, its series shown as `?`.
- **Anything else** — `portable` `false`, or `native` or `portable` absent —
  is used on its own `system_version` only.

When several builds of the system pass, the client takes:

1. the build made on the project's exact system version;
2. else the one on the highest version below the project's;
3. else the one on the lowest version above it.

## Miss reports (`/api/precompiled/reports`)

A client may send what its last build hit, missed and failed, so misses can
be analysed and fixed (`mix precompiled.report` in the `precompiled`
package). Sending is always explicit; nothing is sent during a build.

| Method | Path | Answer |
| --- | --- | --- |
| `POST` | `/api/precompiled/reports` | `201 {"id": "<uuid>"}`; `200 {"duplicate": true}` for the same report within 24 h |
| `DELETE` | `/api/precompiled/reports/<id>` | `204`; `404` for an unknown id |

The id is all a `DELETE` takes, so it is the capability to retract a
report. A duplicate is therefore answered without an id: two testers with
identical projects send identical reports, and the second must not be able
to retract the first one's. The duplicate is counted on the stored report,
not stored again.

The body is at most 256 KiB of `application/json`, with no `charset` or
`charset=utf-8` (413 and 415 otherwise; 400 for a body that is not
well-formed JSON). The size limit applies before the body is parsed, also
for a request whose path is percent-encoded (`/api/precompiled/%72eports`).
Every field at every level is checked and an unknown one refuses the report
with 422 `{"error", "details"}`:

- `format` (integer, 1 today; older formats stay accepted), `client`
  (the client's version), `built_at` (optional ISO 8601);
- `elixir` (version), `otp` (integer major), `os` (`family`: `unix` or
  `win32`; `arch`: `[a-z0-9_.-]{1,64}`), `target` (Mix target),
  optional `system` and `system_version` (the Nerves system; `system`
  follows the Hex package-name rule). A Nerves system that is not a public
  Hex package arrives as `custom`, with the target `custom` and no
  `system_version`, so a private system's name is never sent;
- `lines` (at most 500): `name`, `version`, `status` (`hit`, `miss`,
  `fail`), `reason_code`, `reason_args` (at most 8 strings of at most 64
  characters of `[A-Za-z0-9_.+:-]`: package names, versions,
  Elixir/OTP/target/system names), `reason` (the code's fixed template,
  rendered);
- `lock` (at most 1000): `name`, `version`, `checksum` (the outer
  checksum) of the public Hex entries of the candidates and their closure;
- optional `contact` (at most 100 printable characters).

Reason codes: `hit`, `not_in_batch`, `not_built_version`,
`not_built_target`, `build_method_unknown`, `build_method_override`,
`build_method_mismatch`, `malformed_entry`, `rule8_unscannable`,
`rule8_env`, `rule8_target`, `build_predates`, `toolchain_elixir`,
`toolchain_otp`, `dep_env_differs`, `checksum_differs`,
`closure_mismatch`, `closure_checksum`, `closure_absent`,
`closure_without`, `closure_env_absent`, `compile_env_differs`, `excepted`,
`revoked_provenance`, `revoked_not_in_batch`, `remove_failed`,
`deadline_passed`, `fetch_failed`, `verify_failed`, `install_failed`,
`internal`, `system_version_abi`, `toolchain_otp_minor`,
`needed_lib_missing`, `symbol_version_missing`, `system_unknown`,
`system_bound_compile`, `env_differs`, `env_set_at_build`, `env_all`,
`config_unrecorded`, `config_order_differs`, `rebar3_global_config`,
`erl_compiler_options`, `platform_define_differs`, `endian_differs`, `os_type_differs`,
`triple_differs`, `nif_version_newer`, `origin_unverified`, `deterministic_not_built`, and the
foreign priv codes of client 0.8.0: `foreign_priv_target_compiles` ("writes into {0}'s priv; {0}
compiles from source in this run"), `foreign_priv_target_missing` ("writes into {0}'s priv; {0} is
not in this build"), `foreign_priv_target_linked` ("writes into {0}'s priv, which links to its
sources"), `foreign_priv_conflict` ("writes {0}'s priv/assets/{1}, which {2} also claims"),
`foreign_priv_rule_unknown` ("writes into {0}'s priv under rule {1}, which this client does not
know") and `foreign_priv_device` ("writes into {0}'s priv at compile time; not installed on a
device"), the relocation codes of client 0.9.0: `relocated_paths` ("relocated build: this
project's paths are not its own real paths"), `relocated_otp` ("relocated build: needs OTP 28 or
later"), `relocation_refused` ("relocated build: the rewrite refused"), `relocated_path_spelling`
("relocated build: this project's {0} path is not spelled as on disk"), `relocated_path_ascii`
("relocated build: this project's {0} path is not printable ASCII") and `relocated_path_envelope`
("relocated build: this project's {0} path is outside the paths it was proven at"), and client
0.9.0's `config_all_differs` ("built with a different compile-time config of {0}"), and the probe
codes of client 0.10.0: `probe_definer` ("built where {0} is absent; {1} can supply it here"),
`probe_otp_app` ("built where OTP application {0} is absent; it is installed here") and
`probe_unknown` ("built where {0} is absent; cannot tell whether this project supplies it").
Another code is stored as `unknown`.

Limits: 10 requests an hour per client, one budget that every `POST` and
`DELETE` counts against, refused ones included; and, for `POST` only, 300
newly stored reports an hour and 2000 a day in total, counting only `201`
answers, so refused requests and duplicates sent from many addresses cannot
use up everyone's budget. A `DELETE` is never held back by the shared
limits. 429 with `retry-after` beyond any of them. The limits are checked before the body
is read. The client address is used only in
memory, for the limits and a keyed digest of it; the address is never
stored, nor logged at the production log level.

### What a report triggers

A `miss` line whose code is `not_built_version` or `not_built_target` may
queue a build of what was missed. Each such line gets one decision, the
first rule in this order that applies (a device report without a public
system is `skipped:unbuildable` before anything else but
`skipped:foreign_priv_client` is checked):

| Decision | When |
| --- | --- |
| `skipped:foreign_priv_client` | A `not_built_*` miss from a client before 0.8.0 (or one that names no version) for a version with a foreign priv build, or of kino. That client never reads a version's `foreign_priv` object, so no build changes what it is served. |
| `skipped:relocated_client` | A `not_built_*` miss from a client before 0.9.0 (or one that names no version) for a version with a relocated build. That client never reads a version's `relocated` object. |
| `skipped:unknown_package` | The catalog has no run of the package. |
| `skipped:unbuildable` | No build here produces the missed tuple: a device report without a public system (`custom` included), a system version no run of the last 30 days recorded, or a toolchain no worker image builds. |
| `skipped:superseded` | A run of the last 30 days recorded a newer version of that system. A build now produces the newer one, so the older tuple would never be judged. |
| `skipped:not_on_hex` | Hex lists no such release. |
| `skipped:old_version` | A system tuple for a version that is neither the package's latest tested one nor Hex's newest release without a run yet (the highest version Hex lists, pre-releases included). Building any other version could make it the package's public result. Host (toolchain) reports are not checked: a toolchain build does not change it. |
| `skipped:judged` | A pass, fail or skipped result already stands for the tuple. An error or unknown one (a timeout, retries spent) does not count. |
| `skipped:queued` | A build that covers the tuple is already waiting. |
| `skipped:cap` | The day's budget is spent (below). |
| `skipped:error` | Queueing the build failed; the failure is logged. |
| `queued` | A build was queued. |

The tuple is `(package, version, system, system_version)` for a report with
a Nerves system and `(package, version, toolchain)` for a host report, the
toolchain following from its Elixir and OTP versions. A system tuple for
the package's latest tested version is built as one forced target, the
reported system only. A system tuple for Hex's newest release, when it has
no run yet, gets a plain full build, the build the portal queues for a new
release anyway; it becomes the package's latest result, as it would have. A host report gets a toolchain
build of that package version. Every build a report queues runs at Oban priority 9,
the lowest, so it never runs ahead of the regular builds.

Budgets, per UTC day: 50 report builds in total, 3 per package and 5 per
reporter (a keyed digest of the client address). A report whose reporter
digest retention already cleared counts against one shared `reporter:none`
budget. A line that queues nothing spends nothing.

Once a day, just after the budgets reset, a sweep decides again the lines
of the last 7 days that a budget refused, and the lines left undecided for
more than an hour (their report's own job gave up). The package version
the most distinct reporters asked for goes first, then the one first seen
earliest, so one reporter cannot take the day's budget. A sweep takes at
most 500 lines and stops once the global budget is spent; the rest waits a
day.

A report is an anonymous trigger and a build runs third-party code. The
rules above therefore never build a package the catalog has not built
already, and only a package's owners can publish a release of it. For a
Nerves system a report builds only what the portal would build anyway, only
sooner: a missing target of the latest tested version, or Hex's newest
release. It never builds any other version. A host report can ask for a
toolchain build of any release Hex lists, which the toolchain sweep would
reach in time. One report is enough; an earlier
design required two distinct reporters before queueing, which was dropped
on purpose, because the budgets bound what a single reporter can trigger.
Report builds run in the same sandbox as every other build.

### Retention and storage

A report's `contact` and reporter digest are cleared after 90 days, and
the report, with its lines, is deleted after 365 days. Both periods are
configurable (`:report_anonymise_days` and `:report_retention_days` of
`Portal.Workers.LogRetention`). The client address itself is never stored.

`lock` dominates a report's size: up to 1000 entries of about 100 bytes,
about 100 KiB at worst. The global limits (2000 accepted reports a day)
bound how fast the tables grow, and the 365-day retention bounds their
total.

### Analysis

Until an admin page shows them, `Portal.Reports.Summary` groups the stored
lines for analysis, run on the serving release through the rpc helper:

    ops/portal-rpc.sh 'Portal.Reports.Summary.by_package() |> IO.inspect(limit: :infinity)'
    ops/portal-rpc.sh 'Portal.Reports.Summary.storage() |> IO.inspect()'

`by_package/1` groups by package, version and reason code, `by_client/1`
by client version and reason code, and `by_target/1` by Mix target, OTP
major and reason code. Each row has `count` (lines), `reports` and
`reporters` (distinct), `first_seen` and `last_seen`, and the requeue state
of its lines (`queued`, `skipped`, `open`). Options: `since:` (a
`DateTime`, default 30 days back) and `limit:` (default 100 rows).
`storage/0` gives the row count and on-disk size, indexes included, of
both report tables.

## Trust

A manifest or file is only as trustworthy as the chain that names it: `root.json`
says which key may sign a batch; a batch, signed by that key, names the SHA256
of every package's manifest bytes; `manifests/{package}.json` (and
`v2/manifests/{package}.json` for `manifests_v2`) serves exactly those bytes, so a client can hash what it downloaded and compare it to the
batch entry instead of trusting the connection; `files/{sha256}` is
content-addressed, so each file is its own proof once its manifest entry is
trusted. The reference client,
[elixir_precompiled](https://github.com/TomHoenderdos/elixir_precompiled),
verifies this chain. A client that skips it can still use
`manifests/{package}.json` directly — once a batch exists it is served from
the same stored bytes, just without the batch to check them against.

- **Envelope** — every signed document (`root.json`, `batch.json`,
  `batches/{sequence}.json`, a bundle's `offline.json`) is `{"payload": base64url(bytes), "signatures":
  [{"keyid": hex, "sig": base64url}]}`, Ed25519 over the raw payload bytes. A
  client verifies the signature before decoding the payload.
- **Keys and thresholds** — `root.json` lists the Ed25519 keys allowed to sign
  each role and how many signatures each needs (`roles.root.threshold` and
  `roles.batch.threshold`). A client accepts a document only when it carries at
  least that many valid signatures from the role's keys. The `keyid` is the lowercase hex SHA256 of the key's 32 public
  bytes.
- **Offline role** — `roles.offline`, when present, names the keys that may
  sign a bundle's `offline.json` (see Offline bundles). A client that does
  not know the role ignores it. The role is delegated by the root: it
  appears only in a new `root.json` version signed by the `root` role, and
  is replaced the same way. `offline.json` is never served over https.
- **Expiry** — `root.json` expires a year after it is written by default; a
  batch expires 24 hours after it is issued, and a new one is signed every 15 minutes. A client should refuse an expired document, and the reference client also refuses a batch issued more than 24 hours ago.
- **Sequence** — a batch's `sequence` increases by exactly one each time a new
  batch is signed. A client that has already seen a higher sequence should
  refuse a lower one.
- **Manifests are stored bytes** — a manifest entry in a batch names the
  SHA256 of the manifest JSON as it existed when that batch was built; the
  manifest endpoint serves those same stored bytes (not a fresh render) for
  as long as that is the newest batch, so the hash a client checks against
  always matches what it downloads, and sets an `etag` of that SHA256. Before
  the first batch is signed, and for a package the newest batch does not name
  yet, the endpoint serves a fresh render instead, without an `etag`; a client
  that verifies batches cannot use it. The same bytes stay reachable by
  digest at `manifests/by-sha/{sha256}.json` and
  `v2/manifests/by-sha/{sha256}.json` after newer batches name other bytes.
- **Revocation** — there is no separate revoke endpoint. When a build is
  withdrawn, the next signed batch drops the package from `manifests` and
  `manifests_v2` or points at a different hash in each. A client that verifies
  against the newest batch stops being told to fetch the withdrawn bytes from
  the moment that batch is signed.

## Offline bundles

A bundle is a static copy of this API's layout for a device without
network: `root.json`, `batch.json`, `v2/manifests/<package>.json` (and
`manifests/<package>.json` for format 1) and `files/<sha256>` under one
directory, read by a client through a `file://` source. Every byte is
checked exactly as over https.

`batch.json` in a bundle is the online batch and keeps its expiry (24 hours
after `issued`); a client reading it from a bundle applies that expiry. For
a device that stays offline longer, the bundle may also carry
`offline.json`: an envelope signed by the root's `offline` role over

    {"version": 1, "kind": "offline", "sequence": <int>, "issued": "<time>",
     "manifests": {...}, "manifests_v2": {...}}

with no expiry. `sequence` is the signing time in Unix seconds. A client
honours it only from a source the user named as a bundle (`file://`), only
when the root in use has an `offline` role, and only with a sequence at
least the highest offline sequence it has seen.

- **What it signs** — only the manifests the bundle holds, each with the
  hash the batch gives it; a manifest the batch names but the bundle leaves
  out is not in `offline.json`. A client refuses a manifest that is not in
  the offline maps, or whose bytes do not hash to its entry.
- **The root in use** — a bundle's `root.json` may be newer than the root a
  device has. The client adopts it by the usual chain rule: it verifies
  under its own `root` role and under the `root` role of the root the
  device already trusts, and its version is higher. A device whose root has
  no `offline` role gains one this way. A root that does not follow is
  ignored, and the device keeps its own; it never trusts a bundle's root
  for being in the bundle.
- **Root expiry** — an offline document is valid indefinitely, and the
  root's `expires` does not bound it. When verifying `offline.json` from a
  bundle source, and when adopting that bundle's `root.json` for it, a
  client does not refuse a root because its `expires` has passed; the
  signatures and the chain are checked exactly as always. Every other path
  (https sources, `batch.json`, a root adopted from an https source) keeps
  checking expiry against the clock. A device's clock therefore never ends
  its offline bundles.
- **Signing** — `offline.json` is signed off the portal hosts, with
  `mix portal.precompiled.sign_offline --bundle DIR --key FILE --root FILE`.
  `--root` is the current production `root.json`, never the bundle's own
  and never an older one, and all trust comes from it: the signing key must
  be in its `offline` role and `batch.json` must verify under its `batch`
  role. The bundle's `root.json` must have the same version and payload as
  `--root`; a newer one means `--root` is stale and is refused (devices
  still adopt newer roots on their side). The task also refuses an expired
  `--root` unless `--allow-expired-root` is given, a held manifest that
  does not match the batch, a batch issued more than a day before the
  signer's clock or more than five minutes after it, and an existing
  `offline.json`. A batch can expire after it was signed into
  `offline.json`; the offline document stays valid.
- **Revocation** — an offline document cannot be withdrawn: the only way to
  stop trusting one is to rotate the offline key (`mix
  portal.precompiled.root_rotate`), which a device sees only when it adopts
  the new root, online or from a later bundle. A device that never sees a
  newer root keeps trusting what it has; that is the cost of being offline.
  The highest offline sequence a device has seen is kept on the device
  only, so whoever can write the device's data partition can reset it.
- **Delegation** — the `offline` role is only as strong as the `root` role
  that delegates it. While the `root` and `batch` roles share one key, a
  holder of the online batch key can sign a root that delegates the
  offline role to a key of their choosing, and from it offline documents
  that never expire. The same holder can also sign a batch, build a bundle
  around it as the portal does, and have it signed by the honest offline
  signer: the batch is the signer's only input, so a bundle built from a
  compromised portal gets an offline document that never expires.

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
  `build.deps` is `null` and a client should skip them. Since 2026-11-06 such
  entries are not served at all while any package is withheld (below): their
  closure is unknown, so it may include one.
- `pure_elixir` entries from runs before 2026-10-24 were built without the
  package's optional dependencies, so their `build.deps` lacks them and a
  client whose lock has them (decimal next to jason, for example) does not
  match.
- Per-system entries from firmware runs before 2026-10-27 were built
  without the package's optional dependencies for every target, the same
  as a `pure_elixir` entry from before 2026-10-24; the per-target pass
  added on 2026-10-27 only covers runs from then on, and only the targets
  it kept them for. Until 2026-11-15 such a target published only its build
  with them; the format-2 build without them appears for runs from then on.
- Pure Elixir packages have `pure_elixir` entries only from runs after
  2026-10-20; earlier ones archived no files.
- Toolchain builds before 2026-11-05 were made only with the package's
  optional dependencies, and none was made of a package that ships priv
  files; the build without them, and the build of a package with static
  priv data, appear as the toolchain backlog reaches each version.
- Entries from runs before 2026-10-23 list the release copy of each BEAM,
  stripped of `debug_info`. Later runs list the target's compile output,
  `_build/<target>/lib/<package>/`, whose BEAMs keep it, so a client can
  consolidate protocols a precompiled dependency defines and Dialyzer sees
  its types. The manifest shape is the same either way.
- An entry appears only once every file it lists can be served, so a fresh
  build may be delayed; until then the manifest keeps offering that version's
  previous complete build, if it has one.
- No build whose dependency closure includes a withheld package is served,
  in either manifest format or by `files/{sha256}`; the list is
  `phoenix_live_view` (`Portal.Precompiled.Withheld`), and the package itself
  counts. A build with no recorded lock (`build.deps` `null`) has an unknown
  closure and is withheld too: the portal keeps no other record of it, and a
  package's declared dependencies name only its direct ones. This applies to
  the per-name manifest routes as much as to the batch. Such packages change their dependents' BEAMs through compile-time
  application config the project sets and the portal's builds do not: every
  new Phoenix 1.8 app sets LiveView's `root_tag_attribute`, which changes the
  markup of every `~H` root tag, and LiveView's colocated hooks, JS and CSS
  write asset files at compile time that installing BEAMs never provides.
  A build that records its compile-time config reads (builds since
  2026-11: its `compile_env` lists LiveView's `root_tag_attribute` and the
  other keys the closure read while compiling) is served again: a project
  whose config sets those keys differently does not match it and compiles
  the package itself, and the builder's compile-time trace refuses builds
  that write files at compile time. Only toolchain builds and `pure_elixir`
  entries record their config reads; firmware entries never do, so a
  firmware entry whose closure has a withheld package stays withheld. The
  exception covers the closure only: a build with no recorded lock stays
  withheld whatever it records, and a revoked or withdrawn build stays
  unserved. LiveView-closure builds published before that come back as the
  builder rebuilds them.
- No toolchain, pinned or host-native build that ran a rebar3 plugin is
  served, in either manifest format or by `files/{sha256}`, while Hex has a
  release of that plugin package, or of a plugin dependency the build ran,
  that the builder's plugin review does not cover
  (`Portal.Precompiled.PluginWatch`, read from the registry every hour): a
  user's rebar3 takes a plugin's release from its own registry cache, and a
  release nobody reviewed could change what the package compiles to. The
  build is served again, unchanged, once a portal release that reviews that
  release deploys. A build made before builds recorded the plugins they ran
  (2026-11) records none and is not covered.
- A config variant is served only beside its default build: the default
  build of the same version, toolchain, builder version and optional
  dependencies must itself be served (passing, not revoked, not withheld),
  and the variant must record its own config reads. Revoking, refusing or
  withholding the default
  withdraws its variants in the same batch, in the format-2 manifest, the
  package list and `files/{sha256}` alike. Format 1 never lists a toolchain
  build, so it never lists a variant.
- A `pure_elixir` entry is published only when the run's compile-time trace
  passes, the same trace a toolchain build gets: a compile that read the
  build host, wrote outside its own `ebin`, baked the build path into code,
  depends on a package whose own compile did, or whose trace did not finish
  publishes no `pure_elixir` entry. Its files are the traced compile's, and
  they pass the same native-code checks as a toolchain build's (no NIF or
  driver load, no native sources or build dependencies, no target read,
  `nerves` name or mention of Nerves in the sources, and no dependency whose
  sources read the target or mention Nerves), including code an optional
  dependency compiles in. The
  run's status is unaffected.
