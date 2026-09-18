# Multi-factor authentication: passkeys and TOTP

Status: approved design, not yet implemented.
Date: 2026-09-18.

## Problem

The portal's only credential is a password. `router.ex:54-55` exposes public
`/register`, `Portal.Accounts.User` carries an `is_admin` bit, and that bit gates
`/admin` and `/admin/oban`. Oban Web can cancel, retry and delete jobs across the
whole fleet, so a single phished password is full control of the build pipeline.

Auth is hand-rolled on Argon2 (`Portal.Accounts.register_user/2` and
`authenticate_user/2`), with session state reduced to one key — `:user_id` — read
by `PortalWeb.UserAuth` and the `RequireLogin` / `RequireAdmin` plugs. There is no
authentication framework to enable a feature flag on, but the small surface means
a second factor has few places to hook into.

`ash_authentication` was considered and rejected: it ships password, magic link
and OAuth2, but no WebAuthn, so adopting it would mean migrating working auth and
still hand-rolling passkeys.

Reusing the existing GitHub device flow (`Portal.GitHub`) as a second factor was
also rejected. It is written and tested, but device-flow codes are phishable —
the attack is convincing someone to type a code into the genuine GitHub page — so
it would add a factor with the exact weakness we are trying to remove, plus a
hard dependency on GitHub being reachable to enter `/admin` during an incident.

## Scope

In: passkeys (WebAuthn) as a primary passwordless credential, TOTP as a second
factor for password logins, recovery codes, enrolment UI, and enforcement for
admins.

Out: password reset flows, email (the portal sends none and stores no addresses),
SMS, WebAuthn for the JSON API (`/api/*` is unauthenticated and read-only), and
any change to the GitHub or Hex maintainer-verification flows.

## Who must use what

| account | requirement | accepted factors |
| --- | --- | --- |
| `is_admin` | mandatory | passkey only |
| everyone else | optional | passkey or TOTP |

TOTP does not satisfy the admin requirement. This is deliberate and is the one
rule most likely to look like an oversight later.

An account is only as strong as its weakest factor. An admin holding both a
passkey and TOTP can still be phished down to the TOTP, so offering both to
admins would spend the phishing resistance that motivated passkeys in the first
place. Community users face no targeted phishing and mostly need *something*;
some will be on devices where passkey registration fails, and TOTP is the only
realistic option for them.

Enrolment state is derived, never stored: an admin is satisfied when they hold at
least one passkey, a community user when they hold a passkey or a confirmed TOTP.
There is no flag to drift out of sync, and `set_admin` needs no special handling —
a newly promoted admin fails the check on their next `/admin` request.

## Data model

Three new resources in `Portal.Accounts`. Nothing is added to `User`: it is
assigned as `current_user` on every LiveView mount and passed into layouts, so
anything stored on it is one `inspect` away from a log line.

### `Portal.Accounts.Passkey` → `portal_passkeys`

Many per user, so a laptop and a phone can both be registered.

| field | type | notes |
| --- | --- | --- |
| `credential_id` | binary | unique identity |
| `public_key` | binary | COSE key from Wax, `:erlang.term_to_binary/1`; read back with `binary_to_term(bin, [:safe])` |
| `sign_count` | integer | see sign-count policy below |
| `aaguid` | binary | nullable |
| `transports` | array of string | nullable |
| `nickname` | string | user-supplied label |
| `last_used_at` | utc_datetime_usec | nullable |
| `user_id` | uuid | `belongs_to :user`, `allow_nil? false` |

### `Portal.Accounts.TotpSecret` → `portal_totp_secrets`

One per user, `sensitive?(true)`.

| field | type | notes |
| --- | --- | --- |
| `secret` | binary | |
| `confirmed_at` | utc_datetime_usec | null until one working code is proven |
| `last_used_step` | integer | blocks replay of a code inside its own window |
| `failed_attempts` | integer | default 0 |
| `locked_until` | utc_datetime_usec | nullable |
| `user_id` | uuid | unique identity |

An unconfirmed secret never counts as a factor. A half-finished enrolment that
counted would lock the user out.

### `Portal.Accounts.RecoveryCode` → `portal_recovery_codes`

Ten per generation.

| field | type | notes |
| --- | --- | --- |
| `code_hash` | string | SHA-256 hex, see below |
| `used_at` | utc_datetime_usec | nullable |
| `user_id` | uuid | `belongs_to :user` |

## Recovery codes: 80 bits, SHA-256

`:crypto.strong_rand_bytes(10)` is exactly 80 bits and Base32-encodes (RFC 4648)
to 16 characters with no padding. Displayed lowercase in four groups:
`k3mq-7x2p-9vhd-t4rs`. Input strips dashes and normalises case. The Base32
alphabet is `A-Z` plus `2-7`, which has no `0`/`O` or `1`/`I`/`l` pairs, so there
is nothing to misread off a printed sheet.

Recovery codes hash with **SHA-256, not Argon2**, unlike passwords. Argon2 exists
to make low-entropy human-chosen passwords expensive to guess. These are 80 bits
of CSPRNG output, so there is nothing to brute-force, and Argon2 would cost up to
ten ~100 ms verifications per login attempt.

The two choices are coupled and must move together. A fast hash means the codes
carry their own weight against an **offline** attack on a leaked database, where
rate limiting cannot help because the attacker never talks to our server. At 80
bits that is ~10²⁴ candidates. Shorter, friendlier codes (GitHub's are ~40 bits,
Google's 8-digit ones ~27) are only safe paired with slow hashing. Do not shorten
these without switching to Argon2.

## Login flows

### Passwordless passkey login

1. `/login` offers "Sign in with passkey" beside the existing form.
2. `POST /auth/passkey/challenge` returns `Wax.new_authentication_challenge/1`
   output. The challenge is stored in the signed session, single-use, five-minute
   expiry, deleted on use — not in the database.
3. The browser returns an assertion to `POST /auth/passkey/verify`.
4. `Wax.authenticate/6` verifies it. No username is typed: the challenge omits
   `allow_credentials`, the assertion comes back with a `userHandle`, we look up
   that user's passkeys and pass them as the `credentials` argument. This
   requires the browser to have registered with `residentKey: "required"`.
5. On success: `put_session(:user_id, ...)`, `configure_session(renew: true)`,
   update `sign_count` and `last_used_at`.

### Password login

`create_session` stops calling `put_session(:user_id, ...)` on success.

1. `authenticate_user/2` succeeds.
2. If the user has a confirmed TOTP: set `:pending_user_id` plus a timestamp,
   redirect to `/login/totp`. Do **not** set `:user_id`.
3. `/login/totp` accepts a six-digit code or a recovery code.
4. On success: promote to `:user_id`, `renew: true` to rotate the session id so a
   fixated pre-login cookie is worthless, clear the pending keys.
5. Users with no confirmed factor are promoted immediately, as today.

The pending session expires after five minutes.

### Brute force

Six digits is a million guesses, and an attacker who already holds the password
will spend them. TOTP verification increments `failed_attempts`; after five
failures `locked_until` is set, the pending session is dropped, and the password
step must be repeated.

### Recovery codes

Accepted anywhere a TOTP code is. Consumed on use (`used_at`), single-use, with a
warning shown when two or fewer remain.

## Enrolment

Lives at `/settings/security`:

- register a passkey with a nickname; `excludeCredentials` carries existing
  credential ids so the same authenticator cannot be enrolled twice
- remove a passkey
- enrol TOTP from a QR code (`otpauth://` URI) plus a manual key, confirmed by one
  working code before it counts
- view remaining recovery codes and regenerate them

Recovery codes are generated on first successful factor enrolment and shown once.

### Authorising a factor change

Changing any factor requires re-authentication within the last ten minutes, and
**the password only counts while the account holds no factor yet**.

| account state | may add or remove a factor with |
| --- | --- |
| no factor yet | password |
| holds a passkey | passkey assertion, or an unused recovery code |
| holds TOTP only | TOTP code, or an unused recovery code |

The bootstrap case is the only one where a password is sufficient, because it is
the only credential that exists.

Accepting the password forever would make the admin passkey requirement
decorative. A phished password would let an attacker enrol their own passkey and
walk into `/admin` — the precise attack passkeys were chosen to stop. It would
also mean a stolen session cookie could be converted into permanent access that
survives a password change.

This is what recovery codes are *for* on a passkey-only admin account. Losing the
only passkey is not recoverable by password: the account can still sign in, but
cannot enrol a replacement or reach `/admin` without a recovery code. If the codes
are gone too, the remaining route is break-glass on the host.

## Enforcement

`PortalWeb.Plugs.RequireAdmin` gains a second condition: `is_admin` **and** at
least one passkey. Failing accounts are redirected to `/settings/security` with an
explanatory flash.

The check deliberately lives in that plug, which already guards only the `/admin`
scope, rather than as a global interstitial. An admin keeps normal use of the rest
of the site and simply cannot enter `/admin` until enrolled. A global interstitial
would need carve-outs for the settings page, the enrolment endpoints and logout,
and each carve-out is a chance to build a redirect loop that locks you out of the
very page that fixes it.

Cost is one indexed count per admin request.

## Break-glass

A release eval on the web host:

```
bin/portal eval 'Portal.Accounts.Recovery.clear_factors!("tomhoenderdos")'
```

Removes every passkey, TOTP secret and recovery code for that user, logs at
`:warning`, and leaves the password intact — the account drops to password-only
and enforcement immediately demands re-enrolment.

This grants nothing new. Anyone who can run it already has root on the web host,
where `/etc/ncc-portal/portal.env` and the database credentials live. Document in
`ops/README.md`.

Without it, a lost device plus a lost recovery sheet means `/admin` is gone
permanently and the only way back is hand-editing production Postgres.

## WebAuthn configuration

`rp_id` and `origin` are explicit config, read from env in `runtime.exs`:

| env | rp_id | origin |
| --- | --- | --- |
| prod | `compatibility.nerves-project.org` | `https://compatibility.nerves-project.org` |
| dev | `localhost` | `http://localhost:4001` |

They are never derived from the request. The portal sits behind Virtualmin's
Apache and depends on `X-Forwarded-Proto` to know it is on HTTPS, so a derived
origin would fail closed the moment that header is misconfigured — and the `Host`
header is attacker-supplied in the first place. WebAuthn requires a secure
context, which `localhost` satisfies without TLS.

`origin` is mandatory in `wax_` and has no default, so it must be configured in
any case. `rp_id` defaults to `:auto`, deriving from the origin host; we set it
explicitly rather than rely on that.

Server-side options (`wax_`):

- `user_verification: "required"` — default is `"preferred"`. Required makes the
  passkey possession plus biometric or PIN, which is what earns it the right to
  log in without a password.
- `attestation: "none"` — already the default. We have no reason to care which
  vendor made the authenticator, and requesting attestation creates a privacy
  question we would then have to justify.
- `timeout: 300` — default is 20 minutes; match the five-minute challenge expiry.
- Do **not** pass `bytes`. Supplying our own challenge is flagged in the `wax_`
  security notes as violating the standard's recommendation and opening a replay
  window. Let the library generate it.

Browser-side, in `navigator.credentials.create`: `residentKey: "required"`. This
is not a `wax_` option — it is a client parameter, and the server side of
discoverable credentials is handled by omitting `allow_credentials` and resolving
the user from `userHandle`.

### Sign-count policy

`wax_` has **no** counter option. It returns `sign_count` in the
`Wax.AuthenticatorData` struct and leaves the policy entirely to the caller, so
this is our code to write.

Apple's iCloud Keychain passkeys always report a counter of 0, so a naive
"counter must increase" check rejects the authenticator most likely to be used
first. The rule: when both the stored and incoming counts are 0, skip the
comparison; otherwise flag a non-zero counter that moves backwards.

## Dependencies

- `wax_ ~> 0.7` — WebAuthn. Note the trailing underscore: plain `wax` on Hex is an
  unrelated package.
- `nimble_totp ~> 1.0`

Both go in `apps/portal/mix.exs`. Run `mix deps.get` from the umbrella root only.
A `mix deps.*` inside `apps/` rewrites the shared lock against one child's
dependency list and prunes root-only deps such as `mix_audit`; the audit workflow
checks lock currency.

## Tests

CI has no authenticator, which makes WebAuthn the hard part.

- **Software authenticator for tests.** An EC key via `:public_key` signing
  challenges the way a real authenticator would, roughly a hundred lines. This
  gives real round-trip coverage of registration and authentication. Mocking Wax
  at the boundary would exercise our plumbing and none of the verification, which
  is the part worth testing.
- **TOTP** with fixed secrets and injected clocks: valid code, expired code,
  replay of a code inside its own window, lockout after five failures.
- **Recovery codes**: single use, consumed, case and dash normalisation, warning
  threshold.
- **Enforcement**: admin without a passkey is redirected from `/admin`; admin with
  one passes; a user promoted by `set_admin` is redirected on the next request.
- **Authorising a factor change**: password alone adds the first factor; password
  alone is rejected once a passkey exists; a recovery code authorises the change;
  the window is rejected outside ten minutes.
- **Sign count**: 0-to-0 accepted, increasing accepted, non-zero going backwards
  flagged.
- **Session**: `:pending_user_id` alone grants nothing; session id rotates on
  promotion.

Each guard gets a non-vacuity check, per the precedent set on the manifest
membership fix: revert the guard, confirm the test fails, restore.

`mix precommit` in `apps/portal` when finishing.

## Deferred

- Durable audit trail. Factor changes, recovery-code use and break-glass log at
  `:warning` only, and host logs rotate, so this is not durable evidence. A
  `portal_security_events` table would be, if it turns out to be wanted.
- "Remember this device" for TOTP.
- WebAuthn for anything under `/api`.
