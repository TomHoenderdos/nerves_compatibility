# World builds

A world build is a toolchain build of a package version made in a *world*: a
named, pinned set of Hex package names that a common application has in its
prod env (`Compatibility.Worlds`). The builder adds, at every depth of the
package's dependency closure, each optional dependency that is a member of the
world, until nothing changes. The build's `deps` is then the closure Mix gives
the package in an application of that shape.

Phase 1a has one world, `phx`: the 36 prod packages of a `mix phx.new` 1.8.16
app. Its rows are stored as toolchain build variant `world_phx`.

## Where they are served

Only under `versions[v].builds_closure` in the format-2 manifest
(`PRECOMPILED_API.md`). Clients 0.7.0 and later, which check a build's whole
`deps` closure against their env closure, read that list. A world build never
appears in `builds`, in `builds_with_inputs`, in format 1, or in the signed
batch's payload; the batch only holds the format-2 manifest's hash.

A world build whose `deps` comes out equal to the version's `with` or `without`
build is stored as `skipped` with reason `same closure as the with build` (or
`without`) and no files, so the same build is never listed twice. Like any
skipped row, it is rebuilt once when a newer judge revision reopens the
toolchain's skips.

## What is built

While the `world_variants_enabled` setting is on, the toolchain backlog wants a
world build for every version of a package among the `world_top_packages` most
downloaded on hex.pm (500 by default; `nil` means every package) whose `with`
default build passed or was skipped, is unrevoked and has a recorded lock. A
served world default whose compile read LiveView's config also wants its
`phx_prod`, `phx_test` and `phx_dev` config variants, while the setting is on.

World builds rank after every new build and every reopen. Each sweep gives
them `world_share` of its cap (a quarter by default) at Oban priority 3. A share
they leave free goes to the other builds.

Settings, all under `config :portal, Portal.Toolchains` except the first:

| setting | default | meaning |
| --- | --- | --- |
| `world_variants_enabled` (admin, Maintenance) | off | proposes world builds and their config variants |
| `worlds` | every known world | the worlds built while the setting is on |
| `world_top_packages` | 500 | how many of the most downloaded packages get world builds |
| `world_share` | 0.25 | a sweep's share of its cap for world builds |

The Maintenance tab shows, per toolchain, the world rows by status, how many of
the skips are same-closure skips, and the candidates the backlog wants. The
candidate count is shown whether the setting is on or off, so it is known
before turning it on.

## Turning it on

1. Every node that runs portal code has this release: both web colours, the
   build host, and the toolchain builders that CI does not deploy. Every
   `:toolchain` node also runs a worker image with world mode. An older image
   refuses `optional_deps: "world"` (exit 10), and the job retries and then
   records an `error` row, so it fails closed.
2. Note the candidate count on the Maintenance tab.
3. Turn world builds on from the Maintenance tab.
4. Watch the world rows' error and skip counts on the same tab.

## Turning it off and rolling back

Turning the setting off stops new world builds and new config variants of
world rows. The world rows already built stay served under `builds_closure`.

Revoking world rows is **not** needed to roll back to the variant-tolerant
release (main `c85854ce`) or any later one. Those releases filter every
toolchain build variant they do not know out of their Ash reads in SQL, and
every raw SQL reader restricts itself to the variants it knows. A `world_phx`
row is then never read, served, counted or rebuilt there.

A rollback to a release older than that is not supported once world rows
exist: its Ash reads fail to cast the `world_phx` atom. If one is ever needed,
turn the setting off first, then revoke the world rows before the old release
starts. That keeps them out of its manifest reads, which filter on
`revoked_at` in SQL; its other reads of the table were never checked for it.

```sql
UPDATE catalog_toolchain_builds SET revoked_at = now()
WHERE variant LIKE 'world_%' AND revoked_at IS NULL;
```
