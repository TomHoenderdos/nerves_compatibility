# Serving precompiled files through a CDN

The precompiled API (`PRECOMPILED_API.md`) can be fronted by any pull CDN.
The CDN carries the content-addressed bytes (files and manifests by
SHA256); the portal keeps signing and serving the small trust documents.
Clients learn about the CDN only from the signed batch, and check every
byte they get from it against hashes the portal signed, so a CDN that
misbehaves causes a fallback to the portal, never a wrong install.

The CDN never needs the signing key, a portal credential, or any other
secret: everything it serves is either public, content-addressed bytes a
client re-hashes itself, or short-lived signed metadata it is never asked
to produce, only to relay.

## 1. Create a pull zone

Any provider works (Bunny, Cloudflare, others). Placeholders used below:

- Portal API (origin): `https://portal.example/api/precompiled`
- CDN hostname: `https://cdn.example`

Set the pull zone's origin URL to the portal's API prefix, so that
`https://cdn.example/files/<sha256>` is fetched from
`https://portal.example/api/precompiled/files/<sha256>`. If the provider only
takes a host as origin, put the CDN under a matching path prefix instead
and configure the content origin with that path (for example
`https://cdn.example/api/precompiled`): a content origin may carry a path,
and clients append the same relative paths to it as to the source.

## 2. What to cache

Cache these, honoring the origin's headers
(`cache-control: public, max-age=31536000, immutable`, an `etag` of the
SHA256):

| Path under the origin | Notes |
| --- | --- |
| `/files/<sha256>` | precompiled files |
| `/manifests/by-sha/<sha256>.json` | format-1 manifests |
| `/v2/manifests/by-sha/<sha256>.json` | format-2 manifests |
| `/systems/by-sha/<sha256>.json` | systems tables (`systems` in the batch) |

Settings for these paths:

- Respect origin cache headers (or set the edge TTL to one year).
- Ignore or strip query strings: the URL path is the whole cache key.
- Do not cache error responses. The portal marks every 404 `no-store`; a
  file can be missing for a few minutes after a build and present after.
- Leave the bytes alone: no minification, image optimization, script
  injection or HTML rewriting. Transparent compression is fine; clients
  hash the decoded body.

## 3. What to bypass

Only the four content-addressed path families in section 2 belong on the
CDN. Everything else is fetched by clients only from the portal (the
source), never from a content origin. Do not cache any of it on the CDN;
blocking it there (a 404, or simply not proxying the path) is fine and is
the safer default — the CDN should allow-list the paths it caches rather
than cache by default and bypass a list:

- `/root.json`, `/batch.json`, `/batches/<n>.json`: signed metadata, short
  lived (`public, max-age=60, must-revalidate`, revalidated by `etag`)
- `/manifests/<package>.json`, `/v2/manifests/<package>.json`: change with
  every batch (`private, max-age=60`)
- every other path under the origin (and anything outside `/api/precompiled`,
  such as the site, `/api/packages` and admin routes; the builder API runs on
  its own endpoint) — none of it is
  content-addressed, so none of it belongs on a pull zone built for this API

## 4. Turn it on

1. Check the zone: `curl -sI https://cdn.example/files/<a sha256 from any manifest>`
   answers `200` with the immutable `cache-control`, and the body's SHA256
   equals the name.
2. Set `NCC_PRECOMPILED_CONTENT_ORIGINS=https://cdn.example` in the portal's
   environment (comma-separate several; https only, no trailing slash, no
   query) and **restart the portal**: the setting is read once at boot
   (`Portal.Precompiled.Content.origins/0` reads `Application.get_env/2`, not
   the environment live), so a change takes effect only after a restart, not
   on its own. An invalid value is logged at boot and ignored as a whole;
   batches keep signing without it.
3. The next batch (at most 15 minutes) carries
   `"content": ["https://cdn.example"]` in its signed payload. Check it:

   ```sh
   curl -s https://portal.example/api/precompiled/batch.json \
     | jq -r .payload | tr '_-' '/+' | base64 -d 2>/dev/null | jq .content
   ```

## 5. Why nothing here needs purging or eviction

A SHA256 path never changes meaning, so neither the CDN nor the portal's own
disk housekeeping (`Portal.Workers.Sweep`) ever has to evict a manifest or
file blob on the strength of a newer batch existing:

- **Withdrawn manifests stay servable by sha.** When a build is withdrawn,
  the next batch simply stops naming its manifest sha in `manifests` /
  `manifests_v2`; the old manifest is not deleted and the by-sha routes keep
  serving it. Its files may stop being served by the source (`files/<sha>`
  only serves published files), but a CDN copy can outlive that; purge them
  when a revoked builder's files must be pulled. This is safe because withdrawal is
  enforced client-side by the batch, not by the server refusing old bytes: a
  verified client only ever asks for a sha the *current* batch it checked
  names, so a sha no current batch names is simply never requested by a
  conforming client. A sha still named by an older (but still fresh, within
  its 24-hour freshness bound) batch legitimately stays fetchable, which is
  exactly the property that makes serving it safe to leave to the CDN's
  normal one-year cache instead of trying to invalidate it.
- **The portal never evicts a manifest or file blob a batch named.**
  `Portal.ArtifactStore` (the file blob store) has no eviction path at all,
  and `Portal.Workers.Sweep`, the host's disk-reclaiming worker, never
  touches it either — Sweep only reclaims build scratch directories, the
  dependency build cache, the Hex cache and the Nerves cache, all of which
  are rebuildable working storage, never the published artifact or manifest
  stores. A CDN or mirror in front of this API must hold to the same rule:
  never evict a `/files/<sha256>`, `*/manifests/by-sha/<sha256>.json` or
  `/systems/by-sha/<sha256>.json` object it has ever served, for the same reason the portal doesn't — an
  older, still-fresh client's batch may still name it.
- **Purging is only for taking bytes off the CDN outright** — for example on
  a legal request — never for correctness. The cached paths (section 2) never
  need it in the ordinary course of operation.

## 6. Turn it off

Unset `NCC_PRECOMPILED_CONTENT_ORIGINS` and restart. The next batch has no
`content`, and each client stops using the CDN at its next run, when it
fetches that batch. Keep the zone serving for 24 hours afterwards: a client
that cannot reach the portal may keep using a cached batch for up to a day.
