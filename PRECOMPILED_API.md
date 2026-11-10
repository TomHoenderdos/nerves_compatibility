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
  "content": ["https://cdn.example"]
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
`<origin>/v2/manifests/by-sha/<sha256>.json`). It is signed with the rest of
the payload, so only the portal's key can add an origin. A client may fetch
those paths there first and must fall back to the source; everything is
checked against the hashes the batch and manifests name. Its presence also
says the source serves the by-sha paths. Absent when no origin is
configured. `version` stays `1`: like `manifests_v2`, it is an added field.

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
      assume it is the same across a package's targets.
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
      (`Compatibility.RecordedValue.acceptable?/1`): the worker and the
      portal both refuse to record or re-serve an entry whose value fails
      this check, dropping the whole `compile_env` list to `null` for that
      build instead, because a client's own match (`precompiled`'s
      `Match.recorded_equals?/2`) decodes a value with
      `:erlang.binary_to_term(bin, [:safe])`, which inflates compressed ETF
      before `:safe` runs and still admits a fun of an already-loaded
      module.
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
- `updated_at` — the newest `finished_at` among the builds listed.

What it lists:

- Every build format 1 publishes, with `target` set to its format-1 key.
  Format 1 keeps only the newest per target; format 2 keeps each toolchain's.
- Toolchain builds: a pure-BEAM package version built on a plain Elixir/OTP
  image for `Mix.install` and non-Nerves projects, `target` `pure_elixir` and
  `system_version` `null`. Only passing, unrevoked builds whose files can all
  be served appear. A version is built once with every optional dependency a
  fresh lock would add (as for the `deps` of other entries), and, when that
  build added any, once more without them (also when the build with them was
  skipped, whatever the reason, since it may be one of them): two builds whose `deps` differ by those
  dependencies, so a project that locks them and one that does not each
  find theirs. A toolchain build's files include the package's `priv` when it
  is static data: regular, non-executable files the package's own Hex tarball
  carries byte for byte, none of them native code (by name or by ELF, Mach-O,
  PE or `ar` magic), at most 500 files and 10 MiB in all, from a package with
  no native sources. The builder judges this inside its container, and the
  portal judges it again on the host at ingest, with the same rules, against
  the tarball it fetches itself: its SHA-256 must be the outer checksum the
  signed Hex registry lists, which must also be the build's
  `package_checksum`, and each file must hash to its manifest `sha256`. A
  build that fails publishes none of its files, beams included. A package
  whose `priv` is anything else gets a `skipped` toolchain build.
  The builder also recompiles the package's dependency closure under a
  compile-time trace and skips any build whose compile read the build host
  (its OS, environment, programs or files outside the dependency closure),
  wrote anything outside its own `ebin`, baked the build path into code, or
  depends on a package whose own compile did, and any build whose trace did
  not finish; its beams are the traced compile's. What the package does at
  runtime does not count: a package that runs programs, opens ports, looks
  up executables or reads the OS type when it runs is built and served like
  any other, since those calls run the same from a precompiled build. Native
  code and Nerves still do not: a package with native sources or build
  dependencies, a NIF or driver load, a target read, a `nerves` name or a
  mention of Nerves in its sources, or with a dependency whose sources read
  the target or mention Nerves, gets a `skipped` toolchain build. Its
  `compile_env` lists the config reads that trace observed, so a
  project whose config sets one of those keys differently compiles the
  package itself.
- A build whose `elixir`, `otp`, `deps`, `package_checksum` or `compile_env`
  is `null` is left out, since no client can match it (it stays in format 1).
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
   matter. A client that cannot read the package's `mix.exs` (one installing
   without Mix, for example) takes the list from `build.declared`; a build
   without it gives no list, so such a client treats every dependency in its
   lock as one the package may declare.
9. **compile_env** — `build.compile_env` is present, and every `build.compile_env` item decodes to the value the
   project's config gives for that app and path.

Among the builds that pass, the client prefers an exact Elixir patch match,
then the closest older patch, then `pure_elixir` over a system build, then the
newest `run_id`.

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
`closure_without`, `compile_env_differs`, `excepted`,
`revoked_provenance`, `revoked_not_in_batch`, `remove_failed`,
`deadline_passed`, `fetch_failed`, `verify_failed`, `install_failed`,
`internal`. Another code is stored as `unknown`.

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
system is `skipped:unbuildable` before anything else is checked):

| Decision | When |
| --- | --- |
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
  it kept them for.
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
