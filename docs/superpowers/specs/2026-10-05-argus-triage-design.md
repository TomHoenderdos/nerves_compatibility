# Argus findings triage list

Status: approved design, not yet implemented.
Date: 2026-10-05.
Builds on: `docs/superpowers/specs/2026-10-03-argus-static-analysis-design.md`.

## Problem

argus findings are stored per run (`catalog_runs.argus`) and shown to passkey
admins on each package page. There is no cross-package view, and no way to
record what an admin concluded about a finding. Before anyone contacts package
owners — on hold until agreed with the Nerves maintainers — the findings need
to be reviewed and sorted into real issues and false positives, with notes.

## Decisions taken

- **Internal only.** A LiveView under `/admin`, behind the same `:admin`
  pipeline and `RequireAdmin` passkey `on_mount` as `/admin/oban`.
- **Triage status per finding**, set by an admin:
  `new | confirmed | false_positive | reported`, plus a free-text note.
- **Statuses survive rebuilds.** A finding is identified by a fingerprint that
  ignores line numbers, so a new version of the package with shifted lines keeps
  the status an admin set.
- **No email, no Jev, no public effect.** `false_positive` does not hide
  anything on the package page; that is a separate later decision.
- **No backfill.** Nothing is in production yet; rows are created by ingestion
  from the first argus run on.

## Data

New resource `Portal.Catalog.FindingTriage`, table `catalog_finding_triage`.

| Attribute | Type | Notes |
|---|---|---|
| `fingerprint` | string | identity; see below |
| `package_name` | string | |
| `analysis` | string | from the finding |
| `severity` | string | `error` / `warning` / `info`, from the latest sighting |
| `title` | string | |
| `file` | string, nullable | |
| `line` | integer, nullable | from the latest sighting |
| `finding` | map | the latest finding verbatim, for the details view |
| `status` | atom | `:new` (default), `:confirmed`, `:false_positive`, `:reported` |
| `note` | string, nullable | |
| `first_seen_version` | string | |
| `last_seen_version` | string | |
| `last_seen_run_id` | uuid | the `catalog_runs.id` of the latest sighting |
| `updated_by` | string, nullable | username of the admin who last set status/note |
| timestamps | | |

**Fingerprint:** lowercase hex sha256 of
`package_name <> "\0" <> analysis <> "\0" <> title <> "\0" <> (file || "") <> "\0" <> (detail || "")`.
`detail` names the functions involved, so it separates two findings of one class
in one file; the line number is left out so a shifted line is the same finding.

Actions:

- `:sighting` — create with upsert on `fingerprint`. On conflict it updates only
  `severity`, `line`, `finding`, `last_seen_version`, `last_seen_run_id`; never
  `status`, `note`, `updated_by` or `first_seen_version`.
- `:triage` — update `status`, `note`, `updated_by`.

## Ingestion

`Portal.Catalog.Ingestion.ingest/2`, inside the existing transaction, after
`create_run/6` succeeds: when `result["argus"]` is a map with `"status" => "ok"`
and a list of `"findings"`, upsert one `:sighting` per finding that is a map with
binary `analysis`, `severity` and `title`. Anything else is skipped, never an
ingest failure. A run with argus `error`, `skipped` or absent writes nothing.

## Queries

`Portal.Catalog.triage_list(filters)` returns rows plus a `stale?` flag, where
stale means `last_seen_run_id` is not the package's latest run (the finding
disappeared in a newer build). Filters:

- `status` — list, default `[:new, :confirmed]`
- `severity` — list, default all
- `analysis` — single, default all
- `package` — substring, default none
- `include_stale` — default `false`

Order: status (`new` first), severity (`error`, `warning`, `info`), package
name, title.

`Portal.Catalog.triage_counts/0` returns `%{new: n, confirmed: n,
false_positive: n, reported: n}` over non-stale rows.

`Portal.Catalog.triage!(id, %{status:, note:}, admin)` applies `:triage` with
`updated_by: admin.username`.

## Page

`PortalWeb.Admin.ArgusFindingsLive` at `/admin/argus/findings`.

- Header with the four status counts.
- Filter form (`phx-change`): status checkboxes, severity checkboxes, analysis
  select, package text input, "include no longer seen" checkbox. Filters live
  in the URL query string (`push_patch`) so a filtered view can be shared
  between admins.
- Table, one row per finding: package (link to `/packages/:name`), severity
  badge, analysis, title, `file:line`, versions (`first → last`), a "no longer
  seen" badge when stale, status select, note input, and a `<details>` with the
  argus detail, help and related locations.
- Status select and note save on change (`phx-change` per row form, note
  debounced 500 ms); a flash confirms the save.
- Rows rendered with a LiveView stream.
- `/admin`'s argus card links to the page.

Follows `apps/portal/AGENTS.md`: `<.form>`/`<.input>`, unique DOM ids
(`finding-<id>`, `triage-form-<id>`), no template-local assigns.

## Testing

- Fingerprint: same for a shifted line, different for a different `detail`.
- Ingestion: creates `new` rows; a second run updates `last_seen_*` and keeps a
  status set in between; `error`/absent argus writes nothing; malformed findings
  are skipped and the run still ingests.
- `triage_list/1`: default filters, each filter, stale detection, ordering.
- LiveView: anonymous and password-login admins are refused; passkey admin sees
  rows; changing status persists and updates counts; filters patch the URL.

## Out of scope

Email to owners, Jev suggestions, hiding false positives publicly, CSV export,
bulk status changes.
