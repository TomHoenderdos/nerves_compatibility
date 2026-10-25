# Build sandbox isolation

Date: 2026-10-21. Status: v4, approved for planning after three review rounds.

## Problem

A package's `mix.exs` runs arbitrary code inside the build container, as the
build uid. Three bind mounts are read-write and shared by every later build on
the host, so one malicious package can change what every subsequent build of
every other package produces:

| Mount | What a build can do today | Who is affected |
| --- | --- | --- |
| `/home/nerves/.nerves` | Replace toolchain binaries or `images/rootfs.tar` under `artifacts/<system>-<ver>/`. Nerves only checks the `.fingerprint` file, not contents. | Every firmware of every package built afterwards on that host. |
| `/build-cache/<image slug>` | Write a poisoned `_build/<target>/lib/<dep>` under any cache key. `BuildCache.restore/1` copies without checking. | Every later package whose closure resolves to that key, including files published through the precompiled API. |
| `/hex-cache` | Tamper with tarballs or `cache.ets`, or fill the disk. | Tampering is contained: Hex verifies the registry signature and tarball checksums, so a modified tarball fails the build rather than spreading. Disk fill is not contained. |

Two more issues are not cross-package but worth closing in the same pass:

- Egress is unrestricted. A build can reach the tailnet from the builder,
  including the web host's Postgres on its tailscale address, over v4 and v6.
- `/app` and `/home/nerves` are `chmod a+rwX` in the image, so a build can
  overwrite the argus escript or the worker's own beams before they run later
  in the same container. Ephemeral, one run only.

`docs/PRECOMPILED_SIGNING_PROPOSALS.md` names the first two as prerequisites
1 and 2 for signed precompiled files. This spec is how they get built.

## Goals

1. Nothing a build writes survives the container except `/out` and `/files`
   (per run, read by trusted host code) and new Hex tarballs in `/hex-cache`
   (content-addressed and checksum-verified by Hex, bounded in size).
2. The Nerves cache and the build cache are read-only inside a build container.
3. The Nerves cache is written only by code the image already trusts: the
   template project and packages owned by the `nerves` Hex user. What gets
   warmed is bounded per run and in total, so an untrusted miss list cannot
   drive unbounded trusted downloads.
4. A build-cache entry for dependency D is written only by D's own check run,
   and the host, not the worker, decides which key a candidate lands under.
   Poisoning D's entry then requires code in D's own closure, which already
   owns D's build.
5. A build cannot reach private networks from the container, over v4 or v6,
   and a host whose filter is missing refuses to build rather than building
   unfiltered.
6. No change to results for honest packages; the integration test still passes.

Non-goals: kernel escapes (rootless, seccomp and `cap-drop=ALL` stay as they
are) and validating `result.json` claims beyond what sections 1 and 2 need
(prerequisite 4 in the proposals document, separate work).

## Design

### 1. Nerves cache: read-only mount, per-run symlink farm, trusted warm job

`Portal.Builder` mounts `nerves_cache()` at `/nerves-cache` with `readonly`.
In every mode the worker sets `NERVES_ARTIFACTS_DIR` and `NERVES_DL_DIR`
explicitly (Nerves 2.0.0-pre.3 `Nerves.Paths` reads both); nothing refers to
`/home/nerves/.nerves` once this lands, including the fallback mode below.

**Build mode.** At run start the worker builds a per-run artifact directory
in scratch: `/work/nerves/artifacts/` holds one symlink per entry of
`/nerves-cache/artifacts/`, and `/work/nerves/dl/` is an empty directory.
Both env vars point there for every `mix` invocation. An artifact the cache
has is resolved through its symlink (`.fingerprint` check, rootfs and
toolchain reads all follow the link). An artifact the cache lacks is
downloaded and extracted by Nerves into the per-run directory and the build
succeeds. On a fingerprint mismatch Nerves runs `File.rm_rf!` on the entry;
on a symlink that removes the link, not the target, so the fresh extraction
lands in the run dir and the cache is untouched. Nothing is written to
`/nerves-cache`.

After `deps.get` the worker diffs the run dir against the farm: every entry
that is now a real directory is listed in `result.json` under
`nerves_cache.misses` as `%{name, version}`. No fingerprint: the worker's
report is untrusted, and the only fingerprint the host ever acts on is the
one the warm job produces itself. The worker also
includes the run's `mix.lock` entries for packages whose name starts with
`nerves_system_` or `nerves_toolchain_` under `nerves_cache.lock`.

**What the host warms.** `Portal.Workers.Build` turns misses into warm
requests under three limits, all host-side and independent of what the
worker reported:

- a pair is kept only if it appears in `nerves_cache.lock` (a forged lock
  still only passes the next two filters);
- a pair is kept only if `Portal.HexPm.owners(name)` returns a list that
  includes the username `nerves` (checked against the live API and cached
  for a day; the four packages sampled on 2026-10-21 are all owned by that
  single user, under the `hexpm` repository);
- at most four pairs per run (`@warm_pairs_per_run`), the first four in
  lock order;
- a `{image_digest, name, version}` warmed in the last day is skipped
  (remembered in the `WarmNerves` job's uniqueness over completed jobs), so
  a run that reports the same misses again cannot churn the download.

A system published by anyone else keeps working through the per-run
extraction; it is just never cached. `Portal.Workers.Sweep` gains a size
bound for `nerves_cache()/artifacts` (`NCC_NERVES_CACHE_MAX_GB`, default 40),
evicting by mtime, oldest first, never the versions the template currently
resolves.

**Warm job.** `Portal.Workers.WarmNerves` runs on the node-local queue
(`Portal.Workers.Ingest.local_queue/0` pattern) with concurrency 1, so it
runs on the host whose cache missed and never beside another warm. Args:
`image_digest` and the filtered pairs. Jobs are unique on digest and pairs
for a day over the states scheduled, available, executing, retryable and
completed, which is the repeat bound above. Discarded and cancelled are
left out on purpose: a warm that failed (Hex down, bad download) must not
block the retry until tomorrow.

The job runs the worker with `NCC_INPUT.mode: "warm_nerves"` and the pairs.
The worker creates the template project, pins each pair with
`{name, "== version", runtime: false}` the way `systems_override` already
pins, and runs `mix deps.get` per target with `NERVES_ARTIFACTS_DIR` set to
`/nerves-cache/staging/<run_id>/artifacts` and `NERVES_DL_DIR` to
`/nerves-cache/staging/<run_id>/dl`. The container has `/nerves-cache`
mounted read-write and runs no package code beyond the template and the
allowlisted Nerves packages. When `deps.get` succeeds the worker, for each
`staging/<run_id>/artifacts/<name>-<version>`:

- if `artifacts/<name>-<version>` does not exist, renames it into place;
- if it exists and its `.fingerprint` equals the staging entry's, leaves it
  alone (a concurrent build already warmed it);
- if it exists and its `.fingerprint` differs from the staging entry's,
  renames the old entry to `artifacts/<name>-<version>.stale.<run_id>` and
  the new one into place. This is how a corrupt entry heals instead of
  missing forever, and the comparison is between two things trusted code
  wrote, never against what a build reported.

All renames are within one filesystem, so a concurrent build sees either no
entry (and extracts privately), the old complete one, or the new complete
one. The staging dir and any `.stale.*` dirs are removed at the end of the
job; Sweep prunes both when older than three hours. A build that was
mid-run through its symlink when an entry was replaced resolves later
reads to the new entry, so it may mix old and new files of the same
version. Accepted: identical content makes it harmless, and a corrupt old
entry was failing that build anyway.

No drain and no queue pause: builds only read the mount, the warm job only
renames complete directories into it. The rpi5 "corrupt artifact" race of
2026-10-17 to 10-20 disappears because no build extracts into the shared
directory any more.

**Deploy-time warm.** `ops/builder-deploy.sh` runs the warm container
synchronously after `builder_build_image` and before the queues resume, with
no pairs, so the template's own resolution is in the cache before the first
build. It is a `docker run` from the script, not an Oban job, because a
`:builds` job runs on whichever host polls first.

**Fallback toggle.** `NCC_NERVES_CACHE_RW=1` in `portal.env` drops the
`readonly` flag and the symlink farm for one release: the worker then sets
`NERVES_ARTIFACTS_DIR=/nerves-cache/artifacts` and
`NERVES_DL_DIR=/nerves-cache/dl` directly, which is today's behaviour under
new names. Removed in the release after.

### 2. Build cache: read-only mount, host-derived keys, promoted for the checked package only

Inside a build container `/build-cache` is mounted `readonly`.
`BuildCache.restore/1` reads from it as now. `BuildCache.store/1` writes each
candidate entry to `/out/build-cache/<key>/` with `cp -a` and records every
input of the key per candidate in `result.json` under `cache.candidates`:
`%{key, dep, dep_lock, target, elixir, otp, closure: [%{name, lock}]}` where
`dep_lock` and each closure `lock` are the strings `key_for/4` already builds
from the lock (`"version checksum outer"` or `"unlocked"`). **Amended
2026-10-22 during planning:** the candidate carries `elixir`
(`System.version()`) and `otp` (`:erlang.system_info(:otp_release)`) itself,
as the worker saw them when it hashed the key. The host also requires them
to equal `result.json.toolchain.elixir` and `.erlang`, which the worker builds
from the same two calls (corrected 2026-10-24: an earlier note here said the
`erlang` field was formatted differently; it is not). Both are
container-reported either way; forcing the dependency name below is what
makes the key safe.

After the container exits with a result, `Portal.Workers.Build` considers
only candidates whose `dep` equals the package under test and whose
`dep_lock` first space-separated field equals the version under test
exactly (so `1.0` never matches `1.0.0`) and whose second field equals the
Hex inner checksum the portal already holds for that release
(`Portal.HexPm` release lookup, cached), which ties the candidate to the
real tarball. For each it **recomputes the key** with the same function as
the worker (`v2`, the candidate's own `elixir` and `otp` strings, `target`,
`dep` forced to the package under test, `dep_lock`, sorted closure),
requires the reported key to equal the recomputed one, and only then uses
the recomputed key for both the source path under `/out/build-cache/` and
the destination. The reported string never touches the filesystem; the
equality check also gives the 64-hex guarantee. A candidate whose reported
key differs is refused and logged, since the only way to get there is a
worker that lies.
Because the dep name is an input to the hash and the host forces it, a
candidate can only ever land under a slot that belongs to the package under
test; landing under another package's slot would need a preimage. The key
function moves to `Compatibility.BuildCacheKey` in `apps/compatibility` so
worker and portal share one implementation.

A promoted candidate must also pass: the tree, and `out/` and
`out/build-cache` above it, are real directories by `File.lstat/1`, never a
symlink (**amended 2026-10-22, discovered during execution**); every regular
file in the tree has a link count of 1; and `<build_cache>/<slug>/<key>`
does not already exist. **Amended 2026-10-22 during planning:** a flat ban
on symlinks would refuse most of the cache — production entries on the main
builder carry Mix's own links, 66 in one slug, every one of the form
`<entry>/priv -> ../../../../deps/jose/priv` or
`<entry>/include -> ../../../../deps_bbb/backpex/include`. The rule instead
is that a tree may contain symlinks only at its top level, only named `priv`
or `include`, and only with a target exactly matching
`../../../../<deps_dir>/<dep>/<same name>` where `<deps_dir>` is `deps` or
`deps_<target>`
(`~r/\A\.\.\/\.\.\/\.\.\/\.\.\/deps(_[a-z0-9_]+)?\/<dep>\/(priv|include)\z/`).
Every other symlink, and every regular file with a link count above 1,
refuses the candidate. **Amended 2026-10-22, discovered during execution:**
the walk also refuses any name that is not valid UTF-8, since it is listed
with `:file.list_dir_all/1` rather than `File.ls/1` — which silently drops
non-UTF-8 names on Linux, and such a name would otherwise be promoted
unchecked; every real Mix artifact name is UTF-8. Everything else in
`/out/build-cache/` is ignored and removed with the scratch dir.

Promotion is `File.rename` from `/out/build-cache/<recomputed key>` to a
staging name under the slug directory and a second rename into place.
**Amended 2026-10-22 during planning:** rather than a boot-time `stat -f`
check that scratch and the build cache share a filesystem, promotion tries
the rename directly and on `{:error, :exdev}` falls back to `cp -a` into the
staging name followed by a rename. The error is the check; a boot-time
`stat -f` could still be wrong if an operator remounts either path without
restarting the portal.

This changes who fills the cache. Today P's run stores every dependency P
compiled; after this, D's entry appears when D itself is checked, which the
service does for every package on Hex. The hit rate is lower than before,
not unchanged as first written: a dependency's key covers its resolved
subtree, so even `jason` has more than one key (with and without `decimal`
in its closure), and only the variant its own check resolves gets promoted;
and since amendment 7 a pure-Elixir dependency's `target=any` entry is never
promoted at all. It is lower still for dependencies whose own resolution
differs from the one inside P; `cache_restored` in
`phase_timings` is already recorded and will show the difference. The worker
keeps excluding the package under test from `restore` (it must be compiled
fresh to be tested) but no longer excludes it from `store`.

**Amended 2026-10-22 during planning: a run-local tier for every other
dependency.** The paragraph above describes only the package under test.
Ending storage of every other dependency into the shared cache, as drafted,
would also end in-run sharing: a pure-Elixir dependency keys on
`target=any`, so today a nine-target run compiles it once and eight targets
restore it. Without that, any dependency not yet in the shared cache (the
long tail, a new release, every dependency on a fresh host) compiles once
per target. So the worker keeps its old store behaviour for dependencies
other than the package under test, but pointed at a run-local root,
`Path.join(System.tmp_dir!(), "ncc-build-cache")` inside the container (the
per-run scratch bind from section 4), and `restore/1` reads the shared
read-only root first and the run-local root second. Everything in the
local tier was produced by this run's own code and dies with the run, so it
needs no promotion and no trust.

**Amended 2026-10-22 during planning: sweep and entry ageing are unchanged.**
`Portal.Workers.Sweep` prunes whole per-image slugs (any slug that is not
the current image's or a queued build's, after a 7-day mtime grace) and
never ages single entries inside a kept slug; `restore/1` never touched
entries. A read-only mount therefore changes nothing about cache lifetime
and no host-side touch on restore is needed.

**Amended 2026-10-22 during planning: what the integration test can show.**
The jason integration build is the package under test, which is never
restored from the shared cache, so "a second run restores it" cannot be
demonstrated with jason alone. The integration test instead asserts
promotion — only jason's keys appear under the slug directory, and each
recomputes to the key `result.json` reported; restoring a promoted entry is
covered by worker unit tests instead (`NccWorker.BuildCacheTest`).

**Amendment 7. Amended 2026-10-24 by the operator:** pure-Elixir packages are
checked with a host compile only, so no run produces their `target=any`
entries and firmware builds of other packages compile pure-Elixir
dependencies cold once per run (the run-local tier keeps it to once, not
once per target). Accepted and to be measured with `phase_timings`
`cache_restored` vs `cache_candidates` per target before and after the
deploy; a targeted target-compile for packages firmware builds depend on is
the follow-up if it hurts.

### 3. Egress filter inside the rootless daemon's network namespace, fail closed

On every build host the portal and rootless `dockerd` run as the same uid
(999 on the main builder, 950 on box-a and box-c), and the daemon uses
slirp4netns. Container traffic leaves the host as ordinary sockets of that
uid, so neither a host bridge rule nor `meta skuid` can separate builds from
the portal's own Postgres connections. The rules therefore go inside the
daemon's network namespace, where the bridge exists and `CAP_NET_ADMIN` is
mapped to the rootless user:

```
nsenter -U --preserve-credentials -n -t "$(cat "$XDG_RUNTIME_DIR/docker.pid")" nft -f /etc/ncc-portal/builder-egress.nft
```

`ops/builder-egress.nft` declares its own table `inet ncc_egress` and starts
with `flush table inet ncc_egress` (never `flush ruleset`: rootless dockerd
keeps its NAT rules in iptables-nft in the same namespace). Rules on the
bridge interface, keyed on the name read from `docker network inspect
bridge`:

- allow UDP/TCP 53 to the resolver slirp4netns provides (`10.0.2.3`);
- allow to the slirp gateway `10.0.2.2/32` only on 53 (nothing else lives
  there);
- drop to the bridge subnet itself (no container needs another container;
  equivalently `--icc=false` on the daemon, but the rule is visible here);
- drop to `100.64.0.0/10`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`,
  `169.254.0.0/16`, `127.0.0.0/8`;
- drop to `fd7a:115c:a1e0::/48` (tailnet), `fc00::/7`, `fe80::/10`, `::1`;
- allow TCP 443 and 80 to anything left;
- drop the rest.

Hex.pm, GitHub and the ubuntu mirror all sit on 443, so builds keep working.
Because slirp4netns performs the NAT in user space after the bridge, a drop
in the namespace stops the packet before it ever becomes a host socket.

**Installed on every daemon start, not only on deploy.** The namespace is
recreated whenever rootless dockerd restarts (reboot, crash,
`systemctl --user restart docker`), and the rules with it. `ops/deploy.sh`
installs a drop-in for the rootless docker user unit with
`ExecStartPost=` running a small script: wait for `docker info` to succeed
(bounded, 60 s), then the nsenter line. Upstream's rootless unit is
`Type=notify`, under which `ExecStartPost` already runs after readiness,
but the wait makes the drop-in correct whatever the unit type on the host
and whatever `docker.pid` timing is. The ruleset is copied to
`/etc/ncc-portal/builder-egress.nft` by the deploy script, owned root, mode
644.

**Fail closed.** `Portal.Builder` gains a preflight next to
`check_free_space`: `nsenter ... nft list table inet ncc_egress` must
succeed and contain the chain name, otherwise `build/2` returns
`{:error, :egress_filter_missing}`, which `Portal.Workers.Build` treats like
insufficient disk: cleanup, `{:snooze, 900}`, and a logged error. The check
is also run at boot and logged. `NCC_EGRESS_CHECK=0` disables the preflight
on a host that has no rootless daemon (the integration test's laptop).

Measured before implementation (plan task) on all three hosts: `nsenter ...
nft list ruleset` works unprivileged; the `nf_tables`, `nft_compat` and
`nf_tables_inet` modules are loaded on the host (an unprivileged namespace
cannot modprobe, so `/etc/modules-load.d/ncc-nftables.conf` lists them if
not); the rootless docker user unit's `Type=` and whether any drop-in
changes it; and after the rules load a bare container cannot reach the web
host's Postgres over v4 or v6. Same task: confirm
`GET /api/packages/:name/owners` answers unauthenticated and note its rate
limit, since the first cold miss on three hosts hits it at the same time
before the day's cache exists.

### 4. Container hardening

In `Portal.Builder.build_docker_args/4`:

- `--read-only` root filesystem, with `/tmp` and `/home/nerves/.cache`
  bind-mounted from two new per-run scratch directories (`<scratch>/tmp`,
  `<scratch>/cache`) rather than tmpfs. A tmpfs would be RAM-backed and
  need a size budget measured against `NCC_BUILD_CONCURRENCY` times the
  largest `mix firmware` (fwup, mksquashfs, fakeroot all use `/tmp`); a
  scratch bind is disk-backed on the same filesystem `check_free_space`
  already guards, needs no budget, allows `exec`, and is removed by
  `cleanup/1` with the rest of the run. rebar3's `~/.cache/rebar3` is what
  the second one is for.
- `--pids-limit 4096`.
- Dockerfile: replace `chmod -R a+rwX /home/nerves /app` with `a+rX`. The
  build uid still differs from the image's `nerves` user on hosts that do not
  set `NCC_BUILD_USER=0:0`, so world-readable is still required; writable is
  not, since `--read-only` would refuse the write anyway. `MIX_HOME` and
  `MIX_ARCHIVES` stay at `/home/nerves/.mix`, read-only use.

`/hex-cache` stays read-write. Hex has to write new tarballs every build, its
registry is signed, and its tarballs are verified against the lock's
checksums on unpack, so tampering cannot spread. What remains is disk fill:
`Portal.Workers.Sweep` gains a size bound for `hex_cache()/packages`
(`NCC_HEX_CACHE_MAX_GB`, default 20), evicting by mtime, oldest first; a
tarball evicted is simply re-fetched. mtime rather than atime because the
hosts mount with `relatime`, which makes atime unreliable for this.

## Data contract changes

`NCC_INPUT.mode` gains `"warm_nerves"` with `nerves_packages: [%{name,
version}]`. `result.json.scope` gains `"warm_nerves"`.
`result.json` gains `nerves_cache: %{misses: [...], lock: [...]}` and
`cache: %{candidates: [%{key, dep, dep_lock, target, closure}]}`, both absent
when not applicable. `apps/ncc_worker/README.md`, the typespec at the top of
`worker.ex`, and CLAUDE.md's "How a Package Gets Checked" and "Container /
Caching Details" sections are updated.

## Rollout

Each section is its own branch and deploy, in the order 4, 2, 1, 3: hardening
first because it is the smallest and tells us what else writes outside the
allowed paths; build cache before Nerves cache because it has no host-side
warm dependency; egress last because it needs the per-host measurement.
Sections 1 and 2 need worker and portal to land together, which a main
deploy does (portal, then builder). box-a and box-c are deployed by hand
after each, as today.

Rollback for 1 is `NCC_NERVES_CACHE_RW=1` and a restart. Rollback for 2 and
4 is redeploying the previous commit. Rollback for 3 is `NCC_EGRESS_CHECK=0`
plus `nft delete table inet ncc_egress` in the namespace.

## Testing

- `Portal.BuilderTest`: `readonly` on the Nerves and build-cache mounts for
  a build job and read-write for a warm job; `--read-only`, the `/tmp` and
  `/home/nerves/.cache` scratch binds, `--pids-limit` present; `NCC_NERVES_CACHE_RW=1` drops the flag and the
  farm env; the egress preflight returns `{:error, :egress_filter_missing}`
  when the `nft` probe fails and passes when it lists the table (probe
  injected as a function in config, as `check_free_space` injects `df`).
- `Compatibility.BuildCacheKeyTest`: the key function matches the vectors
  the worker's existing `key_for/4` test uses.
- `NccWorker.BuildCacheTest`: `store/1` writes candidates with their key
  inputs under the out dir and never under the root; `restore/1` unchanged;
  the package under test is stored but not restored.
- `NccWorker.NervesCacheTest` (new): the symlink farm mirrors the read-only
  dir; `misses` lists only real directories; `lock` lists only
  `nerves_system_*` and `nerves_toolchain_*`; warm mode renames a new entry
  into place, leaves a same-fingerprint entry alone, and replaces a
  different-fingerprint entry, comparing against the staging entry's own
  `.fingerprint`. One test reproduces Nerves'
  fingerprint-mismatch path, `File.rm_rf!` on a farm entry followed by
  `mkdir_p` and a write: the cache directory behind the link is untouched
  and the fresh entry is a real directory in the run dir that `misses`
  reports. That is the one place the farm behaves differently from a real
  directory, so it gets its own assertion.
- `Portal.Workers.BuildTest`: promotion accepts only the checked package's
  candidates (exact version field, checksum equal to the Hex release's) and
  lands them under the recomputed key; refuses a candidate whose reported
  key differs from the recomputed one without touching
  `/out/build-cache/<reported key>`; refuses symlinks, hardlinks and
  existing keys. Warm requests: pairs not in the lock, not
  owned by `nerves` (HexPm stubbed), or beyond the per-run cap are dropped.
- `Portal.Workers.WarmNervesTest`: unique per digest and pairs; node-local
  queue; concurrency 1 in the Oban config test.
- `Portal.Workers.SweepTest`: both size bounds evict by mtime and the Nerves
  bound never evicts the template's current versions; stale and staging dirs
  older than three hours are removed.
- Integration test: a warm run with no pairs, then the jason build with
  `NCC_BUILD_CACHE` set, asserting the Nerves mount args are read-only, the
  cache gained jason's key and nothing else, and a second run restores it.
  A follow-up integration case adds a one-dependency package and asserts
  only that package's key was promoted.
- Egress, recorded in `ops/README.md` as the check to repeat on each host
  after a deploy: with `NCC_EGRESS_PROBE=1` the worker, before `deps.get`,
  tries a TCP connect to the web host's Postgres address over v4 and v6 and
  writes the outcome to `result.json.egress_probe`; the check runs one real
  build of a one-dependency package and expects both to be refused. Plus a
  bare container `nc -zw2` to the same address, expected to fail.

## Open points

- The nsenter and module measurement (section 3) is a plan task that comes
  before its implementation tasks.
- A deploy-time warm with nine targets on a cold cache is about 2 GB of
  downloads. Acceptable after a deploy, which already drains.
