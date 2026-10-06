# Sign in with Hex.pm and GitHub, and linked logins

Status: draft for review, not implemented.
Date: 2026-10-06.

## Problem

Accounts sign in with a username and password, optionally with a passkey or
TOTP. Hex.pm and GitHub are only used to prove package ownership for scan
requests, through their OAuth device flows (`Portal.HexPm`, `Portal.GitHub`).
Those flows already create or update a portal account as a side effect, but
nobody can sign in with them, and a user cannot attach them to an account they
made themselves.

The Hex flow also has a flaw that blocks adding Hex login safely:
`Portal.HexPm.upsert_hex_user/1` falls back to the local account whose
**username** equals the Hex username when no account is linked yet, and links
it without proof that it is the same person. With Hex login, a Hex user named
`tom` would be signed in as the local admin account `tom`. The GitHub flow
matches only on a stored `github_username` and has no such fallback, but it
matches on the GitHub login name, which a GitHub user can change and someone
else can then register.

## Goals

- Sign in with Hex.pm and with GitHub, from `/login`.
- One account can carry a password, a Hex.pm link and a GitHub link at once,
  and use any of them to sign in.
- A signed-in user can link and unlink Hex.pm and GitHub from settings.
- A first provider sign-in creates an account; if its username is taken, the
  user chooses another one.
- No identity is ever attached to an account without proof from the provider.

## Non-goals

- Email addresses, email login or reset-by-email.
- Other providers.
- Changing admin access: `/admin` keeps requiring a **passkey** sign-in, so a
  provider sign-in never grants admin rights, even for an admin.
- Changing what scan requests verify (package ownership, repo write access).

## Decisions

### Identity and matching

- An account has at most one Hex.pm link and one GitHub link, stored on the
  user as today (`hex_username`, `github_username`, profiles). A provider
  identity is linked to at most one account (unique index per provider).
- **Hex.pm** identities are matched on `hex_username`. Hex usernames cannot be
  changed by their owner.
- **GitHub** identities are matched on the **numeric user id**, new column
  `github_id`. The login name is kept for display and refreshed on every
  sign-in. Existing rows are backfilled from the stored `github_profile`
  JSON (`"id"`); a row whose profile has no id is matched by login once, on
  its next GitHub flow, and gets its id then.
- Matching only ever uses a stored, verified link. The username fallback in
  `Portal.HexPm` is removed.
- Existing links stay. Production has seven accounts; their links are listed on
  `/admin/users` and are checked by hand once, before release, for any that a
  username fallback could have attached to the wrong account.

### Sign-in flow

`/login` gets "Sign in with Hex.pm" and "Sign in with GitHub" buttons next to
the password form. Both run the provider's existing device flow on a new page:
the user sees a code and a link, approves on hex.pm or github.com, and the page
polls until done (the scan-request pages already work this way).

After the provider confirms the identity:

1. **Linked account exists**: sign in as that account with method `:hex` or
   `:github`. If the account has a second factor (TOTP or passkey), the same
   second step as a password sign-in follows (`Mfa.second_factor_required?`,
   the pending-session flow). The `last_*_login_at` timestamp updates.
2. **No linked account, provider username free locally**: create an account
   with that username, linked to the identity, and sign in.
3. **No linked account, username taken**: show "Choose a username" with the
   provider username suggested but rejected, and a field for another name. The
   verified identity waits in the session (signed cookie) for at most 10
   minutes; it is consumed once. On submit, the account is created with the
   chosen name and the identity linked. The page also says: "Already have an
   account here? Sign in with it and link Hex.pm under Settings."

A provider sign-in never matches or merges into an account by username.

### Accounts without a password

Accounts created by a provider (today's scan-request accounts included) have a
random password hash nobody knows. A new `password_set` flag (false for those,
true for registered accounts) lets settings show **Set a password** instead of
**Change password** (no current password asked). Setting one requires a
fresh sign-in (the existing 10-minute step-up window); for such accounts the
provider sign-in counts as the step-up method.

### Linking and unlinking

Settings gets a **Sign-in methods** card listing Password, Hex.pm and GitHub
with their state.

- **Link** runs the same device flow while signed in, behind the step-up check.
  It is refused if that identity is already linked to another account
  ("This Hex.pm account is linked to another user"). Linking never moves an
  identity between accounts.
- **Unlink** is allowed only while another way in remains: a password that is
  set, the other provider, or a passkey. Behind the step-up check.
- Every link, unlink and provider sign-in that creates an account is logged.

### Scan requests

The owner and repo flows keep verifying exactly what they verify today. Their
account handling changes to the same rules:

- signed in: link the identity to the current account if it is not linked
  elsewhere;
- not signed in, linked account exists: use it;
- not signed in, no linked account: create one only if the provider username is
  free; otherwise create the request with no account attached (`user_id` nil),
  which the request model already allows.

### Admin page

`/admin/users` already shows the Hex and GitHub links per user. It also shows
whether a password is set.

## Data

Migration on `portal_users`:

- `github_id` (bigint, nullable, unique) + backfill from `github_profile`.
- `password_set` (boolean, not null, default true); set to false for rows with
  `last_hex_login_at` or `last_github_login_at` and no successful password
  sign-in recorded. Since password sign-ins are not recorded today, the rule
  is: accounts whose `username` equals their provider username and that were
  created by a provider flow. The migration lists the rows it flips, and they
  are checked by hand before release (seven accounts in production).
- unique indexes on `hex_username` and `github_id` (where not null).

## Testing

- Sign in with a linked Hex.pm account; with a linked GitHub account (matched by
  id after a login-name change).
- First provider sign-in creates an account; a taken username leads to the
  choose-username step; the pending identity expires after 10 minutes and is
  single-use.
- **Takeover regressions**: a Hex user `tom` with no link never signs in as
  local `tom`; a GitHub user who took over a renamed login never signs in as the
  account linked to the old id.
- A second factor is still required after a provider sign-in.
- A provider sign-in never opens `/admin` (passkey required).
- Link from settings: refused without step-up; refused when the identity is
  linked elsewhere. Unlink refused when it would leave no way in.
- Set a password on a provider-created account.
- Scan-request flows: link when signed in; no account attached on a username
  collision; owner and repo checks unchanged.
- Device-flow failures (denied, expired, provider down) show a message and
  create nothing.

## Out of scope / later

- Showing linked providers on public profiles.
- Merging two existing accounts.
- Email.
