# RFC: Precompiled dependencies for Elixir and Erlang projects

Status: draft, not yet posted. Date: 2026-10-23. Updated 2026-10-27, see
"Since this RFC".
Authors: Tom Hoenderdos. Prototype: Nerves 2, see "Phases".
Related: `PRECOMPILED_API.md` for the wire format.

## Since this RFC

This document was written on 2026-10-23, before manifest format 2 shipped on
2026-10-24. The body below is left as written; what has changed since:

- **Client.** The client is no longer a pull request against `nerves`. It is
  [elixir_precompiled](https://github.com/TomHoenderdos/elixir_precompiled),
  which verifies the signed chain in "Trust". The root document travels in
  the elixir_precompiled archive instead of the `nerves` package, and the
  portal also serves it at `/api/precompiled/root.json`.
- **Format 2.** `/api/precompiled/v2/manifests/<package>.json` publishes a
  build list rather than one entry per target, and relaxes or adds rules to
  "What makes a build reusable" (`PRECOMPILED_API.md`, "Matching a format-2
  build to a project", has them in order):
  - Elixir matches on major.minor, with the running patch at least the built
    patch, instead of exactly. OTP stays an exact major match.
  - Each build records `dep_env`, the Mix env it compiled the package under
    (always `prod`), and matches only a project that compiles the dependency
    under that env. This is the environment check "Limits" asks for.
  - Every dependency the package declares, optional ones included, that is
    in the project's lock must also be in the build's lock.
- **Toolchain builds.** Pure-BEAM package versions are also built on plain
  Elixir/OTP images and served in format 2 as `pure_elixir` builds, for
  `Mix.install` and projects that are not Nerves projects. Native code on
  hosts stays out of scope, as in "Limits".

## Summary

Every Elixir project compiles every dependency from source, on every
developer machine and in every CI run. A dependency's compiled output is a
function of a small set of inputs: the package bytes, the Elixir and OTP
versions, the versions of the other packages it compiles against, the
compile-time configuration it reads, and the target. When those inputs are
the same, the output is the same.

A trusted builder can therefore compile a dependency once per input set and
publish the result. A project whose inputs match can install that result
instead of compiling. Nerves does this today behind a configuration flag,
against compatibility.nerves-project.org, a portal that already compiles
every Hex package for every Nerves system to report whether it builds.

This document describes the mechanism, the inputs that define reuse, the
trust chain, and what it saved on a real project. It then asks Mix and Hex
to make the mechanism public, and asks rebar3 to consider the same.

## Motivation and evidence

A Nerves project of ordinary size has about fifty dependencies. Each fresh
checkout and each CI job compiles all of them before the project's own code
compiles. Most of that work produces bytes identical to what every other
user of the same lock file produced.

The prototype was measured on a demo project with 52 dependencies, among
them exqlite, argon2_elixir, circuits_gpio and ash. Run A compiles
everything. Run B fetches precompiled files for every dependency that
matches and compiles the rest.

| Measured 2026-10-20, rpi4, Nerves 2.0.0-pre.4, empty `_build` each run | A: compile everything | B: precompiled | Ratio |
| --- | --- | --- | --- |
| `mix firmware` | 29 s | 9 s | 3.2 |
| `mix firmware`, upload, reboot on the Pi | 73 s | 58 s | 1.3 |

Nerves 2 is a prerelease at the time of writing. The host was an Apple
Silicon laptop.

Run B's 9 seconds split into a fetch and a build.

| B, where the time goes | Seconds |
| --- | --- |
| Fetch: batch, manifests, files | 4 |
| Compile what missed, release, SquashFS, fwup | 5 |

The release and firmware packaging floor is about 4 seconds and no amount of
precompiling removes it. The Nerves tooling itself, the `nerves` package, the
system and the toolchain, compiles in about 0.2 seconds and is never fetched.

The fetch is one request per file, on the order of 1,400 requests for this
project over a keep-alive connection. One archive per package would cut the
request count to one per dependency. That is a future measurement, not a
claim.

A second measurement came from the client's acceptance run against the
production portal on 2026-10-23, with a cold local cache.

| 2026-10-23, production portal, cold cache | Value |
| --- | --- |
| Candidate dependencies | 45 |
| Hit | 38 |
| Miss | 7 |
| Fail | 0 |
| Bytes fetched | 20.5 MB |
| Fetch time | 3.6 s |
| `mix firmware` | 10 s |

All seven misses had the same cause. The portal built each package in a
project holding only that package, so an optional dependency that a real
application has in its lock was absent from the build, and the lock rule in
"What makes a build reusable" refused the entry. The portal now resolves a
package's optional dependencies before building it. The seven packages are
rebuilt as the portal's sweep reaches them.

Why the portal: it builds every Hex package for every Nerves system already.
The marginal cost of publishing is storage and a signature.

## Prior art

| System | What is cached | Keyed by | Trust |
| --- | --- | --- | --- |
| Nix binary cache | build outputs | hash of every input, the derivation | signed narinfo, pinned public keys |
| Python wheels | built distributions | platform, ABI and Python tags | PyPI signatures, no input hash |
| `elixir_make` with `cc_precompiler`, `rustler_precompiled` | the NIF shared object | target triple, NIF version | checksum file committed in the package |
| Bazel remote cache | action outputs | action digest: inputs, command, environment | a trusted cache server |
| Hex registry | source tarballs | name and version | signed registry, per-package checksums |

Nix is the closest. Its outputs are keyed by a hash of every input, and a
cache serves an output only to a client that computed the same hash. Its
weakness is ours: the key must capture every input, or two different outputs
share a key.

Wheels show that a platform tag is not enough when an output depends on the
versions of other packages. A wheel is built against the Python interpreter
and the platform, never against the other packages in the environment. BEAM
files are different. A macro from a dependency is expanded into the caller's
module at compile time, so the dependency's version is part of the output.

The Elixir NIF precompilers are the community's existing answer, and they
cover the native part only. Each package downloads its own shared object
from a release page and checks it against a checksum file the author
committed. This proposal covers the whole `ebin` and `priv` of a dependency
and keys it on everything that went into it.

Hex already holds the registry signature and the per-package checksums that
the key below cites. Nothing in this proposal replaces them.

## What makes a build reusable

The client uses a published entry for dependency `d` at locked version `v`
only when every rule below holds. A failed rule is a skip. The dependency
compiles as it does today and the client prints one line saying why.

1. **Package checksum.** The entry's package checksum equals the outer
   checksum in the project's lock entry for `d`. This is the identity of
   the bytes that were compiled. Git and path dependencies have no such
   checksum and are never fetched.
2. **Elixir and OTP, exact.** The entry's Elixir version and OTP release
   equal the client's. The BEAM format and the compiler's output change
   between versions. Mix's own dependency marker already requires this
   match, see "What Mix already has".
3. **Target.** The entry's Nerves system name and version equal the
   project's. A NIF binds to the system's toolchain, libc and kernel
   headers. A package whose whole dependency closure is pure Elixir has a
   `pure_elixir` entry instead, which matches every system.
4. **Dependency lock, subset.** The entry lists every package in `d`'s
   transitive closure as it was locked for the build, with version and
   checksum. Each one must be in the client's lock at the same version and
   checksum. Packages in the client's lock that the entry does not list are
   fine, because they did not go into this build. A listed package missing
   from the client's lock is a mismatch. The reason is macros. Ash 3.5.2
   requires spark, and spark's macros are expanded into Ash's modules at
   compile time. Ash built against spark 2.7.8 is not Ash built against
   spark 2.7.3. The same holds for optional dependencies: jason declares
   decimal as optional and compiles a `Jason.Encoder` implementation for it
   only when Decimal is loadable, so jason built with decimal present and
   jason built without it are two different outputs.
5. **Compile-time configuration.** `Application.compile_env/3` bakes a
   configuration value into the module. Elixir already records every such
   read in the `.app` file and refuses to boot a release whose runtime
   configuration disagrees. The entry publishes those reads, and the client
   compares them with its own configuration before downloading. It compares
   again against the `.app` inside the downloaded files before anything
   moves into `_build`.
6. **Signed batch membership.** The manifest the client read must be the
   one the signer saw. See "Trust".
7. **Opt-out.** Dependencies listed under `except` in the project's
   configuration are never fetched.

The key leaves out three things on purpose.

- `MIX_ENV`. The builder compiles in `prod`. The client fetches only for
  target builds, and a Nerves target build runs in `prod` by default. The
  prototype checks the target, not the environment, so a target build run
  under another `MIX_ENV` would receive `prod` files. A client should refuse
  to install under any other environment. See "Limits".
- Protocol consolidation. The project consolidates protocols into its own
  `consolidated` directory after all dependencies compile. A dependency's
  files are the same before and after.
- `debug_info`. The portal publishes the target's compile output, the
  files under `_build/<target>/lib/<package>`, which keep `debug_info`. The
  release copy, which `mix release` strips, is not what is published. A
  stripped file would be equivalent on the device and useless for protocol
  consolidation and Dialyzer on the host. See "Limits".

## What Mix already has

Three mechanisms in Mix make precompiled reuse work today, without any
change to Mix. File paths are in the Elixir 1.20.4 source tree.

- **The dependency marker.** `lib/mix/lib/mix/dep/elixir_scm.ex` writes
  `compile.elixir_scm` into each dependency's `.mix` directory after it
  compiles. Format 2 is the term `{2, {elixir_version, otp_release}, scm,
  lock_entry}`. `validate_manifest/1` in `lib/mix/lib/mix/dep/loader.ex`
  reads it back. A missing marker, a different Elixir or OTP, a different
  SCM or a different lock entry each mark the dependency for recompilation.
  A client that writes a correct marker next to precompiled files makes Mix
  treat the dependency as compiled.
- **An extension point before dependencies compile.**
  `lib/mix/lib/mix/tasks/deps.precompile.ex` is a documented no-op task
  whose documentation says it exists to be aliased by projects that need to
  run something before dependencies compile. Nerves aliases it for its own
  bootstrapping.
- **Compile-time configuration in the `.app` file.** `add_compile_env/3` in
  `lib/mix/lib/mix/tasks/compile.app.ex` writes every
  `Application.compile_env/3` read into the application's `.app` file.
  `Config.Provider` in `lib/elixir/lib/config/provider.ex` validates them
  against the runtime configuration when a release boots.

The prototype is these three mechanisms and a download step. The caveat is
that two of them are private. `Mix.Dep.ElixirSCM` and `Mix.Dep.Loader` carry
`@moduledoc false`, and the marker's format is an implementation detail that
has already changed once. The prototype depends on internals that Mix is
free to change.

## What Mix should add

1. **A public dependency state for "installed from a precompiled source",
   with a documented inputs manifest.** The manifest names the Elixir
   version, the OTP release, the dependency's lock entry, the lock entries
   of its transitive closure, a hash of its compile-time configuration
   reads, and a target identifier. Today's marker holds the first three. A
   documented format lets a tool write it and lets Mix verify it.
2. **Record the dependency lock alongside the lock entry.** Mix tracks each
   dependency only against its own lock entry. It recompiles a dependency
   when that entry changes. It does not recompile a dependency when a
   sibling it compiled against changes, which is why `deps.compile` has an
   `--include-children` flag. A dependency compiled against one version of
   a sibling and left in `_build` while the sibling moves is therefore
   already possible inside one project. For a file that arrives from
   outside the project, Mix has even less to go on. Recording the closure's
   lock entries in the marker gives it something.
3. **A supported hook before dependency compilation.** `deps.precompile` is
   the slot. It needs two things it does not have: an ordering guarantee
   that it runs after dependencies are loaded and before any of them
   compiles, and an API that hands the hook the list of dependencies about
   to compile and lets it mark some as satisfied. An alias is not an API.
4. **Optionally, a `Mix.SCM` callback.** An SCM that can fetch sources could
   also offer builds. A callback such as "do you have a build for this lock
   entry and these inputs" would let Hex, or any SCM, answer without a
   separate hook.

## What Hex could add

Two options. This document does not prefer one.

- **A. Hex serves builds next to tarballs.** A Hex-run builder compiles each
  release for a set of targets and Hex serves the output keyed by the
  inputs manifest above. The registry signature covers the index of
  builds as it covers the index of tarballs today.
- **B. Hex package metadata names trusted build sources.** A package's
  metadata, or a per-organisation setting, lists build sources as a URL and
  a root document. A client uses only the sources it trusts. The
  compatibility portal is one such source among many; a company's internal
  builder is another.

Both options reuse what Hex already has: the registry signature and the
per-package checksums that rules 1 and 4 cite. Neither requires the other.

## Trust

A dependency's code runs in two places, on the developer's machine at
compile time through macros and on the device at runtime, and a NIF runs as
native code inside the VM. Downloading compiled code and running it is what
an attacker wants a client to do.

A malicious package's own files are out of scope. Building it locally runs
the same code. What precompilation adds is the risk of serving bytes a local
build would never have produced: files tampered with after the build, and
files built against dependencies or a toolchain the user never locked.
Rules 1 to 5 above address the second. Signing addresses the first. Builds
run sandboxed.

The chain the prototype verifies:

1. A root document shipped inside the `nerves` package names the keys that
   may sign batches and roots. (Now shipped with elixir_precompiled; see
   "Since this RFC".)
2. A signed batch index names every published package and the SHA-256 of
   its manifest bytes. It expires after 7 days and carries a sequence
   number that only increases. The client refuses an expired batch and a
   sequence lower than the last it accepted.
3. The manifest bytes name every file by SHA-256, size, path and mode. The
   client hashes the bytes it received and compares them with the batch.
4. Each file is content-addressed. The client hashes it before it moves
   into `_build`.

Every hop is a signature or a hash.

The chain defends against tampering in transit, a compromised mirror or
CDN, and a replayed stale batch. Default-on waits for a signing scheme with
humans in the loop.

## Limits

- **Native code on hosts.** Phase 1 reuses files for Nerves targets only. A
  Nerves system pins the OS, libc, kernel headers and toolchain, so the
  target identifier is a name and a version. A host build has none of that
  pinned. OS, libc and ABI would all have to join the key, and the builder
  would have to exist for each combination. Out of scope for phase 1.
- **`MIX_ENV`.** Only `prod` target builds are published. The prototype's
  client gates on the target and not on the environment, so it should add
  an environment check before any wider use.
- **Hit rate.** Reuse requires lock agreement. Nerves projects pin their
  system and start from the same generator, so agreement is high. The demo
  project's hit rate went from 7 of 53 to 48 of 52 once the portal rebuilt
  with the lock recorded, and the production acceptance run hit 38 of 45
  with the remaining 7 misses traced to optional dependencies the portal
  had not resolved. A plain Elixir project with a wider spread of lock
  files will miss more often. Resolving optional dependencies has a cost
  too: a project whose lock lacks the optional dependency now misses, where
  before a project that had it missed.
- **`debug_info` and stripped files.** Published files keep `debug_info`.
  A client that wants stripped files for a release gets them from `mix
  release`, as it does for locally compiled dependencies.
- **Compile-time side effects.** As with any build cache, the key covers
  only the inputs named above.

## rebar3

- rebar3 has no per-dependency "compiled against" marker. Mix has
  `compile.elixir_scm`. rebar3 decides per source file by modification time
  and by the compiler DAG under `_build/<profile>/lib/<dep>/.rebar3/`. A
  prebuilt `ebin` survives only if every beam looks newer than its source
  and the DAG agrees. Faking that is fragile, and this document does not
  propose it.
- The hook exists, the concept does not. `provider_hooks` with
  `{pre, [{compile, ...}]}` runs before compilation, but `rebar_app_info`
  has no state for "prebuilt from inputs with hash H" that the compile
  provider could honour.
- The key inputs differ. There is no `compile_env`. Top-level `overrides`
  of `erl_opts` change a dependency's output and would join the key.
  Profiles are separate builds. The OTP release and ERTS version replace
  the Elixir version.
- Erlang dependencies inside Mix projects already benefit. Mix drives
  rebar3 for them and their output lands under `_build/<env>/lib/` with the
  same marker as an Elixir dependency.
- The ask to the rebar3 team mirrors the Mix ask: a documented "precompiled
  app" state with an inputs manifest that the compile provider honours.

This is an ask, not a plan. Nothing in the prototype touches rebar3.

## Phases

1. **Nerves opt-in.** The prototype in this document. The client is a draft
   pull request against the `nerves` package's `v2` branch,
   https://github.com/nerves-project/nerves/pull/1220. The portal side is in
   the compatibility repository: the manifests say what each build used
   and publish one run per entry, publish each build's dependency lock,
   publish only entries whose files can be served, publish pure Elixir runs
   from their host build, record `compile_env` and the package checksum, and
   sign batches. Measure hit rate and fetch time in the wild.
   (The client has since moved to elixir_precompiled; see "Since this RFC".)
2. **Mix.** The public state, the inputs manifest and the supported hook
   from "What Mix should add". A library can then do what Nerves does
   without being Nerves.
3. **Hex.** Option A or B from "What Hex could add". Default-on only after a
   signing scheme with humans in the loop is live.

## Open questions

- Who runs builders for host targets: macOS, Linux with glibc, Linux with
  musl, Windows?
- One archive per package versus one request per file. The request count
  is known. The saving is not, and should be measured before anything
  changes.
- Should the client verify compile-time configuration from the manifest,
  from the downloaded `.app` file, or both? The prototype does both. One
  may be enough.
