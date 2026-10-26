# Shared build cache (L2)

## Overview

The portal's dependency build cache (`NCC_BUILD_CACHE`) is a directory on each build host. L2 adds a shared S3 bucket behind it, served by Garage on `box-b`, so a dependency compiled once on one home host is restored on the others. The local directory is unchanged and is the only thing a build container sees (read-only at `/build-cache`); the worker does not know L2 exists.

Before each `docker run`, `Portal.Builder` lists the bucket under the worker image's slug and downloads the objects missing locally, newest first, within 2 GiB and 5 minutes per build. After each local promotion, `Portal.BuildCache.Promotion` uploads the new entry, best effort. A failed or slow L2 never fails a build. Objects are named `<slug>/<key>.tar.gz` with `x-amz-meta-sha256`; each is a gzip tar of one entry with no symlink members (Mix's `priv`/`include` links travel in a `.ncc-links.json` manifest), and the structure is re-checked on extract with the same walker Promotion uses. Trust rests on the write key: only a holder of the read-write key can put an object there. The design is in `docs/superpowers/specs/2026-10-26-build-cache-l2-design.md`; the operator-facing summary is in [DEPLOY.md](../DEPLOY.md#shared-build-cache-l2).

## Garage on box-b

The module below was written against NixOS 25.05 and `pkgs.garage_1`; `garage.toml` keys are stable across 1.x, but option names (notably `environmentFile`) must match the `services.garage` module of your channel. It has not been verified against a NixOS evaluation. `rpc_secret`, the admin token and the tailnet address are yours: generate each secret with `openssl rand -hex 32` and keep them in `/etc/garage/secrets.env` (`GARAGE_RPC_SECRET`, `GARAGE_ADMIN_TOKEN`), outside the store. `garage.toml` is what the module renders (`/etc/garage.toml`).

```nix
{ config, pkgs, ... }:
let
  # The tailnet address of box-b; S3 is served only there.
  tailnetAddr = "100.64.0.2";
in
{
  services.garage = {
    enable = true;
    package = pkgs.garage_1;
    settings = {
      metadata_dir = "/srv/garage/meta";
      data_dir = "/srv/garage/data";
      db_engine = "sqlite";
      replication_factor = 1;
      compression_level = 1;
      rpc_bind_addr = "127.0.0.1:3901";
      rpc_public_addr = "127.0.0.1:3901";
      s3_api = {
        s3_region = "garage";
        api_bind_addr = "${tailnetAddr}:3900";
        root_domain = ".s3.garage.localhost";
      };
      admin = {
        api_bind_addr = "127.0.0.1:3903";
      };
    };
    # rpc_secret and admin_token: 32 random bytes as hex each, kept out of
    # the store (`openssl rand -hex 32`), e.g. via sops-nix or an
    # EnvironmentFile holding GARAGE_RPC_SECRET and GARAGE_ADMIN_TOKEN.
    environmentFile = "/etc/garage/secrets.env";
  };

  systemd.tmpfiles.rules = [
    "d /srv/garage 0750 root root -"
    "d /srv/garage/meta 0750 root root -"
    "d /srv/garage/data 0750 root root -"
  ];

  # Only the tailnet reaches S3; nothing is opened on other interfaces.
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 3900 ];
}
```

## Layout, bucket and keys

Run on box-b as root; `garage` reads `/etc/garage.toml`.

```bash
garage status                                   # note the node id
garage layout assign -z home -c 500G <node-id>  # one zone, one node
garage layout apply --version 1
garage bucket create ncc-build-cache
garage key create ncc-build-cache-rw
garage key create ncc-build-cache-ro
garage bucket allow --read --write ncc-build-cache --key ncc-build-cache-rw
garage bucket allow --read         ncc-build-cache --key ncc-build-cache-ro
garage key info ncc-build-cache-rw --show-secret   # access key id + secret for the home hosts
garage key info ncc-build-cache-ro --show-secret   # for a read-only host, later
```

## Home hosts

On each home build host add to `/etc/ncc-portal/portal.env`, with the read-write key:

```
NCC_BUILD_CACHE=/home/ncc/.ncc-build-cache
NCC_BUILD_CACHE_S3_ENDPOINT=http://100.64.0.2:3900
NCC_BUILD_CACHE_S3_BUCKET=ncc-build-cache
NCC_BUILD_CACHE_S3_REGION=garage
NCC_BUILD_CACHE_S3_ACCESS_KEY=<rw key id>
NCC_BUILD_CACHE_S3_SECRET_KEY=<rw secret>
```

`NCC_BUILD_CACHE` (use your host's existing path) must be set: L2 is off without a local cache. A host with the read-only key also sets `NCC_BUILD_CACHE_S3_READ_ONLY=1`. Then restart the portal. The boot log has `Build cache L2 on: http://100.64.0.2:3900/ncc-build-cache` (`Build cache L2 off`, or a warning, if the configuration is missing or incomplete). The Maintenance tab at `/admin` shows a "Build cache L2" card: state, endpoint and bucket, read-only, last upload and download, and counters since boot on that node (on a split deployment the web node's, which are zero).

Every home host must run the same worker image by digest: entries are shared only under one image slug. A locally built `ncc-worker:local` has its own slug.

## First push

Seed the bucket from a host's existing cache once, in bounded steps:

```bash
mix portal.build_cache.push --limit 500            # also --max-gb G, --slug S, --dry-run
bin/portal eval 'Portal.BuildCache.L2.Push.run(limit: 500) |> IO.inspect()'   # on a deployed host
```

Use the first form on a checkout and the second on a deployed release. It is resumable: a HEAD per entry is the state, so rerunning skips what is already in the bucket. `--dry-run` reports what would be uploaded.

## Verification

On box-b, `garage bucket info ncc-build-cache` shows the object count and size growing after a push or a few builds. On a home host, look for `Build cache L2 upload of <slug>/<key>.tar.gz: N bytes` after a promotion, and `Build cache L2 prefetch for <run>: N downloaded, ...` in the portal log (and in the run's `runner.log`) before a build. The Maintenance tab's counters and last upload/download times should move too. A second host starting a build on a slug the first has filled should report downloads on its first build.

## Key rotation

Create a new key (`garage key create ncc-build-cache-rw2`), grant it the same `bucket allow` rights, update `NCC_BUILD_CACHE_S3_ACCESS_KEY` and `NCC_BUILD_CACHE_S3_SECRET_KEY` on each host and restart, then `garage key delete` the old one. Objects are not tied to a key. If the read-write key may have leaked, treat the bucket's contents as untrusted: rotate, then empty the bucket (or the affected prefixes) and re-push from a host you trust.

## Pruning

Not automated. When an image is retired, delete its prefix from the bucket with `mc rm --recursive` against the Garage endpoint, or with Garage's own object tooling.

## What L2 does not do

* Remote builders (`ncc_agent`) never touch L2; they run with no build cache.
* Contabo and other hosts that are not on the tailnet do not use it. A host that should only read gets the read-only key and `NCC_BUILD_CACHE_S3_READ_ONLY=1`.
* No pruning or expiry of the bucket, and no change to the worker.
* Staging names are `<key>.tmp.<host>.<hex>`; `Portal.Workers.Sweep` prunes only its own host's (or the older host-less ones), and only past the scratch max age, so hosts never remove each other's in-flight files.
