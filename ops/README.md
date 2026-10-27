# ops/

The deploy path. `.github/workflows/deploy.yml` deploys every push to `main`
once the security workflows have passed on that commit (see `DEPLOY.md`,
"Continuous deployment"). `deploy.sh` can still be run by hand on a host.

| Script | Runs | Purpose |
| --- | --- | --- |
| `wait-for-checks.sh` | in CI | waits for audit, CodeQL, Credo and Sobelow on the commit |
| `ssh-deploy.sh` | in CI | runs `deploy.sh <sha>` on the web host, or `deploy.sh <sha> builder` on the build host through it |
| `deploy-builders.sh` | on a laptop | deploys main's head to the hosts in `ops/builders.hosts` (not committed; see `builders.hosts.example`): installs that commit's `deploy.sh`/`build-release.sh`, runs `deploy.sh <sha> builder` detached, polls until done; `-n` dry run, `-s` one at a time, `-c <sha>` a given commit, `-f` redeploy a host already on it |
| `deploy.sh` | on a host | fast-forwards the checkout, builds the release, migrates, restarts |
| `build-release.sh` | on a host | builds the release in a container matching the host's glibc |
| `builder-deploy.sh` | on the build host | sourced by `deploy.sh`: installs and loads the egress filter, drains the build queues, swaps the worker image and warms the Nerves cache on it |
| `builder-egress-load.sh` | on the build host, as `ncc` | loads `builder-egress.nft` and `builder-egress-bridge.nft` into rootless dockerd's network namespace |
| `builder-egress.nft`, `builder-egress-bridge.nft` | loaded by the above | the build egress policy |
| `images-sync.sh` | on the web host | fetches `images.json` for a commit from its `agent-<sha>` GitHub release into `/etc/ncc-portal/images.json`; run by `deploy.sh` (best-effort) and by `ncc-images-sync.timer` |

## Hosts

Two hosts follow `main` and share one Postgres. The only difference between
them is `/etc/ncc-portal/portal.env`, which is **not** in this repo and holds
secrets.

| Host | Role | `OBAN_QUEUES` |
| --- | --- | --- |
| web host | public site, remote-builder listener (TCP 8443) | `intake:5,maintenance:1,remote:2` |
| build host | builds; owns the scratch and cache disks | `builds:N,ingest:N` |

Each build host also runs an ingest queue of its own, named after its node
(`ingest_portal_<host>`), so a build is ingested on the host whose disk holds its
scratch dir. It is added at boot and needs no entry in `OBAN_QUEUES`; give every
build host a distinct node name.

The home build hosts also share a build cache through Garage on a homelab host; see `docs/BUILD_CACHE_L2.md`.

## Remote builders

The web host serves remote builders on TCP 8443 (`NCC_BUILDER_PORT`), mTLS
against the CA at `NCC_BUILDER_CA_KEY`; open the port to the world. The
`remote:2` queue in its `OBAN_QUEUES` writes the leases and ingests their
uploads. `images.json` reaches the host through `images-sync.sh`:
`deploy.sh` runs it after each deploy, but the images workflow publishes the
file minutes later, so the `ncc-images-sync.timer` retries every 10 minutes:

```bash
/opt/nerves_compatibility/src/ops/images-sync.sh "$(cd /opt/nerves_compatibility/src && git rev-parse HEAD)"
```

Unit texts, the CA setup and the builder cloud-init are in
`docs/REMOTE_BUILDERS.md`.

## Installing a change

`deploy.sh` and `build-release.sh` are not read from the checkout: they live at
`/opt/nerves_compatibility/`, outside `$SRC`, so that a deploy cannot swap the
script out from under itself mid-run. After changing either, copy it to both
hosts:

```bash
for h in WEB_HOST BUILD_HOST; do
  scp ops/deploy.sh ops/build-release.sh "root@$h:/opt/nerves_compatibility/"
  ssh "root@$h" 'chmod +x /opt/nerves_compatibility/*.sh'
done
```

`builder-deploy.sh` is sourced from the checkout and needs no copying.

To check which commit a host is on:

```bash
for h in WEB_HOST BUILD_HOST; do
  ssh "root@$h" 'cd /opt/nerves_compatibility/src && git log --oneline -1'
done
```

## Egress filter

A build may reach DNS and TCP 80/443 on public addresses, and nothing else:
not the tailnet, not the web host's Postgres, not the LAN, over v4 or v6
(isolation spec, section 3). The rules are table `inet ncc_egress`
(`builder-egress.nft`) and, best effort, table `bridge ncc_egress`
(`builder-egress-bridge.nft`, container to container, needs the
`nft_meta_bridge` module). They live in the network namespace of rootless
dockerd's bridge. rootlesskit runs with `--detach-netns`, so that is the
namespace of `$XDG_RUNTIME_DIR/dockerd-rootless/child_pid`, not of
`docker.pid`: dockerd itself sits in the host namespace.

What a builder deploy does (`builder-deploy.sh`, as root):

1. Before pausing the queues: copies both rulesets to `/etc/ncc-portal/`
   (root, 644) and the loader to `/opt/nerves_compatibility/` (root, 755); on
   Ubuntu writes `~ncc/.config/systemd/user/docker.service.d/ncc-egress.conf`
   (`ExecStartPost=-…/builder-egress-load.sh`) as `ncc`, never as root, and
   reloads the user manager; runs the loader as `ncc`. Any failure stops the
   deploy with the running release and queues untouched.
2. Before moving the image tags: runs the new release's
   `Portal.Builder.check_egress/0`; a failure stops the deploy there, with
   the tags unmoved and the queues resumed on the running release. The new
   release is already installed and migrated by then, though, so the next
   restart, crash or reboot starts it, and it refuses every build (fail
   closed). The release it replaced is
   `/opt/nerves_compatibility/portal-previous.tar.gz`.
3. After the restart: asks the running `ncc-portal` service the same
   question over `rpc` (step 2's `eval` runs outside the unit's sandboxing,
   PATH and environment). Anything but `:ok` prints an error naming the
   likely unit settings (`RestrictNamespaces=`, `PrivateUsers=`, PATH,
   `XDG_RUNTIME_DIR`) and fails the deploy; nothing is rolled back and no
   queue is paused. Skipped with `NCC_EGRESS_CHECK=0`.

The namespace, and the rules with it, is recreated whenever the daemon
restarts. On Ubuntu the drop-in reloads them. On NixOS the docker user unit
comes from the nix store, so the same `ExecStartPost` must come from the
host's nix config (homelab repo); without it a daemon restart leaves the
host refusing builds until the loader runs again.

Every build first lists the table (`Portal.Builder.check_egress/0`). Where it
is missing, `build/2` returns `{:error, :egress_filter_missing}` and the job
snoozes 15 minutes; the portal also logs the state at boot.

Load or reload by hand, as root:

```bash
cd /tmp && sudo -u ncc env XDG_RUNTIME_DIR="/run/user/$(id -u ncc)" \
  /opt/nerves_compatibility/builder-egress-load.sh
```

Inspect:

```bash
cd /tmp && sudo -u ncc env XDG_RUNTIME_DIR="/run/user/$(id -u ncc)" sh -c \
  'nsenter -U --preserve-credentials -n -t "$(cat "$XDG_RUNTIME_DIR/dockerd-rootless/child_pid")" nft list table inet ncc_egress'
```

Ask the running service, which is what builds see:

```bash
cd /var/lib/ncc && sudo -u ncc -H env RELEASE_TMP=/var/lib/ncc/tmp bash -c \
  'set -a; . /etc/ncc-portal/portal.env; set +a; /opt/nerves_compatibility/portal/bin/portal rpc "IO.inspect(Portal.Builder.check_egress())"'
```

### Checking a host

Repeat after every deploy that changes the filter, on every build host. It
needs the web host's Postgres address over v4 and v6 (`tailscale ip -4` and
`tailscale ip -6` on the web host; Postgres listens on the v4 one), and takes a
few minutes because it runs one real build of `jason`. As root:

```bash
cd /tmp && sudo -u ncc bash -c '
  cd /var/lib/ncc
  set -a; . /etc/ncc-portal/portal.env; set +a
  export DOCKER_HOST="${DOCKER_HOST:-unix:///run/user/$(id -u)/docker.sock}"
  export NCC_EGRESS_PROBE="WEB_V4:5432,[WEB_V6]:5432"
  exec timeout 30m /opt/nerves_compatibility/portal/bin/portal eval "Portal.EgressCheck.main()"
'
```

It prints the preflight, a bare container's outcome per target and the build
worker's (`result.json` `egress_probe`), then `egress check PASSED` (exit 0)
when the filter is loaded, every target timed out or had no route, and the
`jason` build itself exited 0 with every system `pass` (a filter that breaks
DNS or 443 fails the check). `connected` or `refused` for any target is a
failure: the packet got through. So is a bare probe that never ran (`error:`,
docker itself failed).

### Rollback

1. Add `NCC_EGRESS_CHECK=0` to `/etc/ncc-portal/portal.env` and
   `systemctl restart ncc-portal`. Builds run again at once, unfiltered, and
   later deploys leave the filter alone.
2. Delete the tables:

   ```bash
   cd /tmp && sudo -u ncc env XDG_RUNTIME_DIR="/run/user/$(id -u ncc)" sh -c \
     'p=$(cat "$XDG_RUNTIME_DIR/dockerd-rootless/child_pid"); for f in inet bridge; do nsenter -U --preserve-credentials -n -t "$p" nft delete table "$f" ncc_egress; done'
   ```

3. On Ubuntu, so a daemon restart does not bring them back:
   `rm ~ncc/.config/systemd/user/docker.service.d/ncc-egress.conf` and
   `systemctl --user -M ncc@ daemon-reload`. On NixOS, revert the nix change.

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

First confirm which account you are recovering. Admin access is decided by one
column and nothing else, so the account to clear is whichever row says `t` —
not necessarily the one whose name matches yours:

```bash
psql "$DATABASE_URL" -Atc \
  "select username, is_admin from portal_users where is_admin"
```

On the web host, as root. Running `bin/portal eval` on its own starts with no
database: `DATABASE_URL` lives in `/etc/ncc-portal/portal.env`, which systemd
loads for the running service but a plain shell does not, so the release must
be run as `ncc` with that file sourced first, the same way `ops/deploy.sh`
sources it to run migrations:

```bash
sudo -u ncc bash -c "cd /var/lib/ncc && set -a && . /etc/ncc-portal/portal.env && set +a && \
  /opt/nerves_compatibility/portal/bin/portal eval 'Portal.Accounts.Recovery.clear_factors!(\"USERNAME\")'"
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
`/settings/security` — the way back in if that passkey is lost too. Sign in
with the password as above, then spend a code when the security page asks you
to re-authenticate. `/login` itself never asks for one: the recovery-code field
only appears behind the authenticator-app challenge, and this account has no
authenticator app.

`/admin` stays closed until a passkey exists, and until you sign in with it:
enrolling one upgrades the session you enrol it from, so the first visit works
without signing out.

This call runs against the live database and needs no downtime. It is not a
backdoor worth worrying about: anyone who can run it already has root on the
host holding `/etc/ncc-portal/portal.env`'s database credentials.

## Not tracked here

`builder-run.sh` and `run-tests.sh` exist on the web host only and are still
untracked.
