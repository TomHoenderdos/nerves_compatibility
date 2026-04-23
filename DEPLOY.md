# Deploying

## Overview

Two logical services on two separate hosts:

| Host | Content | Backed by |
| --- | --- | --- |
| `compatibility.embedded-elixir.com` | The compat-tracker site (HTML/CSS/JS + small JSON indexes) | Cloudflare Pages |
| `prebuilt.embedded-elixir.com` *(TBD)* | Precompiled-binary API — `/manifests/<pkg>.json` + `/files/<sha256>` | Cloudflare R2 public bucket (or similar) |

Two hosts because they serve different users for different reasons: the tracker is a research surface, the binaries service is infrastructure that downstream Mix/Livebook code depends on. Splitting them lets each evolve independently and keeps their URL spaces clean.

## Configurable base URLs

All URL-containing output from the site goes through `Site.Config` (see `site/lib/site/config.ex`). Three env vars control where things live:

| Env var | Default | What it controls |
| --- | --- | --- |
| `SITE_BASE_URL` | `https://compatibility.embedded-elixir.com` | Canonical tracker host |
| `PRECOMPILED_FILES_BASE` | `${SITE_BASE_URL}/files` | Where `/files/<sha256>` blobs are served |
| `PRECOMPILED_MANIFESTS_BASE` | `${SITE_BASE_URL}/manifests` | Where `/manifests/<pkg>.json` is served |

Currently the emitted `public/site/manifests/_meta.json` records the active base URLs so downstream tooling doesn't have to hardcode them.

When the binaries service moves to its own host, set the two `PRECOMPILED_*` vars at site-gen time and everything downstream updates.

## Cloudflare Pages setup (one-time)

Wrangler runs via `npx` — no global install needed, just Node.js.

1. Authenticate (browser flow).
   ```bash
   npx wrangler login
   ```

2. Create the Pages project (once).
   ```bash
   npx wrangler pages project create compatibility-embedded-elixir
   ```

3. In the Cloudflare dashboard, wire a custom domain (`compatibility.embedded-elixir.com`) to the project. DNS gets added automatically if the domain is on Cloudflare.

## Deploying

From a clean state (orchestrator has populated `compat_test_results/`):

```bash
make deploy-site
```

The target:
1. Regenerates `public/site/` (via `make site`).
2. Re-runs the site generator with production env vars so URLs bake in.
3. Rsyncs `public/site/` into `public/.deploy/` excluding `files/` — the
   precompiled-binary blob store. Individual artifacts can exceed Pages'
   25 MiB per-file ceiling and the directory is destined for R2 anyway.
   `wrangler pages deploy` has no native exclude flag, so we stage first.
4. Rsyncs `public/data/logs/` into `public/.deploy/data/logs/` so the
   per-system log links on package pages resolve. Logs live outside
   `public/site/` locally but the package-page links are relative
   (`../../data/logs/…`), so they need to land at `/data/logs/` under
   the deploy root.
5. Invokes `npx wrangler pages deploy public/.deploy --project-name=compatibility-embedded-elixir`.

Wrangler prints a deployment preview URL; the custom domain updates when the deployment finishes propagating.

### Targeting a different base URL (staging, preview)

```bash
SITE_BASE_URL=https://staging.compatibility.embedded-elixir.com make deploy-site
```

### Pre-committing to a separate binaries host

```bash
PRECOMPILED_FILES_BASE=https://prebuilt.embedded-elixir.com/files \
PRECOMPILED_MANIFESTS_BASE=https://prebuilt.embedded-elixir.com/manifests \
make deploy-site
```

## When the site grows past Pages limits

Cloudflare Pages has a 20k-file-per-deployment ceiling and a 25MB-per-file ceiling. The tracker's HTML + indexes stay well under both. Two things will eventually force a split:

- **Logs.** `public/data/logs/<pkg>/<system>.log` hits 20k files quickly — each package contributes a handful. Move logs to R2 with a rewrite rule when the count gets uncomfortable.
- **Precompiled files.** The `/files/<sha256>` blob store is designed to grow unboundedly. Put this on R2 from day one when you stand up the binaries host.

Both moves are purely additive: update the two `PRECOMPILED_*` env vars (for `/files/…`) or introduce a new one for logs, regenerate, redeploy.
