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

## Advisory audit

`build-release.sh` runs `mix deps.audit` before the release build and prints
loudly on a finding, but **does not fail the deploy**. The blocking copy is
GitHub Actions, which runs on every push to `main` and weekly against a lock
that has not changed — most advisories are published upstream against code
nobody touched, so the schedule is what actually catches them.

Reproduce either locally:

```bash
mix do deps.loadpaths + deps.audit   # `mix deps.audit` alone cannot find yaml_elixir
mix hex.audit                        # retired packages
```

## Not tracked here

`builder-run.sh` and `run-tests.sh` exist on the web host only and are still
untracked.
