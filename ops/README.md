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
| `contabo.tompc.nl` | public site (`compatibility.nerves-project.org`; old `nerves.tomhoenderdos.nl` 301s to it) | `intake:5,maintenance:1` |
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

## WebAuthn environment

`/etc/ncc-portal/portal.env` on the web host carries two settings that decide
the origin passkeys are bound to:

```bash
NCC_WEBAUTHN_RP_ID=compatibility.nerves-project.org
NCC_WEBAUTHN_ORIGIN=https://compatibility.nerves-project.org
```

Both are optional — unset, they fall back to `PHX_HOST` and `https://` plus
`PHX_HOST`, which gives the same answer today. Set them explicitly anyway,
because the fallback goes wrong silently: a passkey registered under one RP ID
cannot be used under another, and every existing passkey stops working the
moment the value changes. If the site ever moves domain, every user re-enrols.

Neither value is secret. They live in the env file where the rest of the
portal's configuration lives, not because they need protecting.

## Locked out of admin

Symptom: the only admin has lost every passkey, has no authenticator app, and
has no recovery codes. `/admin` redirects to `/settings/security` and nothing
can be changed there, because changing a factor needs a factor.

On the web host, as root. Running `bin/portal eval` on its own starts with no
database: `DATABASE_URL` lives in `/etc/ncc-portal/portal.env`, which systemd
loads for the running service but a plain shell does not, so the release must
be run as `ncc` with that file sourced first, the same way `ops/deploy.sh`
sources it to run migrations:

```bash
sudo -u ncc bash -c "cd /var/lib/ncc && set -a && . /etc/ncc-portal/portal.env && set +a && \
  /opt/nerves_compatibility/portal/bin/portal eval 'Portal.Accounts.Recovery.clear_factors!(\"tomhoenderdos\")'"
```

This deletes every passkey on the account, removes the authenticator app,
invalidates all outstanding recovery codes, and prints ten new ones. Copy them
out of the terminal before you close it — they are shown once and stored only
as SHA-256 hashes.

Then sign in at `/login` with the password. **No second factor will be asked
for** — the account no longer has one, so the login completes on the password
alone. Do not wait for a prompt; there is not one. Register a passkey at
`/settings/security`.

Keep the printed codes anyway. They are not needed for that first sign-in, but
once a passkey exists they become an accepted re-authentication method at
`/login` and `/settings/security` — the way back in if that passkey is lost
too.

`/admin` stays closed until a passkey exists, and until you sign in with it:
enrolling one upgrades the session you enrol it from, so the first visit works
without signing out.

This call runs against the live database and needs no downtime. It is not a
backdoor worth worrying about: anyone who can run it already has root on the
host holding `/etc/ncc-portal/portal.env`'s database credentials.

## Not tracked here

`builder-run.sh` and `run-tests.sh` exist on the web host only and are still
untracked.
