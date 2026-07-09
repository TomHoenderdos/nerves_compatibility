# Request Visibility — Design

**Date:** 2026-07-08
**Status:** Approved (direction + scope)
**Scope:** Portal dynamic app — make in-flight scan requests visible on `/packages` as
placeholders, and show a post-submit confirmation panel on `/request-scan` linking to
each requested package's progress page.

## Goal

Close two UX gaps surfaced after the Dashboard work:
1. A requested package is invisible on `/packages` until its build ingests — users see
   no trace of what's being scanned.
2. A multi-package request has no combined "here's what you just submitted" view.

No users/accounts introduced (deliberately out of scope for a small public service).

## Context

- `/packages` (`PortalWeb.IndexLive`) lists **only** `Catalog.latest_by_pkg_json()` — a
  package appears only after a successful build ingests it.
- Progress for a single request lives at `/requests/:id` (`RequestLive`, a stepper).
- A scan submission fans out to **one `ScanRequest` per package**
  (`page_controller.ex` `create_anonymous_requests`, `HexPm.complete_owner_requests`,
  and the GitHub path) — each returns the created request structs (`id`, `package_name`,
  `status`).
- `ScanRequest.status` ∈ `[:pending, :accepted, :queued, :built, :rejected, :error]`.
  `:pending` = unapproved anonymous (admin note: kept out of public lists until approved).
- `Portal.ScanRequests.queue_requests/0` already returns `status in [:accepted, :queued]`
  sorted by `inserted_at` — exactly the "approved and going to be scanned" set.

## Decisions (locked)

- **Placeholders** show only **approved queue** requests (`:accepted`/`:queued`);
  `:pending` unapproved requests stay hidden (anti-spam).
- **Post-submit** shows a **confirmation panel on `/request-scan`** (no new route, no
  batch id, no combined live page).
- Placeholder cards link to **`/requests/:id`** (not `/packages/:name`, which 404s until
  the build ingests).

## Architecture

### A. Placeholders on `/packages`

**Data source:** reuse `Portal.ScanRequests.queue_requests/0`. Add one helper to build
placeholder entries deduped against the catalog:

- In `PortalWeb.IndexLive`, a private `placeholders(catalog_names, q)`:
  - loads `queue_requests()`,
  - keeps requests whose `package_name` is NOT in `catalog_names` and matches the search
    `q`,
  - dedups by `package_name` (first wins),
  - returns entries `%{name: String.t(), request_id: binary, placeholder?: true}`.

**Rendering:** `list_packages/1` already returns catalog package maps. Merge: catalog
entries (tagged `placeholder?: false`) + placeholders, all sorted by `name`. The stream
config sets `dom_id` per entry: `"package-#{name}"` for real packages (unchanged — a
regression-tested hook), `"placeholder-#{name}"` for placeholders.

The template branches per entry:
- real package → existing `PortalWeb.UI.package_card` (href `~p"/packages/#{name}"`).
- placeholder → `package_card` with `href={~p"/requests/#{request_id}"}`,
  `summary="in queue"`, `summary_status="queued"`, `statuses={[]}` (no system bar),
  `version={nil}`.

`status_pill_class/1` already returns an amber pill for any unknown status string, so
`"queued"` renders a distinct amber "in queue" pill without changing `PortalWeb.UI`.

The package count (`@package_count`) counts catalog packages + placeholders. Search
(`phx-change="search"`, param `q`) filters both.

**Boundary:** IndexLive owns the merge; `queue_requests/0` stays the single source of
"approved in-flight". No change to `Catalog` or `ScanRequests`.

### B. Confirmation panel on `/request-scan`

**Controller:** the three submit success branches currently call
`render_request_scan(packages: Enum.map(requests, & &1.package_name))`. Change each to
also pass `submitted_requests: requests` (the structs). `render_request_scan/2` adds
`submitted_requests: Keyword.get(assigns, :submitted_requests, [])` to its render assigns.

**Template (`request_scan.html.heex`):** when `@submitted_requests != []`, render a
Beacon panel at the top of the content (above the "Add packages" card):

- heading: `Requested {n} package(s) — track progress`
- a list; each row: the package name (mono) + a link
  `~p"/requests/#{request.id}"` labeled "View progress →".
- styled with the existing card idiom (`rounded-2xl border border-base-300 bg-base-100
  p-6 shadow-sm`, primary accents).

This works identically for single (list of 1) and batch (list of N). The existing
"Your recent requests" table (logged-in) is unchanged.

## Testing

- **IndexLive placeholders** (`catalog_live_test.exs` or a new
  `index_placeholders_test.exs`):
  - Seed an accepted `ScanRequest` for `"queuedpkg"` (not in catalog) → `/packages`
    renders `#placeholder-queuedpkg`, an "in queue" label, and a link to
    `/requests/<id>`.
  - A `:pending` request for `"pendingpkg"` → NOT shown.
  - A queued request whose package IS in the catalog → only the catalog card
    (`#package-<name>`), no `#placeholder-<name>` duplicate.
  - Search `q` filters placeholders.
- **Confirmation panel** (`page_controller_test.exs`): submitting an anonymous request
  renders the panel with "track progress" and a `/requests/<id>` link for each submitted
  package.
- Regression: existing IndexLive hooks (`#package-<name>`, `search`/`q`,
  `Nerves Compatibility`) still pass; existing `page_controller_test` request-scan
  assertions (`Request scans for packages`, `data-package-picker`, etc.) still pass.
- `mix precommit` + umbrella `mix test` green.

## Non-goals (YAGNI)

- No accounts/users, no "My requests" page.
- No new route, no batch id, no combined live progress page.
- No change to the worker/`result.json`, JSON API, badge, Oban, or `Catalog`/
  `ScanRequests` public API (only additive reads reused).
- Pending (unapproved anonymous) requests remain invisible publicly.

## Risks / notes

- Placeholders reflect `queue_requests/0` at page-load time; they don't live-update as a
  build finishes (no PubSub on the index). Acceptable — a refresh moves a finished
  package from placeholder to catalog card. Live index updates are a possible follow-up.
- A package with both a catalog row and a fresh queued re-scan shows only the catalog
  card (no "re-scanning" hint). Acceptable for this pass.
