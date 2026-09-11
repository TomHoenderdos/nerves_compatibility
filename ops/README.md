# ops/

The deploy path. There is no deploying CI: GitHub Actions audits the lock
(`.github/workflows/audit.yml`), and shipping is `deploy.sh`, run by hand on
each host.

These scripts used to live only at `/opt/nerves_compatibility/*.sh` on the two
hosts, untracked and slowly diverging — the web host had an apt-mirror fix the
build host did not. They are tracked here so a change is reviewable and lands
on both machines identically.

## Hosts

Both follow `main` and share one Postgres. The only difference between them is
`/etc/ncc-portal/portal.env`, which is **not** in this repo and holds secrets.

| Host | Role | `OBAN_QUEUES` |
| --- | --- | --- |
| `contabo.tompc.nl` | public site (`nerves.tomhoenderdos.nl`) | `intake:5,maintenance:1` |
| `vmi3525942` (tailscale `100.106.217.14`) | builds; owns the scratch and cache disks | `builds:3,ingest:3` |

## Installing a change

These files are not read from the checkout — `deploy.sh` lives outside `$SRC`
so that a deploy cannot swap the script out from under itself mid-run. After
changing anything here, copy it to both hosts:

```bash
for h in contabo.tompc.nl 100.106.217.14; do
  scp ops/deploy.sh ops/build-release.sh "root@$h:/opt/nerves_compatibility/"
  ssh "root@$h" 'chmod +x /opt/nerves_compatibility/*.sh'
done
```

## Nobody watches a deploy nobody runs

`deploy.sh` is run by hand, per host, and nothing reports that a host has
fallen behind. On 2026-09-11 both hosts were found sitting 40 commits behind
main -- every deploy since the robots.txt change had aborted at `git pull`,
because the release build rewrites the tracked digested assets under
`apps/portal/priv/static` and leaves the checkout dirty. `deploy.sh` now
restores that one directory before pulling, but the wider point stands: the
script failing loudly into an empty terminal is indistinguishable from nobody
having deployed. To check where a host actually is:

```bash
for h in contabo.tompc.nl 100.106.217.14; do
  ssh "root@$h" 'cd /opt/nerves_compatibility/src && git log --oneline -1'
done
```

## Advisory audit

`build-release.sh` runs `mix deps.audit` before the release build and prints
loudly on a finding, but **does not fail the deploy**. The blocking copy is
GitHub Actions, which runs on every push to `main` and weekly against a lock
that has not changed — most advisories are published upstream against code
nobody touched, so the schedule is what actually catches them.

Reproduce either locally:

```bash
mix do deps.loadpaths + deps.audit   # `mix deps.audit` alone cannot find yaml_elixir
mix hex.audit                        # needs Hex >= 2.5 to report advisories at all
```

Run both. They read different sources: `mix_audit` uses a mirror of the GitHub
Advisory Database, `hex.audit` asks hex.pm, which carries EEF-issued CVEs the
mirror can lag on. If `hex.audit` says only `No retired packages found`, your
Hex is too old to be checking advisories -- `mix local.hex --force`.

## Not tracked here

`builder-run.sh` and `run-tests.sh` exist on the web host only and are still
untracked.
