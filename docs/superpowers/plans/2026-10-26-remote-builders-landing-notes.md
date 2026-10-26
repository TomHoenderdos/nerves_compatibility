# Remote builders: landing notes

Date: 2026-10-26. The 44 commits of `feat/remote-builders` (built from
`docs/superpowers/specs/2026-10-25-remote-builders-design.md` v2 and
`docs/superpowers/plans/2026-10-25-remote-builders.md`) rebased onto
`main` at `5d41ee0` ("Bump ash to 3.37.2 past this morning's advisory"),
reconciled with the sandbox-isolation work main carries, gated, reviewed
adversarially in four layers, and fixed. Nothing here is merged or
deployed; the laptop session lands it.

## Rebase: what conflicted and how it was resolved

`main` had moved 34 commits past the branch's base `9ddcad3`, carrying its
own `Compatibility.Builder.Argv`, the read-only Nerves cache with the
worker-side per-run symlink farm, the host-side egress filter
(`ops/builder-egress*.nft`, `Portal.EgressCheck`), `ops/deploy-builders.sh`
and two Ash advisory bumps. Five files conflicted (the task note said
three; `ops/deploy.sh` and `.github/workflows/deploy.yml` were the other
two). Each was touched by exactly one branch commit, so each was resolved
once, at that commit:

| File | Conflict | Resolution |
| --- | --- | --- |
| `apps/compatibility/lib/compatibility/builder/argv.ex` | add/add: two independent implementations | **main's module is the base**, byte for byte (production runs it). Added only `safe_name/1` and `container_name/1`, which the agent needs for its scratch and container names. The branch's `:legacy`/`:readwrite` modes, `hardening:`, `extra_env:` and flat `work_dir`/`output_dir` spec shape were not ported: on main every build is hardened and the spec carries `paths`. |
| `apps/compatibility/test/compatibility/builder/argv_test.exs` | add/add | main's test plus one test for the two name helpers. |
| `ops/README.md` | both sides extended the script table | both kept: main's `deploy-builders.sh`, `builder-egress-load.sh`, `*.nft` rows and the branch's `images-sync.sh` row; main's "Egress filter" section and the branch's "Remote builders" section both stay. |
| `ops/deploy.sh` | both appended a tail block after `sleep_until_up` | one `if builder / else` block: builder deploys run main's `builder_check_running_egress`, portal deploys run the branch's best-effort `images-sync.sh`. |
| `.github/workflows/deploy.yml` | both extended the "Validate deployment scripts" list | the branch's one-file-per-call `bash -n` loop over the union of both lists (main's `builder-egress-load.sh`, `deploy-builders.sh` plus `images-sync.sh` and `apps/ncc_agent/priv/egress.sh`), same union for `shellcheck -x`. Hit again at the egress-ruleset commit; kept the merged list. |

Auto-merged but checked by hand: `apps/portal/lib/portal/application.ex`
(main's `WarmNerves.with_local_queue` and the ETS tables next to the
branch's `RateLimit` child and `Listener.configure/0`),
`apps/portal/lib/portal/workers/build.ex` (uniqueness `fields: [:args]`
on top of main's warm request), `apps/portal/lib/portal/workers/ingest.ex`
(the remote source next to main's toolchain path), `config/runtime.exs`,
`apps/portal/config/*.exs`, `mix.lock`.

### Follow-up commits after the rebase

1. **Reconcile the agent with main's Argv and Nerves cache** (`dde009a`).
   The branch was written ahead of the isolation work and did host-side what
   main's worker now does in the container:
   - `NccAgent.Job.argv_spec/3` builds main's spec (`container_name`,
     `paths`, `nerves_cache_mode: :readonly`, `build_cache: nil`).
   - The agent no longer builds a symlink farm or passes
     `NERVES_ARTIFACTS_DIR`/`NERVES_DL_DIR`; `input.json` is the claim's
     `input` (`Portal.Builder.worker_input/1`) verbatim. `NccWorker.NervesCache`
     lays out the farm inside the container.
   - The warm decision moved to the portal, as on the local host: the
     `complete` answer carries `warm`, computed by
     `Portal.NervesCache.warm_pairs/2` over the uploaded `result.json`
     (named by the run's lock, owned by the `nerves` Hex user, at most
     four). The agent re-checks the shape and runs exactly those pairs with
     the cache mounted `:warm`. `Portal.Builders.WarmAllowlist`, the static
     list the claim carried (its own moduledoc called it a placeholder for
     `Portal.HexPm.owners/1`), is gone, and so is `warm_allowlist` from the
     claim body. This is a deliberate deviation from spec section 5 ("the
     allowlist travels in the claim response"), in the spec's own
     direction: the portal decides, the agent has no policy.
   - `NccAgent.ArgvParityTest` checks against the shared fixture
     `apps/compatibility/test/fixtures/argv/post_isolation.exs` minus the
     build-cache pair; the branch's own fixture and the portal's duplicate
     parity test are deleted (main's `Portal.BuilderTest` "argv parity"
     covers the portal). `Portal.Builder.safe_name/1` delegates to
     `Argv.safe_name/1`.
   - `docs/REMOTE_BUILDERS.md` loses its "Depends on feat/sandbox-isolation"
     section; the worker README's informational-paths paragraph is reverted.
2. **MAKEFLAGS** (`b8b8913`). `feat/makeflags-libnl` was not on main when
   fetched, so per the task note `"-e", "MAKEFLAGS=-j#{quota}"` follows
   `NCC_SQUASHFS_PROCESSORS` in `Argv.cpu_env/1`, in the fixture and in every
   parity test. **Note for the landing:** main's module carried a comment
   and a `Portal.BuilderTest` test ("make runs serially, as it does for a
   user") deliberately *not* setting it, citing circuits_spi 2.1.0 on rpi4;
   both were rewritten to pin the bound instead. If `feat/makeflags-libnl`
   lands first with a different position or wording, expect a small
   conflict in `argv.ex`, the fixture, `argv_test.exs` and
   `builder_test.exs`; the branch's version should then yield to main's.
3. Fake-portal clause grouping (`5aca9f5`), found by the forced compile gate.

## Gates

Run from the umbrella root on OTP 28.5.0.8 / Elixir 1.20.0 / PostgreSQL 17.4
(the CI versions), after the three follow-up commits above:

| Gate | Result |
| --- | --- |
| `mix format --check-formatted` | exit 0 |
| `mix compile --warnings-as-errors --force` | exit 0 (first run exit 1: `defp route/4` clauses split by a helper in `test/support/fake_portal.ex`; fixed in `5aca9f5`) |
| `mix credo` | exit 0, "3999 mods/funs, found no issues" |
| `mix test` | exit 0: compatibility 24, ncc_worker 270, portal 1616 (9 excluded: `:integration`, `:e2e`), ncc_agent 86; all passed |
| `mix sobelow --root apps/portal --private --skip --strict --exit low` | exit 0 |
| `mix sobelow --root apps/ncc_worker --no-router --private --skip --strict --exit low` | exit 0 |
| `mix sobelow --root apps/compatibility --private --skip --strict --exit low` | exit 0 |
| `mix sobelow --root apps/ncc_agent --no-router --private --skip --strict --exit low` | exit 0 |
| `mix do deps.loadpaths + deps.audit` | exit 0, "No vulnerabilities found" |
| `mix hex.audit` | exit 0, "No retired or security advisory packages found" |
| `bash -n` on every `ops/*.sh` and `apps/ncc_agent/priv/egress.sh` | all parse |
| `shellcheck ops/*.sh apps/ncc_agent/priv/egress.sh` | exit 0 |
| `python3 -m unittest discover -s ops -p 'test_*.py'` | 56 tests OK (1 skipped) |
| `make test-remote-e2e` (real `ncc_agent` process, fake docker, tag `:e2e`) | 1 passed |

Not run: `make test-integration` and `make test-remote-integration` (need
Docker and the `ncc-worker:local` image; this box has neither). Run them
on a build host before going live, as `CLAUDE.md` asks after any change to
the Docker invocation.

`.github/workflows/sobelow.yml` already lists `ncc_agent` in its matrix;
`credo.yml` runs umbrella-wide. Migrations `20261025204639_remote_builders`
and `20261025233114_run_builder_index` only create tables, columns and new
indexes; no existing unique index is touched.

## Adversarial review

Four reviewers, fresh context each, one layer each, with the spec section
and the diff of their files only. Findings per layer, with what was fixed
or why not, follow.

REVIEW_PLACEHOLDER

## What an operator still has to do by hand to go live

In order, on the web host unless said otherwise. `docs/REMOTE_BUILDERS.md`
has the commands and unit files.

1. **Deploy** this branch (merged to `main`) through the normal CI deploy;
   `ops/deploy.sh` runs the migration. Nothing changes behaviour yet: the
   listener only starts with a CA key, routing stays local without
   `images.json`.
2. **Create the CA key** as `ncc`, outside the checkout, with the portal
   env sourced: `install -d -o ncc -g ncc -m 0700 /etc/ncc-portal/builder-ca`
   then `bin/portal eval 'Portal.Builders.CA.init("/etc/ncc-portal/builder-ca/ca-key.pem")'`.
   It refuses to overwrite. Back the key up: losing it means re-enrolling
   every builder.
3. **Env file** `/etc/ncc-portal/portal.env`: `NCC_BUILDER_CA_KEY`,
   `NCC_UPLOAD_ROOT` (a filesystem with room for 2 GiB per in-flight
   lease), `OBAN_QUEUES=intake:5,maintenance:1,remote:2` (`remote` is
   required on the web host: remote ingests run there), optionally
   `NCC_BUILDER_PORT` (default 8443) and `NCC_IMAGES_JSON`.
4. **Firewall**: open TCP 8443 to the world on the web host (the client
   certificate is the gate; only `ca.pem` and `enroll` answer without one).
   Apache is not involved; Bandit terminates this TLS itself.
5. **images.yml**: needs no extra secrets (`GITHUB_TOKEN` with
   `packages: write` for GHCR and `contents: write` for the `agent-<sha>`
   release). Check the repository's Actions settings allow workflow write
   permissions, run the workflow once by hand (`workflow_dispatch`) to prove
   the GHCR push, the two release tarballs and `images.json` land, then set
   the GHCR packages to public.
6. **images.json on the web host**: install and enable
   `ncc-images-sync.timer` (unit texts in `docs/REMOTE_BUILDERS.md`); until
   the file names an `ncc-worker` digest every job stays local.
7. **Restart the portal**; the log should say `builder listener on 8443`.
8. **Enrol the first builder**: `/admin/builders` → New enrolment token
   (24 h, shown once) → boot an Ubuntu 24.04 VM with the cloud-init from
   `docs/REMOTE_BUILDERS.md` (`PORTAL_HOST`, `TOKEN`, `COMMIT` filled in).
   It appears on the tab with `publishing` off and `egress: ok`.
9. **Rehearse** per spec: from a real build on that VM probe
   `http://169.254.169.254/latest/meta-data/` and a tailnet address and
   assert both are refused; run a pinned job; revoke the builder and see its
   run revoked and the version re-enqueued locally. Re-enrol with a new
   token.
10. **Turn remote building on** (`remote_mode` auto or on, backlog
    threshold) and, after inspecting the first runs, flip `publishing` per
    builder.
