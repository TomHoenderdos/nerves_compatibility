# Multi-factor authentication (passkeys + TOTP) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give portal accounts a phishing-resistant credential — passkeys as a primary passwordless login, TOTP as a second factor for password logins, recovery codes as the escape hatch — and require a passkey of anyone entering `/admin`.

**Architecture:** Three new Ash resources hang off `Portal.Accounts.User` (`Passkey`, `TotpSecret`, `RecoveryCode`); nothing is added to `User` itself, because `User` is assigned as `current_user` on every mount and passed into layouts. Five thin context modules sit on top — `Passkeys`, `Totp`, `RecoveryCodes`, `WebAuthn` (all `wax_` plumbing), and `Mfa` (policy: who needs what, and what may authorise a factor change). The web layer gains three controllers: `PasskeyController` (JSON, passwordless login), `MfaController` (the `/login/totp` step), and `SecurityController` (`/settings/security` enrolment). Enrolment state is derived on read, never stored, so there is no flag to drift.

**Tech Stack:** Elixir/Phoenix 1.8, Ash 3 + AshPostgres, `wax_ ~> 0.7` (WebAuthn), `nimble_totp ~> 1.0`, `cbor ~> 1.0` (transitive via `wax_`, used by the test authenticator), esbuild-bundled vanilla JS.

**Spec:** `docs/superpowers/specs/2026-09-18-mfa-passkeys-design.md`

## Global Constraints

- **Umbrella dependency rule.** Run `mix deps.get` **from the repo root only**. A `mix deps.*` task inside `apps/*` rewrites the shared root `mix.lock` against one child's dependency list and silently prunes root-only deps such as `mix_audit`. CI checks lock currency in `.github/workflows/audit.yml`. Non-deps mix tasks (`mix test`, `mix ash_postgres.generate_migrations`, `mix format`) inside `apps/portal` are fine.
- **Package name is `wax_`, with a trailing underscore.** Plain `wax` on Hex is an unrelated package.
- **Recovery codes are 80 bits (`:crypto.strong_rand_bytes(10)`) hashed with SHA-256, not Argon2.** These two choices are coupled and must move together. Do not shorten the codes without switching to Argon2.
- **Passkeys are the only factor that satisfies an admin.** TOTP does not. This is deliberate and is the rule most likely to look like an oversight later.
- **`rp_id` and `origin` are explicit configuration, never derived from the request.** The portal sits behind Apache and trusts `X-Forwarded-Proto`; the `Host` header is attacker-supplied.
- **Never pass `bytes:` to a `wax_` challenge constructor.** `wax_`'s security notes flag caller-supplied challenges as a replay window. Let the library generate them.
- **Fixed `wax_` options everywhere:** `user_verification: "required"`, `attestation: "none"`, `timeout: 300` (seconds).
- **`residentKey: "required"` is browser-side**, in `navigator.credentials.create`. The server half of discoverable credentials is omitting `allow_credentials` and resolving the user from `userHandle`.
- **Sign-count carve-out:** Apple iCloud Keychain passkeys always report a counter of 0. A stored count of 0 means "no baseline" and always passes.
- **Non-vacuity check on every guard.** After a guard's test passes, revert the guard, confirm the test fails, restore it. This is the precedent set by the manifest-membership fix.
- **No maintainer email addresses** enter the database or any rendered page. Unrelated to this feature, but the rule stands.
- Ash style in this repo: `use Ash.Resource, domain: …, data_layer: AshPostgres.DataLayer`, `postgres do table(…) repo(Portal.Repo) end`, `actions do defaults([:read]) …`, attributes in `attribute :name, :type do … end` block form. Mirror `apps/portal/lib/portal/accounts/user.ex`.
- Migrations are **generated**, not hand-written: `mix ash_postgres.generate_migrations --name <name>` from `apps/portal`, with snapshots in `apps/portal/priv/resource_snapshots/`.
- `mix precommit` in `apps/portal` when the branch is finished.

## Two refinements to the spec

Both are deliberate and should not be "fixed" back to the spec's wording:

1. **`TotpSecret.last_used_step` becomes `last_used_at` (`utc_datetime_usec`).** The spec named an integer step counter, but `NimbleTOTP.valid?/3` takes `since:` as a `DateTime`/`NaiveDateTime`/Unix-seconds value, not a step index. Storing the timestamp the library actually wants removes a conversion that could only be wrong. Replay protection is identical.
2. **A sign-count regression rejects the assertion** rather than merely being recorded. The spec says "flag"; for a credential that gates `/admin`, a clone signal should fail closed. It logs at `:warning` on the way out.

## File structure

**New — domain:**

| File | Responsibility |
| --- | --- |
| `apps/portal/lib/portal/accounts/passkey.ex` | Ash resource, `portal_passkeys` |
| `apps/portal/lib/portal/accounts/totp_secret.ex` | Ash resource, `portal_totp_secrets` |
| `apps/portal/lib/portal/accounts/recovery_code.ex` | Ash resource, `portal_recovery_codes` |
| `apps/portal/lib/portal/accounts/passkeys.ex` | Query/command helpers for passkeys |
| `apps/portal/lib/portal/accounts/totp.ex` | TOTP enrolment, verification, replay, lockout |
| `apps/portal/lib/portal/accounts/recovery_codes.ex` | Generation, formatting, consumption |
| `apps/portal/lib/portal/accounts/web_authn.ex` | All `wax_` plumbing; sign-count policy |
| `apps/portal/lib/portal/accounts/mfa.ex` | Policy: factors held, admin requirement, re-auth rules |
| `apps/portal/lib/portal/accounts/recovery.ex` | Break-glass `clear_factors!/1` |

**New — web:**

| File | Responsibility |
| --- | --- |
| `apps/portal/lib/portal_web/controllers/passkey_controller.ex` | JSON challenge/verify for passwordless login |
| `apps/portal/lib/portal_web/controllers/mfa_controller.ex` | `/login/totp` second-factor step |
| `apps/portal/lib/portal_web/controllers/security_controller.ex` | `/settings/security` enrolment |
| `apps/portal/lib/portal_web/controllers/mfa_html.ex` + `mfa_html/totp_challenge.html.heex` | TOTP step template |
| `apps/portal/lib/portal_web/controllers/security_html.ex` + `security_html/show.html.heex` | Security settings page |
| `apps/portal/lib/portal_web/web_authn_session.ex` | Stashes a challenge in the session, single-use, with a TTL |
| `apps/portal/assets/js/webauthn.js` | Browser WebAuthn glue |

**New — test support:**

| File | Responsibility |
| --- | --- |
| `apps/portal/test/support/software_authenticator.ex` | Real EC-signing authenticator for round-trip tests |
| `apps/portal/test/support/fixtures/accounts_fixtures.ex` | `user_fixture/1`, `admin_fixture/1` |

**Modified:**

| File | Change |
| --- | --- |
| `apps/portal/mix.exs` | add `wax_`, `nimble_totp` |
| `apps/portal/config/config.exs` | dev/test WebAuthn defaults |
| `config/runtime.exs` | prod WebAuthn config, inside the `config_env() == :prod` block |
| `apps/portal/lib/portal/accounts.ex` | register the three resources |
| `apps/portal/lib/portal_web/user_auth.ex` | `complete_login/3`, `mark_reauth/2`, `reauth_method/1`, `reauth_at/1`, pending-session helpers |
| `apps/portal/lib/portal_web/controllers/page_controller.ex:137-143` | two-phase `create_session/2` |
| `apps/portal/lib/portal_web/controllers/page_html/login.html.heex` | "Sign in with a passkey" button |
| `apps/portal/lib/portal_web/controllers/page_html/settings.html.heex` | link to `/settings/security` |
| `apps/portal/lib/portal_web/plugs/require_admin.ex` | passkey requirement |
| `apps/portal/lib/portal_web/router.ex` | new routes |
| `apps/portal/assets/js/app.js` | `import {initWebAuthn}` and call it |
| `ops/README.md` | break-glass procedure |

---

### Task 1: Dependencies and WebAuthn configuration

**Files:**
- Modify: `apps/portal/mix.exs` (the `defp deps` list)
- Modify: `apps/portal/config/config.exs` (append a new config block)
- Modify: `config/runtime.exs` (inside `if config_env() == :prod do`, near the existing `host = System.get_env("PHX_HOST") || "example.com"`)
- Create: `apps/portal/lib/portal/accounts/web_authn.ex`
- Test: `apps/portal/test/portal/accounts/web_authn_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `Portal.Accounts.WebAuthn.opts(extra :: keyword()) :: keyword()` — the base `wax_` challenge options with `extra` merged over them. Every later task that builds a challenge goes through this.

- [ ] **Step 1: Add the dependencies**

In `apps/portal/mix.exs`, inside `defp deps`, after `{:argon2_elixir, "~> 4.1"},`:

```elixir
      {:wax_, "~> 0.7"},
      {:nimble_totp, "~> 1.0"},
```

Note the trailing underscore on `wax_`. `wax_` pulls in `cbor ~> 1.0`, which Task 5's test authenticator uses.

- [ ] **Step 2: Fetch dependencies from the umbrella root**

```bash
cd /Users/tomhoenderdos/Projects/nerves_compatibility && mix deps.get
```

Never run this from inside `apps/portal` — it prunes root-only deps from the shared lock. Confirm afterwards that `mix_audit` is still in the lock:

```bash
grep -c '"mix_audit"' mix.lock
```

Expected: `1`. If it is `0`, the lock was pruned — `git checkout mix.lock`, then re-run from the root.

- [ ] **Step 3: Write the failing test**

`apps/portal/test/portal/accounts/web_authn_test.exs`:

```elixir
defmodule Portal.Accounts.WebAuthnTest do
  use ExUnit.Case, async: true

  alias Portal.Accounts.WebAuthn

  test "base options come from config and pin the security-relevant values" do
    opts = WebAuthn.opts()

    assert opts[:rp_id] == "localhost"
    assert opts[:origin] == "http://localhost:4001"
    assert opts[:user_verification] == "required"
    assert opts[:attestation] == "none"
    assert opts[:timeout] == 300
  end

  test "never supplies its own challenge bytes" do
    # wax_'s security notes call a caller-supplied challenge a replay window.
    refute Keyword.has_key?(WebAuthn.opts(), :bytes)
    refute Keyword.has_key?(WebAuthn.opts(allow_credentials: []), :bytes)
  end

  test "extra options merge over the defaults" do
    opts = WebAuthn.opts(allow_credentials: [], timeout: 60)

    assert opts[:allow_credentials] == []
    assert opts[:timeout] == 60
    assert opts[:rp_id] == "localhost"
  end
end
```

- [ ] **Step 4: Run it and watch it fail**

```bash
cd apps/portal && mix test test/portal/accounts/web_authn_test.exs
```

Expected: FAIL — `module Portal.Accounts.WebAuthn is not available`.

- [ ] **Step 5: Add the configuration**

Append to `apps/portal/config/config.exs`:

```elixir
# WebAuthn relying party. Explicit, never derived from the request: the Host
# header is attacker-supplied, and the portal learns its scheme from
# X-Forwarded-Proto behind Apache, so a derived origin fails closed the moment
# that header is misconfigured. `config/runtime.exs` overrides both in prod.
# localhost is a secure context without TLS, which is what makes dev work.
config :portal, Portal.Accounts.WebAuthn,
  rp_id: "localhost",
  origin: "http://localhost:4001"
```

In `config/runtime.exs`, inside the `if config_env() == :prod do` block, just after the `host = System.get_env("PHX_HOST") || "example.com"` line:

```elixir
    # The relying party id is the registrable domain a passkey is bound to.
    # Changing it invalidates every registered passkey, so it tracks PHX_HOST
    # rather than being a second thing to keep in sync.
    webauthn_rp_id = System.get_env("NCC_WEBAUTHN_RP_ID") || host

    config :portal, Portal.Accounts.WebAuthn,
      rp_id: webauthn_rp_id,
      origin: System.get_env("NCC_WEBAUTHN_ORIGIN") || "https://#{webauthn_rp_id}"
```

- [ ] **Step 6: Write the module**

`apps/portal/lib/portal/accounts/web_authn.ex`:

```elixir
defmodule Portal.Accounts.WebAuthn do
  @moduledoc """
  WebAuthn plumbing around `wax_`.

  Relying-party id and origin are explicit configuration and are never derived
  from the request. `user_verification: "required"` is what earns a passkey the
  right to log in without a password: possession plus a biometric or PIN.
  """

  @doc """
  Base `wax_` challenge options, with `extra` merged over them.

  Never returns `:bytes` — supplying our own challenge is flagged in the `wax_`
  security notes as violating the standard's recommendation and opening a
  replay window. The library generates it.
  """
  @spec opts(keyword()) :: keyword()
  def opts(extra \\ []) do
    config = Application.fetch_env!(:portal, __MODULE__)

    [
      rp_id: Keyword.fetch!(config, :rp_id),
      origin: Keyword.fetch!(config, :origin),
      user_verification: "required",
      attestation: "none",
      timeout: 300
    ]
    |> Keyword.merge(extra)
  end
end
```

- [ ] **Step 7: Run the tests**

```bash
cd apps/portal && mix test test/portal/accounts/web_authn_test.exs
```

Expected: 3 tests, 0 failures.

- [ ] **Step 8: Commit**

```bash
git add apps/portal/mix.exs mix.lock apps/portal/config/config.exs config/runtime.exs \
  apps/portal/lib/portal/accounts/web_authn.ex \
  apps/portal/test/portal/accounts/web_authn_test.exs
git commit -m "feat(portal): add wax_ and nimble_totp with explicit WebAuthn config"
```

The working tree may already carry unrelated uncommitted changes to `mix.exs`, `mix.lock`, `apps/portal/lib/portal_web/components/layouts/root.html.heex`, `apps/portal/lib/portal_web/live/dashboard_live.ex` and an untracked `.tool-versions`. Stage only the files listed above; never `git add -A` on this branch.

---

### Task 2: The three resources, the migration, and the passkey context

**Files:**
- Create: `apps/portal/lib/portal/accounts/passkey.ex`
- Create: `apps/portal/lib/portal/accounts/totp_secret.ex`
- Create: `apps/portal/lib/portal/accounts/recovery_code.ex`
- Create: `apps/portal/lib/portal/accounts/passkeys.ex`
- Create: `apps/portal/test/support/fixtures/accounts_fixtures.ex`
- Modify: `apps/portal/lib/portal/accounts.ex:8-10` (the `resources do` block)
- Generated: one migration under `apps/portal/priv/repo/migrations/` plus snapshots under `apps/portal/priv/resource_snapshots/`
- Test: `apps/portal/test/portal/accounts/passkeys_test.exs`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `Portal.Accounts.Passkey` with fields `:id, :credential_id, :public_key, :sign_count, :aaguid, :transports, :nickname, :last_used_at, :user_id`
  - `Portal.Accounts.TotpSecret` with `:id, :secret, :confirmed_at, :last_used_at, :failed_attempts, :locked_until, :user_id`
  - `Portal.Accounts.RecoveryCode` with `:id, :code_hash, :used_at, :user_id`
  - `Portal.Accounts.Passkeys.list_for_user(user) :: [Passkey.t()]`
  - `Portal.Accounts.Passkeys.count_for_user(user) :: non_neg_integer()`
  - `Portal.Accounts.Passkeys.get_by_credential_id(binary) :: {:ok, Passkey.t()} | :error`
  - `Portal.Accounts.Passkeys.create(user, attrs :: map) :: {:ok, Passkey.t()} | {:error, term}`
  - `Portal.Accounts.Passkeys.delete(user, id :: String.t()) :: :ok | {:error, :not_found}`
  - `Portal.Accounts.Passkeys.record_use(passkey, sign_count :: non_neg_integer()) :: {:ok, Passkey.t()} | {:error, term}`
  - `Portal.Test.AccountsFixtures.user_fixture/1` and `admin_fixture/1`

- [ ] **Step 1: Write the failing test**

`apps/portal/test/portal/accounts/passkeys_test.exs`:

```elixir
defmodule Portal.Accounts.PasskeysTest do
  use Portal.DataCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.Passkeys

  test "stores a credential and finds it by credential id" do
    user = user_fixture()

    {:ok, passkey} =
      Passkeys.create(user, %{
        credential_id: <<1, 2, 3>>,
        public_key: :erlang.term_to_binary(%{1 => 2, 3 => -7}),
        nickname: "laptop",
        aaguid: <<0::128>>,
        transports: ["internal"]
      })

    assert passkey.sign_count == 0
    assert passkey.user_id == user.id
    assert {:ok, found} = Passkeys.get_by_credential_id(<<1, 2, 3>>)
    assert found.id == passkey.id
    assert Passkeys.count_for_user(user) == 1
  end

  test "the same credential cannot be registered twice" do
    user = user_fixture()
    attrs = %{credential_id: <<9, 9>>, public_key: <<0>>, nickname: "one"}

    assert {:ok, _} = Passkeys.create(user, attrs)
    assert {:error, _} = Passkeys.create(user, %{attrs | nickname: "two"})
  end

  test "records use by advancing the sign count and stamping last_used_at" do
    user = user_fixture()
    {:ok, passkey} = Passkeys.create(user, %{credential_id: <<7>>, public_key: <<0>>, nickname: "k"})

    assert {:ok, updated} = Passkeys.record_use(passkey, 42)
    assert updated.sign_count == 42
    assert updated.last_used_at
  end

  test "delete only removes the caller's own passkey" do
    owner = user_fixture()
    stranger = user_fixture()
    {:ok, passkey} = Passkeys.create(owner, %{credential_id: <<5>>, public_key: <<0>>, nickname: "k"})

    assert Passkeys.delete(stranger, passkey.id) == {:error, :not_found}
    assert Passkeys.count_for_user(owner) == 1
    assert Passkeys.delete(owner, passkey.id) == :ok
    assert Passkeys.count_for_user(owner) == 0
  end

  test "a TOTP secret is unique per user and starts unconfirmed" do
    user = user_fixture()

    secret =
      Portal.Accounts.TotpSecret
      |> Ash.Changeset.for_create(:create, %{secret: NimbleTOTP.secret(), user_id: user.id})
      |> Ash.create!(domain: Portal.Accounts)

    assert is_nil(secret.confirmed_at)
    assert secret.failed_attempts == 0

    assert_raise Ash.Error.Invalid, fn ->
      Portal.Accounts.TotpSecret
      |> Ash.Changeset.for_create(:create, %{secret: NimbleTOTP.secret(), user_id: user.id})
      |> Ash.create!(domain: Portal.Accounts)
    end
  end

  test "a recovery code stores only a hash" do
    user = user_fixture()

    code =
      Portal.Accounts.RecoveryCode
      |> Ash.Changeset.for_create(:create, %{code_hash: String.duplicate("a", 64), user_id: user.id})
      |> Ash.create!(domain: Portal.Accounts)

    assert is_nil(code.used_at)
    refute Map.has_key?(code, :code)
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd apps/portal && mix test test/portal/accounts/passkeys_test.exs
```

Expected: FAIL — `Portal.Test.AccountsFixtures is not available`.

- [ ] **Step 3: Write the fixtures**

`apps/portal/test/support/fixtures/accounts_fixtures.ex`:

```elixir
defmodule Portal.Test.AccountsFixtures do
  @moduledoc """
  Users for tests that need one to hang credentials off.
  """

  @doc """
  A registered user. `:password` defaults to something over the 12-character
  minimum that `Portal.Accounts.valid_password?/1` enforces.
  """
  def user_fixture(attrs \\ %{}) do
    username = Map.get(attrs, :username, "user#{System.unique_integer([:positive])}")
    password = Map.get(attrs, :password, "correct horse battery staple")

    Portal.Accounts.User
    |> Ash.Changeset.for_create(:create, %{
      username: username,
      password_hash: Argon2.hash_pwd_salt(password),
      is_admin: Map.get(attrs, :is_admin, false)
    })
    |> Ash.create!(domain: Portal.Accounts)
  end

  def admin_fixture(attrs \\ %{}) do
    attrs |> Map.put(:is_admin, true) |> user_fixture()
  end
end
```

- [ ] **Step 4: Write the three resources**

`apps/portal/lib/portal/accounts/passkey.ex`:

```elixir
defmodule Portal.Accounts.Passkey do
  @moduledoc """
  A registered WebAuthn credential. Many per user, so a laptop and a phone can
  both sign in.

  Nothing here lives on `Portal.Accounts.User`: that struct is assigned as
  `current_user` on every LiveView mount and passed into layouts, so anything
  stored on it is one `inspect` away from a log line.
  """

  use Ash.Resource,
    domain: Portal.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("portal_passkeys")
    repo(Portal.Repo)

    custom_indexes do
      index([:user_id])
    end
  end

  identities do
    identity(:unique_credential_id, [:credential_id])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([
        :credential_id,
        :public_key,
        :sign_count,
        :aaguid,
        :transports,
        :nickname,
        :user_id
      ])
    end

    update :record_use do
      accept([:sign_count, :last_used_at])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :credential_id, :binary do
      allow_nil?(false)
    end

    # The COSE key from Wax, through `:erlang.term_to_binary/1`. Read it back
    # with `:erlang.binary_to_term(bin, [:safe])` — never a bare
    # `binary_to_term/1` on a value that round-tripped through storage.
    attribute :public_key, :binary do
      allow_nil?(false)
    end

    attribute :sign_count, :integer do
      allow_nil?(false)
      default(0)
    end

    attribute :aaguid, :binary do
      public?(true)
    end

    attribute :transports, {:array, :string} do
      public?(true)
    end

    attribute :nickname, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :last_used_at, :utc_datetime_usec do
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :user, Portal.Accounts.User do
      allow_nil?(false)
      public?(true)
    end
  end
end
```

`apps/portal/lib/portal/accounts/totp_secret.ex`:

```elixir
defmodule Portal.Accounts.TotpSecret do
  @moduledoc """
  One TOTP secret per user.

  An unconfirmed secret never counts as a factor — a half-finished enrolment
  that counted would lock the user out of their own account.
  """

  use Ash.Resource,
    domain: Portal.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("portal_totp_secrets")
    repo(Portal.Repo)
  end

  identities do
    identity(:unique_user, [:user_id])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:secret, :user_id])
    end

    update :confirm do
      accept([:confirmed_at, :last_used_at, :failed_attempts])
    end

    update :record_success do
      accept([:last_used_at, :failed_attempts, :locked_until])
    end

    update :record_failure do
      accept([:failed_attempts, :locked_until])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :secret, :binary do
      allow_nil?(false)
      sensitive?(true)
    end

    attribute :confirmed_at, :utc_datetime_usec do
      public?(true)
    end

    # The moment the last accepted code was used. Handed straight to
    # `NimbleTOTP.valid?(secret, code, since: last_used_at)`, which rejects a
    # code minted inside an already-consumed window.
    attribute :last_used_at, :utc_datetime_usec do
      public?(true)
    end

    attribute :failed_attempts, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :locked_until, :utc_datetime_usec do
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :user, Portal.Accounts.User do
      allow_nil?(false)
      public?(true)
    end
  end
end
```

`apps/portal/lib/portal/accounts/recovery_code.ex`:

```elixir
defmodule Portal.Accounts.RecoveryCode do
  @moduledoc """
  One row per issued recovery code, holding only a SHA-256 hash of it.

  SHA-256 rather than Argon2 is deliberate: these are 80 bits of CSPRNG
  output, so there is nothing to brute-force, and Argon2 would cost up to ten
  ~100 ms verifications per login attempt. The two choices are coupled — see
  the spec before shortening the codes.
  """

  use Ash.Resource,
    domain: Portal.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("portal_recovery_codes")
    repo(Portal.Repo)

    custom_indexes do
      index([:user_id])
      index([:code_hash])
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:code_hash, :user_id])
    end

    update :consume do
      accept([:used_at])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :code_hash, :string do
      allow_nil?(false)
      sensitive?(true)
    end

    attribute :used_at, :utc_datetime_usec do
      public?(true)
    end

    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :user, Portal.Accounts.User do
      allow_nil?(false)
      public?(true)
    end
  end
end
```

- [ ] **Step 5: Register the resources in the domain**

`apps/portal/lib/portal/accounts.ex`, replace the `resources do` block at lines 8-10:

```elixir
  resources do
    resource(Portal.Accounts.User)
    resource(Portal.Accounts.Passkey)
    resource(Portal.Accounts.TotpSecret)
    resource(Portal.Accounts.RecoveryCode)
  end
```

- [ ] **Step 6: Write the passkey context**

`apps/portal/lib/portal/accounts/passkeys.ex`:

```elixir
defmodule Portal.Accounts.Passkeys do
  @moduledoc """
  Reads and writes for `Portal.Accounts.Passkey`.

  Every function that mutates takes the owning user and scopes by it, so a
  credential id from a request body can never reach another account's row.
  """

  require Ash.Query

  alias Portal.Accounts.{Passkey, User}

  @spec list_for_user(User.t()) :: [Passkey.t()]
  def list_for_user(%User{id: user_id}) do
    Passkey
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(domain: Portal.Accounts)
  end

  @spec count_for_user(User.t()) :: non_neg_integer()
  def count_for_user(%User{} = user), do: length(list_for_user(user))

  @spec get_by_credential_id(binary()) :: {:ok, Passkey.t()} | :error
  def get_by_credential_id(credential_id) when is_binary(credential_id) do
    Passkey
    |> Ash.Query.filter(credential_id == ^credential_id)
    |> Ash.read(domain: Portal.Accounts)
    |> case do
      {:ok, [passkey]} -> {:ok, passkey}
      _ -> :error
    end
  end

  @spec create(User.t(), map()) :: {:ok, Passkey.t()} | {:error, term()}
  def create(%User{id: user_id}, attrs) do
    Passkey
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :user_id, user_id))
    |> Ash.create(domain: Portal.Accounts)
  end

  @spec delete(User.t(), String.t()) :: :ok | {:error, :not_found}
  def delete(%User{} = user, id) do
    user
    |> list_for_user()
    |> Enum.find(&(&1.id == id))
    |> case do
      nil ->
        {:error, :not_found}

      passkey ->
        Ash.destroy!(passkey, domain: Portal.Accounts)
        :ok
    end
  end

  @spec record_use(Passkey.t(), non_neg_integer()) :: {:ok, Passkey.t()} | {:error, term()}
  def record_use(%Passkey{} = passkey, sign_count) do
    passkey
    |> Ash.Changeset.for_update(:record_use, %{
      sign_count: sign_count,
      last_used_at: DateTime.utc_now()
    })
    |> Ash.update(domain: Portal.Accounts)
  end

  @doc """
  The COSE key as `wax_` wants it. `[:safe]` because the bytes came back out of
  the database and a bare `binary_to_term/1` on stored input is a remote code
  execution primitive if that storage is ever tampered with.
  """
  @spec cose_key(Passkey.t()) :: map()
  def cose_key(%Passkey{public_key: bin}), do: :erlang.binary_to_term(bin, [:safe])
end
```

- [ ] **Step 7: Generate the migration**

```bash
cd apps/portal && mix ash_postgres.generate_migrations --name add_mfa_resources
```

Read the generated file before running it. It must create `portal_passkeys`, `portal_totp_secrets` and `portal_recovery_codes` with foreign keys to `portal_users`, a unique index on `portal_passkeys.credential_id`, and a unique index on `portal_totp_secrets.user_id`. It must not alter `portal_users`. If it tries to touch any other table, stop — the snapshots are stale and that is a separate problem.

```bash
cd apps/portal && mix ecto.migrate
```

- [ ] **Step 8: Run the tests**

```bash
cd apps/portal && mix test test/portal/accounts/passkeys_test.exs
```

Expected: 6 tests, 0 failures.

- [ ] **Step 9: Non-vacuity check on the ownership guard**

Temporarily change `Passkeys.delete/2` to look the row up by id alone rather than through `list_for_user/1`. Run the test — "delete only removes the caller's own passkey" must fail. Restore the scoped version and confirm it passes again.

- [ ] **Step 10: Commit**

```bash
git add apps/portal/lib/portal/accounts/ apps/portal/test/support/fixtures/accounts_fixtures.ex \
  apps/portal/test/portal/accounts/passkeys_test.exs \
  apps/portal/priv/repo/migrations/ apps/portal/priv/resource_snapshots/
git commit -m "feat(portal): add passkey, TOTP secret and recovery code resources"
```

---

### Task 3: Recovery codes

**Files:**
- Create: `apps/portal/lib/portal/accounts/recovery_codes.ex`
- Test: `apps/portal/test/portal/accounts/recovery_codes_test.exs`

**Interfaces:**
- Consumes: `Portal.Accounts.RecoveryCode` and `Portal.Test.AccountsFixtures` from Task 2.
- Produces:
  - `Portal.Accounts.RecoveryCodes.generate(user) :: {:ok, [String.t()]}` — replaces every existing code, returns ten formatted codes in plaintext exactly once
  - `Portal.Accounts.RecoveryCodes.consume(user, input :: String.t()) :: :ok | {:error, :invalid_code}`
  - `Portal.Accounts.RecoveryCodes.remaining(user) :: non_neg_integer()`
  - `Portal.Accounts.RecoveryCodes.low?(user) :: boolean()`
  - `Portal.Accounts.RecoveryCodes.normalize(String.t()) :: String.t()`
  - `Portal.Accounts.RecoveryCodes.format(String.t()) :: String.t()`

- [ ] **Step 1: Write the failing test**

`apps/portal/test/portal/accounts/recovery_codes_test.exs`:

```elixir
defmodule Portal.Accounts.RecoveryCodesTest do
  use Portal.DataCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.RecoveryCodes

  test "generates ten formatted 80-bit codes" do
    user = user_fixture()

    assert {:ok, codes} = RecoveryCodes.generate(user)
    assert length(codes) == 10
    assert length(Enum.uniq(codes)) == 10

    for code <- codes do
      # 16 base32 characters in four dash-separated groups of four.
      assert Regex.match?(~r/^[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}$/, code)
    end

    assert RecoveryCodes.remaining(user) == 10
  end

  test "regenerating replaces every previous code" do
    user = user_fixture()
    {:ok, [old | _]} = RecoveryCodes.generate(user)
    {:ok, _new} = RecoveryCodes.generate(user)

    assert RecoveryCodes.remaining(user) == 10
    assert RecoveryCodes.consume(user, old) == {:error, :invalid_code}
  end

  test "a code works once and never again" do
    user = user_fixture()
    {:ok, [code | _]} = RecoveryCodes.generate(user)

    assert RecoveryCodes.consume(user, code) == :ok
    assert RecoveryCodes.remaining(user) == 9
    assert RecoveryCodes.consume(user, code) == {:error, :invalid_code}
  end

  test "input normalises case, dashes and surrounding whitespace" do
    user = user_fixture()
    {:ok, [code | _]} = RecoveryCodes.generate(user)

    mangled = "  " <> String.upcase(String.replace(code, "-", "")) <> "  "

    assert RecoveryCodes.consume(user, mangled) == :ok
  end

  test "one user's code does not work for another" do
    owner = user_fixture()
    stranger = user_fixture()
    {:ok, [code | _]} = RecoveryCodes.generate(owner)
    {:ok, _} = RecoveryCodes.generate(stranger)

    assert RecoveryCodes.consume(stranger, code) == {:error, :invalid_code}
    assert RecoveryCodes.remaining(owner) == 10
  end

  test "low? turns on at two remaining" do
    user = user_fixture()
    {:ok, codes} = RecoveryCodes.generate(user)

    refute RecoveryCodes.low?(user)

    codes |> Enum.take(7) |> Enum.each(&(:ok = RecoveryCodes.consume(user, &1)))
    refute RecoveryCodes.low?(user)

    :ok = RecoveryCodes.consume(user, Enum.at(codes, 7))
    assert RecoveryCodes.low?(user)
  end

  test "garbage is rejected without raising" do
    user = user_fixture()
    {:ok, _} = RecoveryCodes.generate(user)

    assert RecoveryCodes.consume(user, "") == {:error, :invalid_code}
    assert RecoveryCodes.consume(user, "not-a-real-code") == {:error, :invalid_code}
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd apps/portal && mix test test/portal/accounts/recovery_codes_test.exs
```

Expected: FAIL — `Portal.Accounts.RecoveryCodes is not available`.

- [ ] **Step 3: Write the module**

`apps/portal/lib/portal/accounts/recovery_codes.ex`:

```elixir
defmodule Portal.Accounts.RecoveryCodes do
  @moduledoc """
  Single-use recovery codes: the way back in when the passkey is gone.

  Each code is `:crypto.strong_rand_bytes(10)` — exactly 80 bits — Base32
  encoded (RFC 4648) to 16 characters with no padding, shown lowercase in four
  groups. The Base32 alphabet is `A-Z` plus `2-7`, which has no `0`/`O` or
  `1`/`I`/`l` pairs, so there is nothing to misread off a printed sheet.

  Hashing is SHA-256, deliberately not Argon2: 80 bits of CSPRNG output has
  nothing to brute-force, and Argon2 would cost up to ten ~100 ms
  verifications per login attempt. The fast hash is only safe because the
  codes are long. Do not shorten them without switching to Argon2.
  """

  require Ash.Query

  alias Portal.Accounts.{RecoveryCode, User}

  @count 10
  @entropy_bytes 10
  @low_water 2

  @doc """
  Issues a fresh set of ten codes, discarding any previous set.

  The plaintext is returned once and never stored. The caller must show it to
  the user immediately; there is no second chance to read it.
  """
  @spec generate(User.t()) :: {:ok, [String.t()]}
  def generate(%User{id: user_id} = user) do
    user |> all_for_user() |> Enum.each(&Ash.destroy!(&1, domain: Portal.Accounts))

    codes = Enum.map(1..@count, fn _ -> new_code() end)

    for code <- codes do
      RecoveryCode
      |> Ash.Changeset.for_create(:create, %{code_hash: hash(code), user_id: user_id})
      |> Ash.create!(domain: Portal.Accounts)
    end

    {:ok, Enum.map(codes, &format/1)}
  end

  @doc """
  Spends a code. Accepts it in any case, with or without the display dashes.
  """
  @spec consume(User.t(), String.t()) :: :ok | {:error, :invalid_code}
  def consume(%User{} = user, input) when is_binary(input) do
    hashed = input |> normalize() |> hash()

    user
    |> all_for_user()
    |> Enum.find(fn code -> is_nil(code.used_at) and code.code_hash == hashed end)
    |> case do
      nil ->
        {:error, :invalid_code}

      code ->
        code
        |> Ash.Changeset.for_update(:consume, %{used_at: DateTime.utc_now()})
        |> Ash.update!(domain: Portal.Accounts)

        :ok
    end
  end

  def consume(%User{}, _input), do: {:error, :invalid_code}

  @spec remaining(User.t()) :: non_neg_integer()
  def remaining(%User{} = user) do
    user |> all_for_user() |> Enum.count(&is_nil(&1.used_at))
  end

  @doc "True once the user is down to the last couple of codes."
  @spec low?(User.t()) :: boolean()
  def low?(%User{} = user), do: remaining(user) <= @low_water

  @doc "Strips the display dashes and surrounding whitespace, and downcases."
  @spec normalize(String.t()) :: String.t()
  def normalize(input) when is_binary(input) do
    input |> String.trim() |> String.replace("-", "") |> String.downcase()
  end

  @doc "Groups a bare 16-character code into four dash-separated blocks."
  @spec format(String.t()) :: String.t()
  def format(code) when is_binary(code) do
    code
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join("-", &Enum.join/1)
  end

  defp new_code do
    @entropy_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(padding: false)
    |> String.downcase()
  end

  defp hash(code) do
    :sha256 |> :crypto.hash(code) |> Base.encode16(case: :lower)
  end

  defp all_for_user(%User{id: user_id}) do
    RecoveryCode
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read!(domain: Portal.Accounts)
  end
end
```

- [ ] **Step 4: Run the tests**

```bash
cd apps/portal && mix test test/portal/accounts/recovery_codes_test.exs
```

Expected: 7 tests, 0 failures.

- [ ] **Step 5: Non-vacuity check on the single-use guard**

Remove `is_nil(code.used_at) and` from the `Enum.find/2` predicate in `consume/2`. Run the test — "a code works once and never again" must fail. Restore it.

Then remove the `user_id == ^user_id` filter from `all_for_user/1` and confirm "one user's code does not work for another" fails. Restore it.

- [ ] **Step 6: Commit**

```bash
git add apps/portal/lib/portal/accounts/recovery_codes.ex \
  apps/portal/test/portal/accounts/recovery_codes_test.exs
git commit -m "feat(portal): 80-bit single-use recovery codes"
```

---

### Task 4: TOTP enrolment, verification, replay and lockout

**Files:**
- Create: `apps/portal/lib/portal/accounts/totp.ex`
- Test: `apps/portal/test/portal/accounts/totp_test.exs`

**Interfaces:**
- Consumes: `Portal.Accounts.TotpSecret` and the fixtures from Task 2.
- Produces:
  - `Portal.Accounts.Totp.start_enrolment(user) :: {:ok, %{secret: binary(), uri: String.t()}}`
  - `Portal.Accounts.Totp.confirm(user, code, now \\ DateTime.utc_now()) :: :ok | {:error, reason}`
  - `Portal.Accounts.Totp.verify(user, code, now \\ DateTime.utc_now()) :: :ok | {:error, reason}`
  - `Portal.Accounts.Totp.confirmed?(user) :: boolean()`
  - `Portal.Accounts.Totp.get_secret(user) :: {:ok, TotpSecret.t()} | :error`
  - `Portal.Accounts.Totp.disable(user) :: :ok`
  - reasons: `:not_enrolled | :invalid_code | {:locked, DateTime.t()}`

- [ ] **Step 1: Write the failing test**

`apps/portal/test/portal/accounts/totp_test.exs`:

```elixir
defmodule Portal.Accounts.TotpTest do
  use Portal.DataCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.Totp

  # Fixed clocks throughout: a test that asks the system what time it is will
  # eventually straddle a 30-second period boundary and fail for nobody's good.
  @t0 ~U[2026-09-18 12:00:00.000000Z]

  defp enrol(user, now \\ @t0) do
    {:ok, %{secret: secret}} = Totp.start_enrolment(user)
    :ok = Totp.confirm(user, NimbleTOTP.verification_code(secret, time: now), now)
    secret
  end

  test "enrolment yields a secret and an otpauth URI naming the portal" do
    user = user_fixture(%{username: "wrenchbird"})

    assert {:ok, %{secret: secret, uri: uri}} = Totp.start_enrolment(user)
    assert byte_size(secret) == 20
    assert String.starts_with?(uri, "otpauth://totp/")
    assert uri =~ "wrenchbird"
    assert uri =~ "issuer=Nerves"
  end

  test "an unconfirmed secret is not a factor" do
    user = user_fixture()
    {:ok, _} = Totp.start_enrolment(user)

    refute Totp.confirmed?(user)
  end

  test "one working code confirms the secret" do
    user = user_fixture()
    {:ok, %{secret: secret}} = Totp.start_enrolment(user)

    assert Totp.confirm(user, NimbleTOTP.verification_code(secret, time: @t0), @t0) == :ok
    assert Totp.confirmed?(user)
  end

  test "a wrong code does not confirm" do
    user = user_fixture()
    {:ok, _} = Totp.start_enrolment(user)

    assert Totp.confirm(user, "000000", @t0) == {:error, :invalid_code}
    refute Totp.confirmed?(user)
  end

  test "restarting enrolment discards the previous unconfirmed secret" do
    user = user_fixture()
    {:ok, %{secret: first}} = Totp.start_enrolment(user)
    {:ok, %{secret: second}} = Totp.start_enrolment(user)

    refute first == second
    assert Totp.confirm(user, NimbleTOTP.verification_code(first, time: @t0), @t0) ==
             {:error, :invalid_code}
  end

  test "a valid code verifies" do
    user = user_fixture()
    secret = enrol(user)
    later = DateTime.add(@t0, 60, :second)

    assert Totp.verify(user, NimbleTOTP.verification_code(secret, time: later), later) == :ok
  end

  test "a code cannot be replayed inside its own window" do
    user = user_fixture()
    secret = enrol(user)
    later = DateTime.add(@t0, 60, :second)
    code = NimbleTOTP.verification_code(secret, time: later)

    assert Totp.verify(user, code, later) == :ok
    assert Totp.verify(user, code, later) == {:error, :invalid_code}
  end

  test "a code from an old window is rejected" do
    user = user_fixture()
    secret = enrol(user)
    stale = NimbleTOTP.verification_code(secret, time: @t0)
    much_later = DateTime.add(@t0, 600, :second)

    assert Totp.verify(user, stale, much_later) == {:error, :invalid_code}
  end

  test "five failures lock the secret, and a correct code is refused while locked" do
    user = user_fixture()
    secret = enrol(user)
    later = DateTime.add(@t0, 60, :second)

    for _ <- 1..4 do
      assert Totp.verify(user, "000000", later) == {:error, :invalid_code}
    end

    assert {:error, {:locked, until}} = Totp.verify(user, "000000", later)
    assert DateTime.compare(until, later) == :gt

    good = NimbleTOTP.verification_code(secret, time: later)
    assert {:error, {:locked, ^until}} = Totp.verify(user, good, later)
  end

  test "the lock lifts and the counter resets once the window passes" do
    user = user_fixture()
    secret = enrol(user)
    later = DateTime.add(@t0, 60, :second)

    for _ <- 1..5, do: Totp.verify(user, "000000", later)

    after_lock = DateTime.add(later, 16 * 60, :second)
    assert Totp.verify(user, NimbleTOTP.verification_code(secret, time: after_lock), after_lock) == :ok
  end

  test "a successful verification clears the failure counter" do
    user = user_fixture()
    secret = enrol(user)
    later = DateTime.add(@t0, 60, :second)

    assert Totp.verify(user, "000000", later) == {:error, :invalid_code}
    assert Totp.verify(user, NimbleTOTP.verification_code(secret, time: later), later) == :ok

    {:ok, stored} = Totp.get_secret(user)
    assert stored.failed_attempts == 0
  end

  test "verifying without enrolment says so" do
    user = user_fixture()

    assert Totp.verify(user, "000000", @t0) == {:error, :not_enrolled}
  end

  test "disable removes the secret entirely" do
    user = user_fixture()
    enrol(user)

    assert Totp.disable(user) == :ok
    refute Totp.confirmed?(user)
    assert Totp.get_secret(user) == :error
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd apps/portal && mix test test/portal/accounts/totp_test.exs
```

Expected: FAIL — `Portal.Accounts.Totp is not available`.

- [ ] **Step 3: Write the module**

`apps/portal/lib/portal/accounts/totp.ex`:

```elixir
defmodule Portal.Accounts.Totp do
  @moduledoc """
  TOTP as a second factor for password logins.

  Six digits is a million guesses, and an attacker who already holds the
  password will spend them, so verification counts failures and locks the
  secret after five. Replay inside a single 30-second window is blocked by
  handing `NimbleTOTP` the moment the last accepted code was used.

  TOTP never satisfies the admin passkey requirement. See
  `Portal.Accounts.Mfa`.
  """

  require Ash.Query
  require Logger

  alias Portal.Accounts.{TotpSecret, User}

  @max_failures 5
  @lockout_seconds 15 * 60
  @issuer "Nerves Compatibility Tracker"

  @doc """
  Mints a new secret for `user`, replacing any existing one, and returns it
  with the `otpauth://` URI to render as a QR code.

  The secret is unconfirmed until `confirm/3` proves one working code.
  """
  @spec start_enrolment(User.t()) :: {:ok, %{secret: binary(), uri: String.t()}}
  def start_enrolment(%User{id: user_id} = user) do
    :ok = disable(user)

    secret = NimbleTOTP.secret()

    TotpSecret
    |> Ash.Changeset.for_create(:create, %{secret: secret, user_id: user_id})
    |> Ash.create!(domain: Portal.Accounts)

    uri = NimbleTOTP.otpauth_uri("#{@issuer}:#{user.username}", secret, issuer: @issuer)

    {:ok, %{secret: secret, uri: uri}}
  end

  @doc """
  Turns an enrolled-but-unconfirmed secret into a real factor.

  Stamps `last_used_at` so the confirming code cannot immediately be replayed
  as a login.
  """
  @spec confirm(User.t(), String.t(), DateTime.t()) ::
          :ok | {:error, :not_enrolled | :invalid_code}
  def confirm(%User{} = user, code, now \\ DateTime.utc_now()) do
    with {:ok, secret} <- get_secret(user),
         true <- valid_code?(secret, code, now) do
      secret
      |> Ash.Changeset.for_update(:confirm, %{
        confirmed_at: now,
        last_used_at: now,
        failed_attempts: 0
      })
      |> Ash.update!(domain: Portal.Accounts)

      :ok
    else
      :error -> {:error, :not_enrolled}
      false -> {:error, :invalid_code}
    end
  end

  @doc """
  Checks a code against the user's confirmed secret.
  """
  @spec verify(User.t(), String.t(), DateTime.t()) ::
          :ok | {:error, :not_enrolled | :invalid_code | {:locked, DateTime.t()}}
  def verify(%User{} = user, code, now \\ DateTime.utc_now()) do
    with {:ok, secret} <- confirmed_secret(user),
         :ok <- check_lock(secret, now) do
      if valid_code?(secret, code, now) do
        record_success(secret, now)
      else
        record_failure(secret, user, now)
      end
    end
  end

  @spec confirmed?(User.t()) :: boolean()
  def confirmed?(%User{} = user), do: match?({:ok, _}, confirmed_secret(user))

  @spec get_secret(User.t()) :: {:ok, TotpSecret.t()} | :error
  def get_secret(%User{id: user_id}) do
    TotpSecret
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read(domain: Portal.Accounts)
    |> case do
      {:ok, [secret]} -> {:ok, secret}
      _ -> :error
    end
  end

  @spec disable(User.t()) :: :ok
  def disable(%User{} = user) do
    case get_secret(user) do
      {:ok, secret} -> Ash.destroy!(secret, domain: Portal.Accounts)
      :error -> :ok
    end

    :ok
  end

  defp confirmed_secret(user) do
    case get_secret(user) do
      {:ok, %TotpSecret{confirmed_at: nil}} -> {:error, :not_enrolled}
      {:ok, secret} -> {:ok, secret}
      :error -> {:error, :not_enrolled}
    end
  end

  defp valid_code?(%TotpSecret{} = secret, code, now) when is_binary(code) do
    NimbleTOTP.valid?(secret.secret, String.trim(code),
      time: now,
      since: secret.last_used_at
    )
  end

  defp valid_code?(_secret, _code, _now), do: false

  defp check_lock(%TotpSecret{locked_until: nil}, _now), do: :ok

  defp check_lock(%TotpSecret{locked_until: until}, now) do
    if DateTime.compare(now, until) == :lt, do: {:error, {:locked, until}}, else: :ok
  end

  defp record_success(secret, now) do
    secret
    |> Ash.Changeset.for_update(:record_success, %{
      last_used_at: now,
      failed_attempts: 0,
      locked_until: nil
    })
    |> Ash.update!(domain: Portal.Accounts)

    :ok
  end

  defp record_failure(secret, user, now) do
    attempts = secret.failed_attempts + 1

    if attempts >= @max_failures do
      until = DateTime.add(now, @lockout_seconds, :second)

      secret
      |> Ash.Changeset.for_update(:record_failure, %{failed_attempts: 0, locked_until: until})
      |> Ash.update!(domain: Portal.Accounts)

      Logger.warning("TOTP locked for user #{user.username} until #{DateTime.to_iso8601(until)}")

      {:error, {:locked, until}}
    else
      secret
      |> Ash.Changeset.for_update(:record_failure, %{failed_attempts: attempts})
      |> Ash.update!(domain: Portal.Accounts)

      {:error, :invalid_code}
    end
  end
end
```

- [ ] **Step 4: Run the tests**

```bash
cd apps/portal && mix test test/portal/accounts/totp_test.exs
```

Expected: 13 tests, 0 failures.

If "a code cannot be replayed inside its own window" fails, the cause is almost always `since:` not being passed through — `NimbleTOTP.valid?/3` accepts an unknown option silently rather than raising.

- [ ] **Step 5: Non-vacuity check on the replay and lockout guards**

Drop `since: secret.last_used_at` from `valid_code?/3`. Run the test — "a code cannot be replayed inside its own window" must fail. Restore it.

Change `check_lock/2` to always return `:ok`. Run the test — "five failures lock the secret, and a correct code is refused while locked" must fail. Restore it.

- [ ] **Step 6: Commit**

```bash
git add apps/portal/lib/portal/accounts/totp.ex apps/portal/test/portal/accounts/totp_test.exs
git commit -m "feat(portal): TOTP enrolment with replay protection and lockout"
```

---

### Task 5: Software authenticator and passkey registration

This is the hardest task in the plan. CI has no authenticator, so the tests
carry one: an EC key that produces the exact byte structures a real device
returns — CBOR attestation objects, raw authenticator data, DER ECDSA
signatures. Mocking `wax_` at the boundary would exercise our plumbing and
none of the verification, which is the part worth testing.

**Files:**
- Create: `apps/portal/test/support/software_authenticator.ex`
- Modify: `apps/portal/lib/portal/accounts/web_authn.ex` (add registration functions)
- Test: `apps/portal/test/portal/accounts/web_authn_registration_test.exs`

**Interfaces:**
- Consumes: `WebAuthn.opts/1` (Task 1), `Passkeys.create/2`, `Passkeys.list_for_user/1`, `Passkeys.cose_key/1`, `Portal.Test.AccountsFixtures` (Task 2).
- Produces:
  - `Portal.Accounts.WebAuthn.registration_challenge(user) :: {Wax.Challenge.t(), map()}` — the challenge to stash in the session, and a JSON-ready payload for the browser
  - `Portal.Accounts.WebAuthn.register(user, params :: map(), Wax.Challenge.t()) :: {:ok, Passkey.t()} | {:error, term()}`
  - `Portal.Accounts.WebAuthn.rp_name() :: String.t()`
  - `Portal.Test.SoftwareAuthenticator.new(rp_id, opts \\ []) :: t()`
  - `Portal.Test.SoftwareAuthenticator.create(auth, challenge_bytes, origin) :: %{attestation_object: binary(), client_data_json: binary(), credential_id: binary()}`
  - `Portal.Test.SoftwareAuthenticator.get(auth, challenge_bytes, origin, opts \\ []) :: %{credential_id: binary(), authenticator_data: binary(), signature: binary(), client_data_json: binary()}` (used by Task 6)

- [ ] **Step 1: Write the software authenticator**

This one is written before its test, because it *is* test apparatus — nothing
in `lib/` depends on it, and the round-trip test in Step 2 is what proves it
works.

`apps/portal/test/support/software_authenticator.ex`:

```elixir
defmodule Portal.Test.SoftwareAuthenticator do
  @moduledoc """
  A minimal WebAuthn authenticator, for tests.

  Produces the byte structures a real authenticator returns, so `wax_` does
  genuine verification against it: CBOR attestation objects, raw authenticator
  data, and DER-encoded ECDSA P-256 signatures over
  `authData || SHA256(clientDataJSON)`.

  Everything is ES256 (COSE alg -7) with "none" attestation, which is what the
  portal asks browsers for.
  """

  import Bitwise

  defstruct [:credential_id, :private_key, :rp_id, sign_count: 0]

  @type t :: %__MODULE__{}

  # Flags byte, per the WebAuthn spec.
  @up 0x01
  @uv 0x04
  @at 0x40

  # No attestation means no meaningful AAGUID.
  @aaguid <<0::128>>

  @spec new(String.t(), keyword()) :: t()
  def new(rp_id, opts \\ []) do
    %__MODULE__{
      rp_id: rp_id,
      credential_id: Keyword.get(opts, :credential_id, :crypto.strong_rand_bytes(32)),
      private_key: :public_key.generate_key({:namedCurve, :secp256r1}),
      sign_count: Keyword.get(opts, :sign_count, 0)
    }
  end

  @doc """
  What `navigator.credentials.create` would hand back.
  """
  def create(%__MODULE__{} = auth, challenge_bytes, origin) do
    client_data_json = client_data("webauthn.create", challenge_bytes, origin)

    attestation_object =
      CBOR.encode(%{
        "fmt" => "none",
        "attStmt" => %{},
        "authData" => %CBOR.Tag{tag: :bytes, value: authenticator_data(auth, @up ||| @uv ||| @at)}
      })

    %{
      attestation_object: attestation_object,
      client_data_json: client_data_json,
      credential_id: auth.credential_id
    }
  end

  @doc """
  What `navigator.credentials.get` would hand back.

  `:sign_count` overrides the counter for this one assertion, which is how the
  sign-count tests produce a regression.
  """
  def get(%__MODULE__{} = auth, challenge_bytes, origin, opts \\ []) do
    auth = %{auth | sign_count: Keyword.get(opts, :sign_count, auth.sign_count)}

    client_data_json = client_data("webauthn.get", challenge_bytes, origin)
    auth_data = authenticator_data(auth, @up ||| @uv)

    signature =
      :public_key.sign(
        auth_data <> :crypto.hash(:sha256, client_data_json),
        :sha256,
        auth.private_key
      )

    %{
      credential_id: auth.credential_id,
      authenticator_data: auth_data,
      signature: signature,
      client_data_json: client_data_json
    }
  end

  defp client_data(type, challenge_bytes, origin) do
    Jason.encode!(%{
      "type" => type,
      "challenge" => Base.url_encode64(challenge_bytes, padding: false),
      "origin" => origin,
      "crossOrigin" => false
    })
  end

  # rpIdHash(32) || flags(1) || signCount(4, big endian) [|| attested credential data]
  defp authenticator_data(%__MODULE__{} = auth, flags) do
    head =
      :crypto.hash(:sha256, auth.rp_id) <>
        <<flags::unsigned-8, auth.sign_count::unsigned-big-32>>

    if (flags &&& @at) == 0 do
      head
    else
      head <>
        @aaguid <>
        <<byte_size(auth.credential_id)::unsigned-big-16>> <>
        auth.credential_id <>
        cose_key(auth)
    end
  end

  # COSE_Key for an EC2 P-256 public key:
  #   1 (kty) => 2 (EC2), 3 (alg) => -7 (ES256), -1 (crv) => 1 (P-256),
  #   -2 => x, -3 => y
  defp cose_key(%__MODULE__{private_key: key}) do
    # An OTP ECPrivateKey record: {:ECPrivateKey, version, privateKey,
    # parameters, publicKey, attributes}. The public key is an uncompressed
    # point, 0x04 followed by the two 32-byte coordinates.
    <<4, x::binary-size(32), y::binary-size(32)>> = elem(key, 4)

    CBOR.encode(%{
      1 => 2,
      3 => -7,
      -1 => 1,
      -2 => %CBOR.Tag{tag: :bytes, value: x},
      -3 => %CBOR.Tag{tag: :bytes, value: y}
    })
  end
end
```

`CBOR` comes from the `cbor` package, a transitive dependency of `wax_`. It is
already on the path; do not add it to `mix.exs`.

- [ ] **Step 2: Write the failing test**

`apps/portal/test/portal/accounts/web_authn_registration_test.exs`:

```elixir
defmodule Portal.Accounts.WebAuthnRegistrationTest do
  use Portal.DataCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.{Passkeys, WebAuthn}
  alias Portal.Test.SoftwareAuthenticator

  @rp_id "localhost"
  @origin "http://localhost:4001"

  defp registration_params(response, extra \\ %{}) do
    Map.merge(
      %{
        "nickname" => "laptop",
        "attestation_object" =>
          Base.url_encode64(response.attestation_object, padding: false),
        "client_data_json" => Base.url_encode64(response.client_data_json, padding: false),
        "transports" => ["internal"]
      },
      extra
    )
  end

  test "a real attestation round-trip registers the credential" do
    user = user_fixture()
    {challenge, payload} = WebAuthn.registration_challenge(user)
    authenticator = SoftwareAuthenticator.new(@rp_id)
    response = SoftwareAuthenticator.create(authenticator, challenge.bytes, @origin)

    assert {:ok, passkey} = WebAuthn.register(user, registration_params(response), challenge)

    assert passkey.credential_id == authenticator.credential_id
    assert passkey.nickname == "laptop"
    assert passkey.transports == ["internal"]
    assert passkey.user_id == user.id
    assert is_map(Passkeys.cose_key(passkey))
    assert Passkeys.count_for_user(user) == 1

    assert payload.rp_id == @rp_id
    assert payload.user_name == user.username
    assert payload.user_handle == Base.url_encode64(Ecto.UUID.dump!(user.id), padding: false)
    assert payload.exclude_credentials == []
  end

  test "the challenge payload lists already-registered credentials to exclude" do
    user = user_fixture()
    {challenge, _} = WebAuthn.registration_challenge(user)
    authenticator = SoftwareAuthenticator.new(@rp_id)
    response = SoftwareAuthenticator.create(authenticator, challenge.bytes, @origin)
    {:ok, _} = WebAuthn.register(user, registration_params(response), challenge)

    {_next_challenge, payload} = WebAuthn.registration_challenge(user)

    assert payload.exclude_credentials == [
             Base.url_encode64(authenticator.credential_id, padding: false)
           ]
  end

  test "an attestation signed against a different origin is rejected" do
    user = user_fixture()
    {challenge, _} = WebAuthn.registration_challenge(user)
    authenticator = SoftwareAuthenticator.new(@rp_id)
    response = SoftwareAuthenticator.create(authenticator, challenge.bytes, "https://evil.example")

    assert {:error, _} = WebAuthn.register(user, registration_params(response), challenge)
    assert Passkeys.count_for_user(user) == 0
  end

  test "an attestation for a different relying party is rejected" do
    user = user_fixture()
    {challenge, _} = WebAuthn.registration_challenge(user)
    authenticator = SoftwareAuthenticator.new("evil.example")
    response = SoftwareAuthenticator.create(authenticator, challenge.bytes, @origin)

    assert {:error, _} = WebAuthn.register(user, registration_params(response), challenge)
  end

  test "an attestation answering a different challenge is rejected" do
    user = user_fixture()
    {challenge, _} = WebAuthn.registration_challenge(user)
    authenticator = SoftwareAuthenticator.new(@rp_id)
    response = SoftwareAuthenticator.create(authenticator, :crypto.strong_rand_bytes(32), @origin)

    assert {:error, _} = WebAuthn.register(user, registration_params(response), challenge)
  end

  test "the same credential cannot be registered twice, even by another account" do
    user = user_fixture()
    stranger = user_fixture()
    authenticator = SoftwareAuthenticator.new(@rp_id)

    {challenge, _} = WebAuthn.registration_challenge(user)
    response = SoftwareAuthenticator.create(authenticator, challenge.bytes, @origin)
    {:ok, _} = WebAuthn.register(user, registration_params(response), challenge)

    {challenge2, _} = WebAuthn.registration_challenge(stranger)
    response2 = SoftwareAuthenticator.create(authenticator, challenge2.bytes, @origin)

    assert WebAuthn.register(stranger, registration_params(response2), challenge2) ==
             {:error, :already_registered}
  end

  test "a blank nickname gets a default and an overlong one is truncated" do
    user = user_fixture()

    {challenge, _} = WebAuthn.registration_challenge(user)
    response = SoftwareAuthenticator.create(SoftwareAuthenticator.new(@rp_id), challenge.bytes, @origin)
    {:ok, blank} = WebAuthn.register(user, registration_params(response, %{"nickname" => "   "}), challenge)

    assert blank.nickname == "Passkey"

    {challenge2, _} = WebAuthn.registration_challenge(user)
    response2 = SoftwareAuthenticator.create(SoftwareAuthenticator.new(@rp_id), challenge2.bytes, @origin)

    {:ok, long} =
      WebAuthn.register(user, registration_params(response2, %{"nickname" => String.duplicate("x", 200)}), challenge2)

    assert String.length(long.nickname) == 60
  end

  test "malformed base64 is an error, not a crash" do
    user = user_fixture()
    {challenge, _} = WebAuthn.registration_challenge(user)

    params = %{
      "nickname" => "k",
      "attestation_object" => "!!!not base64!!!",
      "client_data_json" => "!!!",
      "transports" => []
    }

    assert WebAuthn.register(user, params, challenge) == {:error, :malformed_request}
  end
end
```

- [ ] **Step 3: Run it and watch it fail**

```bash
cd apps/portal && mix test test/portal/accounts/web_authn_registration_test.exs
```

Expected: FAIL — `function Portal.Accounts.WebAuthn.registration_challenge/1 is undefined`.

- [ ] **Step 4: Add registration to the WebAuthn module**

Append to `apps/portal/lib/portal/accounts/web_authn.ex`, inside the module:

```elixir
  alias Portal.Accounts.{Passkey, Passkeys, User}

  @rp_name "Nerves Compatibility Tracker"
  @max_nickname_length 60

  @spec rp_name() :: String.t()
  def rp_name, do: @rp_name

  @doc """
  A registration challenge plus the JSON-ready payload the browser needs.

  The caller stashes the `Wax.Challenge` in the signed session and sends the
  payload. `exclude_credentials` carries the ids the account already holds so
  the same authenticator cannot be enrolled twice; it is advisory — the
  duplicate check in `register/3` is what actually enforces it.
  """
  @spec registration_challenge(User.t()) :: {Wax.Challenge.t(), map()}
  def registration_challenge(%User{} = user) do
    challenge = Wax.new_registration_challenge(opts())

    payload = %{
      challenge: b64(challenge.bytes),
      rp_id: challenge.rp_id,
      rp_name: @rp_name,
      # The WebAuthn user handle. The UUID's 16 raw bytes, well inside the
      # 64-byte limit, and it is what a discoverable credential hands back at
      # login time to say who is signing in.
      user_handle: b64(Ecto.UUID.dump!(user.id)),
      user_name: user.username,
      timeout: 300,
      exclude_credentials: Enum.map(Passkeys.list_for_user(user), &b64(&1.credential_id))
    }

    {challenge, payload}
  end

  @doc """
  Verifies an attestation and stores the resulting credential.
  """
  @spec register(User.t(), map(), Wax.Challenge.t()) :: {:ok, Passkey.t()} | {:error, term()}
  def register(%User{} = user, params, %Wax.Challenge{} = challenge) do
    with {:ok, attestation_object} <- decode(params["attestation_object"]),
         {:ok, client_data_json} <- decode(params["client_data_json"]),
         {:ok, {auth_data, _attestation}} <-
           Wax.register(attestation_object, client_data_json, challenge),
         credential_data = auth_data.attested_credential_data,
         :ok <- ensure_unregistered(credential_data.credential_id) do
      Passkeys.create(user, %{
        credential_id: credential_data.credential_id,
        public_key: :erlang.term_to_binary(credential_data.credential_public_key),
        sign_count: auth_data.sign_count,
        aaguid: Wax.AuthenticatorData.get_aaguid(auth_data),
        transports: transports(params["transports"]),
        nickname: nickname(params["nickname"])
      })
    end
  end

  defp ensure_unregistered(credential_id) do
    case Passkeys.get_by_credential_id(credential_id) do
      {:ok, _} -> {:error, :already_registered}
      :error -> :ok
    end
  end

  defp transports(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp transports(_), do: []

  defp nickname(value) when is_binary(value) do
    case value |> String.trim() |> String.slice(0, @max_nickname_length) do
      "" -> "Passkey"
      trimmed -> trimmed
    end
  end

  defp nickname(_), do: "Passkey"

  @doc false
  def b64(bin), do: Base.url_encode64(bin, padding: false)

  @doc false
  def decode(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :malformed_request}
    end
  end

  def decode(_), do: {:error, :malformed_request}
```

- [ ] **Step 5: Run the tests**

```bash
cd apps/portal && mix test test/portal/accounts/web_authn_registration_test.exs
```

Expected: 7 tests, 0 failures.

If `Wax.register/3` rejects a response the authenticator produced, read the
error struct — `wax_` returns a named exception per failed check, and the
message says which one. The three most likely causes, in order: the flags byte
is missing `UV` (config sets `user_verification: "required"`); `CBOR.encode`
was handed a raw binary rather than a `%CBOR.Tag{tag: :bytes}`, so it encoded
a text string where a byte string belongs; or `elem(key, 4)` did not match the
uncompressed-point pattern, which means the OTP record shape differs — inspect
the record and take the field that is 65 bytes starting with `0x04`.

If `Passkeys.cose_key(passkey)` raises on `binary_to_term(bin, [:safe])`, the
COSE key contains a struct (`%CBOR.Tag{}`) that `:safe` refuses because the
module is not loaded in that process. Store
`Map.new(key, fn {k, v} -> {k, unwrap_tag(v)} end)` instead, unwrapping tags to
raw binaries, and adjust the test accordingly.

- [ ] **Step 6: Non-vacuity check on the duplicate guard**

Delete the `ensure_unregistered/1` clause from the `with`. Run the test — "the
same credential cannot be registered twice, even by another account" must fail.
Restore it.

- [ ] **Step 7: Commit**

```bash
git add apps/portal/test/support/software_authenticator.ex \
  apps/portal/lib/portal/accounts/web_authn.ex \
  apps/portal/test/portal/accounts/web_authn_registration_test.exs
git commit -m "feat(portal): verify and store passkey registrations"
```

---

### Task 6: Passkey authentication and the sign-count policy

**Files:**
- Modify: `apps/portal/lib/portal/accounts/web_authn.ex` (add authentication functions)
- Test: `apps/portal/test/portal/accounts/web_authn_authentication_test.exs`

**Interfaces:**
- Consumes: everything Task 5 produced, plus `SoftwareAuthenticator.get/4`.
- Produces:
  - `Portal.Accounts.WebAuthn.authentication_challenge() :: {Wax.Challenge.t(), map()}`
  - `Portal.Accounts.WebAuthn.authenticate(params :: map(), Wax.Challenge.t()) :: {:ok, %{user: User.t(), passkey: Passkey.t()}} | {:error, term()}`
  - `Portal.Accounts.WebAuthn.check_sign_count(stored :: non_neg_integer(), incoming :: non_neg_integer()) :: :ok | {:error, :sign_count_regression}`

- [ ] **Step 1: Write the failing test**

`apps/portal/test/portal/accounts/web_authn_authentication_test.exs`:

```elixir
defmodule Portal.Accounts.WebAuthnAuthenticationTest do
  use Portal.DataCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.{Passkeys, WebAuthn}
  alias Portal.Test.SoftwareAuthenticator

  @rp_id "localhost"
  @origin "http://localhost:4001"

  defp enrolled_user(opts \\ []) do
    user = user_fixture()
    authenticator = SoftwareAuthenticator.new(@rp_id, opts)
    {challenge, _} = WebAuthn.registration_challenge(user)
    response = SoftwareAuthenticator.create(authenticator, challenge.bytes, @origin)

    {:ok, passkey} =
      WebAuthn.register(
        user,
        %{
          "nickname" => "laptop",
          "attestation_object" => WebAuthn.b64(response.attestation_object),
          "client_data_json" => WebAuthn.b64(response.client_data_json),
          "transports" => []
        },
        challenge
      )

    {user, authenticator, passkey}
  end

  defp assertion_params(user, response) do
    %{
      "credential_id" => WebAuthn.b64(response.credential_id),
      "authenticator_data" => WebAuthn.b64(response.authenticator_data),
      "signature" => WebAuthn.b64(response.signature),
      "client_data_json" => WebAuthn.b64(response.client_data_json),
      "user_handle" => WebAuthn.b64(Ecto.UUID.dump!(user.id))
    }
  end

  test "a discoverable credential signs in with no username typed" do
    {user, authenticator, _passkey} = enrolled_user()
    {challenge, payload} = WebAuthn.authentication_challenge()

    # Discoverable credentials: the server names no credentials, the
    # authenticator picks one and says who it belongs to.
    assert payload.rp_id == @rp_id
    refute Map.has_key?(payload, :allow_credentials)

    response = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    assert {:ok, %{user: signed_in, passkey: passkey}} =
             WebAuthn.authenticate(assertion_params(user, response), challenge)

    assert signed_in.id == user.id
    assert passkey.sign_count == 1
    assert passkey.last_used_at
  end

  test "an assertion for the wrong origin is rejected" do
    {user, authenticator, _} = enrolled_user()
    {challenge, _} = WebAuthn.authentication_challenge()
    response = SoftwareAuthenticator.get(authenticator, challenge.bytes, "https://evil.example")

    assert {:error, _} = WebAuthn.authenticate(assertion_params(user, response), challenge)
  end

  test "an assertion signed by a different key is rejected" do
    {user, _authenticator, passkey} = enrolled_user()
    {challenge, _} = WebAuthn.authentication_challenge()

    impostor = SoftwareAuthenticator.new(@rp_id, credential_id: passkey.credential_id)
    response = SoftwareAuthenticator.get(impostor, challenge.bytes, @origin, sign_count: 1)

    assert {:error, _} = WebAuthn.authenticate(assertion_params(user, response), challenge)
  end

  test "an unknown credential id is rejected" do
    {user, authenticator, _} = enrolled_user()
    {challenge, _} = WebAuthn.authentication_challenge()
    response = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    params =
      user
      |> assertion_params(response)
      |> Map.put("credential_id", WebAuthn.b64(:crypto.strong_rand_bytes(32)))

    assert WebAuthn.authenticate(params, challenge) == {:error, :unknown_credential}
  end

  test "a credential id belonging to someone else's account is rejected" do
    {_user, authenticator, _} = enrolled_user()
    stranger = user_fixture()
    {challenge, _} = WebAuthn.authentication_challenge()
    response = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    assert WebAuthn.authenticate(assertion_params(stranger, response), challenge) ==
             {:error, :unknown_credential}
  end

  test "a missing user handle is rejected rather than guessed at" do
    {user, authenticator, _} = enrolled_user()
    {challenge, _} = WebAuthn.authentication_challenge()
    response = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    params = user |> assertion_params(response) |> Map.put("user_handle", nil)

    assert WebAuthn.authenticate(params, challenge) == {:error, :missing_user_handle}
  end

  test "sign count: zero stays zero, which is what iCloud Keychain does" do
    assert WebAuthn.check_sign_count(0, 0) == :ok
    assert WebAuthn.check_sign_count(0, 5) == :ok
  end

  test "sign count: increasing is fine, standing still or going backwards is not" do
    assert WebAuthn.check_sign_count(4, 5) == :ok
    assert WebAuthn.check_sign_count(5, 5) == {:error, :sign_count_regression}
    assert WebAuthn.check_sign_count(9, 4) == {:error, :sign_count_regression}
  end

  test "an assertion whose counter went backwards is refused end to end" do
    {user, authenticator, passkey} = enrolled_user()

    {first, _} = WebAuthn.authentication_challenge()
    response = SoftwareAuthenticator.get(authenticator, first.bytes, @origin, sign_count: 7)
    {:ok, _} = WebAuthn.authenticate(assertion_params(user, response), first)

    {second, _} = WebAuthn.authentication_challenge()
    replay = SoftwareAuthenticator.get(authenticator, second.bytes, @origin, sign_count: 3)

    assert WebAuthn.authenticate(assertion_params(user, replay), second) ==
             {:error, :sign_count_regression}

    {:ok, unchanged} = Passkeys.get_by_credential_id(passkey.credential_id)
    assert unchanged.sign_count == 7
  end

  test "an iCloud-style authenticator that always reports zero keeps working" do
    {user, authenticator, _} = enrolled_user(sign_count: 0)

    for _ <- 1..3 do
      {challenge, _} = WebAuthn.authentication_challenge()
      response = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 0)

      assert {:ok, _} = WebAuthn.authenticate(assertion_params(user, response), challenge)
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd apps/portal && mix test test/portal/accounts/web_authn_authentication_test.exs
```

Expected: FAIL — `function Portal.Accounts.WebAuthn.authentication_challenge/0 is undefined`.

- [ ] **Step 3: Add authentication to the WebAuthn module**

Append inside `apps/portal/lib/portal/accounts/web_authn.ex`:

```elixir
  @doc """
  An authentication challenge for a passwordless sign-in.

  Deliberately omits `allow_credentials`: nobody has typed a username yet, so
  there is no account to narrow the list to. The authenticator picks a
  discoverable credential and returns a `userHandle` naming its owner.
  """
  @spec authentication_challenge() :: {Wax.Challenge.t(), map()}
  def authentication_challenge do
    challenge = Wax.new_authentication_challenge(opts())

    {challenge, %{challenge: b64(challenge.bytes), rp_id: challenge.rp_id, timeout: 300}}
  end

  @doc """
  Verifies an assertion and returns the account it belongs to.
  """
  @spec authenticate(map(), Wax.Challenge.t()) ::
          {:ok, %{user: User.t(), passkey: Passkey.t()}} | {:error, term()}
  def authenticate(params, %Wax.Challenge{} = challenge) do
    with {:ok, credential_id} <- decode(params["credential_id"]),
         {:ok, auth_data_bin} <- decode(params["authenticator_data"]),
         {:ok, signature} <- decode(params["signature"]),
         {:ok, client_data_json} <- decode(params["client_data_json"]),
         {:ok, user} <- user_from_handle(params["user_handle"]),
         {:ok, passkey} <- passkey_for(user, credential_id),
         {:ok, auth_data} <-
           Wax.authenticate(
             credential_id,
             auth_data_bin,
             signature,
             client_data_json,
             challenge,
             [{passkey.credential_id, Passkeys.cose_key(passkey)}]
           ),
         :ok <- verify_sign_count(passkey, auth_data.sign_count),
         {:ok, passkey} <- Passkeys.record_use(passkey, auth_data.sign_count) do
      {:ok, %{user: user, passkey: passkey}}
    end
  end

  @doc """
  The clone-detection rule.

  A stored count of zero means there is no baseline to compare against —
  either the credential has never been used, or the authenticator does not
  keep a counter at all. Apple's iCloud Keychain passkeys always report zero,
  and they are the authenticator most people will reach for first, so a naive
  "must increase" check would reject exactly the common case.

  Once a non-zero baseline exists the standard requires the counter to
  advance, so anything that does not is treated as a clone.
  """
  @spec check_sign_count(non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, :sign_count_regression}
  def check_sign_count(0, _incoming), do: :ok
  def check_sign_count(stored, incoming) when incoming > stored, do: :ok
  def check_sign_count(_stored, _incoming), do: {:error, :sign_count_regression}

  defp verify_sign_count(%Passkey{} = passkey, incoming) do
    case check_sign_count(passkey.sign_count, incoming) do
      :ok ->
        :ok

      {:error, :sign_count_regression} = error ->
        Logger.warning(
          "Passkey sign count regression for credential #{b64(passkey.credential_id)}: " <>
            "stored #{passkey.sign_count}, presented #{incoming}. Assertion refused."
        )

        error
    end
  end

  defp user_from_handle(handle) when is_binary(handle) do
    with {:ok, raw} <- decode(handle),
         {:ok, uuid} <- Ecto.UUID.load(raw),
         {:ok, user} <- Portal.Accounts.get_user(uuid) do
      {:ok, user}
    else
      _ -> {:error, :unknown_credential}
    end
  end

  defp user_from_handle(_), do: {:error, :missing_user_handle}

  defp passkey_for(%User{id: user_id}, credential_id) do
    case Passkeys.get_by_credential_id(credential_id) do
      {:ok, %Passkey{user_id: ^user_id} = passkey} -> {:ok, passkey}
      _ -> {:error, :unknown_credential}
    end
  end
```

Add `require Logger` to the top of the module, below the `@moduledoc`.

- [ ] **Step 4: Run the tests**

```bash
cd apps/portal && mix test test/portal/accounts/web_authn_authentication_test.exs
```

Expected: 10 tests, 0 failures.

- [ ] **Step 5: Non-vacuity checks**

Three guards, three checks:

1. Change `check_sign_count/2`'s last clause to return `:ok`. "an assertion whose counter went backwards is refused end to end" must fail. Restore.
2. Change `passkey_for/2` to match any `%Passkey{}` regardless of `user_id`. "a credential id belonging to someone else's account is rejected" must fail. Restore.
3. Replace the `credentials` argument to `Wax.authenticate/6` with `[]`. "a discoverable credential signs in with no username typed" must fail — without the COSE key there is nothing to verify the signature against. Restore.

- [ ] **Step 6: Commit**

```bash
git add apps/portal/lib/portal/accounts/web_authn.ex \
  apps/portal/test/portal/accounts/web_authn_authentication_test.exs
git commit -m "feat(portal): verify passkey assertions with a clone-detection rule"
```

---

### Task 7: The MFA policy module

Everything that decides *who needs what* lives here, so the rules can be read
in one place rather than inferred from scattered `if`s.

**Files:**
- Create: `apps/portal/lib/portal/accounts/mfa.ex`
- Test: `apps/portal/test/portal/accounts/mfa_test.exs`

**Interfaces:**
- Consumes: `Passkeys.count_for_user/1` (Task 2), `Totp.confirmed?/1` (Task 4).
- Produces:
  - `Portal.Accounts.Mfa.factors(user) :: %{passkeys: non_neg_integer(), totp: boolean()}`
  - `Portal.Accounts.Mfa.enrolled?(user) :: boolean()`
  - `Portal.Accounts.Mfa.admin_satisfied?(user) :: boolean()`
  - `Portal.Accounts.Mfa.second_factor_required?(user) :: boolean()`
  - `Portal.Accounts.Mfa.accepted_reauth_methods(user) :: [:password | :passkey | :totp | :recovery_code]`
  - `Portal.Accounts.Mfa.reauth_fresh?(user, method, at :: integer() | nil, now :: integer()) :: boolean()`
  - `Portal.Accounts.Mfa.reauth_window_seconds() :: pos_integer()`

- [ ] **Step 1: Write the failing test**

`apps/portal/test/portal/accounts/mfa_test.exs`:

```elixir
defmodule Portal.Accounts.MfaTest do
  use Portal.DataCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.{Mfa, Passkeys, Totp}

  @now 1_789_000_000

  defp with_passkey(user) do
    {:ok, _} =
      Passkeys.create(user, %{
        credential_id: :crypto.strong_rand_bytes(16),
        public_key: :erlang.term_to_binary(%{3 => -7}),
        nickname: "laptop"
      })

    user
  end

  defp with_totp(user) do
    at = ~U[2026-09-18 12:00:00.000000Z]
    {:ok, %{secret: secret}} = Totp.start_enrolment(user)
    :ok = Totp.confirm(user, NimbleTOTP.verification_code(secret, time: at), at)
    user
  end

  test "factors report what the account actually holds" do
    bare = user_fixture()
    assert Mfa.factors(bare) == %{passkeys: 0, totp: false}
    refute Mfa.enrolled?(bare)

    keyed = with_passkey(user_fixture())
    assert Mfa.factors(keyed) == %{passkeys: 1, totp: false}
    assert Mfa.enrolled?(keyed)

    coded = with_totp(user_fixture())
    assert Mfa.factors(coded) == %{passkeys: 0, totp: true}
    assert Mfa.enrolled?(coded)
  end

  test "an unconfirmed TOTP secret is not a factor" do
    user = user_fixture()
    {:ok, _} = Totp.start_enrolment(user)

    assert Mfa.factors(user) == %{passkeys: 0, totp: false}
    refute Mfa.enrolled?(user)
  end

  test "only a passkey satisfies an admin" do
    refute Mfa.admin_satisfied?(admin_fixture())
    refute Mfa.admin_satisfied?(with_totp(admin_fixture()))
    assert Mfa.admin_satisfied?(with_passkey(admin_fixture()))

    # Non-admins are never subject to the check at all.
    assert Mfa.admin_satisfied?(user_fixture())
  end

  test "a confirmed TOTP is what makes a password login two-phase" do
    refute Mfa.second_factor_required?(user_fixture())
    refute Mfa.second_factor_required?(with_passkey(user_fixture()))
    assert Mfa.second_factor_required?(with_totp(user_fixture()))
  end

  test "the password authorises a factor change only while no factor exists" do
    assert Mfa.accepted_reauth_methods(user_fixture()) == [:password]
    assert Mfa.accepted_reauth_methods(with_passkey(user_fixture())) == [:passkey, :recovery_code]
    assert Mfa.accepted_reauth_methods(with_totp(user_fixture())) == [:totp, :recovery_code]

    # A passkey holder is held to the passkey even if they also have TOTP: an
    # account is only as strong as the weakest credential that can change it.
    both = user_fixture() |> with_passkey() |> with_totp()
    assert Mfa.accepted_reauth_methods(both) == [:passkey, :recovery_code]
  end

  test "freshness needs an accepted method inside the ten-minute window" do
    user = with_passkey(user_fixture())

    assert Mfa.reauth_fresh?(user, :passkey, @now, @now)
    assert Mfa.reauth_fresh?(user, :passkey, @now - 599, @now)
    assert Mfa.reauth_fresh?(user, :recovery_code, @now - 10, @now)

    refute Mfa.reauth_fresh?(user, :passkey, @now - 601, @now)
    refute Mfa.reauth_fresh?(user, :password, @now, @now)
    refute Mfa.reauth_fresh?(user, :totp, @now, @now)
    refute Mfa.reauth_fresh?(user, nil, @now, @now)
    refute Mfa.reauth_fresh?(user, :passkey, nil, @now)
  end

  test "the password stops working the moment the first factor lands" do
    user = user_fixture()
    assert Mfa.reauth_fresh?(user, :password, @now, @now)

    keyed = with_passkey(user)
    refute Mfa.reauth_fresh?(keyed, :password, @now, @now)
  end

  test "a timestamp from the future is not fresh" do
    user = user_fixture()
    refute Mfa.reauth_fresh?(user, :password, @now + 60, @now)
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd apps/portal && mix test test/portal/accounts/mfa_test.exs
```

Expected: FAIL — `Portal.Accounts.Mfa is not available`.

- [ ] **Step 3: Write the module**

`apps/portal/lib/portal/accounts/mfa.ex`:

```elixir
defmodule Portal.Accounts.Mfa do
  @moduledoc """
  Who must hold what, and what may authorise a change.

  Enrolment state is derived, never stored: an admin is satisfied when they
  hold at least one passkey, a community user when they hold a passkey or a
  confirmed TOTP. There is no flag to drift out of sync, and `set_admin` needs
  no special handling — a newly promoted admin simply fails the check on their
  next `/admin` request.
  """

  alias Portal.Accounts.{Passkeys, Totp, User}

  @reauth_window_seconds 600

  @type method :: :password | :passkey | :totp | :recovery_code

  @spec reauth_window_seconds() :: pos_integer()
  def reauth_window_seconds, do: @reauth_window_seconds

  @spec factors(User.t()) :: %{passkeys: non_neg_integer(), totp: boolean()}
  def factors(%User{} = user) do
    %{passkeys: Passkeys.count_for_user(user), totp: Totp.confirmed?(user)}
  end

  @spec enrolled?(User.t()) :: boolean()
  def enrolled?(%User{} = user) do
    case factors(user) do
      %{passkeys: 0, totp: false} -> false
      _ -> true
    end
  end

  @doc """
  Whether this account may enter `/admin`.

  TOTP does not satisfy an admin, and that is deliberate. An account is only
  as strong as its weakest factor: an admin holding both a passkey and TOTP
  can still be phished down to the TOTP, which would spend the phishing
  resistance that motivated passkeys in the first place.

  Non-admins are trivially satisfied — the requirement does not apply to them.
  """
  @spec admin_satisfied?(User.t()) :: boolean()
  def admin_satisfied?(%User{is_admin: false}), do: true
  def admin_satisfied?(%User{} = user), do: factors(user).passkeys > 0

  @doc """
  Whether a successful password check still owes a second step.

  A passkey is an alternative way to log in, not a second factor on top of a
  password, so holding one does not make the password flow two-phase.
  """
  @spec second_factor_required?(User.t()) :: boolean()
  def second_factor_required?(%User{} = user), do: factors(user).totp

  @doc """
  Which credentials may authorise adding or removing a factor.

  The password counts only while the account holds no factor at all — the
  bootstrap case, where it is the only credential that exists. Accepting it
  forever would make the admin passkey requirement decorative: a phished
  password would let an attacker enrol their own passkey and walk into
  `/admin`, which is the precise attack passkeys were chosen to stop.
  """
  @spec accepted_reauth_methods(User.t()) :: [method()]
  def accepted_reauth_methods(%User{} = user) do
    case factors(user) do
      %{passkeys: n} when n > 0 -> [:passkey, :recovery_code]
      %{totp: true} -> [:totp, :recovery_code]
      _ -> [:password]
    end
  end

  @doc """
  Whether `method`, proven at `at` (Unix seconds), still authorises a change.
  """
  @spec reauth_fresh?(User.t(), method() | nil, integer() | nil, integer()) :: boolean()
  def reauth_fresh?(user, method, at, now \\ System.system_time(:second))

  def reauth_fresh?(%User{}, nil, _at, _now), do: false
  def reauth_fresh?(%User{}, _method, nil, _now), do: false

  def reauth_fresh?(%User{} = user, method, at, now) when is_integer(at) and is_integer(now) do
    method in accepted_reauth_methods(user) and now >= at and
      now - at <= @reauth_window_seconds
  end
end
```

- [ ] **Step 4: Run the tests**

```bash
cd apps/portal && mix test test/portal/accounts/mfa_test.exs
```

Expected: 8 tests, 0 failures.

- [ ] **Step 5: Non-vacuity check on the step-up rule**

Add `:password` to every branch of `accepted_reauth_methods/1`. Run the test —
"the password stops working the moment the first factor lands" and "the
password authorises a factor change only while no factor exists" must both
fail. Restore.

Then change `admin_satisfied?/1` to `enrolled?/1`. "only a passkey satisfies an
admin" must fail on the TOTP line. Restore.

- [ ] **Step 6: Commit**

```bash
git add apps/portal/lib/portal/accounts/mfa.ex apps/portal/test/portal/accounts/mfa_test.exs
git commit -m "feat(portal): MFA policy — derived enrolment state and step-up rules"
```

---

### Task 8: Two-phase password login

**Files:**
- Modify: `apps/portal/lib/portal_web/user_auth.ex`
- Modify: `apps/portal/lib/portal_web/controllers/page_controller.ex:137-150` (`create_session/2`)
- Create: `apps/portal/lib/portal_web/controllers/mfa_controller.ex`
- Create: `apps/portal/lib/portal_web/controllers/mfa_html.ex`
- Create: `apps/portal/lib/portal_web/controllers/mfa_html/totp_challenge.html.heex`
- Modify: `apps/portal/lib/portal_web/router.ex` (the first `scope "/", PortalWeb` block, beside `post "/login"`)
- Test: `apps/portal/test/portal_web/controllers/mfa_controller_test.exs`

**Interfaces:**
- Consumes: `Mfa.second_factor_required?/1`, `Mfa.reauth_window_seconds/0` (Task 7); `Totp.verify/3` (Task 4); `RecoveryCodes.consume/2`, `RecoveryCodes.low?/1` (Task 3).
- Produces:
  - `PortalWeb.UserAuth.complete_login(conn, user, method) :: Plug.Conn.t()` — rotates the session id, sets `:user_id`, stamps the re-auth marker, clears pending keys
  - `PortalWeb.UserAuth.mark_reauth(conn, method) :: Plug.Conn.t()`
  - `PortalWeb.UserAuth.reauth_method(conn) :: atom() | nil`
  - `PortalWeb.UserAuth.reauth_at(conn) :: integer() | nil`
  - `PortalWeb.UserAuth.pending_user(conn) :: {:ok, User.t()} | :error`
  - `PortalWeb.UserAuth.start_pending(conn, user) :: Plug.Conn.t()`
  - `PortalWeb.UserAuth.drop_pending(conn) :: Plug.Conn.t()`
  - Session keys: `:user_id`, `:pending_user_id`, `:pending_started_at`, `:reauth_method`, `:reauth_at`
  - Routes `GET /login/totp` and `POST /login/totp`

- [ ] **Step 1: Write the failing test**

`apps/portal/test/portal_web/controllers/mfa_controller_test.exs`:

```elixir
defmodule PortalWeb.MfaControllerTest do
  use PortalWeb.ConnCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.{RecoveryCodes, Totp}

  @password "correct horse battery staple"

  defp user_with_totp do
    user = user_fixture(%{password: @password})
    at = ~U[2026-09-18 12:00:00.000000Z]
    {:ok, %{secret: secret}} = Totp.start_enrolment(user)
    :ok = Totp.confirm(user, NimbleTOTP.verification_code(secret, time: at), at)
    {user, secret}
  end

  defp code_now(secret), do: NimbleTOTP.verification_code(secret)

  test "a password login with no factor signs straight in", %{conn: conn} do
    user = user_fixture(%{password: @password})

    conn = post(conn, ~p"/login", %{"username" => user.username, "password" => @password})

    assert get_session(conn, :user_id) == user.id
    assert get_session(conn, :reauth_method) == :password
    assert is_integer(get_session(conn, :reauth_at))
    assert redirected_to(conn) == ~p"/request-scan"
  end

  test "a password login with TOTP stops at the second step", %{conn: conn} do
    {user, _secret} = user_with_totp()

    conn = post(conn, ~p"/login", %{"username" => user.username, "password" => @password})

    assert redirected_to(conn) == ~p"/login/totp"
    refute get_session(conn, :user_id)
    assert get_session(conn, :pending_user_id) == user.id
  end

  test "a pending session grants nothing on its own", %{conn: conn} do
    {user, _secret} = user_with_totp()

    conn = post(conn, ~p"/login", %{"username" => user.username, "password" => @password})
    conn = get(recycle(conn), ~p"/settings")

    assert redirected_to(conn) == ~p"/login"
    refute get_session(conn, :user_id)
  end

  test "a valid code promotes the pending session and rotates the session id", %{conn: conn} do
    {user, secret} = user_with_totp()

    conn = post(conn, ~p"/login", %{"username" => user.username, "password" => @password})
    before_id = conn.cookies["_portal_key"]

    conn = post(recycle(conn), ~p"/login/totp", %{"code" => code_now(secret)})

    assert get_session(conn, :user_id) == user.id
    assert get_session(conn, :reauth_method) == :totp
    refute get_session(conn, :pending_user_id)
    assert redirected_to(conn) == ~p"/request-scan"
    refute conn.cookies["_portal_key"] == before_id
  end

  test "a wrong code keeps the session pending", %{conn: conn} do
    {user, _secret} = user_with_totp()

    conn = post(conn, ~p"/login", %{"username" => user.username, "password" => @password})
    conn = post(recycle(conn), ~p"/login/totp", %{"code" => "000000"})

    refute get_session(conn, :user_id)
    assert get_session(conn, :pending_user_id) == user.id
    assert html_response(conn, 200) =~ "code"
  end

  test "lockout drops the pending session and sends the user back to the password step", %{conn: conn} do
    {user, _secret} = user_with_totp()

    conn = post(conn, ~p"/login", %{"username" => user.username, "password" => @password})

    conn =
      Enum.reduce(1..5, conn, fn _, acc ->
        post(recycle(acc), ~p"/login/totp", %{"code" => "000000"})
      end)

    assert redirected_to(conn) == ~p"/login"
    refute get_session(conn, :pending_user_id)
  end

  test "a recovery code is accepted at the second step and is then spent", %{conn: conn} do
    {user, _secret} = user_with_totp()
    {:ok, [recovery | _]} = RecoveryCodes.generate(user)

    conn = post(conn, ~p"/login", %{"username" => user.username, "password" => @password})
    conn = post(recycle(conn), ~p"/login/totp", %{"code" => recovery})

    assert get_session(conn, :user_id) == user.id
    assert get_session(conn, :reauth_method) == :recovery_code
    assert RecoveryCodes.remaining(user) == 9
  end

  test "an expired pending session is refused", %{conn: conn} do
    {user, secret} = user_with_totp()

    conn =
      conn
      |> init_test_session(%{})
      |> put_session(:pending_user_id, user.id)
      |> put_session(:pending_started_at, System.system_time(:second) - 301)

    conn = post(conn, ~p"/login/totp", %{"code" => code_now(secret)})

    assert redirected_to(conn) == ~p"/login"
    refute get_session(conn, :user_id)
  end

  test "the second-factor page is not reachable without a pending session", %{conn: conn} do
    conn = get(conn, ~p"/login/totp")

    assert redirected_to(conn) == ~p"/login"
  end
end
```

The session cookie name in `refute conn.cookies["_portal_key"] == before_id`
must match the endpoint's `session_options` key — check
`apps/portal/lib/portal_web/endpoint.ex` and use whatever `key:` is set there.

- [ ] **Step 2: Run it and watch it fail**

```bash
cd apps/portal && mix test test/portal_web/controllers/mfa_controller_test.exs
```

Expected: FAIL — no route matches `/login/totp`.

- [ ] **Step 3: Add the session helpers**

Replace `apps/portal/lib/portal_web/user_auth.ex` with:

```elixir
defmodule PortalWeb.UserAuth do
  @moduledoc """
  Session handling for logins, and the LiveView `on_mount` hook that assigns
  auth-derived state.

  Controllers derive `current_user` from `get_session(conn, :user_id)` via
  `Portal.Accounts.get_user/1`. LiveViews mounted outside a controller need
  the same assign so `<Layouts.app current_user={@current_user} ...>` shows
  the signed-in nav state instead of always rendering Login/Register.

  A half-finished login lives under `:pending_user_id`, never `:user_id`, so
  it grants nothing anywhere: every plug and hook reads `:user_id` alone.
  """

  import Phoenix.Component, only: [assign: 3]
  import Plug.Conn

  alias Portal.Accounts.User

  @pending_ttl_seconds 300

  def on_mount(:assign_current_user, _params, session, socket) do
    {:cont, assign(socket, :current_user, current_user_from_session(session))}
  end

  @doc """
  Signs `user` in, having proven `method`.

  `configure_session(renew: true)` rotates the session id so a cookie fixated
  before the login is worthless afterwards.
  """
  @spec complete_login(Plug.Conn.t(), User.t(), atom()) :: Plug.Conn.t()
  def complete_login(conn, %User{} = user, method) do
    conn
    |> configure_session(renew: true)
    |> put_session(:user_id, user.id)
    |> mark_reauth(method)
    |> drop_pending()
  end

  @doc """
  Records that `method` was proven just now, starting a fresh step-up window.
  """
  @spec mark_reauth(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  def mark_reauth(conn, method) when is_atom(method) do
    conn
    |> put_session(:reauth_method, method)
    |> put_session(:reauth_at, System.system_time(:second))
  end

  @spec reauth_method(Plug.Conn.t()) :: atom() | nil
  def reauth_method(conn), do: get_session(conn, :reauth_method)

  @spec reauth_at(Plug.Conn.t()) :: integer() | nil
  def reauth_at(conn), do: get_session(conn, :reauth_at)

  @doc """
  Parks a password-authenticated user until they clear the second step.
  """
  @spec start_pending(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  def start_pending(conn, %User{} = user) do
    conn
    |> put_session(:pending_user_id, user.id)
    |> put_session(:pending_started_at, System.system_time(:second))
  end

  @spec drop_pending(Plug.Conn.t()) :: Plug.Conn.t()
  def drop_pending(conn) do
    conn
    |> delete_session(:pending_user_id)
    |> delete_session(:pending_started_at)
  end

  @doc """
  The user waiting on a second factor, if the pending session is still valid.

  Expiry is checked here rather than at the call sites so there is one place
  for the five-minute rule to live.
  """
  @spec pending_user(Plug.Conn.t()) :: {:ok, User.t()} | :error
  def pending_user(conn) do
    with user_id when is_binary(user_id) <- get_session(conn, :pending_user_id),
         started when is_integer(started) <- get_session(conn, :pending_started_at),
         true <- System.system_time(:second) - started <= @pending_ttl_seconds,
         {:ok, user} <- Portal.Accounts.get_user(user_id) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  defp current_user_from_session(%{"user_id" => user_id}) when is_binary(user_id) do
    case Portal.Accounts.get_user(user_id) do
      {:ok, user} -> user
      _ -> nil
    end
  end

  defp current_user_from_session(_session), do: nil
end
```

- [ ] **Step 4: Make the password login two-phase**

In `apps/portal/lib/portal_web/controllers/page_controller.ex`, replace
`create_session/2`:

```elixir
  def create_session(conn, %{"username" => username, "password" => password}) do
    case Portal.Accounts.authenticate_user(username, password) do
      {:ok, user} ->
        # The password alone no longer produces a session. A confirmed TOTP
        # means the user is parked under `:pending_user_id`, which grants
        # nothing, until they clear `/login/totp`.
        if Portal.Accounts.Mfa.second_factor_required?(user) do
          conn
          |> PortalWeb.UserAuth.start_pending(user)
          |> redirect(to: ~p"/login/totp")
        else
          conn
          |> PortalWeb.UserAuth.complete_login(user, :password)
          |> put_flash(:info, "Signed in.")
          |> redirect(to: landing_path(user))
        end

      {:error, reason} ->
        conn
        |> put_flash(:error, account_error_message(reason))
        |> render_auth(:login, username: username)
    end
  end
```

- [ ] **Step 5: Write the second-factor controller**

`apps/portal/lib/portal_web/controllers/mfa_controller.ex`:

```elixir
defmodule PortalWeb.MfaController do
  @moduledoc """
  The second step of a password login.

  Accepts either a six-digit TOTP code or a recovery code. Which one was used
  is recorded as the re-auth method, because a recovery code and a TOTP code
  authorise different things later — see `Portal.Accounts.Mfa`.
  """

  use PortalWeb, :controller

  alias Portal.Accounts.{Mfa, RecoveryCodes, Totp}
  alias PortalWeb.UserAuth

  def totp_challenge(conn, _params) do
    case UserAuth.pending_user(conn) do
      {:ok, _user} -> render_challenge(conn)
      :error -> restart(conn, "That sign-in attempt expired. Start again.")
    end
  end

  def totp_verify(conn, params) do
    code = params |> Map.get("code", "") |> to_string()

    case UserAuth.pending_user(conn) do
      {:ok, user} -> check(conn, user, code)
      :error -> restart(conn, "That sign-in attempt expired. Start again.")
    end
  end

  defp check(conn, user, code) do
    case Totp.verify(user, code) do
      :ok ->
        finish(conn, user, :totp)

      {:error, {:locked, _until}} ->
        restart(conn, "Too many wrong codes. Sign in with your password again in 15 minutes.")

      {:error, _} ->
        # A recovery code is accepted anywhere a TOTP code is, so a failed
        # TOTP check falls through rather than ending the attempt.
        case RecoveryCodes.consume(user, code) do
          :ok -> finish(conn, user, :recovery_code)
          {:error, :invalid_code} -> reject(conn)
        end
    end
  end

  defp finish(conn, user, method) do
    conn
    |> UserAuth.complete_login(user, method)
    |> maybe_warn_low_codes(user, method)
    |> put_flash(:info, "Signed in.")
    |> redirect(to: landing_path(user))
  end

  defp maybe_warn_low_codes(conn, user, :recovery_code) do
    if RecoveryCodes.low?(user) do
      put_flash(
        conn,
        :error,
        "#{RecoveryCodes.remaining(user)} recovery codes left. Generate a new set in Security settings."
      )
    else
      conn
    end
  end

  defp maybe_warn_low_codes(conn, _user, _method), do: conn

  defp reject(conn) do
    conn
    |> put_flash(:error, "That code did not match. Try again.")
    |> render_challenge()
  end

  defp restart(conn, message) do
    conn
    |> UserAuth.drop_pending()
    |> put_flash(:error, message)
    |> redirect(to: ~p"/login")
  end

  defp render_challenge(conn) do
    render(conn, :totp_challenge,
      page_title: "Two-factor authentication",
      current_user: nil,
      reauth_window_minutes: div(Mfa.reauth_window_seconds(), 60)
    )
  end

  defp landing_path(user) do
    if Portal.Accounts.admin?(user), do: ~p"/admin", else: ~p"/request-scan"
  end
end
```

`apps/portal/lib/portal_web/controllers/mfa_html.ex`:

```elixir
defmodule PortalWeb.MfaHTML do
  @moduledoc """
  Templates for the second-factor step.
  """

  use PortalWeb, :html

  embed_templates("mfa_html/*")
end
```

`apps/portal/lib/portal_web/controllers/mfa_html/totp_challenge.html.heex`:

```heex
<Layouts.flash_group flash={@flash} />

<main class="min-h-screen bg-base-100 text-base-content">
  <.site_nav current_user={@current_user} />

  <div class="mx-auto max-w-md px-4 py-10 sm:px-6 lg:px-8">
    <section class="space-y-8">
      <PortalWeb.UI.page_header kicker="Account" title="Two-factor authentication">
        <:subtitle>
          Enter the six-digit code from your authenticator app, or one of your recovery codes.
        </:subtitle>
      </PortalWeb.UI.page_header>

      <section class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body gap-6">
          <form method="post" action={~p"/login/totp"} class="space-y-4">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />

            <div class="form-control">
              <span class="label">
                <span class="label-text font-semibold">Code</span>
              </span>
              <input
                id="code"
                name="code"
                inputmode="text"
                autocomplete="one-time-code"
                autofocus
                required
                class="input input-bordered w-full font-mono"
              />
              <span class="label">
                <span class="label-text-alt text-base-content/60">
                  Six digits, or a recovery code like <code>k3mq-7x2p-9vhd-t4rs</code>.
                </span>
              </span>
            </div>

            <button type="submit" class="btn btn-primary w-full">
              <.icon name="hero-lock-open-mini" class="size-5" /> Continue
            </button>
          </form>

          <p class="text-sm leading-6 text-base-content/70">
            Lost your device and your recovery codes? Ask an operator to reset your factors.
          </p>
        </div>
      </section>
    </section>
  </div>
</main>
```

If `PortalWeb.UI.page_header` or `.site_nav` take different attributes here
than in `login.html.heex`, copy that file's usage exactly — it is the closest
sibling page.

- [ ] **Step 6: Add the routes**

In `apps/portal/lib/portal_web/router.ex`, in the browser scope, immediately
after `post "/login", PageController, :create_session`:

```elixir
    get "/login/totp", MfaController, :totp_challenge
    post "/login/totp", MfaController, :totp_verify
```

- [ ] **Step 7: Run the tests**

```bash
cd apps/portal && mix test test/portal_web/controllers/mfa_controller_test.exs
```

Expected: 9 tests, 0 failures.

- [ ] **Step 8: Run the full suite — this task changes how everyone logs in**

```bash
cd /Users/tomhoenderdos/Projects/nerves_compatibility && mix test
```

Any existing test that logged in by posting to `/login` and then expected a
session still passes, because a user with no factor is promoted immediately.
Any test that set `:user_id` directly is untouched. If something fails, it is
a real regression in the login path — fix it here, not later.

- [ ] **Step 9: Non-vacuity checks**

1. Change `create_session/2` to call `complete_login/3` unconditionally. "a
   password login with TOTP stops at the second step" and "a pending session
   grants nothing on its own" must both fail. Restore.
2. Remove `configure_session(renew: true)` from `complete_login/3`. "a valid
   code promotes the pending session and rotates the session id" must fail.
   Restore.
3. Change the `@pending_ttl_seconds` comparison in `pending_user/1` to always
   return true. "an expired pending session is refused" must fail. Restore.

- [ ] **Step 10: Commit**

```bash
git add apps/portal/lib/portal_web/user_auth.ex \
  apps/portal/lib/portal_web/controllers/page_controller.ex \
  apps/portal/lib/portal_web/controllers/mfa_controller.ex \
  apps/portal/lib/portal_web/controllers/mfa_html.ex \
  apps/portal/lib/portal_web/controllers/mfa_html/ \
  apps/portal/lib/portal_web/router.ex \
  apps/portal/test/portal_web/controllers/mfa_controller_test.exs
git commit -m "feat(portal): require a second factor before a password login completes"
```

---

### Task 9: Passwordless passkey login

**Files:**
- Create: `apps/portal/lib/portal_web/web_authn_session.ex`
- Create: `apps/portal/lib/portal_web/controllers/passkey_controller.ex`
- Create: `apps/portal/assets/js/webauthn.js`
- Modify: `apps/portal/assets/js/app.js`
- Modify: `apps/portal/lib/portal_web/controllers/page_html/login.html.heex`
- Modify: `apps/portal/lib/portal_web/router.ex`
- Test: `apps/portal/test/portal_web/controllers/passkey_controller_test.exs`

**Interfaces:**
- Consumes: `WebAuthn.authentication_challenge/0`, `WebAuthn.authenticate/2` (Task 6); `UserAuth.complete_login/3` (Task 8); `SoftwareAuthenticator` (Task 5).
- Produces:
  - `PortalWeb.WebAuthnSession.put(conn, key :: atom(), Wax.Challenge.t()) :: Plug.Conn.t()`
  - `PortalWeb.WebAuthnSession.take(conn, key :: atom()) :: {:ok, Wax.Challenge.t(), Plug.Conn.t()} | {:error, Plug.Conn.t()}` — always deletes, so a challenge is single-use
  - Session key `:passkey_login_challenge`
  - Routes `POST /auth/passkey/challenge` and `POST /auth/passkey/verify`, both JSON
  - `initWebAuthn()` exported from `assets/js/webauthn.js`

- [ ] **Step 1: Write the failing test**

`apps/portal/test/portal_web/controllers/passkey_controller_test.exs`:

```elixir
defmodule PortalWeb.PasskeyControllerTest do
  use PortalWeb.ConnCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.WebAuthn
  alias Portal.Test.SoftwareAuthenticator

  @rp_id "localhost"
  @origin "http://localhost:4001"

  defp enrol(user) do
    authenticator = SoftwareAuthenticator.new(@rp_id)
    {challenge, _} = WebAuthn.registration_challenge(user)
    response = SoftwareAuthenticator.create(authenticator, challenge.bytes, @origin)

    {:ok, _} =
      WebAuthn.register(
        user,
        %{
          "nickname" => "laptop",
          "attestation_object" => WebAuthn.b64(response.attestation_object),
          "client_data_json" => WebAuthn.b64(response.client_data_json),
          "transports" => []
        },
        challenge
      )

    authenticator
  end

  defp assertion_body(user, response) do
    %{
      "credential_id" => WebAuthn.b64(response.credential_id),
      "authenticator_data" => WebAuthn.b64(response.authenticator_data),
      "signature" => WebAuthn.b64(response.signature),
      "client_data_json" => WebAuthn.b64(response.client_data_json),
      "user_handle" => WebAuthn.b64(Ecto.UUID.dump!(user.id))
    }
  end

  defp stashed_challenge(conn) do
    {challenge, _at} = get_session(conn, :passkey_login_challenge)
    challenge
  end

  test "the challenge endpoint names no credentials and stashes the challenge", %{conn: conn} do
    conn = post(conn, ~p"/auth/passkey/challenge")

    body = json_response(conn, 200)
    assert body["rp_id"] == @rp_id
    assert body["timeout"] == 300
    assert is_binary(body["challenge"])
    refute Map.has_key?(body, "allow_credentials")
    assert stashed_challenge(conn)
  end

  test "a valid assertion signs in and hands back where to go", %{conn: conn} do
    user = user_fixture()
    authenticator = enrol(user)

    conn = post(conn, ~p"/auth/passkey/challenge")
    challenge = stashed_challenge(conn)
    response = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    conn = post(recycle(conn), ~p"/auth/passkey/verify", assertion_body(user, response))

    assert json_response(conn, 200)["redirect_to"] == ~p"/request-scan"
    assert get_session(conn, :user_id) == user.id
    assert get_session(conn, :reauth_method) == :passkey
  end

  test "an admin lands on the admin page", %{conn: conn} do
    admin = admin_fixture()
    authenticator = enrol(admin)

    conn = post(conn, ~p"/auth/passkey/challenge")
    challenge = stashed_challenge(conn)
    response = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    conn = post(recycle(conn), ~p"/auth/passkey/verify", assertion_body(admin, response))

    assert json_response(conn, 200)["redirect_to"] == ~p"/admin"
  end

  test "a challenge works exactly once", %{conn: conn} do
    user = user_fixture()
    authenticator = enrol(user)

    conn = post(conn, ~p"/auth/passkey/challenge")
    challenge = stashed_challenge(conn)
    response = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    first = post(recycle(conn), ~p"/auth/passkey/verify", assertion_body(user, response))
    assert json_response(first, 200)["redirect_to"]

    replay = post(recycle(conn), ~p"/auth/passkey/verify", assertion_body(user, response))
    assert json_response(replay, 401)["error"]
  end

  test "verifying with no challenge in the session is a 401", %{conn: conn} do
    user = user_fixture()
    authenticator = enrol(user)
    response = SoftwareAuthenticator.get(authenticator, :crypto.strong_rand_bytes(32), @origin)

    conn = post(conn, ~p"/auth/passkey/verify", assertion_body(user, response))

    assert json_response(conn, 401)["error"]
    refute get_session(conn, :user_id)
  end

  test "a bad assertion is a 401 and grants nothing", %{conn: conn} do
    user = user_fixture()
    enrol(user)

    conn = post(conn, ~p"/auth/passkey/challenge")
    challenge = stashed_challenge(conn)

    impostor = SoftwareAuthenticator.new(@rp_id)
    response = SoftwareAuthenticator.get(impostor, challenge.bytes, @origin, sign_count: 1)

    conn = post(recycle(conn), ~p"/auth/passkey/verify", assertion_body(user, response))

    assert json_response(conn, 401)["error"]
    refute get_session(conn, :user_id)
  end

  test "an expired challenge is refused", %{conn: conn} do
    user = user_fixture()
    authenticator = enrol(user)
    {challenge, _} = WebAuthn.authentication_challenge()
    response = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    conn =
      conn
      |> init_test_session(%{})
      |> put_session(:passkey_login_challenge, {challenge, System.system_time(:second) - 301})
      |> post(~p"/auth/passkey/verify", assertion_body(user, response))

    assert json_response(conn, 401)["error"]
    refute get_session(conn, :user_id)
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd apps/portal && mix test test/portal_web/controllers/passkey_controller_test.exs
```

Expected: FAIL — no route matches `/auth/passkey/challenge`.

- [ ] **Step 3: Write the challenge-session helper**

`apps/portal/lib/portal_web/web_authn_session.ex`:

```elixir
defmodule PortalWeb.WebAuthnSession do
  @moduledoc """
  Holds a `Wax.Challenge` in the signed session between the two halves of a
  WebAuthn ceremony.

  The session rather than the database: a challenge is worthless to anyone who
  cannot also present the assertion, it expires in five minutes, and this way
  there is no table to prune. `take/2` always deletes, so a challenge is
  single-use whether or not it verified.
  """

  import Plug.Conn

  @ttl_seconds 300

  @spec put(Plug.Conn.t(), atom(), Wax.Challenge.t()) :: Plug.Conn.t()
  def put(conn, key, %Wax.Challenge{} = challenge) do
    put_session(conn, key, {challenge, System.system_time(:second)})
  end

  @spec take(Plug.Conn.t(), atom()) ::
          {:ok, Wax.Challenge.t(), Plug.Conn.t()} | {:error, Plug.Conn.t()}
  def take(conn, key) do
    value = get_session(conn, key)
    conn = delete_session(conn, key)

    case value do
      {%Wax.Challenge{} = challenge, at} when is_integer(at) ->
        if System.system_time(:second) - at <= @ttl_seconds do
          {:ok, challenge, conn}
        else
          {:error, conn}
        end

      _ ->
        {:error, conn}
    end
  end
end
```

If the session cookie overflows Phoenix's 4 KB limit once a challenge is in it
— watch for a `Plug.Conn.CookieOverflowError` in the logs — the fix is to move
the challenge into an ETS table keyed by a random id and keep only that id in
the session. Measure before assuming: a challenge is a small struct and should
serialise to a few hundred bytes.

- [ ] **Step 4: Write the controller**

`apps/portal/lib/portal_web/controllers/passkey_controller.ex`:

```elixir
defmodule PortalWeb.PasskeyController do
  @moduledoc """
  JSON endpoints for signing in with a passkey and no password.

  Both actions speak JSON because the browser's WebAuthn API is asynchronous
  and deals in `ArrayBuffer`s; every binary crosses the wire base64url-encoded.
  """

  use PortalWeb, :controller

  require Logger

  alias Portal.Accounts.WebAuthn
  alias PortalWeb.{UserAuth, WebAuthnSession}

  @session_key :passkey_login_challenge

  def login_challenge(conn, _params) do
    {challenge, payload} = WebAuthn.authentication_challenge()

    conn
    |> WebAuthnSession.put(@session_key, challenge)
    |> json(payload)
  end

  def login_verify(conn, params) do
    case WebAuthnSession.take(conn, @session_key) do
      {:ok, challenge, conn} -> verify(conn, params, challenge)
      {:error, conn} -> deny(conn, :no_challenge)
    end
  end

  defp verify(conn, params, challenge) do
    case WebAuthn.authenticate(params, challenge) do
      {:ok, %{user: user}} ->
        conn
        |> UserAuth.complete_login(user, :passkey)
        |> put_flash(:info, "Signed in.")
        |> json(%{redirect_to: landing_path(user)})

      {:error, reason} ->
        deny(conn, reason)
    end
  end

  defp deny(conn, reason) do
    Logger.info("Passkey sign-in refused: #{inspect(reason)}")

    # One message for every failure. Distinguishing "no such credential" from
    # "bad signature" would tell an attacker which credential ids are real.
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "That passkey could not be verified. Try again, or use your password."})
  end

  defp landing_path(user) do
    if Portal.Accounts.admin?(user), do: ~p"/admin", else: ~p"/request-scan"
  end
end
```

- [ ] **Step 5: Add the routes**

In the browser scope of `apps/portal/lib/portal_web/router.ex`, after the
`/login/totp` routes from Task 8:

```elixir
    post "/auth/passkey/challenge", PasskeyController, :login_challenge
    post "/auth/passkey/verify", PasskeyController, :login_verify
```

These sit in the `:browser` pipeline, not `:api`, because they need the
session and CSRF protection. The browser sends `x-csrf-token`.

- [ ] **Step 6: Write the browser glue**

`apps/portal/assets/js/webauthn.js`:

```javascript
// WebAuthn glue for the login and security-settings pages.
//
// Both are controller-rendered, not LiveView, so this binds plain listeners
// rather than registering hooks. Every binary crosses the wire base64url
// encoded, because JSON has no way to carry an ArrayBuffer.

const b64urlToBuf = (value) => {
  const padded = value + "=".repeat((4 - (value.length % 4)) % 4)
  const binary = atob(padded.replace(/-/g, "+").replace(/_/g, "/"))
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) { bytes[i] = binary.charCodeAt(i) }
  return bytes.buffer
}

const bufToB64url = (buffer) => {
  const bytes = new Uint8Array(buffer)
  let binary = ""
  for (let i = 0; i < bytes.length; i++) { binary += String.fromCharCode(bytes[i]) }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

const csrfToken = () =>
  document.querySelector("meta[name='csrf-token']").getAttribute("content")

const postJSON = async (url, body) => {
  const response = await fetch(url, {
    method: "POST",
    credentials: "same-origin",
    headers: {
      "content-type": "application/json",
      accept: "application/json",
      "x-csrf-token": csrfToken()
    },
    body: JSON.stringify(body || {})
  })

  const data = await response.json()
  if (!response.ok) { throw new Error(data.error || "Request failed") }
  return data
}

export async function loginWithPasskey() {
  const options = await postJSON("/auth/passkey/challenge", {})

  const assertion = await navigator.credentials.get({
    publicKey: {
      challenge: b64urlToBuf(options.challenge),
      rpId: options.rp_id,
      timeout: options.timeout * 1000,
      userVerification: "required"
      // No allowCredentials: the credential is discoverable, so the
      // authenticator picks one and tells us whose it is via userHandle.
    }
  })

  const result = await postJSON("/auth/passkey/verify", {
    credential_id: bufToB64url(assertion.rawId),
    authenticator_data: bufToB64url(assertion.response.authenticatorData),
    signature: bufToB64url(assertion.response.signature),
    client_data_json: bufToB64url(assertion.response.clientDataJSON),
    user_handle: assertion.response.userHandle
      ? bufToB64url(assertion.response.userHandle)
      : null
  })

  window.location.assign(result.redirect_to)
}

export async function registerPasskey(nickname) {
  const options = await postJSON("/settings/security/passkeys/challenge", {})

  const credential = await navigator.credentials.create({
    publicKey: {
      challenge: b64urlToBuf(options.challenge),
      rp: {id: options.rp_id, name: options.rp_name},
      user: {
        id: b64urlToBuf(options.user_handle),
        name: options.user_name,
        displayName: options.user_name
      },
      // ES256 first, RS256 as the fallback some Windows Hello stacks need.
      pubKeyCredParams: [
        {type: "public-key", alg: -7},
        {type: "public-key", alg: -257}
      ],
      timeout: options.timeout * 1000,
      attestation: "none",
      excludeCredentials: options.exclude_credentials.map((id) => ({
        type: "public-key",
        id: b64urlToBuf(id)
      })),
      authenticatorSelection: {
        // Discoverable, so the passwordless login flow can find it without a
        // username. This is the browser half of that; the server half is
        // omitting allowCredentials.
        residentKey: "required",
        requireResidentKey: true,
        userVerification: "required"
      }
    }
  })

  await postJSON("/settings/security/passkeys", {
    nickname: nickname,
    attestation_object: bufToB64url(credential.response.attestationObject),
    client_data_json: bufToB64url(credential.response.clientDataJSON),
    transports: credential.response.getTransports
      ? credential.response.getTransports()
      : []
  })

  window.location.reload()
}

const run = async (button, statusEl, work) => {
  button.disabled = true
  if (statusEl) { statusEl.textContent = "" }

  try {
    await work()
  } catch (error) {
    // AbortError and NotAllowedError mean the person dismissed the browser
    // prompt. That is not a failure worth shouting about.
    const dismissed = error.name === "NotAllowedError" || error.name === "AbortError"
    if (statusEl) {
      statusEl.textContent = dismissed ? "Cancelled." : error.message
    }
    button.disabled = false
  }
}

export function initWebAuthn() {
  const supported = Boolean(window.PublicKeyCredential)

  const loginButton = document.getElementById("passkey-login")
  if (loginButton) {
    const block = loginButton.closest("[data-passkey-block]")
    if (!supported && block) {
      block.hidden = true
    } else {
      const status = document.getElementById("passkey-login-status")
      loginButton.addEventListener("click", (event) => {
        event.preventDefault()
        run(loginButton, status, loginWithPasskey)
      })
    }
  }

  const registerButton = document.getElementById("passkey-register")
  if (registerButton) {
    const block = registerButton.closest("[data-passkey-block]")
    if (!supported && block) {
      block.hidden = true
    } else {
      const status = document.getElementById("passkey-register-status")
      const nicknameInput = document.getElementById("passkey-nickname")
      registerButton.addEventListener("click", (event) => {
        event.preventDefault()
        run(registerButton, status, () =>
          registerPasskey(nicknameInput ? nicknameInput.value : "")
        )
      })
    }
  }
}
```

In `apps/portal/assets/js/app.js`, after the `topbar` import:

```javascript
import {initWebAuthn} from "./webauthn"
```

and near the bottom, after the LiveSocket is connected:

```javascript
initWebAuthn()
```

- [ ] **Step 7: Add the login button**

In `apps/portal/lib/portal_web/controllers/page_html/login.html.heex`, after
the closing `</form>` of the password form and before that `</div>`:

```heex
          <div class="divider">or</div>

          <div data-passkey-block class="space-y-2">
            <button id="passkey-login" type="button" class="btn btn-outline w-full">
              <.icon name="hero-finger-print-mini" class="size-5" /> Sign in with a passkey
            </button>
            <p id="passkey-login-status" class="text-sm text-error" aria-live="polite"></p>
          </div>
```

`data-passkey-block` is what the JS hides on a browser with no WebAuthn, so
nobody is offered a button that cannot work.

- [ ] **Step 8: Run the tests**

```bash
cd apps/portal && mix test test/portal_web/controllers/passkey_controller_test.exs
```

Expected: 7 tests, 0 failures.

- [ ] **Step 9: Non-vacuity check on single use and expiry**

Change `WebAuthnSession.take/2` to keep the challenge in the session rather
than deleting it. "a challenge works exactly once" must fail. Restore.

Change the TTL comparison to always pass. "an expired challenge is refused"
must fail. Restore.

- [ ] **Step 10: Check it by hand**

```bash
cd apps/portal && mix phx.server
```

Visit `http://localhost:4001/login`. The passkey button should be visible, and
clicking it should raise the browser's passkey picker. There is nothing to
pick yet — registration arrives in Task 10 — so expect the browser to report
no credential found. What is being verified here is that the button is wired,
the challenge round-trips, and no JS error appears in the console.

- [ ] **Step 11: Commit**

```bash
git add apps/portal/lib/portal_web/web_authn_session.ex \
  apps/portal/lib/portal_web/controllers/passkey_controller.ex \
  apps/portal/lib/portal_web/router.ex \
  apps/portal/lib/portal_web/controllers/page_html/login.html.heex \
  apps/portal/assets/js/webauthn.js apps/portal/assets/js/app.js \
  apps/portal/test/portal_web/controllers/passkey_controller_test.exs
git commit -m "feat(portal): sign in with a passkey and no password"
```

---

### Task 10: The security settings page

**Files:**
- Create: `apps/portal/lib/portal_web/controllers/security_controller.ex`
- Create: `apps/portal/lib/portal_web/controllers/security_html.ex`
- Create: `apps/portal/lib/portal_web/controllers/security_html/show.html.heex`
- Modify: `apps/portal/assets/js/webauthn.js` (add the passkey step-up)
- Modify: `apps/portal/lib/portal_web/controllers/page_html/settings.html.heex` (link to the new page)
- Modify: `apps/portal/lib/portal_web/router.ex` (the `:authenticated` scope)
- Test: `apps/portal/test/portal_web/controllers/security_controller_test.exs`

**One deviation from the spec, deliberate.** The spec says recovery codes are
generated on first successful factor enrolment. Here they are generated by an
explicit click on a banner that appears the moment a first factor lands. The
reason is narrow: the plaintext must reach exactly one rendered response and
must never sit in the session, and Phoenix's cookie store is signed rather
than encrypted. Handing them back through a JSON response after passkey
registration or stashing them across a redirect both put the plaintext
somewhere it does not belong. One button, rendered directly, has neither
problem.

**Interfaces:**
- Consumes: `Mfa.*` (Task 7), `Passkeys.*` (Task 2), `Totp.*` (Task 4), `RecoveryCodes.*` (Task 3), `WebAuthn.*` (Tasks 5-6), `WebAuthnSession` and `UserAuth` (Tasks 8-9).
- Produces: routes under `/settings/security`, all inside the `:authenticated` pipeline.

| Method | Path | Action | Format |
| --- | --- | --- | --- |
| GET | `/settings/security` | `:show` | HTML |
| POST | `/settings/security/reauth` | `:reauth` | HTML |
| POST | `/settings/security/reauth/passkey/challenge` | `:reauth_challenge` | JSON |
| POST | `/settings/security/reauth/passkey` | `:reauth_passkey` | JSON |
| POST | `/settings/security/passkeys/challenge` | `:registration_challenge` | JSON |
| POST | `/settings/security/passkeys` | `:create_passkey` | JSON |
| POST | `/settings/security/passkeys/:id/delete` | `:delete_passkey` | HTML |
| POST | `/settings/security/totp/start` | `:start_totp` | HTML |
| POST | `/settings/security/totp/confirm` | `:confirm_totp` | HTML |
| POST | `/settings/security/totp/delete` | `:delete_totp` | HTML |
| POST | `/settings/security/recovery-codes` | `:regenerate_recovery_codes` | HTML |

`POST` rather than `DELETE` for removals, matching the existing
`post "/admin/requests/:id/approve"` convention in this router — plain forms,
no `data-method` JS.

- [ ] **Step 1: Write the failing test**

`apps/portal/test/portal_web/controllers/security_controller_test.exs`:

```elixir
defmodule PortalWeb.SecurityControllerTest do
  use PortalWeb.ConnCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.{Passkeys, RecoveryCodes, Totp, WebAuthn}
  alias Portal.Test.SoftwareAuthenticator

  @password "correct horse battery staple"
  @rp_id "localhost"
  @origin "http://localhost:4001"
  @at ~U[2026-09-18 12:00:00.000000Z]

  defp sign_in(conn, user, method \\ :password) do
    conn
    |> init_test_session(%{})
    |> put_session(:user_id, user.id)
    |> put_session(:reauth_method, method)
    |> put_session(:reauth_at, System.system_time(:second))
  end

  defp stale_sign_in(conn, user, method \\ :password) do
    conn
    |> init_test_session(%{})
    |> put_session(:user_id, user.id)
    |> put_session(:reauth_method, method)
    |> put_session(:reauth_at, System.system_time(:second) - 601)
  end

  defp add_passkey(user) do
    {:ok, passkey} =
      Passkeys.create(user, %{
        credential_id: :crypto.strong_rand_bytes(16),
        public_key: :erlang.term_to_binary(%{3 => -7}),
        nickname: "laptop"
      })

    passkey
  end

  defp add_totp(user) do
    {:ok, %{secret: secret}} = Totp.start_enrolment(user)
    :ok = Totp.confirm(user, NimbleTOTP.verification_code(secret, time: @at), @at)
    secret
  end

  test "the page lists factors and is reachable without a fresh re-auth", %{conn: conn} do
    user = user_fixture(%{password: @password})
    add_passkey(user)

    conn = conn |> stale_sign_in(user) |> get(~p"/settings/security")

    body = html_response(conn, 200)
    assert body =~ "laptop"
    assert body =~ "Security"
  end

  test "signing out of the window blocks a factor change", %{conn: conn} do
    user = user_fixture(%{password: @password})
    passkey = add_passkey(user)

    conn =
      conn
      |> stale_sign_in(user, :passkey)
      |> post(~p"/settings/security/passkeys/#{passkey.id}/delete")

    assert redirected_to(conn) == ~p"/settings/security"
    assert Passkeys.count_for_user(user) == 1
  end

  test "the password re-authorises while the account holds no factor", %{conn: conn} do
    user = user_fixture(%{password: @password})

    conn =
      conn
      |> stale_sign_in(user)
      |> post(~p"/settings/security/reauth", %{"method" => "password", "credential" => @password})

    assert redirected_to(conn) == ~p"/settings/security"
    assert get_session(conn, :reauth_method) == :password
  end

  test "the password stops re-authorising once a passkey exists", %{conn: conn} do
    user = user_fixture(%{password: @password})
    add_passkey(user)

    conn =
      conn
      |> stale_sign_in(user)
      |> post(~p"/settings/security/reauth", %{"method" => "password", "credential" => @password})

    assert html_response(conn, 200) =~ "passkey"
    refute get_session(conn, :reauth_method) == :password
  end

  test "a recovery code re-authorises and is spent", %{conn: conn} do
    user = user_fixture(%{password: @password})
    add_passkey(user)
    {:ok, [code | _]} = RecoveryCodes.generate(user)

    conn =
      conn
      |> stale_sign_in(user, :passkey)
      |> post(~p"/settings/security/reauth", %{"method" => "recovery_code", "credential" => code})

    assert redirected_to(conn) == ~p"/settings/security"
    assert get_session(conn, :reauth_method) == :recovery_code
    assert RecoveryCodes.remaining(user) == 9
  end

  test "a TOTP code re-authorises a TOTP-only account", %{conn: conn} do
    user = user_fixture(%{password: @password})
    secret = add_totp(user)

    conn =
      conn
      |> stale_sign_in(user, :totp)
      |> post(~p"/settings/security/reauth", %{
        "method" => "totp",
        "credential" => NimbleTOTP.verification_code(secret)
      })

    assert redirected_to(conn) == ~p"/settings/security"
    assert get_session(conn, :reauth_method) == :totp
  end

  test "registering a passkey works end to end with a fresh re-auth", %{conn: conn} do
    user = user_fixture(%{password: @password})
    authenticator = SoftwareAuthenticator.new(@rp_id)

    conn = conn |> sign_in(user) |> post(~p"/settings/security/passkeys/challenge")
    payload = json_response(conn, 200)
    {challenge, _at} = get_session(conn, :passkey_registration_challenge)
    response = SoftwareAuthenticator.create(authenticator, challenge.bytes, @origin)

    assert payload["user_name"] == user.username

    conn =
      post(recycle(conn), ~p"/settings/security/passkeys", %{
        "nickname" => "yubikey",
        "attestation_object" => WebAuthn.b64(response.attestation_object),
        "client_data_json" => WebAuthn.b64(response.client_data_json),
        "transports" => ["usb"]
      })

    assert json_response(conn, 200)["ok"]
    assert Passkeys.count_for_user(user) == 1
  end

  test "the registration challenge is refused without a fresh re-auth", %{conn: conn} do
    user = user_fixture(%{password: @password})
    add_passkey(user)

    conn = conn |> stale_sign_in(user, :passkey) |> post(~p"/settings/security/passkeys/challenge")

    assert json_response(conn, 403)["error"]
    refute get_session(conn, :passkey_registration_challenge)
  end

  test "TOTP enrolment needs one working code before it counts", %{conn: conn} do
    user = user_fixture(%{password: @password})

    conn = conn |> sign_in(user) |> post(~p"/settings/security/totp/start")
    body = html_response(conn, 200)
    assert body =~ "otpauth://totp/"

    refute Totp.confirmed?(user)

    {:ok, stored} = Totp.get_secret(user)

    conn =
      post(recycle(conn), ~p"/settings/security/totp/confirm", %{
        "code" => NimbleTOTP.verification_code(stored.secret)
      })

    assert redirected_to(conn) == ~p"/settings/security"
    assert Totp.confirmed?(user)
  end

  test "a passkey can be removed with a fresh passkey re-auth", %{conn: conn} do
    user = user_fixture(%{password: @password})
    passkey = add_passkey(user)

    conn =
      conn
      |> sign_in(user, :passkey)
      |> post(~p"/settings/security/passkeys/#{passkey.id}/delete")

    assert redirected_to(conn) == ~p"/settings/security"
    assert Passkeys.count_for_user(user) == 0
  end

  test "another account's passkey id does nothing", %{conn: conn} do
    user = user_fixture(%{password: @password})
    add_passkey(user)
    stranger = user_fixture()
    theirs = add_passkey(stranger)

    conn =
      conn
      |> sign_in(user, :passkey)
      |> post(~p"/settings/security/passkeys/#{theirs.id}/delete")

    assert redirected_to(conn) == ~p"/settings/security"
    assert Passkeys.count_for_user(stranger) == 1
  end

  test "recovery codes are shown once and only once", %{conn: conn} do
    user = user_fixture(%{password: @password})
    add_passkey(user)

    conn = conn |> sign_in(user, :passkey) |> post(~p"/settings/security/recovery-codes")

    body = html_response(conn, 200)
    assert Regex.scan(~r/[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}/, body) |> length() == 10
    assert RecoveryCodes.remaining(user) == 10

    reloaded = get(recycle(conn), ~p"/settings/security")
    refute Regex.match?(~r/[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}/, html_response(reloaded, 200))
  end

  test "an anonymous visitor is sent to the login page", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/settings/security")) == ~p"/login"
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd apps/portal && mix test test/portal_web/controllers/security_controller_test.exs
```

Expected: FAIL — no route matches `/settings/security`.

- [ ] **Step 3: Write the controller**

`apps/portal/lib/portal_web/controllers/security_controller.ex`:

```elixir
defmodule PortalWeb.SecurityController do
  @moduledoc """
  Enrolment and removal of second factors.

  Viewing the page is free; changing anything needs a re-authentication inside
  the last ten minutes, with a credential `Portal.Accounts.Mfa` accepts for
  this account. The password counts only while the account holds no factor —
  otherwise a phished password would let an attacker enrol their own passkey,
  which is exactly what the admin passkey requirement exists to prevent.
  """

  use PortalWeb, :controller

  require Logger

  alias Portal.Accounts.{Mfa, Passkeys, RecoveryCodes, Totp, WebAuthn}
  alias PortalWeb.{UserAuth, WebAuthnSession}

  @registration_key :passkey_registration_challenge
  @reauth_key :passkey_reauth_challenge
  @json_actions [:registration_challenge, :create_passkey, :reauth_challenge, :reauth_passkey]
  @guarded_actions [
    :registration_challenge,
    :create_passkey,
    :delete_passkey,
    :start_totp,
    :confirm_totp,
    :delete_totp,
    :regenerate_recovery_codes
  ]

  plug(:require_fresh_reauth when action in @guarded_actions)

  def show(conn, _params), do: render_page(conn)

  # --- Re-authentication -----------------------------------------------------

  def reauth(conn, %{"method" => method, "credential" => credential}) do
    user = conn.assigns.current_user
    method = parse_method(method)

    cond do
      method not in Mfa.accepted_reauth_methods(user) ->
        render_page(conn, error: reauth_message(user))

      proven?(user, method, credential) ->
        conn
        |> UserAuth.mark_reauth(method)
        |> put_flash(:info, "Confirmed. You have #{window_minutes()} minutes to make changes.")
        |> redirect(to: ~p"/settings/security")

      true ->
        render_page(conn, error: "That did not match. Try again.")
    end
  end

  def reauth(conn, _params), do: render_page(conn, error: reauth_message(conn.assigns.current_user))

  def reauth_challenge(conn, _params) do
    {challenge, payload} = WebAuthn.authentication_challenge()

    conn
    |> WebAuthnSession.put(@reauth_key, challenge)
    |> json(payload)
  end

  def reauth_passkey(conn, params) do
    user = conn.assigns.current_user

    with {:ok, challenge, conn} <- WebAuthnSession.take(conn, @reauth_key),
         {:ok, %{user: %{id: id}}} when id == user.id <- WebAuthn.authenticate(params, challenge) do
      conn
      |> UserAuth.mark_reauth(:passkey)
      |> json(%{ok: true})
    else
      {:error, %Plug.Conn{} = conn} -> json_error(conn, :unauthorized, "That passkey could not be verified.")
      _ -> json_error(conn, :unauthorized, "That passkey could not be verified.")
    end
  end

  # --- Passkeys --------------------------------------------------------------

  def registration_challenge(conn, _params) do
    {challenge, payload} = WebAuthn.registration_challenge(conn.assigns.current_user)

    conn
    |> WebAuthnSession.put(@registration_key, challenge)
    |> json(payload)
  end

  def create_passkey(conn, params) do
    user = conn.assigns.current_user

    with {:ok, challenge, conn} <- WebAuthnSession.take(conn, @registration_key),
         {:ok, passkey} <- WebAuthn.register(user, params, challenge) do
      Logger.warning("Passkey #{passkey.nickname} registered for #{user.username}")
      json(conn, %{ok: true})
    else
      {:error, %Plug.Conn{} = conn} ->
        json_error(conn, :unprocessable_entity, "That registration expired. Try again.")

      {:error, :already_registered} ->
        json_error(conn, :unprocessable_entity, "That security key is already registered.")

      {:error, reason} ->
        Logger.info("Passkey registration refused: #{inspect(reason)}")
        json_error(conn, :unprocessable_entity, "That passkey could not be registered.")
    end
  end

  def delete_passkey(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Passkeys.delete(user, id) do
      :ok ->
        Logger.warning("Passkey removed for #{user.username}")

        conn
        |> put_flash(:info, "Passkey removed.")
        |> redirect(to: ~p"/settings/security")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "No such passkey on this account.")
        |> redirect(to: ~p"/settings/security")
    end
  end

  # --- TOTP ------------------------------------------------------------------

  def start_totp(conn, _params) do
    {:ok, %{uri: uri}} = Totp.start_enrolment(conn.assigns.current_user)

    render_page(conn, totp_uri: uri)
  end

  def confirm_totp(conn, %{"code" => code}) do
    user = conn.assigns.current_user

    case Totp.confirm(user, code) do
      :ok ->
        Logger.warning("TOTP confirmed for #{user.username}")

        conn
        |> put_flash(:info, "Authenticator app confirmed.")
        |> redirect(to: ~p"/settings/security")

      {:error, _} ->
        render_page(conn, error: "That code did not match. Check the clock on your device.")
    end
  end

  def delete_totp(conn, _params) do
    user = conn.assigns.current_user
    :ok = Totp.disable(user)
    Logger.warning("TOTP removed for #{user.username}")

    conn
    |> put_flash(:info, "Authenticator app removed.")
    |> redirect(to: ~p"/settings/security")
  end

  # --- Recovery codes --------------------------------------------------------

  def regenerate_recovery_codes(conn, _params) do
    user = conn.assigns.current_user
    {:ok, codes} = RecoveryCodes.generate(user)
    Logger.warning("Recovery codes regenerated for #{user.username}")

    # Rendered straight into this one response. They are never stored, never
    # put in the session, and cannot be shown again.
    render_page(conn, new_recovery_codes: codes)
  end

  # --- Plumbing --------------------------------------------------------------

  defp require_fresh_reauth(conn, _opts) do
    user = conn.assigns.current_user

    if Mfa.reauth_fresh?(user, UserAuth.reauth_method(conn), UserAuth.reauth_at(conn)) do
      conn
    else
      conn |> deny_reauth(user) |> halt()
    end
  end

  defp deny_reauth(conn, user) do
    if conn.private[:phoenix_action] in @json_actions do
      json_error(conn, :forbidden, reauth_message(user))
    else
      conn
      |> put_flash(:error, reauth_message(user))
      |> redirect(to: ~p"/settings/security")
    end
  end

  defp reauth_message(user) do
    case Mfa.accepted_reauth_methods(user) do
      [:password] -> "Confirm your password before changing sign-in settings."
      [:passkey, :recovery_code] -> "Confirm with your passkey or a recovery code first."
      [:totp, :recovery_code] -> "Confirm with a code from your authenticator app, or a recovery code."
    end
  end

  defp parse_method("password"), do: :password
  defp parse_method("totp"), do: :totp
  defp parse_method("recovery_code"), do: :recovery_code
  defp parse_method(_), do: :unknown

  defp proven?(user, :password, credential) do
    match?({:ok, _}, Portal.Accounts.authenticate_user(user.username, credential))
  end

  defp proven?(user, :totp, credential), do: Totp.verify(user, credential) == :ok
  defp proven?(user, :recovery_code, credential), do: RecoveryCodes.consume(user, credential) == :ok
  defp proven?(_user, _method, _credential), do: false

  defp json_error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end

  defp window_minutes, do: div(Mfa.reauth_window_seconds(), 60)

  defp render_page(conn, extra \\ []) do
    user = conn.assigns.current_user

    conn =
      case Keyword.fetch(extra, :error) do
        {:ok, message} -> put_flash(conn, :error, message)
        :error -> conn
      end

    render(conn, :show,
      page_title: "Security",
      current_user: user,
      passkeys: Passkeys.list_for_user(user),
      totp_confirmed: Totp.confirmed?(user),
      recovery_remaining: RecoveryCodes.remaining(user),
      recovery_low: RecoveryCodes.low?(user),
      enrolled: Mfa.enrolled?(user),
      admin_satisfied: Mfa.admin_satisfied?(user),
      accepted_methods: Mfa.accepted_reauth_methods(user),
      reauth_fresh:
        Mfa.reauth_fresh?(user, UserAuth.reauth_method(conn), UserAuth.reauth_at(conn)),
      window_minutes: window_minutes(),
      totp_uri: Keyword.get(extra, :totp_uri),
      new_recovery_codes: Keyword.get(extra, :new_recovery_codes)
    )
  end
end
```

- [ ] **Step 4: Write the template module and template**

`apps/portal/lib/portal_web/controllers/security_html.ex`:

```elixir
defmodule PortalWeb.SecurityHTML do
  @moduledoc """
  Templates for the security settings page.
  """

  use PortalWeb, :html

  embed_templates("security_html/*")
end
```

`apps/portal/lib/portal_web/controllers/security_html/show.html.heex`:

```heex
<Layouts.flash_group flash={@flash} />

<main class="min-h-screen bg-base-100 text-base-content">
  <.site_nav current_user={@current_user} />

  <div class="mx-auto max-w-2xl px-4 py-10 sm:px-6 lg:px-8">
    <section class="space-y-8">
      <PortalWeb.UI.page_header kicker="Account" title="Security">
        <:subtitle>
          Passkeys sign you in without a password and cannot be phished.
          An authenticator app adds a second step to password sign-ins.
        </:subtitle>
      </PortalWeb.UI.page_header>

      <div :if={@current_user.is_admin and not @admin_satisfied} class="alert alert-warning">
        <.icon name="hero-shield-exclamation-mini" class="size-5" />
        <span>
          Admin accounts need a passkey to reach <code>/admin</code>.
          An authenticator app does not substitute: a passkey cannot be phished, and a code can.
        </span>
      </div>

      <div :if={@enrolled and @recovery_remaining == 0} class="alert alert-error">
        <.icon name="hero-lifebuoy-mini" class="size-5" />
        <span>
          You have no recovery codes. Without them, a lost passkey means losing the account.
        </span>
      </div>

      <div :if={@recovery_low and @recovery_remaining > 0} class="alert alert-warning">
        <span>{@recovery_remaining} recovery codes left. Generate a fresh set.</span>
      </div>

      <section :if={@new_recovery_codes} class="card border-2 border-primary bg-base-100 shadow-sm">
        <div class="card-body gap-4">
          <h2 class="text-lg font-semibold tracking-tight">Your recovery codes</h2>
          <p class="text-sm leading-6 text-base-content/70">
            Save these now. Each works once, and this page will not show them again.
          </p>
          <ul class="grid grid-cols-2 gap-2 font-mono text-sm">
            <li :for={code <- @new_recovery_codes} class="rounded bg-base-200 px-3 py-2">{code}</li>
          </ul>
        </div>
      </section>

      <section :if={not @reauth_fresh} class="card border border-warning bg-base-100 shadow-sm">
        <div class="card-body gap-4">
          <h2 class="text-lg font-semibold tracking-tight">Confirm it is you</h2>
          <p class="text-sm leading-6 text-base-content/70">
            Changing sign-in settings needs a fresh confirmation, good for {@window_minutes} minutes.
          </p>

          <form :if={:password in @accepted_methods} method="post" action={~p"/settings/security/reauth"} class="space-y-3">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <input type="hidden" name="method" value="password" />
            <input name="credential" type="password" autocomplete="current-password" required
              placeholder="Password" class="input input-bordered w-full" />
            <button type="submit" class="btn btn-primary w-full">Confirm</button>
          </form>

          <form :if={:totp in @accepted_methods or :recovery_code in @accepted_methods}
            method="post" action={~p"/settings/security/reauth"} class="space-y-3">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <input type="hidden" name="method" value={if :totp in @accepted_methods, do: "totp", else: "recovery_code"} />
            <input name="credential" inputmode="text" autocomplete="one-time-code" required
              placeholder={if :totp in @accepted_methods, do: "Six-digit code", else: "Recovery code"}
              class="input input-bordered w-full font-mono" />
            <button type="submit" class="btn btn-primary w-full">Confirm</button>
          </form>

          <form :if={:recovery_code in @accepted_methods and :totp in @accepted_methods == false}
            method="post" action={~p"/settings/security/reauth"} class="space-y-3">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <input type="hidden" name="method" value="recovery_code" />
            <input name="credential" required placeholder="Recovery code"
              class="input input-bordered w-full font-mono" />
            <button type="submit" class="btn btn-outline w-full">Use a recovery code</button>
          </form>

          <div :if={:passkey in @accepted_methods} data-passkey-block class="space-y-2">
            <button id="passkey-reauth" type="button" class="btn btn-outline w-full">
              <.icon name="hero-finger-print-mini" class="size-5" /> Confirm with your passkey
            </button>
            <p id="passkey-reauth-status" class="text-sm text-error" aria-live="polite"></p>
          </div>
        </div>
      </section>

      <section class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body gap-4">
          <h2 class="text-lg font-semibold tracking-tight">Passkeys</h2>

          <p :if={@passkeys == []} class="text-sm leading-6 text-base-content/70">
            No passkeys registered.
          </p>

          <ul class="divide-y divide-base-300">
            <li :for={passkey <- @passkeys} class="flex items-center justify-between gap-4 py-3">
              <div>
                <p class="font-semibold">{passkey.nickname}</p>
                <p class="text-sm text-base-content/60">
                  Added {Calendar.strftime(passkey.inserted_at, "%Y-%m-%d")}
                  <span :if={passkey.last_used_at}>
                    · last used {Calendar.strftime(passkey.last_used_at, "%Y-%m-%d")}
                  </span>
                </p>
              </div>
              <form :if={@reauth_fresh} method="post" action={~p"/settings/security/passkeys/#{passkey.id}/delete"}>
                <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
                <button type="submit" class="btn btn-sm btn-ghost text-error">Remove</button>
              </form>
            </li>
          </ul>

          <div :if={@reauth_fresh} data-passkey-block class="space-y-3">
            <input id="passkey-nickname" placeholder="Name this device" maxlength="60"
              class="input input-bordered w-full" />
            <button id="passkey-register" type="button" class="btn btn-primary w-full">
              <.icon name="hero-plus-mini" class="size-5" /> Add a passkey
            </button>
            <p id="passkey-register-status" class="text-sm text-error" aria-live="polite"></p>
          </div>
        </div>
      </section>

      <section class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body gap-4">
          <h2 class="text-lg font-semibold tracking-tight">Authenticator app</h2>

          <p class="text-sm leading-6 text-base-content/70">
            <span :if={@totp_confirmed}>Enabled. Password sign-ins ask for a code.</span>
            <span :if={not @totp_confirmed}>Not set up.</span>
          </p>

          <div :if={@totp_uri} class="space-y-3">
            <p class="text-sm leading-6 text-base-content/70">
              Add this to your authenticator app, then enter the code it shows.
            </p>
            <p class="break-all rounded bg-base-200 p-3 font-mono text-xs">{@totp_uri}</p>
            <form method="post" action={~p"/settings/security/totp/confirm"} class="space-y-3">
              <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
              <input name="code" inputmode="numeric" autocomplete="one-time-code" required
                placeholder="Six-digit code" class="input input-bordered w-full font-mono" />
              <button type="submit" class="btn btn-primary w-full">Confirm</button>
            </form>
          </div>

          <form :if={@reauth_fresh and not @totp_confirmed and is_nil(@totp_uri)}
            method="post" action={~p"/settings/security/totp/start"}>
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <button type="submit" class="btn btn-outline w-full">Set up an authenticator app</button>
          </form>

          <form :if={@reauth_fresh and @totp_confirmed} method="post" action={~p"/settings/security/totp/delete"}>
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <button type="submit" class="btn btn-ghost w-full text-error">Remove authenticator app</button>
          </form>
        </div>
      </section>

      <section class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body gap-4">
          <h2 class="text-lg font-semibold tracking-tight">Recovery codes</h2>
          <p class="text-sm leading-6 text-base-content/70">
            {@recovery_remaining} unused. Each works once, in place of a passkey or a code.
          </p>
          <form :if={@reauth_fresh} method="post" action={~p"/settings/security/recovery-codes"}>
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <button type="submit" class="btn btn-outline w-full">
              Generate a new set
            </button>
          </form>
          <p :if={@reauth_fresh and @recovery_remaining > 0} class="text-sm text-base-content/60">
            Generating replaces every existing code.
          </p>
        </div>
      </section>
    </section>
  </div>
</main>
```

The `:if={:recovery_code in @accepted_methods and :totp in @accepted_methods == false}`
expression parses awkwardly. Replace it with a bound variable computed in the
controller if HEEx complains — a `recovery_only?` assign is clearer than
fighting operator precedence in a template.

- [ ] **Step 5: Add the routes**

In `apps/portal/lib/portal_web/router.ex`, inside the existing `:authenticated`
scope, after `post "/settings", PageController, :update_settings`:

```elixir
    get "/settings/security", SecurityController, :show
    post "/settings/security/reauth", SecurityController, :reauth
    post "/settings/security/reauth/passkey/challenge", SecurityController, :reauth_challenge
    post "/settings/security/reauth/passkey", SecurityController, :reauth_passkey
    post "/settings/security/passkeys/challenge", SecurityController, :registration_challenge
    post "/settings/security/passkeys", SecurityController, :create_passkey
    post "/settings/security/passkeys/:id/delete", SecurityController, :delete_passkey
    post "/settings/security/totp/start", SecurityController, :start_totp
    post "/settings/security/totp/confirm", SecurityController, :confirm_totp
    post "/settings/security/totp/delete", SecurityController, :delete_totp
    post "/settings/security/recovery-codes", SecurityController, :regenerate_recovery_codes
```

- [ ] **Step 6: Link the page from account settings**

In `apps/portal/lib/portal_web/controllers/page_html/settings.html.heex`, add a
card between the username and password sections:

```heex
      <section class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body gap-4">
          <h2 class="text-lg font-semibold tracking-tight">Sign-in security</h2>
          <p class="text-sm leading-6 text-base-content/70">
            Passkeys, authenticator apps and recovery codes live on their own page.
          </p>
          <.link href={~p"/settings/security"} class="btn btn-outline w-full">
            <.icon name="hero-shield-check-mini" class="size-5" /> Security settings
          </.link>
        </div>
      </section>
```

- [ ] **Step 7: Add the passkey step-up to the browser glue**

In `apps/portal/assets/js/webauthn.js`, add beside `loginWithPasskey`:

```javascript
export async function reauthWithPasskey() {
  const options = await postJSON("/settings/security/reauth/passkey/challenge", {})

  const assertion = await navigator.credentials.get({
    publicKey: {
      challenge: b64urlToBuf(options.challenge),
      rpId: options.rp_id,
      timeout: options.timeout * 1000,
      userVerification: "required"
    }
  })

  await postJSON("/settings/security/reauth/passkey", {
    credential_id: bufToB64url(assertion.rawId),
    authenticator_data: bufToB64url(assertion.response.authenticatorData),
    signature: bufToB64url(assertion.response.signature),
    client_data_json: bufToB64url(assertion.response.clientDataJSON),
    user_handle: assertion.response.userHandle
      ? bufToB64url(assertion.response.userHandle)
      : null
  })

  window.location.reload()
}
```

and inside `initWebAuthn`, after the register block:

```javascript
  const reauthButton = document.getElementById("passkey-reauth")
  if (reauthButton) {
    const block = reauthButton.closest("[data-passkey-block]")
    if (!supported && block) {
      block.hidden = true
    } else {
      const status = document.getElementById("passkey-reauth-status")
      reauthButton.addEventListener("click", (event) => {
        event.preventDefault()
        run(reauthButton, status, reauthWithPasskey)
      })
    }
  }
```

- [ ] **Step 8: Run the tests**

```bash
cd apps/portal && mix test test/portal_web/controllers/security_controller_test.exs
```

Expected: 13 tests, 0 failures.

- [ ] **Step 9: Non-vacuity checks**

1. Remove the `plug(:require_fresh_reauth …)` line. "signing out of the window
   blocks a factor change" and "the registration challenge is refused without a
   fresh re-auth" must both fail. Restore.
2. Remove the `method not in Mfa.accepted_reauth_methods(user)` branch from
   `reauth/2`. "the password stops re-authorising once a passkey exists" must
   fail. Restore.
3. In `reauth_passkey/2`, drop the `when id == user.id` guard. Write a throwaway
   assertion proving another account's passkey can re-authorise this session,
   confirm it passes without the guard and fails with it, then delete the
   throwaway and restore the guard.

- [ ] **Step 10: Check it by hand — this is the enrolment path you will use**

```bash
cd apps/portal && mix phx.server
```

Register an account, visit `/settings/security`, confirm with the password,
add a passkey with a real authenticator, generate recovery codes, then sign
out and sign back in with the passkey button on `/login`.

- [ ] **Step 11: Commit**

```bash
git add apps/portal/lib/portal_web/controllers/security_controller.ex \
  apps/portal/lib/portal_web/controllers/security_html.ex \
  apps/portal/lib/portal_web/controllers/security_html/ \
  apps/portal/lib/portal_web/controllers/page_html/settings.html.heex \
  apps/portal/lib/portal_web/router.ex apps/portal/assets/js/webauthn.js \
  apps/portal/test/portal_web/controllers/security_controller_test.exs
git commit -m "feat(portal): security settings page for passkeys, TOTP and recovery codes"
```

---

### Task 11: Require a passkey for admin access

**Files:**
- Modify: `apps/portal/lib/portal_web/plugs/require_admin.ex`
- Test: `apps/portal/test/portal_web/plugs/require_admin_test.exs` (new file)

This is the point of the whole feature. `/admin` and `/admin/oban` can enqueue
builds, approve scan requests and edit package metadata. An admin session
obtained with a phished password is worth stopping; an admin session obtained
with a passkey assertion cannot be phished at all.

Enforcement lives here and nowhere else. The spec is explicit that there is no
global interstitial: a non-admin never sees a nag screen, and an admin who has
not enrolled is redirected to `/settings/security` rather than locked out of
the whole site.

**Interfaces:**
- Consumes: `Mfa.admin_satisfied?/1` (Task 7).
- Produces: nothing new. Behaviour change only.

- [ ] **Step 1: Write the failing test**

`apps/portal/test/portal_web/plugs/require_admin_test.exs`:

```elixir
defmodule PortalWeb.Plugs.RequireAdminTest do
  use PortalWeb.ConnCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.Passkeys

  defp add_passkey(user) do
    {:ok, _} =
      Passkeys.create(user, %{
        credential_id: :crypto.strong_rand_bytes(16),
        public_key: :erlang.term_to_binary(%{3 => -7}),
        nickname: "laptop"
      })

    :ok
  end

  defp sign_in(conn, user) do
    conn |> init_test_session(%{}) |> put_session(:user_id, user.id)
  end

  test "an admin with a passkey reaches the admin page", %{conn: conn} do
    admin = admin_fixture()
    add_passkey(admin)

    conn = conn |> sign_in(admin) |> get(~p"/admin")

    assert html_response(conn, 200)
  end

  test "an admin without a passkey is sent to security settings", %{conn: conn} do
    admin = admin_fixture()

    conn = conn |> sign_in(admin) |> get(~p"/admin")

    assert redirected_to(conn) == ~p"/settings/security"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "passkey"
  end

  test "TOTP alone does not open the admin page", %{conn: conn} do
    admin = admin_fixture()
    {:ok, %{secret: secret}} = Portal.Accounts.Totp.start_enrolment(admin)
    :ok = Portal.Accounts.Totp.confirm(admin, NimbleTOTP.verification_code(secret))

    conn = conn |> sign_in(admin) |> get(~p"/admin")

    assert redirected_to(conn) == ~p"/settings/security"
  end

  test "a non-admin is still sent away without a passkey nag", %{conn: conn} do
    user = user_fixture()

    conn = conn |> sign_in(user) |> get(~p"/admin")

    assert redirected_to(conn) == ~p"/request-scan"
    refute Phoenix.Flash.get(conn.assigns.flash, :error) =~ "passkey"
  end

  test "an anonymous visitor goes to the login page", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/admin")) == ~p"/login"
  end

  test "the oban dashboard is gated the same way", %{conn: conn} do
    admin = admin_fixture()

    conn = conn |> sign_in(admin) |> get("/admin/oban")

    assert redirected_to(conn) == ~p"/settings/security"
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd apps/portal && mix test test/portal_web/plugs/require_admin_test.exs
```

Expected: FAIL — the two "sent to security settings" tests get a 200, because
the plug does not look at factors yet.

- [ ] **Step 3: Add the branch**

In `apps/portal/lib/portal_web/plugs/require_admin.ex`, extend the moduledoc and
put a new clause into the `cond` **between** the `is_nil(user)` clause and the
`Portal.Accounts.admin?(user)` clause. Order matters: the unenrolled-admin check
must run before the success branch, and after the anonymous check so a signed-out
visitor still lands on `/login`.

```elixir
  @moduledoc """
  Halts the connection unless the current session belongs to an admin user
  who holds a passkey.

  Used to gate the Oban Web dashboard (and any other admin-only mount).

  The passkey requirement is enforced here rather than site-wide on purpose:
  an admin without one keeps full use of the rest of the portal and is sent to
  `/settings/security` to enrol, and a non-admin never sees the requirement at
  all. An authenticator app does not substitute. A TOTP code can be read out
  over the phone to someone claiming to be from the project; a passkey
  assertion is bound to the origin and cannot leave the browser.
  """
```

```elixir
      Portal.Accounts.admin?(user) and not Portal.Accounts.Mfa.admin_satisfied?(user) ->
        conn
        |> put_flash(:error, "Admin access needs a passkey. Add one to continue.")
        |> redirect(to: ~p"/settings/security")
        |> halt()

      Portal.Accounts.admin?(user) ->
        assign(conn, :current_user, user)
```

- [ ] **Step 4: Run the tests**

```bash
cd apps/portal && mix test test/portal_web/plugs/require_admin_test.exs
cd apps/portal && mix test
```

Expected: 6 tests here, 0 failures. Then the whole portal suite green.

**If existing admin tests now fail**, they are signing in an admin without a
passkey. That is the correct new behaviour — fix the tests, not the plug. The
cheapest fix is a helper in `Portal.Test.AccountsFixtures`:

```elixir
  def admin_with_passkey_fixture(attrs \\ %{}) do
    admin = admin_fixture(attrs)

    {:ok, _} =
      Portal.Accounts.Passkeys.create(admin, %{
        credential_id: :crypto.strong_rand_bytes(16),
        public_key: :erlang.term_to_binary(%{3 => -7}),
        nickname: "test key"
      })

    admin
  end
```

Swap `admin_fixture` for `admin_with_passkey_fixture` in the admin controller and
LiveView tests. Do not add a config switch that disables the requirement in test —
a switch that turns the check off in test is a switch someone will find in prod.

- [ ] **Step 5: Non-vacuity check**

Comment out the new `cond` clause. "an admin without a passkey is sent to
security settings", "TOTP alone does not open the admin page" and "the oban
dashboard is gated the same way" must all fail. Restore.

Then flip the clause's condition to drop `Portal.Accounts.admin?(user) and`.
"a non-admin is still sent away without a passkey nag" must fail, proving the
admin scoping is doing work. Restore.

- [ ] **Step 6: Commit**

```bash
git add apps/portal/lib/portal_web/plugs/require_admin.ex \
  apps/portal/test/portal_web/plugs/require_admin_test.exs \
  apps/portal/test/support/fixtures/accounts_fixtures.ex
git commit -m "feat(portal): require a passkey for admin access"
```

Add any admin test files you had to adjust to that `git add` line.

---

### Task 12: Break-glass recovery and the operator documentation

**Files:**
- Create: `apps/portal/lib/portal/accounts/recovery.ex`
- Modify: `ops/README.md`
- Test: `apps/portal/test/portal/accounts/recovery_test.exs`

Every factor can be lost at once: a stolen laptop with the only passkey on it,
a wiped phone holding the only TOTP secret, recovery codes left in a drawer in
another country. Without an escape hatch the account is gone, and with it
`/admin`.

The hatch is a remote console call on the web host. That is not a weaker door
than the passkey: reaching the console means holding root on the machine where
`/etc/ncc-portal/portal.env` and the database credentials already live. Anyone
who can run it can already read everything the admin panel shows.

**Interfaces:**
- Consumes: `Passkeys.list_for_user/1` and `Passkeys.delete/2` (Task 2), `Totp.disable/1` (Task 4), `RecoveryCodes.generate/1` (Task 3).
- Produces: `Portal.Accounts.Recovery.clear_factors!/1` — takes a username, returns the freshly generated recovery codes as a list of strings, raises if the user does not exist.

- [ ] **Step 1: Write the failing test**

`apps/portal/test/portal/accounts/recovery_test.exs`:

```elixir
defmodule Portal.Accounts.RecoveryTest do
  use Portal.DataCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.{Mfa, Passkeys, Recovery, RecoveryCodes, Totp}

  defp add_passkey(user, nickname) do
    {:ok, _} =
      Passkeys.create(user, %{
        credential_id: :crypto.strong_rand_bytes(16),
        public_key: :erlang.term_to_binary(%{3 => -7}),
        nickname: nickname
      })

    :ok
  end

  test "clearing factors removes every passkey and the authenticator app" do
    user = user_fixture()
    add_passkey(user, "laptop")
    add_passkey(user, "phone")
    {:ok, %{secret: secret}} = Totp.start_enrolment(user)
    :ok = Totp.confirm(user, NimbleTOTP.verification_code(secret))

    codes = Recovery.clear_factors!(user.username)

    assert Passkeys.count_for_user(user) == 0
    refute Totp.confirmed?(user)
    refute Mfa.enrolled?(user)
    assert length(codes) == 10
  end

  test "the returned codes work" do
    user = user_fixture()
    add_passkey(user, "laptop")

    [code | _] = Recovery.clear_factors!(user.username)

    assert RecoveryCodes.consume(user, code) == :ok
  end

  test "old recovery codes stop working" do
    user = user_fixture()
    add_passkey(user, "laptop")
    {:ok, [old | _]} = RecoveryCodes.generate(user)

    _new = Recovery.clear_factors!(user.username)

    assert RecoveryCodes.consume(user, old) == {:error, :invalid_code}
  end

  test "an account with no factors is still handled" do
    user = user_fixture()

    codes = Recovery.clear_factors!(user.username)

    assert length(codes) == 10
  end

  test "an unknown username raises" do
    assert_raise RuntimeError, ~r/nobody/, fn ->
      Recovery.clear_factors!("nobody")
    end
  end

  test "another account is untouched" do
    user = user_fixture()
    add_passkey(user, "laptop")
    bystander = user_fixture()
    add_passkey(bystander, "their laptop")

    _codes = Recovery.clear_factors!(user.username)

    assert Passkeys.count_for_user(bystander) == 1
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd apps/portal && mix test test/portal/accounts/recovery_test.exs
```

Expected: FAIL — `Portal.Accounts.Recovery` is undefined.

- [ ] **Step 3: Write the module**

`apps/portal/lib/portal/accounts/recovery.ex`:

```elixir
defmodule Portal.Accounts.Recovery do
  @moduledoc """
  Break-glass recovery, run from a remote console on the web host.

  Strips every second factor from one account and prints a fresh set of
  recovery codes. There is no web route and no API for this, deliberately:
  reaching the console requires root on the host that already holds the
  database credentials and `/etc/ncc-portal/portal.env`, so this grants no
  access an attacker at that level does not already have.

      bin/portal eval 'Portal.Accounts.Recovery.clear_factors!("tomhoenderdos")'

  Documented in `ops/README.md`.
  """

  require Logger

  alias Portal.Accounts
  alias Portal.Accounts.{Passkeys, RecoveryCodes, Totp}

  @doc """
  Removes all passkeys and any authenticator app from `username`, issues ten
  fresh recovery codes and returns them.

  Raises if no such account exists. Every existing recovery code stops working.
  """
  @spec clear_factors!(String.t()) :: [String.t()]
  def clear_factors!(username) when is_binary(username) do
    user = fetch_user!(username)

    passkeys = Passkeys.list_for_user(user)
    Enum.each(passkeys, fn passkey -> :ok = Passkeys.delete(user, passkey.id) end)
    :ok = Totp.disable(user)
    {:ok, codes} = RecoveryCodes.generate(user)

    Logger.warning(
      "BREAK-GLASS: cleared #{length(passkeys)} passkeys and TOTP for #{username}, " <>
        "issued #{length(codes)} recovery codes"
    )

    IO.puts("""

    Factors cleared for #{username}.

    Recovery codes — each works once, and this is the only time they are shown:

    #{Enum.map_join(codes, "\n", &("  " <> &1))}

    Sign in at /login with the password, use one of these when asked for a
    second factor, then enrol a passkey at /settings/security. Admin access
    stays closed until a passkey is registered.
    """)

    codes
  end

  defp fetch_user!(username) do
    case Accounts.get_user_by_username(username) do
      {:ok, user} -> user
      _ -> raise "no account named #{inspect(username)}"
    end
  end
end
```

`Portal.Accounts.get_user_by_username/1` already exists
(`apps/portal/lib/portal/accounts.ex:64`) and returns `{:ok, user}` or
`{:ok, nil}` — hence the `_ -> raise` catch-all rather than matching
`{:error, _}`. Use it; do not reach into the Ash resource from here.

- [ ] **Step 4: Run the tests**

```bash
cd apps/portal && mix test test/portal/accounts/recovery_test.exs
```

Expected: 6 tests, 0 failures.

- [ ] **Step 5: Non-vacuity check**

Delete the `RecoveryCodes.generate(user)` call and return `[]`. "the returned
codes work", "old recovery codes stop working" and both length assertions must
fail. Restore.

Then change `Passkeys.delete(user, passkey.id)` to pass a hard-coded other
user — "another account is untouched" must fail. Restore.

- [ ] **Step 6: Document it in `ops/README.md`**

Add these two sections before `## Not tracked here`:

```markdown
## WebAuthn environment

`/etc/ncc-portal/portal.env` on the web host carries two variables that decide
which origin passkeys are bound to:

    NCC_WEBAUTHN_RP_ID=compatibility.nerves-project.org
    NCC_WEBAUTHN_ORIGIN=https://compatibility.nerves-project.org

Both are optional — unset, they fall back to `PHX_HOST` and `https://` plus
`PHX_HOST`, which is the same answer today. Set them explicitly anyway, because
the fallback goes wrong silently: a passkey registered under one RP ID cannot
be used under another, and every existing passkey stops working the moment the
value changes. If the site ever moves domain, every user re-enrols.

Neither value is a secret. They are in the env file because that is where the
portal's configuration lives, not because they need protecting.

## Locked out of admin

Symptom: the only admin has lost every passkey, the authenticator app and the
recovery codes. `/admin` redirects to `/settings/security` and nothing there
can be changed, because changing a factor needs a factor.

On the web host:

    cd /opt/nerves_compatibility/portal
    bin/portal eval 'Portal.Accounts.Recovery.clear_factors!("tomhoenderdos")'

This deletes every passkey on that account, removes the authenticator app,
invalidates all outstanding recovery codes and prints ten new ones. Copy them
out of the terminal before you close it — they are shown once and stored only
as SHA-256 hashes.

Then sign in at `/login` with the password, use one of the printed codes when
asked for a second factor, and register a passkey at `/settings/security`.
`/admin` stays closed until that passkey exists.

The call runs against the live database and needs no downtime. It is not a
backdoor worth worrying about: anyone who can run it already has root on the
host holding `/etc/ncc-portal/portal.env` and the database credentials.
```

- [ ] **Step 7: Run the whole thing**

```bash
cd apps/portal && mix precommit
```

Then, from the umbrella root, confirm the shared lock still has everything:

```bash
cd /Users/tomhoenderdos/Projects/nerves_compatibility && mix test && grep -c '"mix_audit"' mix.lock
```

Expected: full suite green, `grep` prints `1`. A `0` means a `mix deps.get`
was run from inside `apps/*` at some point and pruned the root-only deps out of
the shared lock — see the warning in `CLAUDE.md`. Recover with
`git checkout mix.lock` followed by `mix deps.get` from the root.

- [ ] **Step 8: Commit**

```bash
git add apps/portal/lib/portal/accounts/recovery.ex \
  apps/portal/test/portal/accounts/recovery_test.exs ops/README.md
git commit -m "feat(portal): break-glass factor reset from the remote console"
```

---

## Deployment notes

Nothing in this plan requires downtime, and nothing about it is reversible by
rolling back the release alone — the migration adds three tables, and a
rollback that drops them takes every registered passkey with it.

Order of operations on the first deploy:

1. Set `NCC_WEBAUTHN_RP_ID` and `NCC_WEBAUTHN_ORIGIN` in
   `/etc/ncc-portal/portal.env` **before** the release starts. Registering a
   passkey under the wrong RP ID produces a credential that can never be used.
2. Deploy. Migrations run on boot, as they already do.
3. Sign in as the admin account and enrol a passkey immediately. Until then
   `/admin` and `/admin/oban` are closed to everyone, including you. The
   break-glass call in Task 12 is the way back if this step is skipped and
   something else goes wrong in between.
4. Save the recovery codes somewhere that is not the same laptop as the
   passkey.

Existing accounts are unaffected: no factors, so password sign-in continues to
work exactly as before and no second-factor step appears.

## What this plan deliberately leaves out

Carried forward from the spec, unchanged:

- **A durable audit trail.** Factor changes are logged at `:warning` and no
  more. A `portal_security_events` table with a queryable history is the right
  answer, and is worth doing once there is more than one admin.
- **"Remember this device".** Every password sign-in on an account with TOTP
  asks for a code, every time. Trusted-device cookies are a second credential
  store with their own theft story, and the traffic here does not justify one.
- **WebAuthn for `/api`.** The JSON API stays unauthenticated and read-only.
