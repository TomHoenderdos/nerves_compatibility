# Argus static analysis as an advisory build step

Status: approved design, not yet implemented.
Date: 2026-10-03.

## Problem

A package that builds firmware for every Nerves system can still carry OTP bugs
that only show on a device: a GenServer call cycle that deadlocks at boot, a
supervisor tree whose children are coupled across branches, a TLS client that
does not verify its peer. The tracker already has the compiled beams of every
package it checks and says nothing about any of this.

[`argus_beam`](https://hex.pm/packages/argus_beam) (0.20.1, MIT) disassembles
compiled `.beam` files, extracts facts from the bytecode and evaluates Souffle
Datalog rules for 14 BEAM/OTP analyses (startup, shutdown, blocking, coupling,
mailbox, failure, structure, races, state_machine, ets, effects, unsafe_input,
exposure, coverage). Its findings carry a severity, a source anchor and a
remediation hint, and it has a stable JSON output.

Running it on the beams the worker already compiled, and showing the findings
on the package page, is an extra service to package authors.

## Decisions taken

- **Advisory only.** Findings never change a system's status, the run's
  `overall_status`, the badge, or worker exit codes (`0`/`10`/`11`). An argus
  failure is recorded and otherwise ignored.
- **Internal for now** (changed 2026-10-05; originally public): the section
  on the package page renders only for an admin signed in with a passkey
  (`RequireAdmin.check/2`, the `/admin` gate), labelled "admins only" and
  filtered by an admin-configured severity floor. Going public later is a
  one-line change in `PortalWeb.PackageLive.assign_argus/3`. Emailing owners
  is on hold until agreed with the Nerves maintainers.
- **In the worker**, against the host compile, once per run (bytecode is
  target-independent, so one run covers every system). No separate job or
  container.
- **Default analyses: argus's `default` set plus `exposure`.** `exposure` flags
  TLS without peer verification and secrets printed by `inspect/1`, both
  relevant on devices. `unsafe_input` is left out by default: on libraries it
  is mostly API doing what it is for.
- **Default scope: firmware packages only** (`NccWorker.BuildSelection`
  returns `:firmware`). Widening to all packages is an admin setting.
- **Admin-configurable** at `/admin`: enabled, analyses, scope, public severity
  floor, timeout.
- **HTML only in v1.** The schema-v2 JSON API is unchanged; findings can be
  added there later as an additive field.
- **Priors are never enabled.** `Argus.Priors` sends identifiers to an external
  model (typesafe.ai, `TYPESAFE_API_KEY`). Not exposed as a setting.

## Scope

In:

- Souffle and the `argus` escript in the worker image, version-pinned.
- `NccWorker.Argus`: runs the escript, maps its outcome, returns a result map.
- A top-level `argus` field in `result.json`.
- `Portal.Settings` singleton with the argus settings, and an admin card.
- `Portal.Builder` passes the settings in `NCC_INPUT`.
- `runs.argus` jsonb column, filled by ingestion.
- A section on `/packages/:name`.

Out:

- Backfill of existing runs. Runs are deduplicated on
  (package, version, image digest); the new image has a new digest, so the
  next catalogue sweep or update check picks argus up for each package.
- Re-analysis when settings change. A change applies to builds started after
  it. The severity floor is the exception: it is a display filter and applies
  immediately.
- Per-package suppression. If an author asks for it, it belongs on
  `Portal.Catalog.PackageOverride`, as a later change.
- Moving other app-env tunables (`queue_filter.enabled`, build total timeout,
  log retention budget) into settings.
- The JSON API, badges, stats.

## Worker

### Image

`apps/ncc_worker/Dockerfile`:

- Install Souffle 2.5 after the existing apt layer. amd64 installs the
  upstream `.deb` (SHA-512 pinned); arm64 builds the same tag from source
  (SHA-256 pinned), since upstream ships no arm64 package and Ubuntu 24.04 has
  none. Souffle must be on `PATH`.
- `mix escript.install hex argus_beam 0.20.1 --force` as the `nerves` user,
  with `/home/nerves/.mix/escripts` on `PATH`. The existing `a+rwX` chmod on
  `/home/nerves` keeps it usable under `--user $(id -u):$(id -g)`.
- `argus version` as a build-time smoke check (prints argus, runtime and
  souffle versions; fails the image build when souffle is missing).

argus requires Elixir `~> 1.19`; the image has Elixir 1.20.3 on OTP 29.

The escript is used rather than `mix argus` because `mix argus` needs
`argus_beam` added to the generated project's deps, which changes the
`mix.lock` that `NccWorker.LockPolicy` inspects and the dependency closure
that `BuildSelection` classifies.

### Input

`NCC_INPUT` gains an optional key. Absent means argus does not run.

```json
"argus": {
  "analyses": ["default", "exposure"],
  "scope": "firmware",
  "timeout_seconds": 300
}
```

`scope` is `"firmware"` or `"all"`.

### `NccWorker.Argus`

```elixir
@spec run(project :: Path.t(), package :: String.t(), deps :: [String.t()],
          config :: map() | nil, selection :: :firmware | :pure_elixir) :: map()
```

When it runs: after the host compile and `BuildSelection.select/5`, from
`NccWorker.Worker`. It returns `skipped` when:

- `config` is nil (disabled), or
- `scope` is `"firmware"` and `selection` is `:pure_elixir`, or
- the host compile did not pass (no beams), or
- the run took one of the forced-skip paths (`build_forced_skip_system`).

Command, from the project directory:

```
argus --project beams \
  --ebin _build/host/lib/<package>/ebin \
  --dep-ebin _build/host/lib/<dep>/ebin   # once per dep in the package's closure
  --analyses default,exposure \
  --format json --color never
```

- `<dep>` is every `_build/host/lib/*/ebin` except the package and the
  generated wrapper app `nerves_compatibility_test` — a superset of the
  closure, which saves a second `mix deps.tree`. Deps are context for the
  whole-program analysis; without `--include-deps` argus reports findings only
  for the package's own modules, so no filtering is needed on our side.
- Env: `ARGUS_CACHE_DIR=<project>/.argus-cache` (per-run scratch under `/work`,
  never the shared caches), `TYPESAFE_API_KEY` unset.
- `--state-dir <project>/.argus-state`, also per-run scratch.
- Wall-clock timeout `timeout_seconds` (default 300) via coreutils
  `timeout -k 10`, which kills the OS process; exit 124/137 is a timeout.
  stderr is redirected to a file so stdout stays the JSON document.
- The command runner is injectable (an option to `NccWorker.Argus.run/6`) so
  unit tests do not need souffle.

Outcome mapping:

| argus result | `status` | `findings` | `error` |
|---|---|---|---|
| exit 0 or 1, stdout parses as a JSON list | `ok` | parsed list | `nil` |
| exit 2 (usage/project/config error) | `error` | `[]` | `"exit 2: <last stderr line>"` |
| exit 3 (analyses could not run) | `error` | `[]` | `"exit 3: <last stderr line>"` |
| timeout | `error` | `[]` | `"timeout after Ns"` |
| stdout not a JSON list | `error` | `[]` | `"invalid json"` |
| escript missing / any raise | `error` | `[]` | short reason |

`--fail-above` is not passed, so exit 1 does not occur in practice; it is
still treated as `ok`.

Findings are kept verbatim in argus's documented JSON schema
(`Argus.Report.Json`): `analysis`, `severity`, `file`, `line`, `end_line`,
`title`, `at_label`, `detail`, `help`, `provenance`, `confidence`, `related`.
Capped at 200 findings in argus order; `truncated: true` when capped.

The stderr tail of the argus run is appended to the worker log under an
`argus` heading, so failures are debuggable from `/admin` logs.

### Output

`result.json` gains a top-level `argus` field, and the typespec at the top of
`worker.ex` documents it:

```json
"argus": {
  "status": "ok",
  "version": "0.20.1",
  "analyses": ["default", "exposure"],
  "duration_ms": 18234,
  "findings": [ { "analysis": "blocking", "severity": "warning", "file": "lib/x.ex", "line": 12, "...": "..." } ],
  "truncated": false,
  "error": null
}
```

`version` comes from `argus version` at run time (first line), so a result
records which argus produced it. A `skipped` result has `findings: []`,
`version: null`, `duration_ms: null`.

Every `result.json` carries the field, including forced-skip and error paths
that still write one.

## Portal

### Settings

New Ash domain `Portal.Settings` with a single resource
`Portal.Settings.Setting` (table `settings`, one row). Attributes:

| Attribute | Type | Default | Constraint |
|---|---|---|---|
| `argus_enabled` | boolean | `true` | |
| `argus_analyses` | `{:array, :string}` | `["default", "exposure"]` | non-empty, each in the allow-list |
| `argus_scope` | atom | `:firmware` | `:firmware \| :all` |
| `argus_min_severity` | atom | `:warning` | `:info \| :warning \| :error` |
| `argus_timeout_seconds` | integer | `300` | 30..1800 |

Allow-list for analyses: the 14 analysis names and the named sets `default`,
`all`, `security`, `effects`, `otp`. Validating here keeps an admin typo from
turning into an argus exit 2 on every build. The allow-list is tied to the
pinned argus version and is updated with it.

Code interface:

- `Portal.Settings.get/0` returns the row, or an unsaved struct with the
  defaults when no row exists. Reading never fails a build.
- `Portal.Settings.save/1` upserts the single row (not `update/1`: `Ash.Domain` already defines a deprecated one).

### Admin

A new card on `/admin`, "Static analysis (argus)", following the existing plain
form convention (`post "/admin/argus"` → `PageController` →
`Portal.Admin.update_argus_settings/1`):

- enabled checkbox
- one checkbox per analysis and named set
- scope radio: firmware packages only / all packages
- public severity floor select: info / warning / error
- timeout seconds number input
- a one-line note that changes apply to builds started afterwards, except the
  severity floor

Validation errors re-render the admin page with a flash, as the existing forms
do.

### Builder

`Portal.Builder.write_worker_input/2` (`builder.ex:369`) adds the `argus` key
from `Portal.Settings.get/0` when `argus_enabled`, and omits it otherwise.

### Storage and ingestion

- Migration: `runs.argus` jsonb, nullable. `Portal.Catalog.Run` gains
  `attribute :argus, :map`.
- `Portal.Catalog.Ingestion` copies `result["argus"]` onto the run. Old results
  and old images produce `nil`.

### Package page

`PortalWeb.PackageLive`, under the per-system results, for the latest run:

- Heading "OTP analysis", with "advisory — by argus_beam <version>" and a link
  to the argus README.
- `ok` with findings at or above the floor: grouped by severity (error, warning,
  info). Each finding shows `title`, `file:line`, the analysis as a badge, and
  `at_label`/`detail`/`help`/`related` in a `<details>`. "Showing N of M" with
  `truncated`.
- `ok` with none at or above the floor: "No findings at <floor> or above for:
  default, exposure".
- `error`: "Analysis could not run for this version." The reason is shown only
  to admins.
- `skipped` or `nil`: section not rendered.

Findings use `file` relative to the package source; no links into hexdocs or
the repo in v1.

## Testing

Worker (`mix test apps/ncc_worker/test/` from the root):

- `NccWorker.Argus` with a stubbed runner: exit 0 with findings, exit 0 empty,
  exit 2, exit 3, timeout, non-JSON stdout, missing escript, truncation at 200,
  skip on nil config, skip on `scope: firmware` + `:pure_elixir`, run on
  `scope: all` + `:pure_elixir`.
- Command construction: `--ebin`, one `--dep-ebin` per existing closure ebin,
  analyses joined with commas, no `--include-deps`, no priors env.
- `result.json` always carries `argus`, including the forced-skip path.

Portal:

- Settings: defaults when no row, upsert, each constraint rejects bad input,
  unknown analysis rejected.
- Admin: form updates settings, admin-gated, invalid input flashes.
- Builder: input contains `argus` when enabled with the configured values,
  omits it when disabled.
- Ingestion: `argus` stored; absent field stores `nil`.
- PackageLive: each state renders as specified; the floor hides lower
  severities; the error reason is admin-only.

Integration (`:integration`, real Docker): the result for the fixture package
has an `argus` field with `status` `ok` or `skipped` per its selection, and
`version` set when `ok`.

Before merging, run the image against a handful of real firmware packages
(e.g. `vintage_net`, `circuits_uart`, `nerves_hub_link`) and record per-package
argus duration and finding counts in the PR, to confirm the 300 s default and
to look at false-positive rates before findings go public.

## Docs

- `apps/ncc_worker/README.md`: `NCC_INPUT.argus`.
- `worker.ex` typespec: `argus`.
- `CLAUDE.md`: step 4 of "How a Package Gets Checked" mentions argus; the
  Container section mentions Souffle and the escript.

## Risks

- **False positives in public.** argus documents precision per bug class and
  is young (0.20, frequent breaking changes). Mitigations: advisory label,
  severity floor, `unsafe_input` off by default, pre-merge sample run.
- **Image size and build time.** Souffle adds a C++ runtime; measure the image
  delta in the PR.
- **Per-run cost.** Bounded by the timeout; the Souffle run is per package, not
  per system.
- **argus upgrades.** Pinned in the Dockerfile; an upgrade is a deliberate image
  rebuild that also reviews the analysis allow-list.
