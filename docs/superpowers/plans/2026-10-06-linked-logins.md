# Linked logins (Hex.pm + GitHub sign-in) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let people sign in with Hex.pm or GitHub, link and unlink both on one account, and close the Hex username-fallback takeover.

**Architecture:** One new domain module, `Portal.Accounts.Identities`, owns every rule about provider identities (match by stored link only, create, collision, link, unlink, scan-request accounts). `Portal.HexPm` and `Portal.GitHub` stop touching users; each gains `verify_device/1` returning a `%Portal.Accounts.Identity{}`. A new `PortalWeb.ProviderAuthController` drives the device flow for three purposes (login, link, step-up) on one template. Providers are looked up through app config so controller tests swap in a fake.

**Tech Stack:** Elixir, Phoenix 1.8 controllers + HEEx, Ash 3 / AshPostgres, Argon2.

**Spec:** `docs/superpowers/specs/2026-10-06-linked-logins-design.md`

## Global Constraints

- Matching only ever uses a stored, verified link. No username fallback anywhere.
- Hex.pm identities match on `hex_username`; GitHub identities match on numeric `github_id` (login kept for display, refreshed every sign-in).
- An identity is linked to at most one account; an account has at most one link per provider. Linking never moves an identity between accounts.
- A provider sign-in never matches or merges into an account by username.
- Pending identity (choose-username step): held in the session, single use, at most 10 minutes (600 s).
- Second factor: a provider sign-in owes the same second step as a password sign-in (`Mfa.second_factor_required?/1`).
- `/admin` keeps requiring `login_method == :passkey`; provider sign-ins never satisfy it.
- Link, unlink, and set-password sit behind the existing step-up window (`Mfa.reauth_fresh?/4`, 600 s). For accounts with no passkey/TOTP the linked providers count as step-up methods.
- Unlink allowed only while another way in remains: a set password, the other provider, or a passkey.
- Log every link, unlink and provider-created account.
- Never persist provider access tokens; never put them in the session.
- Run all commands from the umbrella root; never run `mix deps.*` inside `apps/*`. Migrations are generated inside `apps/portal` with `mix ash_postgres.generate_migrations --name <name>`.
- Before any push: the gates script (format, compile `--warnings-as-errors`, credo, sobelow, deps.audit, test).

## Review Focus

1. **Provider login that fails the local username regex** (GitHub allows 1–2 char logins and mixed case; regex needs 3–40 chars). Expected: treated like a collision, user goes to choose-username, never a crash. Test in Task 2 (`sign_in/1` with login `"ab"`) and Task 4.
2. **Choose-username replay / stale pending identity**: submitting the form twice, or after 10 minutes, or after the identity got linked elsewhere meanwhile. Expected: second submit and stale submit refused with "start again", nothing created; linked-elsewhere refused. Tests in Task 2 (`create_with_username/2` → `:identity_taken`) and Task 4.
3. **Step-up for a password-less, factor-less provider account**: today `accepted_reauth_methods/1` would return `[:password]` and the user could never step up. Expected: `[:hex]`/`[:github]` accepted, and the provider confirm flow works. Tests in Task 2 (Mfa) and Task 5.
4. **Confirm-with-provider using a *different* provider account than the linked one** (attacker with a session approves with their own Hex account). Expected: refused, step-up not marked. Test in Task 5.
5. **Unique-index race / backfill collisions**: two rows with the same `hex_username` or the same backfilled `github_id` would make the migration fail in prod. Expected: pre-release query finds none; migration aborts loudly rather than silently. Covered by Task 1 Step 6 (prod check) and Task 1 constraint test.

---

### Task 1: Data — `github_id`, `password_set`, unique links, `Identity` struct

**Files:**
- Modify: `apps/portal/lib/portal/accounts/user.ex`
- Create: `apps/portal/lib/portal/accounts/identity.ex`
- Create (generated, then edited): `apps/portal/priv/repo/migrations/<ts>_add_linked_logins.exs`, resource snapshot under `apps/portal/priv/resource_snapshots/repo/portal_users/`
- Test: `apps/portal/test/portal/accounts/user_links_test.exs`

**Interfaces:**
- Produces: `User` attributes `github_id :: integer | nil`, `password_set :: boolean` (default true). Actions: `:create` also accepts `github_id`, `password_set`; `:record_github_login` also accepts `github_id`; `:update_profile` also accepts `password_set`; new `:set_links` accepting `hex_username, hex_profile, github_username, github_profile, github_id`.
- Produces: `%Portal.Accounts.Identity{provider: :hex | :github, uid: String.t() | integer(), username: String.t(), profile: map(), access_token: String.t() | nil}`; `Identity.to_session/1 :: map()` (drops `profile` and `access_token`), `Identity.from_session/1 :: {:ok, Identity.t()} | :error`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Portal.Accounts.UserLinksTest do
  use Portal.DataCase, async: true

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.{Identity, User}

  defp set_links(user, attrs) do
    user |> Ash.Changeset.for_update(:set_links, attrs) |> Ash.update(domain: Portal.Accounts)
  end

  test "a new account has a password unless told otherwise" do
    assert user_fixture().password_set
  end

  test "a Hex.pm identity links to one account only" do
    {:ok, _} = set_links(user_fixture(), %{hex_username: "tom"})
    assert {:error, _} = set_links(user_fixture(), %{hex_username: "tom"})
  end

  test "a GitHub id links to one account only" do
    {:ok, _} = set_links(user_fixture(), %{github_id: 42, github_username: "a"})
    assert {:error, _} = set_links(user_fixture(), %{github_id: 42, github_username: "b"})
  end

  test "many accounts may have no link at all" do
    assert {:ok, %User{}} = set_links(user_fixture(), %{hex_username: nil, github_id: nil})
    assert {:ok, %User{}} = set_links(user_fixture(), %{hex_username: nil, github_id: nil})
  end

  test "the session form of an identity carries no token and no profile" do
    identity = %Identity{
      provider: :github,
      uid: 42,
      username: "octo",
      profile: %{"id" => 42, "login" => "octo"},
      access_token: "secret"
    }

    session = Identity.to_session(identity)
    refute inspect(session) =~ "secret"
    refute Map.has_key?(session, "profile")
    assert {:ok, %Identity{provider: :github, uid: 42, username: "octo"}} = Identity.from_session(session)
  end

  test "a tampered or foreign session value is not an identity" do
    assert :error = Identity.from_session(%{"provider" => "gitlab", "uid" => 1, "username" => "x"})
    assert :error = Identity.from_session(nil)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test apps/portal/test/portal/accounts/user_links_test.exs`
Expected: FAIL — `Portal.Accounts.Identity` undefined / `:set_links` action unknown.

- [ ] **Step 3: Implement**

`apps/portal/lib/portal/accounts/identity.ex`:

```elixir
defmodule Portal.Accounts.Identity do
  @moduledoc """
  An account at Hex.pm or GitHub that the provider has just vouched for.

  `uid` is what links match on: the Hex username (which its owner cannot
  change) or the numeric GitHub user id (the login can change and be taken by
  someone else). `username` is only a suggestion for a new local account.

  `access_token` exists so the GitHub repo check can use it within the same
  request. It is never stored and never written to the session.
  """

  @enforce_keys [:provider, :uid, :username]
  defstruct [:provider, :uid, :username, profile: %{}, access_token: nil]

  @type provider :: :hex | :github
  @type t :: %__MODULE__{
          provider: provider(),
          uid: String.t() | integer(),
          username: String.t(),
          profile: map(),
          access_token: String.t() | nil
        }

  @spec to_session(t()) :: map()
  def to_session(%__MODULE__{} = identity) do
    %{
      "provider" => Atom.to_string(identity.provider),
      "uid" => identity.uid,
      "username" => identity.username
    }
  end

  @spec from_session(term()) :: {:ok, t()} | :error
  def from_session(%{"provider" => "hex", "uid" => uid, "username" => name})
      when is_binary(uid) and is_binary(name),
      do: {:ok, %__MODULE__{provider: :hex, uid: uid, username: name}}

  def from_session(%{"provider" => "github", "uid" => uid, "username" => name})
      when is_integer(uid) and is_binary(name),
      do: {:ok, %__MODULE__{provider: :github, uid: uid, username: name}}

  def from_session(_), do: :error
end
```

`user.ex` changes:

```elixir
    custom_indexes do
      index([:username], unique: true)
      # One account per identity. Partial, so any number of accounts can have
      # no link at all.
      index([:hex_username], unique: true, where: "hex_username IS NOT NULL")
      index([:github_id], unique: true, where: "github_id IS NOT NULL")
      index([:github_username])
    end
```

Add to `:create` accept list: `:github_id, :password_set`. Add `:github_id` to `:record_github_login`. Add `:password_set` to `:update_profile`. New action:

```elixir
    # Link or unlink providers. `Portal.Accounts.Identities` is the only
    # caller; it owns the rules about when that is allowed.
    update :set_links do
      accept([:hex_username, :hex_profile, :github_username, :github_profile, :github_id])
    end
```

Attributes:

```elixir
    # GitHub's numeric user id. Links match on this, never on the login name,
    # which a user can change and someone else can then register.
    attribute :github_id, :integer do
      public?(true)
    end

    # False for accounts a provider sign-in created: their password hash is
    # random and nobody knows it. Settings then offers "Set a password".
    attribute :password_set, :boolean do
      allow_nil?(false)
      default(true)
      public?(true)
    end
```

- [ ] **Step 4: Generate the migration, then add backfill before the indexes**

Run: `cd apps/portal && mix ash_postgres.generate_migrations --name add_linked_logins`

Edit the generated `up/0` so the order is: add columns → backfill → drop old `hex_username` index → create unique indexes. Insert between the `alter table` and the `create unique_index` calls:

```elixir
    # Every GitHub link made so far stored the /user body, which carries the id.
    execute("""
    UPDATE portal_users
       SET github_id = (github_profile::jsonb ->> 'id')::bigint
     WHERE github_id IS NULL
       AND github_username IS NOT NULL
       AND jsonb_typeof(github_profile::jsonb -> 'id') = 'number'
    """)

    # Accounts a provider flow created have a random password nobody knows.
    # Registered accounts that a provider flow later linked keep `true`; the
    # rows this flips are checked by hand before release (see the plan).
    execute("""
    UPDATE portal_users
       SET password_set = false
     WHERE (hex_username IS NOT NULL AND username = lower(hex_username) AND last_hex_login_at IS NOT NULL)
        OR (github_username IS NOT NULL AND username = lower(github_username) AND last_github_login_at IS NOT NULL)
    """)
```

Make sure `github_id` is `:bigint` in the migration (Ash `:integer` generates `:bigint`; check). `down/0` from the generator is fine (data updates are not reversed).

- [ ] **Step 5: Run the test and the migration**

Run: `mix test apps/portal/test/portal/accounts/user_links_test.exs`
Expected: PASS, 6 tests.

- [ ] **Step 6: Prod pre-check query (record result in the ledger; run during release, Task 7)**

```sql
SELECT username, hex_username, github_username,
       github_profile::jsonb ->> 'id' AS gh_id,
       last_hex_login_at, last_github_login_at
  FROM portal_users
 WHERE hex_username IS NOT NULL OR github_username IS NOT NULL;
SELECT hex_username, count(*) FROM portal_users WHERE hex_username IS NOT NULL GROUP BY 1 HAVING count(*) > 1;
```

Expected: no duplicate `hex_username`; each linked row looks like the same person.

- [ ] **Step 7: Commit**

```bash
git add apps/portal/lib/portal/accounts/identity.ex apps/portal/lib/portal/accounts/user.ex apps/portal/priv apps/portal/test/portal/accounts/user_links_test.exs
git commit -m "feat(accounts): github_id, password_set and one account per identity"
```

---

### Task 2: `Portal.Accounts.Identities` — the rules

**Files:**
- Create: `apps/portal/lib/portal/accounts/identities.ex`
- Modify: `apps/portal/lib/portal/accounts.ex` (add `set_password/2`, `valid_username?/1`, make `change_password/3` and `set_temporary_password/1` set `password_set: true`, `register_user/2` unchanged)
- Modify: `apps/portal/lib/portal/accounts/mfa.ex` (`accepted_reauth_methods/1`)
- Modify: `apps/portal/lib/portal_web/controllers/security_controller.ex` (`reauth_message/1` must not crash on new method lists)
- Test: `apps/portal/test/portal/accounts/identities_test.exs`, extend `apps/portal/test/portal/accounts/mfa_test.exs` (create if absent)

**Interfaces:**
- Consumes: Task 1 `Identity`, `User` actions.
- Produces (all in `Portal.Accounts.Identities`):
  - `find_user(Identity.t()) :: {:ok, User.t() | nil}`
  - `sign_in(Identity.t()) :: {:ok, User.t()} | {:error, :choose_username} | {:error, term()}` — linked → records login and returns user; unlinked and username free and valid → creates `password_set: false` account; else `:choose_username`.
  - `create_with_username(Identity.t(), String.t()) :: {:ok, User.t()} | {:error, :invalid_username | :username_taken | :identity_taken}`
  - `link(User.t(), Identity.t()) :: {:ok, User.t()} | {:error, :linked_elsewhere | :provider_already_linked}`
  - `unlink(User.t(), :hex | :github) :: {:ok, User.t()} | {:error, :not_linked | :last_way_in}`
  - `matches?(User.t(), Identity.t()) :: boolean()` — the identity is the one linked to this user.
  - `for_scan_request(Identity.t(), User.t() | nil) :: {:ok, User.t() | nil}`
  - `ways_in(User.t()) :: [:password | :hex | :github | :passkey]`
- Produces: `Portal.Accounts.set_password(User.t(), String.t()) :: {:ok, User.t()} | {:error, :invalid_password}`; `Portal.Accounts.valid_username?(String.t()) :: boolean()`.
- Produces: `Mfa.accepted_reauth_methods/1` returns `[:passkey, :recovery_code]` / `[:totp, :recovery_code]` unchanged when factors exist; otherwise `[:password | if password_set] ++ [:hex | if linked] ++ [:github | if linked]`. `Mfa.method` type gains `:hex | :github`.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Portal.Accounts.IdentitiesTest do
  use Portal.DataCase, async: true

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.{Identities, Identity, Mfa}

  defp hex(name), do: %Identity{provider: :hex, uid: name, username: name, profile: %{"username" => name}}

  defp github(id, login),
    do: %Identity{provider: :github, uid: id, username: login, profile: %{"id" => id, "login" => login}}

  describe "sign_in/1" do
    test "a linked Hex.pm identity signs in as its account" do
      user = user_fixture()
      {:ok, user} = Identities.link(user, hex("frank"))
      assert {:ok, signed_in} = Identities.sign_in(hex("frank"))
      assert signed_in.id == user.id
      assert signed_in.last_hex_login_at
    end

    test "a first sign-in with a free name creates a password-less account" do
      assert {:ok, user} = Identities.sign_in(hex("newcomer"))
      assert user.username == "newcomer"
      assert user.hex_username == "newcomer"
      refute user.password_set
    end

    # The takeover this whole feature had to fix first.
    test "a Hex.pm user named like a local account never signs in as it" do
      local = user_fixture(%{username: "tom"})
      assert {:error, :choose_username} = Identities.sign_in(hex("tom"))
      assert {:ok, nil} = Identities.find_user(hex("tom"))
      {:ok, reloaded} = Portal.Accounts.get_user(local.id)
      assert is_nil(reloaded.hex_username)
    end

    test "GitHub matches on the id, so a renamed login still finds its account" do
      {:ok, user} = Identities.link(user_fixture(), github(7, "oldname"))
      assert {:ok, signed_in} = Identities.sign_in(github(7, "newname"))
      assert signed_in.id == user.id
      assert signed_in.github_username == "newname"
    end

    test "someone who registers a freed GitHub login is not the old account" do
      {:ok, _old} = Identities.link(user_fixture(), github(7, "taken"))
      assert {:error, :choose_username} = Identities.sign_in(github(8, "taken"))
    end

    test "a provider name the local rules reject goes to choose-username" do
      assert {:error, :choose_username} = Identities.sign_in(github(9, "ab"))
    end

    test "a mixed-case GitHub login becomes a lower-case local name" do
      assert {:ok, user} = Identities.sign_in(github(10, "OctoCat"))
      assert user.username == "octocat"
      assert user.github_username == "OctoCat"
    end
  end

  describe "create_with_username/2" do
    test "creates the account with the chosen name and links the identity" do
      user_fixture(%{username: "tom"})
      assert {:ok, user} = Identities.create_with_username(hex("tom"), "tom-hex")
      assert user.username == "tom-hex"
      assert user.hex_username == "tom"
      refute user.password_set
    end

    test "refuses a taken or invalid name" do
      user_fixture(%{username: "tom"})
      assert {:error, :username_taken} = Identities.create_with_username(hex("tom"), "TOM")
      assert {:error, :invalid_username} = Identities.create_with_username(hex("tom"), "x")
    end

    test "refuses an identity that got linked meanwhile" do
      {:ok, _} = Identities.link(user_fixture(), hex("tom"))
      assert {:error, :identity_taken} = Identities.create_with_username(hex("tom"), "other")
    end
  end

  describe "link/2 and unlink/2" do
    test "an identity linked elsewhere is refused" do
      {:ok, _} = Identities.link(user_fixture(), hex("frank"))
      assert {:error, :linked_elsewhere} = Identities.link(user_fixture(), hex("frank"))
    end

    test "a second Hex.pm account on the same user is refused" do
      {:ok, user} = Identities.link(user_fixture(), hex("a"))
      assert {:error, :provider_already_linked} = Identities.link(user, hex("b"))
    end

    test "re-linking the same identity is a no-op success" do
      {:ok, user} = Identities.link(user_fixture(), hex("a"))
      assert {:ok, _} = Identities.link(user, hex("a"))
    end

    test "unlink works while a password remains" do
      {:ok, user} = Identities.link(user_fixture(), hex("a"))
      assert {:ok, user} = Identities.unlink(user, :hex)
      assert is_nil(user.hex_username)
      assert {:ok, nil} = Identities.find_user(hex("a"))
    end

    test "unlink refuses to remove the last way in" do
      {:ok, user} = Identities.sign_in(hex("solo"))
      assert {:error, :last_way_in} = Identities.unlink(user, :hex)
    end

    test "a passkey counts as another way in" do
      {:ok, user} = Identities.sign_in(hex("solo2"))
      user = add_test_passkey(user)
      assert {:ok, _} = Identities.unlink(user, :hex)
    end

    test "unlinking GitHub clears the id too" do
      {:ok, user} = Identities.link(user_fixture(), github(11, "g"))
      {:ok, user} = Identities.unlink(user, :github)
      assert is_nil(user.github_id)
      assert is_nil(user.github_username)
    end

    test "unlinking something that is not linked says so" do
      assert {:error, :not_linked} = Identities.unlink(user_fixture(), :github)
    end
  end

  describe "for_scan_request/2" do
    test "signed in: links the identity to the current account" do
      user = user_fixture()
      assert {:ok, same} = Identities.for_scan_request(hex("owner"), user)
      assert same.id == user.id
      assert same.hex_username == "owner"
    end

    test "signed in, identity linked elsewhere: request still belongs to the current user, no move" do
      {:ok, other} = Identities.link(user_fixture(), hex("owner"))
      user = user_fixture()
      assert {:ok, same} = Identities.for_scan_request(hex("owner"), user)
      assert same.id == user.id
      assert {:ok, %{id: id}} = Identities.find_user(hex("owner"))
      assert id == other.id
    end

    test "anonymous, name collides: no account" do
      user_fixture(%{username: "tom"})
      assert {:ok, nil} = Identities.for_scan_request(hex("tom"), nil)
    end

    test "anonymous, linked: that account" do
      {:ok, user} = Identities.link(user_fixture(), hex("owner"))
      assert {:ok, %{id: id}} = Identities.for_scan_request(hex("owner"), nil)
      assert id == user.id
    end

    test "anonymous, free name: creates the account" do
      assert {:ok, %{username: "fresh"}} = Identities.for_scan_request(hex("fresh"), nil)
    end
  end

  describe "step-up methods" do
    test "a password-less provider account steps up with its provider" do
      {:ok, user} = Identities.sign_in(hex("p"))
      assert Mfa.accepted_reauth_methods(user) == [:hex]
    end

    test "a registered account with Hex.pm linked accepts either" do
      {:ok, user} = Identities.link(user_fixture(), hex("q"))
      assert Mfa.accepted_reauth_methods(user) == [:password, :hex]
    end

    test "factors still win over providers" do
      {:ok, user} = Identities.link(user_fixture(), hex("r"))
      user = add_test_passkey(user)
      assert Mfa.accepted_reauth_methods(user) == [:passkey, :recovery_code]
    end
  end

  describe "Portal.Accounts.set_password/2" do
    test "sets a password and marks it set" do
      {:ok, user} = Identities.sign_in(hex("s"))
      assert {:ok, user} = Portal.Accounts.set_password(user, "a long enough password")
      assert user.password_set
      assert {:ok, _} = Portal.Accounts.authenticate_user("s", "a long enough password")
    end

    test "refuses a short one" do
      {:ok, user} = Identities.sign_in(hex("t"))
      assert {:error, :invalid_password} = Portal.Accounts.set_password(user, "short")
    end
  end
end
```

Check `add_test_passkey/1` is public in `AccountsFixtures` (it is used by `admin_with_passkey_fixture/1`); make it public if it is `defp`.

- [ ] **Step 2: Run to verify failure**

Run: `mix test apps/portal/test/portal/accounts/identities_test.exs`
Expected: FAIL — `Portal.Accounts.Identities` undefined.

- [ ] **Step 3: Implement `Portal.Accounts.Identities`**

```elixir
defmodule Portal.Accounts.Identities do
  @moduledoc """
  Which portal account a Hex.pm or GitHub identity belongs to.

  Every rule here rests on one: an identity is matched only through a link
  stored after the provider vouched for it. A name that happens to equal a
  local username proves nothing -- a Hex user called `tom` is not the local
  admin `tom` -- so names are only ever suggestions for new accounts.
  """

  require Ash.Query
  require Logger

  alias Portal.Accounts.{Identity, Passkeys, User}

  @spec find_user(Identity.t()) :: {:ok, User.t() | nil}
  def find_user(%Identity{provider: :hex, uid: uid}) do
    User
    |> Ash.Query.filter(hex_username == ^uid)
    |> Ash.read_one(domain: Portal.Accounts)
  end

  def find_user(%Identity{provider: :github, uid: uid}) do
    User
    |> Ash.Query.filter(github_id == ^uid)
    |> Ash.read_one(domain: Portal.Accounts)
  end

  @spec sign_in(Identity.t()) :: {:ok, User.t()} | {:error, term()}
  def sign_in(%Identity{} = identity) do
    with {:ok, nil} <- find_user(identity) do
      create_if_free(identity)
    else
      {:ok, %User{} = user} -> record_login(user, identity)
      {:error, _} = error -> error
    end
  end

  @spec create_with_username(Identity.t(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid_username | :username_taken | :identity_taken}
  def create_with_username(%Identity{} = identity, username) do
    username = username |> to_string() |> String.trim() |> String.downcase()

    cond do
      not Portal.Accounts.valid_username?(username) -> {:error, :invalid_username}
      match?({:ok, %User{}}, find_user(identity)) -> {:error, :identity_taken}
      match?({:ok, %User{}}, Portal.Accounts.get_user_by_username(username)) -> {:error, :username_taken}
      true -> create(identity, username)
    end
  end

  @spec link(User.t(), Identity.t()) ::
          {:ok, User.t()} | {:error, :linked_elsewhere | :provider_already_linked}
  def link(%User{} = user, %Identity{} = identity) do
    cond do
      matches?(user, identity) ->
        record_login(user, identity)

      linked?(user, identity.provider) ->
        {:error, :provider_already_linked}

      match?({:ok, %User{}}, find_user(identity)) ->
        {:error, :linked_elsewhere}

      true ->
        with {:ok, user} <- update_links(user, link_attrs(identity)) do
          Logger.info("Linked #{identity.provider} #{inspect(identity.uid)} to user #{user.id}")
          record_login(user, identity)
        end
    end
  end

  @spec unlink(User.t(), Identity.provider()) :: {:ok, User.t()} | {:error, :not_linked | :last_way_in}
  def unlink(%User{} = user, provider) when provider in [:hex, :github] do
    cond do
      not linked?(user, provider) ->
        {:error, :not_linked}

      ways_in(user) -- [provider] == [] ->
        {:error, :last_way_in}

      true ->
        with {:ok, user} <- update_links(user, unlink_attrs(provider)) do
          Logger.info("Unlinked #{provider} from user #{user.id}")
          {:ok, user}
        end
    end
  end

  @spec matches?(User.t(), Identity.t()) :: boolean()
  def matches?(%User{hex_username: linked}, %Identity{provider: :hex, uid: uid}),
    do: is_binary(linked) and linked == uid

  def matches?(%User{github_id: linked}, %Identity{provider: :github, uid: uid}),
    do: is_integer(linked) and linked == uid

  @spec for_scan_request(Identity.t(), User.t() | nil) :: {:ok, User.t() | nil}
  def for_scan_request(%Identity{} = identity, %User{} = current_user) do
    case link(current_user, identity) do
      {:ok, user} -> {:ok, user}
      # Linked elsewhere, or this account already has another one: the request
      # is still this signed-in user's; the identity just stays where it is.
      {:error, _} -> {:ok, current_user}
    end
  end

  def for_scan_request(%Identity{} = identity, nil) do
    case sign_in(identity) do
      {:ok, user} -> {:ok, user}
      {:error, :choose_username} -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  @spec ways_in(User.t()) :: [:password | :hex | :github | :passkey]
  def ways_in(%User{} = user) do
    [
      user.password_set && :password,
      linked?(user, :hex) && :hex,
      linked?(user, :github) && :github,
      Passkeys.count_for_user(user) > 0 && :passkey
    ]
    |> Enum.filter(& &1)
  end

  @spec linked?(User.t(), Identity.provider()) :: boolean()
  def linked?(%User{hex_username: name}, :hex), do: is_binary(name)
  def linked?(%User{github_id: id}, :github), do: is_integer(id)

  defp create_if_free(identity) do
    username = String.downcase(identity.username)

    if Portal.Accounts.valid_username?(username) and
         match?({:ok, nil}, Portal.Accounts.get_user_by_username(username)) do
      create(identity, username)
    else
      {:error, :choose_username}
    end
  end

  defp create(identity, username) do
    attrs =
      identity
      |> link_attrs()
      |> Map.merge(login_attrs(identity))
      |> Map.merge(%{
        username: username,
        password_hash: random_password_hash(),
        password_set: false
      })

    with {:ok, user} <-
           User |> Ash.Changeset.for_create(:create, attrs) |> Ash.create(domain: Portal.Accounts) do
      Logger.info("Created user #{user.id} (#{username}) from #{identity.provider} #{inspect(identity.uid)}")
      {:ok, user}
    end
  end

  defp record_login(user, %Identity{provider: :hex} = identity) do
    user
    |> Ash.Changeset.for_update(:record_hex_login, login_attrs(identity))
    |> Ash.update(domain: Portal.Accounts)
  end

  defp record_login(user, %Identity{provider: :github} = identity) do
    user
    |> Ash.Changeset.for_update(:record_github_login, login_attrs(identity))
    |> Ash.update(domain: Portal.Accounts)
  end

  defp login_attrs(%Identity{provider: :hex} = identity) do
    %{hex_profile: Jason.encode!(identity.profile), last_hex_login_at: now()}
  end

  defp login_attrs(%Identity{provider: :github} = identity) do
    %{
      github_username: identity.username,
      github_profile: Jason.encode!(identity.profile),
      last_github_login_at: now()
    }
  end

  defp link_attrs(%Identity{provider: :hex, uid: uid}), do: %{hex_username: uid}

  defp link_attrs(%Identity{provider: :github, uid: uid, username: login}),
    do: %{github_id: uid, github_username: login}

  defp unlink_attrs(:hex), do: %{hex_username: nil, hex_profile: "{}"}
  defp unlink_attrs(:github), do: %{github_id: nil, github_username: nil, github_profile: "{}"}

  defp update_links(user, attrs) do
    user |> Ash.Changeset.for_update(:set_links, attrs) |> Ash.update(domain: Portal.Accounts)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp random_password_hash do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false) |> Argon2.hash_pwd_salt()
  end
end
```

Note: `:record_hex_login` accepts `hex_username` today — Identities never passes it there; linking only happens through `:set_links`.

- [ ] **Step 4: `Portal.Accounts` and `Mfa` changes**

In `accounts.ex`:

```elixir
  def valid_username?(username) when is_binary(username), do: Regex.match?(@username_regex, username)
  def valid_username?(_), do: false

  @doc """
  Gives a password to an account that has none anyone knows. The caller
  enforces the step-up check; there is no current password to ask for.
  """
  def set_password(%Portal.Accounts.User{} = user, new_password) do
    if valid_password?(new_password) do
      update_profile(user, %{
        password_hash: Argon2.hash_pwd_salt(new_password),
        password_set: true,
        password_reset_required: false
      })
    else
      {:error, :invalid_password}
    end
  end
```

Use `valid_username?/1` in `register_user/2`'s cond instead of the inline regex. Add `password_set: true` to the `update_profile` maps in `change_password/3` and `set_temporary_password/1`.

In `mfa.ex`:

```elixir
  @type method :: :password | :passkey | :totp | :recovery_code | :hex | :github

  def accepted_reauth_methods(%User{} = user) do
    case factors(user) do
      %{passkeys: n} when n > 0 -> [:passkey, :recovery_code]
      %{totp: true} -> [:totp, :recovery_code]
      # No factor yet: whatever the account can sign in with. A provider
      # counts only while no factor exists, for the same reason the password
      # does -- see the moduledoc above.
      _ -> without_factor(user)
    end
  end

  defp without_factor(user) do
    [
      user.password_set && :password,
      is_binary(user.hex_username) && :hex,
      is_integer(user.github_id) && :github
    ]
    |> Enum.filter(& &1)
  end
```

Update the doc above `accepted_reauth_methods/1` to mention providers.

In `security_controller.ex` replace `reauth_message/1` so any list works:

```elixir
  defp reauth_message(user) do
    case Mfa.accepted_reauth_methods(user) do
      [:passkey, :recovery_code] ->
        "Confirm with your passkey or a recovery code first. #{@no_longer_the_password}"

      [:totp, :recovery_code] ->
        "Confirm with a code from your authenticator app, or a recovery code, first. " <>
          @no_longer_the_password

      [:password | _] ->
        "Confirm your password first."

      _ ->
        "Confirm it is you with Hex.pm or GitHub first."
    end
  end
```

- [ ] **Step 5: Run tests**

Run: `mix test apps/portal/test/portal/accounts/ apps/portal/test/portal_web/controllers/security_controller_test.exs`
Expected: PASS (new tests green, existing security tests unchanged).

- [ ] **Step 6: Commit**

```bash
git add apps/portal/lib/portal/accounts apps/portal/lib/portal/accounts.ex apps/portal/lib/portal_web/controllers/security_controller.ex apps/portal/test
git commit -m "feat(accounts): match provider identities by stored link only"
```

---

### Task 3: Providers return identities; scan flows use the rules; fallback removed

**Files:**
- Create: `apps/portal/lib/portal/accounts/identity_provider.ex` (behaviour + lookup)
- Modify: `apps/portal/lib/portal/hex_pm.ex`, `apps/portal/lib/portal/github.ex`
- Modify: `apps/portal/lib/portal_web/controllers/page_controller.ex` (`hex_complete/2`, `github_complete/2` pass `current_user(conn)`)
- Modify: `apps/portal/config/test.exs`
- Create: `apps/portal/test/support/fake_provider.ex`
- Test: `apps/portal/test/portal/hex_pm_test.exs`, `apps/portal/test/portal/github_test.exs`

**Interfaces:**
- Consumes: Task 2 `Identities.for_scan_request/2`, Task 1 `Identity`.
- Produces: behaviour `Portal.Accounts.IdentityProvider` with callbacks `start_device_flow() :: {:ok, map()} | {:error, atom()}` and `verify_device(String.t()) :: {:ok, Identity.t()} | {:pending, atom()} | {:error, atom()}`; `IdentityProvider.module(:hex | :github) :: module()` reading `Application.get_env(:portal, :identity_providers, %{hex: Portal.HexPm, github: Portal.GitHub})`.
- Produces: `Portal.HexPm.identity_from_profile(map()) :: {:ok, Identity.t()} | {:error, :hex_api_unavailable}`, `Portal.GitHub.identity_from_profile(map(), String.t() | nil) :: {:ok, Identity.t()} | {:error, :github_api_unavailable}`.
- Produces: `HexPm.complete_owner_requests(package_names, device_code, current_user_or_nil)`, `GitHub.complete_repo_requests(package_names, device_code, current_user_or_nil)`; subjects come from the identity, not the user.
- Produces (test support): `Portal.Test.FakeProvider` — `start_device_flow/0` returns `Process.get(:fake_provider_start, {:ok, %{device_code: "dev", user_code: "ABCD-1234", verification_uri: "https://example.test/device", expires_in: 900, interval: 5}})`; `verify_device/1` returns `Process.get(:fake_provider_verify, {:pending, :authorization_pending})`.

- [ ] **Step 1: Failing tests (pure profile mapping)**

Append to `hex_pm_test.exs`:

```elixir
  describe "identity_from_profile/1" do
    test "the Hex username is the link" do
      assert {:ok, %Portal.Accounts.Identity{provider: :hex, uid: "frank", username: "frank"}} =
               HexPm.identity_from_profile(%{"username" => "frank", "email" => "f@example.com"})
    end

    test "the profile we keep carries no email" do
      {:ok, identity} = HexPm.identity_from_profile(%{"username" => "frank", "email" => "f@example.com"})
      refute inspect(identity.profile) =~ "example.com"
    end

    test "no username is no identity" do
      assert {:error, :hex_api_unavailable} = HexPm.identity_from_profile(%{})
    end
  end
```

Append to `github_test.exs`:

```elixir
  describe "identity_from_profile/2" do
    test "the numeric id is the link, the login only a name" do
      assert {:ok, %Portal.Accounts.Identity{provider: :github, uid: 583_231, username: "octocat", access_token: "t"}} =
               GitHub.identity_from_profile(%{"id" => 583_231, "login" => "octocat"}, "t")
    end

    test "a body without a numeric id is no identity" do
      assert {:error, :github_api_unavailable} = GitHub.identity_from_profile(%{"login" => "octocat"}, "t")
      assert {:error, :github_api_unavailable} = GitHub.identity_from_profile(%{"id" => "1", "login" => "x"}, "t")
    end
  end
```

Run: `mix test apps/portal/test/portal/hex_pm_test.exs apps/portal/test/portal/github_test.exs`
Expected: FAIL — undefined `identity_from_profile`.

- [ ] **Step 2: Behaviour + lookup**

```elixir
defmodule Portal.Accounts.IdentityProvider do
  @moduledoc """
  A provider that proves who someone is through the OAuth device flow.

  The modules are looked up through config so controller tests can drive the
  whole sign-in flow without hex.pm or github.com.
  """

  alias Portal.Accounts.Identity

  @callback start_device_flow() :: {:ok, map()} | {:error, atom()}
  @callback verify_device(String.t()) ::
              {:ok, Identity.t()} | {:pending, atom()} | {:error, atom()}

  @spec module(Identity.provider()) :: module()
  def module(provider) when provider in [:hex, :github] do
    :portal
    |> Application.get_env(:identity_providers, %{hex: Portal.HexPm, github: Portal.GitHub})
    |> Map.fetch!(provider)
  end
end
```

`config/test.exs`: `config :portal, :identity_providers, %{hex: Portal.Test.FakeProvider, github: Portal.Test.FakeProvider}`.

Note this means `Portal.Test.FakeProvider` must be compiled in test (`test/support` is in `elixirc_paths(:test)` — confirm in `apps/portal/mix.exs`).

`test/support/fake_provider.ex`:

```elixir
defmodule Portal.Test.FakeProvider do
  @moduledoc """
  Stands in for hex.pm and github.com. Controller tests run in the test
  process, so each test scripts its answers with `Process.put/2`.
  """

  @behaviour Portal.Accounts.IdentityProvider

  @impl true
  def start_device_flow do
    Process.get(
      :fake_provider_start,
      {:ok,
       %{
         device_code: "dev",
         user_code: "ABCD-1234",
         verification_uri: "https://example.test/device",
         expires_in: 900,
         interval: 5
       }}
    )
  end

  @impl true
  def verify_device(_device_code),
    do: Process.get(:fake_provider_verify, {:pending, :authorization_pending})
end
```

- [ ] **Step 3: `Portal.HexPm`**

Add `@behaviour Portal.Accounts.IdentityProvider`, `@impl true` on `start_device_flow/0`, and:

```elixir
  @impl true
  def verify_device(device_code) do
    with {:ok, token} <- poll_device_flow(device_code),
         access_token when is_binary(access_token) <- token["access_token"],
         {:ok, profile} <- current_user(access_token) do
      identity_from_profile(profile)
    else
      nil -> {:error, :missing_access_token}
      other -> other
    end
  end

  @doc """
  The identity Hex.pm vouched for. Only the username is kept: `users/me`
  also returns the email, which never enters our database.
  """
  def identity_from_profile(%{"username" => username}) when is_binary(username) and username != "" do
    {:ok,
     %Portal.Accounts.Identity{
       provider: :hex,
       uid: username,
       username: username,
       profile: %{"username" => username}
     }}
  end

  def identity_from_profile(_), do: {:error, :hex_api_unavailable}

  def complete_owner_requests(package_names, device_code, current_user) when is_list(package_names) do
    package_names = package_names |> Enum.reject(&is_nil/1) |> Enum.uniq()

    with {:ok, identity} <- verify_device(device_code),
         {:ok, user} <- Portal.Accounts.Identities.for_scan_request(identity, current_user) do
      create_owner_requests(package_names, identity.uid, user)
    end
  end

  def complete_owner_requests(_package_names, _device_code, _current_user), do: {:error, :missing_package}
```

`create_owner_requests/3` and `create_scan_request/2` take the Hex username explicitly: `create_scan_request(package_name, username, user)` with `user_id: user && user.id, subject: username`. Delete `upsert_hex_user/1`, `get_user_by_hex_username/1`, `get_hex_user/1` (the fallback), `hash_generated_password/0`, `encode_profile/1`, and the old `complete_owner_requests/2`.

Note: the old upsert stored the whole `users/me` body (with email) in `hex_profile`. The new profile is `%{"username" => ...}` only — strictly less data.

- [ ] **Step 4: `Portal.GitHub`**

Same shape:

```elixir
  @impl true
  def verify_device(device_code) do
    with {:ok, token} <- poll_device_flow(device_code),
         access_token when is_binary(access_token) <- token["access_token"],
         {:ok, profile} <- current_user(access_token) do
      identity_from_profile(profile, access_token)
    else
      nil -> {:error, :missing_access_token}
      other -> other
    end
  end

  @doc """
  The identity GitHub vouched for. The numeric id is the link; the login is
  only a display name, because a login can be renamed and re-registered.
  """
  def identity_from_profile(%{"id" => id, "login" => login}, access_token)
      when is_integer(id) and is_binary(login) do
    {:ok,
     %Portal.Accounts.Identity{
       provider: :github,
       uid: id,
       username: login,
       profile: %{"id" => id, "login" => login},
       access_token: access_token
     }}
  end

  def identity_from_profile(_profile, _access_token), do: {:error, :github_api_unavailable}

  def complete_repo_requests(package_names, device_code, current_user) when is_list(package_names) do
    package_names = package_names |> Enum.reject(&is_nil/1) |> Enum.uniq()

    with {:ok, identity} <- verify_device(device_code),
         {:ok, user} <- Portal.Accounts.Identities.for_scan_request(identity, current_user) do
      create_repo_requests(package_names, identity, user)
    end
  end

  def complete_repo_requests(_package_names, _device_code, _current_user), do: {:error, :missing_package}
```

`create_repo_requests/3` uses `identity.username` as login and `identity.access_token`; `create_scan_request(package_name, repo, identity.username, user)` sets `user_id: user && user.id, subject: "#{login}:#{repo.full_name}"`. Delete `upsert_github_user/1`, `get_github_user/1`, `hash_generated_password/0`, `encode_profile/1`, old `complete_repo_requests/2`.

- [ ] **Step 5: PageController**

In `hex_complete/2`: `Portal.HexPm.complete_owner_requests(packages, device_code, current_user(conn))`. In `github_complete/2`: `Portal.GitHub.complete_repo_requests(packages, device_code, current_user(conn))`. The scan flows keep calling `Portal.HexPm`/`Portal.GitHub` directly (not through `IdentityProvider.module/1`), so their behaviour in tests is unchanged.

- [ ] **Step 6: Run tests**

Run: `mix test apps/portal/test/portal/hex_pm_test.exs apps/portal/test/portal/github_test.exs apps/portal/test/portal_web/controllers/page_controller_test.exs`
Expected: PASS. Then `mix compile --warnings-as-errors` from root: no unused-function warnings.

- [ ] **Step 7: Commit**

```bash
git add apps/portal
git commit -m "fix(auth): scan flows link identities by rule; drop Hex username fallback"
```

---

### Task 4: Sign in with Hex.pm / GitHub, choose-username step

**Files:**
- Create: `apps/portal/lib/portal_web/controllers/provider_auth_controller.ex`
- Create: `apps/portal/lib/portal_web/controllers/provider_auth_html.ex`
- Create: `apps/portal/lib/portal_web/controllers/provider_auth_html/device.html.heex`
- Create: `apps/portal/lib/portal_web/controllers/provider_auth_html/choose_username.html.heex`
- Modify: `apps/portal/lib/portal_web/router.ex`, `apps/portal/lib/portal_web/controllers/page_html/login.html.heex`
- Test: `apps/portal/test/portal_web/controllers/provider_auth_controller_test.exs`

**Interfaces:**
- Consumes: `IdentityProvider.module/1`, `Identities.sign_in/1`, `Identities.create_with_username/2`, `Identity.to_session/1`/`from_session/1`, `UserAuth.complete_login/3`, `UserAuth.start_pending/2`, `UserAuth.landing_path/2`, `Mfa.second_factor_required?/1`.
- Produces routes (`:browser` scope):
  - `POST /auth/:provider/login` → `:start` (purpose login)
  - `POST /auth/:provider/login/complete` → `:complete_login`
  - `GET /auth/choose-username` → `:choose_username`
  - `POST /auth/choose-username` → `:create_with_username`
- Produces session keys: `:provider_flow` = `%{"provider" => "hex" | "github", "purpose" => "login" | "link" | "reauth", "device_code" => ..., "user_code" => ..., "verification_uri" => ..., "verification_uri_complete" => ... | nil}`; `:pending_identity` = `Identity.to_session/1` map plus `"at" => unix seconds`.
- Produces private helpers Task 5 reuses in the same controller: `parse_provider/1 :: {:ok, :hex | :github} | :error`, `start_flow(conn, provider, purpose)`, `verify_flow(conn, provider, purpose) :: {:ok, Identity.t(), conn} | {:render, conn}`, `provider_label/1`.

- [ ] **Step 1: Failing tests**

```elixir
defmodule PortalWeb.ProviderAuthControllerTest do
  use PortalWeb.ConnCase, async: true

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.{Identities, Identity, Totp}

  defp hex(name), do: %Identity{provider: :hex, uid: name, username: name, profile: %{"username" => name}}
  defp approve(identity), do: Process.put(:fake_provider_verify, {:ok, identity})

  defp start_login(conn, provider \\ "hex") do
    conn = post(conn, ~p"/auth/#{provider}/login")
    assert html_response(conn, 200) =~ "ABCD-1234"
    conn
  end

  defp finish(conn, provider \\ "hex"), do: post(recycle(conn), ~p"/auth/#{provider}/login/complete")

  test "login page offers both providers", %{conn: conn} do
    body = conn |> get(~p"/login") |> html_response(200)
    assert body =~ "Sign in with Hex.pm"
    assert body =~ "Sign in with GitHub"
  end

  test "an unknown provider is a 404", %{conn: conn} do
    assert_error_sent 404, fn -> post(conn, "/auth/gitlab/login") end
  end

  test "a linked Hex.pm account signs in", %{conn: conn} do
    {:ok, user} = Identities.link(user_fixture(), hex("frank"))
    approve(hex("frank"))

    conn = conn |> start_login() |> finish()

    assert get_session(conn, :user_id) == user.id
    assert get_session(conn, :login_method) == :hex
    assert redirected_to(conn) == ~p"/request-scan"
  end

  test "still pending re-renders the code with a check-again button", %{conn: conn} do
    conn = conn |> start_login() |> finish()
    body = html_response(conn, 200)
    assert body =~ "ABCD-1234"
    assert body =~ "Check again"
    refute get_session(conn, :user_id)
  end

  test "denied or expired shows a message and creates nothing", %{conn: conn} do
    Process.put(:fake_provider_verify, {:error, :access_denied})
    conn = conn |> start_login() |> finish()
    assert redirected_to(conn) == ~p"/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "denied"
    assert {:ok, nil} = Identities.find_user(hex("anyone"))
    refute get_session(conn, :user_id)
  end

  test "provider down at start shows a message", %{conn: conn} do
    Process.put(:fake_provider_start, {:error, :hex_oauth_unavailable})
    conn = post(conn, ~p"/auth/hex/login")
    assert redirected_to(conn) == ~p"/login"
  end

  test "complete without a started flow goes back to login", %{conn: conn} do
    conn = post(conn, ~p"/auth/hex/login/complete")
    assert redirected_to(conn) == ~p"/login"
  end

  test "a first sign-in with a free name creates the account and signs in", %{conn: conn} do
    approve(hex("newbie"))
    conn = conn |> start_login() |> finish()
    {:ok, user} = Portal.Accounts.get_user_by_username("newbie")
    assert get_session(conn, :user_id) == user.id
  end

  test "a taken name goes to choose-username, never to the local account", %{conn: conn} do
    local = user_fixture(%{username: "tom"})
    approve(hex("tom"))

    conn = conn |> start_login() |> finish()

    assert redirected_to(conn) == ~p"/auth/choose-username"
    refute get_session(conn, :user_id) == local.id
    refute get_session(conn, :user_id)

    page = conn |> recycle() |> get(~p"/auth/choose-username") |> html_response(200)
    assert page =~ "tom"
    assert page =~ "Already have an account here?"

    conn = post(recycle(conn), ~p"/auth/choose-username", %{"username" => "tom-hex"})
    {:ok, created} = Portal.Accounts.get_user_by_username("tom-hex")
    assert created.hex_username == "tom"
    assert get_session(conn, :user_id) == created.id
    refute get_session(conn, :pending_identity)
  end

  test "the pending identity is single use", %{conn: conn} do
    user_fixture(%{username: "tom"})
    approve(hex("tom"))
    conn = conn |> start_login() |> finish()
    conn = post(recycle(conn), ~p"/auth/choose-username", %{"username" => "tom-one"})

    # Replaying the old cookie: the identity is linked now, so it cannot make a second account.
    conn =
      build_conn()
      |> init_test_session(%{
        pending_identity: Map.put(Identity.to_session(hex("tom")), "at", System.system_time(:second))
      })
      |> post(~p"/auth/choose-username", %{"username" => "tom-two"})

    assert redirected_to(conn) == ~p"/login"
    assert {:ok, nil} = Portal.Accounts.get_user_by_username("tom-two")
  end

  test "a pending identity older than ten minutes is refused", %{conn: conn} do
    stale = Map.put(Identity.to_session(hex("old")), "at", System.system_time(:second) - 601)

    conn =
      conn
      |> init_test_session(%{pending_identity: stale})
      |> post(~p"/auth/choose-username", %{"username" => "old-name"})

    assert redirected_to(conn) == ~p"/login"
    assert {:ok, nil} = Portal.Accounts.get_user_by_username("old-name")
  end

  test "a taken choice re-renders with an error", %{conn: conn} do
    user_fixture(%{username: "tom"})
    approve(hex("tom"))
    conn = conn |> start_login() |> finish()
    conn = post(recycle(conn), ~p"/auth/choose-username", %{"username" => "tom"})
    assert html_response(conn, 200) =~ "taken"
  end

  test "an account with TOTP still owes the second step", %{conn: conn} do
    {:ok, user} = Identities.link(user_fixture(), hex("totp"))
    at = ~U[2026-09-18 12:00:00.000000Z]
    {:ok, %{secret: secret}} = Totp.start_enrolment(user)
    :ok = Totp.confirm(user, NimbleTOTP.verification_code(secret, time: at), at)
    approve(hex("totp"))

    conn = conn |> start_login() |> finish()

    assert redirected_to(conn) == ~p"/login/totp"
    refute get_session(conn, :user_id)
    assert get_session(conn, :pending_user_id) == user.id
  end

  test "an admin signed in with Hex.pm does not get into /admin", %{conn: conn} do
    {:ok, admin} = Identities.link(admin_with_passkey_fixture(), hex("boss"))
    approve(hex("boss"))

    conn = conn |> start_login() |> finish()
    assert get_session(conn, :user_id) == admin.id

    conn = get(recycle(conn), ~p"/admin")
    refute conn.status == 200
  end
end
```

Run: `mix test apps/portal/test/portal_web/controllers/provider_auth_controller_test.exs`
Expected: FAIL — routes missing.

- [ ] **Step 2: Routes**

In the `:browser` scope next to `/login`:

```elixir
    post "/auth/:provider/login", ProviderAuthController, :start_login
    post "/auth/:provider/login/complete", ProviderAuthController, :complete_login
    get "/auth/choose-username", ProviderAuthController, :choose_username
    post "/auth/choose-username", ProviderAuthController, :create_with_username
```

Put these **after** the existing `/auth/hex/start|complete` and `/auth/github/start|complete` routes; the paths differ (`/login` suffix) so there is no clash.

- [ ] **Step 3: Controller**

```elixir
defmodule PortalWeb.ProviderAuthController do
  @moduledoc """
  Hex.pm and GitHub as ways to sign in, link, and confirm it is you.

  All three run the provider's device flow and differ only in what the
  verified identity is used for. The flow's state lives in the session under
  `:provider_flow`, tagged with its purpose, so a code started to link an
  account cannot be completed as a login or the other way round.
  """

  use PortalWeb, :controller

  alias Portal.Accounts.{Identities, Identity, IdentityProvider, Mfa}
  alias PortalWeb.UserAuth

  @pending_ttl_seconds 600

  # --- Sign in ---------------------------------------------------------------

  def start_login(conn, %{"provider" => provider}) do
    with_provider(conn, provider, &start_flow(conn, &1, "login", ~p"/login"))
  end

  def complete_login(conn, %{"provider" => provider}) do
    with_provider(conn, provider, fn provider ->
      case verify_flow(conn, provider, "login", ~p"/login") do
        {:ok, identity, conn} -> sign_in(conn, identity)
        {:render, conn} -> conn
      end
    end)
  end

  defp sign_in(conn, identity) do
    case Identities.sign_in(identity) do
      {:ok, user} ->
        finish_login(conn, user, identity.provider)

      {:error, :choose_username} ->
        conn
        |> put_session(:pending_identity, Map.put(Identity.to_session(identity), "at", now()))
        |> redirect(to: ~p"/auth/choose-username")

      {:error, _} ->
        conn
        |> put_flash(:error, "Signing in failed. Try again.")
        |> redirect(to: ~p"/login")
    end
  end

  # Same fork as the password sign-in in `PageController.create_session/2`.
  defp finish_login(conn, user, method) do
    if Mfa.second_factor_required?(user) do
      conn
      |> UserAuth.start_pending(user)
      |> redirect(to: ~p"/login/totp")
    else
      conn
      |> UserAuth.complete_login(user, method)
      |> put_flash(:info, "Signed in.")
      |> redirect(to: UserAuth.landing_path(user, method))
    end
  end

  # --- Choose a username -----------------------------------------------------

  def choose_username(conn, _params) do
    case pending_identity(conn) do
      {:ok, identity} -> render_choose(conn, identity, identity.username)
      :error -> expired(conn)
    end
  end

  def create_with_username(conn, %{"username" => username}) do
    case pending_identity(conn) do
      {:ok, identity} ->
        case Identities.create_with_username(identity, username) do
          {:ok, user} ->
            conn
            |> delete_session(:pending_identity)
            |> finish_login(user, identity.provider)

          {:error, :identity_taken} ->
            conn |> delete_session(:pending_identity) |> expired()

          {:error, reason} ->
            conn
            |> put_flash(:error, username_error(reason))
            |> render_choose(identity, username)
        end

      :error ->
        expired(conn)
    end
  end

  def create_with_username(conn, _params), do: create_with_username(conn, %{"username" => ""})

  defp pending_identity(conn) do
    with %{"at" => at} = stored when is_integer(at) <- get_session(conn, :pending_identity),
         true <- now() - at in 0..@pending_ttl_seconds,
         {:ok, identity} <- Identity.from_session(stored) do
      {:ok, identity}
    else
      _ -> :error
    end
  end

  defp render_choose(conn, identity, username) do
    render(conn, :choose_username,
      page_title: "Choose a username",
      current_user: nil,
      provider_label: provider_label(identity.provider),
      suggested: identity.username,
      username: username
    )
  end

  defp expired(conn) do
    conn
    |> delete_session(:pending_identity)
    |> put_flash(:error, "That sign-in expired. Start again.")
    |> redirect(to: ~p"/login")
  end

  defp username_error(:username_taken), do: "That username is taken. Pick another."
  defp username_error(:invalid_username),
    do: "Use 3 to 40 letters, digits, dots, dashes or underscores."

  # --- Device flow, shared by every purpose ----------------------------------

  defp with_provider(conn, provider, fun) do
    case parse_provider(provider) do
      {:ok, provider} -> fun.(provider)
      :error -> conn |> put_status(:not_found) |> put_view(PortalWeb.ErrorHTML) |> render(:"404") |> halt()
    end
  end

  defp parse_provider("hex"), do: {:ok, :hex}
  defp parse_provider("github"), do: {:ok, :github}
  defp parse_provider(_), do: :error

  defp start_flow(conn, provider, purpose, back) do
    case IdentityProvider.module(provider).start_device_flow() do
      {:ok, flow} ->
        flow = %{
          "provider" => Atom.to_string(provider),
          "purpose" => purpose,
          "device_code" => flow.device_code,
          "user_code" => flow.user_code,
          "verification_uri" => flow.verification_uri,
          "verification_uri_complete" => Map.get(flow, :verification_uri_complete)
        }

        conn
        |> put_session(:provider_flow, flow)
        |> render_device(flow, polling?: false)

      {:error, _} ->
        conn
        |> put_flash(:error, "#{provider_label(provider)} is not reachable right now. Try again later.")
        |> redirect(to: back)
    end
  end

  defp verify_flow(conn, provider, purpose, back) do
    provider_name = Atom.to_string(provider)

    case get_session(conn, :provider_flow) do
      %{"provider" => ^provider_name, "purpose" => ^purpose, "device_code" => code} = flow ->
        case IdentityProvider.module(provider).verify_device(code) do
          {:ok, identity} ->
            {:ok, identity, delete_session(conn, :provider_flow)}

          {:pending, _} ->
            {:render, render_device(conn, flow, polling?: true)}

          {:error, reason} ->
            {:render,
             conn
             |> delete_session(:provider_flow)
             |> put_flash(:error, flow_error(provider, reason))
             |> redirect(to: back)}
        end

      _ ->
        {:render, conn |> put_flash(:error, "Start again.") |> redirect(to: back)}
    end
  end

  defp render_device(conn, flow, opts) do
    provider = if flow["provider"] == "github", do: :github, else: :hex

    render(conn, :device,
      page_title: "Confirm with #{provider_label(provider)}",
      current_user: conn.assigns[:current_user],
      provider_label: provider_label(provider),
      flow: flow,
      complete_path: complete_path(flow["provider"], flow["purpose"]),
      polling?: Keyword.fetch!(opts, :polling?)
    )
  end

  defp complete_path(provider, "login"), do: ~p"/auth/#{provider}/login/complete"

  defp flow_error(provider, :access_denied), do: "You denied the request at #{provider_label(provider)}."
  defp flow_error(_provider, :expired_token), do: "The code expired. Start again."
  defp flow_error(provider, _), do: "#{provider_label(provider)} is not reachable right now. Try again later."

  defp provider_label(:hex), do: "Hex.pm"
  defp provider_label(:github), do: "GitHub"

  defp now, do: System.system_time(:second)
end
```

Notes for the implementer:
- `conn.assigns[:current_user]` is nil on the public `:browser` scope; that is fine for the layout.
- Check how the existing 404 is raised in this app (e.g. `PortalWeb.ErrorHTML` + `Phoenix.Router.NoRouteError` vs `render(:"404")`). If a cleaner existing pattern exists (raise `Ecto.NoResultsError` / a custom `NotFound` exception with `plug_status: 404`), use it; `assert_error_sent 404` passes either way.
- `render(:"404")` with a literal atom is fine for Sobelow (no interpolation).
- If a pending choose-username exists and `complete_login` succeeds for an unrelated identity, `finish_login` does not clear `:pending_identity` — call `delete_session(conn, :pending_identity)` inside `finish_login/3` so a later stray submit cannot use it.

`provider_auth_html.ex`:

```elixir
defmodule PortalWeb.ProviderAuthHTML do
  use PortalWeb, :html

  embed_templates "provider_auth_html/*"
end
```

- [ ] **Step 4: Templates**

`device.html.heex` — same page chrome as `login.html.heex` (flash group, `<main>`, `site_nav`, narrow container, `page_header`):

```heex
<Layouts.flash_group flash={@flash} />

<main class="min-h-screen bg-base-100 text-base-content">
  <.site_nav current_user={@current_user} />

  <div class="mx-auto max-w-md px-4 py-10 sm:px-6 lg:px-8">
    <section class="space-y-8">
      <PortalWeb.UI.page_header kicker="Account" title={"Confirm with #{@provider_label}"}>
        <:subtitle>
          Open {@provider_label}, enter the code below and approve. Then come back here.
        </:subtitle>
      </PortalWeb.UI.page_header>

      <section id="provider-flow" class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body gap-6">
          <p class="text-center font-mono text-3xl font-semibold tracking-widest" id="device-user-code">
            {@flow["user_code"]}
          </p>

          <a
            href={@flow["verification_uri_complete"] || @flow["verification_uri"]}
            target="_blank"
            rel="noopener noreferrer"
            class="btn btn-outline w-full"
          >
            <.icon name="hero-arrow-top-right-on-square-mini" class="size-5" /> Open {@provider_label}
          </a>

          <p :if={@polling?} class="text-sm text-base-content/70">
            Not approved yet. Approve it on {@provider_label}, then check again.
          </p>

          <form method="post" action={@complete_path}>
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <button type="submit" class="btn btn-primary w-full">
              {if @polling?, do: "Check again", else: "I approved it"}
            </button>
          </form>
        </div>
      </section>
    </section>
  </div>
</main>
```

`choose_username.html.heex`:

```heex
<Layouts.flash_group flash={@flash} />

<main class="min-h-screen bg-base-100 text-base-content">
  <.site_nav current_user={@current_user} />

  <div class="mx-auto max-w-md px-4 py-10 sm:px-6 lg:px-8">
    <section class="space-y-8">
      <PortalWeb.UI.page_header kicker="Account" title="Choose a username">
        <:subtitle>
          {@provider_label} confirmed you as <span class="font-mono">{@suggested}</span>,
          but that username is already used here. Pick another one for your new account.
        </:subtitle>
      </PortalWeb.UI.page_header>

      <section class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body gap-6">
          <form id="choose-username-form" method="post" action={~p"/auth/choose-username"} class="space-y-4">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <div class="form-control">
              <span class="label"><span class="label-text font-semibold">Username</span></span>
              <input
                id="username"
                name="username"
                value={@username}
                autocomplete="username"
                required
                class="input input-bordered w-full font-mono"
              />
            </div>
            <button type="submit" class="btn btn-primary w-full">Create account</button>
          </form>

          <p class="text-sm leading-6 text-base-content/70">
            Already have an account here? Sign in with it and link {@provider_label} under
            <a href={~p"/settings/security"} class="font-semibold text-primary hover:underline">Settings</a>.
          </p>
        </div>
      </section>
    </section>
  </div>
</main>
```

`login.html.heex`: after the passkey block, before "No account yet?":

```heex
          <div id="provider-login" class="grid gap-2">
            <form method="post" action={~p"/auth/hex/login"}>
              <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
              <button type="submit" class="btn btn-outline w-full">Sign in with Hex.pm</button>
            </form>
            <form method="post" action={~p"/auth/github/login"}>
              <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
              <button type="submit" class="btn btn-outline w-full">Sign in with GitHub</button>
            </form>
          </div>
```

Update the login subtitle: "Use your portal account, Hex.pm or GitHub."

- [ ] **Step 5: Run tests**

Run: `mix test apps/portal/test/portal_web/controllers/provider_auth_controller_test.exs apps/portal/test/portal_web/controllers/mfa_controller_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/portal
git commit -m "feat(auth): sign in with Hex.pm or GitHub"
```

---

### Task 5: Settings — sign-in methods, link/unlink, confirm with provider, set a password

**Files:**
- Modify: `apps/portal/lib/portal_web/controllers/provider_auth_controller.ex`
- Modify: `apps/portal/lib/portal_web/router.ex` (`:authenticated` scope)
- Modify: `apps/portal/lib/portal_web/controllers/security_controller.ex` (`render_page/2` assigns)
- Modify: `apps/portal/lib/portal_web/controllers/security_html/show.html.heex`
- Modify: `apps/portal/lib/portal_web/controllers/page_controller.ex` (`set_password/2`, `render_settings/2` assigns)
- Modify: `apps/portal/lib/portal_web/controllers/page_html/settings.html.heex`
- Test: `apps/portal/test/portal_web/controllers/provider_link_controller_test.exs`

**Interfaces:**
- Consumes: Task 4 private helpers (`with_provider/3`, `start_flow/4`, `verify_flow/4`, `render_device/3`, `provider_label/1`), `Identities.link/2`, `unlink/2`, `matches?/2`, `ways_in/1`, `linked?/2`, `Mfa.reauth_fresh?/4`, `UserAuth.mark_reauth/2`, `Accounts.set_password/2`.
- Produces routes (`:authenticated` scope):
  - `POST /settings/providers/:provider/link` → `:start_link`
  - `POST /settings/providers/:provider/link/complete` → `:complete_link`
  - `POST /settings/providers/:provider/confirm` → `:start_confirm` (step-up)
  - `POST /settings/providers/:provider/confirm/complete` → `:complete_confirm`
  - `POST /settings/providers/:provider/unlink` → `:unlink`
  - `POST /settings/password/set` → `PageController.set_password`
- Produces: `complete_path/2` clauses for `"link"` → `~p"/settings/providers/#{p}/link/complete"` and `"reauth"` → `~p"/settings/providers/#{p}/confirm/complete"`.

- [ ] **Step 1: Failing tests**

```elixir
defmodule PortalWeb.ProviderLinkControllerTest do
  use PortalWeb.ConnCase, async: true

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.{Identities, Identity}

  defp hex(name), do: %Identity{provider: :hex, uid: name, username: name, profile: %{"username" => name}}
  defp approve(identity), do: Process.put(:fake_provider_verify, {:ok, identity})

  defp signed_in(conn, user, opts \\ []) do
    fresh_at = if Keyword.get(opts, :fresh, true), do: System.system_time(:second), else: nil
    method = Keyword.get(opts, :method, :password)

    init_test_session(conn, %{
      user_id: user.id,
      login_method: method,
      reauth_method: method,
      reauth_at: fresh_at
    })
  end

  defp run_flow(conn, start_path, complete_path) do
    conn = post(conn, start_path)
    assert html_response(conn, 200) =~ "ABCD-1234"
    post(recycle(conn), complete_path)
  end

  test "the security page lists sign-in methods", %{conn: conn} do
    body = conn |> signed_in(user_fixture()) |> get(~p"/settings/security") |> html_response(200)
    assert body =~ "Sign-in methods"
    assert body =~ "Link Hex.pm"
    assert body =~ "Link GitHub"
  end

  test "linking Hex.pm with a fresh step-up", %{conn: conn} do
    user = user_fixture()
    approve(hex("mine"))

    conn =
      conn
      |> signed_in(user)
      |> run_flow(~p"/settings/providers/hex/link", ~p"/settings/providers/hex/link/complete")

    assert redirected_to(conn) == ~p"/settings/security"
    {:ok, user} = Portal.Accounts.get_user(user.id)
    assert user.hex_username == "mine"
  end

  test "linking without a fresh step-up is refused before the flow starts", %{conn: conn} do
    conn = conn |> signed_in(user_fixture(), fresh: false) |> post(~p"/settings/providers/hex/link")
    assert redirected_to(conn) == ~p"/settings/security"
    refute get_session(conn, :provider_flow)
  end

  test "an identity linked to someone else is refused", %{conn: conn} do
    {:ok, _} = Identities.link(user_fixture(), hex("theirs"))
    user = user_fixture()
    approve(hex("theirs"))

    conn =
      conn
      |> signed_in(user)
      |> run_flow(~p"/settings/providers/hex/link", ~p"/settings/providers/hex/link/complete")

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "linked to another"
    {:ok, user} = Portal.Accounts.get_user(user.id)
    assert is_nil(user.hex_username)
  end

  test "a login flow cannot be completed as a link", %{conn: conn} do
    user = user_fixture()
    approve(hex("x"))
    conn = conn |> signed_in(user) |> post(~p"/auth/hex/login")
    conn = post(recycle(conn), ~p"/settings/providers/hex/link/complete")
    assert redirected_to(conn) == ~p"/settings/security"
    {:ok, user} = Portal.Accounts.get_user(user.id)
    assert is_nil(user.hex_username)
  end

  test "unlink while a password remains", %{conn: conn} do
    {:ok, user} = Identities.link(user_fixture(), hex("gone"))
    conn = conn |> signed_in(user) |> post(~p"/settings/providers/hex/unlink")
    assert redirected_to(conn) == ~p"/settings/security"
    {:ok, user} = Portal.Accounts.get_user(user.id)
    assert is_nil(user.hex_username)
  end

  test "unlink refuses to remove the last way in", %{conn: conn} do
    {:ok, user} = Identities.sign_in(hex("only"))
    conn = conn |> signed_in(user, method: :hex) |> post(~p"/settings/providers/hex/unlink")
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "only way"
    {:ok, user} = Portal.Accounts.get_user(user.id)
    assert user.hex_username == "only"
  end

  test "unlink without step-up is refused", %{conn: conn} do
    {:ok, user} = Identities.link(user_fixture(), hex("stay"))
    conn = conn |> signed_in(user, fresh: false) |> post(~p"/settings/providers/hex/unlink")
    {:ok, user} = Portal.Accounts.get_user(user.id)
    assert user.hex_username == "stay"
    assert redirected_to(conn) == ~p"/settings/security"
  end

  test "a provider account confirms with its own provider", %{conn: conn} do
    {:ok, user} = Identities.sign_in(hex("conf"))
    approve(hex("conf"))

    conn =
      conn
      |> signed_in(user, method: :hex, fresh: false)
      |> run_flow(~p"/settings/providers/hex/confirm", ~p"/settings/providers/hex/confirm/complete")

    assert get_session(conn, :reauth_method) == :hex
    assert is_integer(get_session(conn, :reauth_at))
  end

  test "confirming with a different Hex.pm account is refused", %{conn: conn} do
    {:ok, user} = Identities.sign_in(hex("victim"))
    approve(hex("attacker"))

    conn =
      conn
      |> signed_in(user, method: :hex, fresh: false)
      |> run_flow(~p"/settings/providers/hex/confirm", ~p"/settings/providers/hex/confirm/complete")

    refute get_session(conn, :reauth_at)
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not the"
  end

  test "a provider account sets a password after step-up", %{conn: conn} do
    {:ok, user} = Identities.sign_in(hex("pw"))

    conn =
      conn
      |> signed_in(user, method: :hex)
      |> post(~p"/settings/password/set", %{"new_password" => "a long enough password"})

    assert redirected_to(conn) == ~p"/settings"
    {:ok, user} = Portal.Accounts.get_user(user.id)
    assert user.password_set
  end

  test "setting a password without step-up is refused", %{conn: conn} do
    {:ok, user} = Identities.sign_in(hex("pw2"))

    conn
    |> signed_in(user, method: :hex, fresh: false)
    |> post(~p"/settings/password/set", %{"new_password" => "a long enough password"})

    {:ok, user} = Portal.Accounts.get_user(user.id)
    refute user.password_set
  end

  test "an account that has a password cannot use set-password to skip the current one", %{conn: conn} do
    user = user_fixture()
    conn = conn |> signed_in(user) |> post(~p"/settings/password/set", %{"new_password" => "another long password"})
    assert redirected_to(conn) == ~p"/settings"
    assert {:error, _} = Portal.Accounts.authenticate_user(user.username, "another long password")
  end

  test "settings shows Set a password for a provider account", %{conn: conn} do
    {:ok, user} = Identities.sign_in(hex("pw3"))
    body = conn |> signed_in(user, method: :hex) |> get(~p"/settings") |> html_response(200)
    assert body =~ "Set a password"
    refute body =~ "Current password"
  end
end
```

Run: `mix test apps/portal/test/portal_web/controllers/provider_link_controller_test.exs`
Expected: FAIL — routes missing.

- [ ] **Step 2: Routes** in the `:authenticated` scope:

```elixir
    post "/settings/password/set", PageController, :set_password
    post "/settings/providers/:provider/link", ProviderAuthController, :start_link
    post "/settings/providers/:provider/link/complete", ProviderAuthController, :complete_link
    post "/settings/providers/:provider/confirm", ProviderAuthController, :start_confirm
    post "/settings/providers/:provider/confirm/complete", ProviderAuthController, :complete_confirm
    post "/settings/providers/:provider/unlink", ProviderAuthController, :unlink
```

- [ ] **Step 3: Controller actions** (append to `ProviderAuthController`):

```elixir
  # --- Link, unlink, confirm (signed in) -------------------------------------

  defp security, do: ~p"/settings/security"

  def start_link(conn, %{"provider" => provider}) do
    with_provider(conn, provider, fn provider ->
      with_step_up(conn, fn -> start_flow(conn, provider, "link", security()) end)
    end)
  end

  def complete_link(conn, %{"provider" => provider}) do
    with_provider(conn, provider, fn provider ->
      with_step_up(conn, fn ->
        case verify_flow(conn, provider, "link", security()) do
          {:ok, identity, conn} -> link(conn, identity)
          {:render, conn} -> conn
        end
      end)
    end)
  end

  defp link(conn, identity) do
    label = provider_label(identity.provider)

    message =
      case Identities.link(conn.assigns.current_user, identity) do
        {:ok, _} -> {:info, "#{label} linked. You can sign in with it now."}
        {:error, :linked_elsewhere} -> {:error, "This #{label} account is linked to another user."}
        {:error, :provider_already_linked} -> {:error, "Unlink your current #{label} account first."}
        {:error, _} -> {:error, "Linking #{label} failed. Try again."}
      end

    {kind, text} = message
    conn |> put_flash(kind, text) |> redirect(to: security())
  end

  def unlink(conn, %{"provider" => provider}) do
    with_provider(conn, provider, fn provider ->
      with_step_up(conn, fn ->
        label = provider_label(provider)

        {kind, text} =
          case Identities.unlink(conn.assigns.current_user, provider) do
            {:ok, _} -> {:info, "#{label} unlinked."}
            {:error, :last_way_in} -> {:error, "#{label} is your only way to sign in. Set a password or add a passkey first."}
            {:error, :not_linked} -> {:error, "#{label} is not linked."}
            {:error, _} -> {:error, "Unlinking #{label} failed. Try again."}
          end

        conn |> put_flash(kind, text) |> redirect(to: security())
      end)
    end)
  end

  # Step-up for accounts with no passkey or TOTP: prove it again with the
  # provider that is linked. The identity must be *the* linked one -- anyone
  # can approve a device code with an account of their own.
  def start_confirm(conn, %{"provider" => provider}) do
    with_provider(conn, provider, fn provider ->
      if provider in Mfa.accepted_reauth_methods(conn.assigns.current_user) do
        start_flow(conn, provider, "reauth", security())
      else
        conn |> put_flash(:error, "Confirm another way.") |> redirect(to: security())
      end
    end)
  end

  def complete_confirm(conn, %{"provider" => provider}) do
    with_provider(conn, provider, fn provider ->
      user = conn.assigns.current_user

      case verify_flow(conn, provider, "reauth", security()) do
        {:ok, identity, conn} ->
          if provider in Mfa.accepted_reauth_methods(user) and Identities.matches?(user, identity) do
            conn
            |> UserAuth.mark_reauth(provider)
            |> put_flash(:info, "Confirmed. You have #{div(Mfa.reauth_window_seconds(), 60)} minutes to make changes.")
            |> redirect(to: security())
          else
            conn
            |> put_flash(:error, "That is not the #{provider_label(provider)} account linked here.")
            |> redirect(to: security())
          end

        {:render, conn} ->
          conn
      end
    end)
  end

  defp with_step_up(conn, fun) do
    user = conn.assigns.current_user

    if Mfa.reauth_fresh?(user, UserAuth.reauth_method(conn), UserAuth.reauth_at(conn)) do
      fun.()
    else
      conn
      |> put_flash(:error, "Confirm it is you first.")
      |> redirect(to: security())
    end
  end
```

Extend `complete_path/2`:

```elixir
  defp complete_path(provider, "link"), do: ~p"/settings/providers/#{provider}/link/complete"
  defp complete_path(provider, "reauth"), do: ~p"/settings/providers/#{provider}/confirm/complete"
```

`with_provider/3`'s fun returns a conn in all clauses; keep `with_step_up/2` returning the fun's conn.

- [ ] **Step 4: Security page**

`SecurityController.render_page/2` adds:

```elixir
      ways_in: Identities.ways_in(user),
      hex_linked: Identities.linked?(user, :hex),
      github_linked: Identities.linked?(user, :github),
```

(alias `Portal.Accounts.Identities`).

In `show.html.heex`, inside the "Confirm it is you" card, after the existing forms:

```heex
          <form
            :for={provider <- Enum.filter(@accepted_methods, &(&1 in [:hex, :github]))}
            method="post"
            action={~p"/settings/providers/#{provider}/confirm"}
          >
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <button type="submit" class="btn btn-outline w-full">
              Confirm with {if provider == :hex, do: "Hex.pm", else: "GitHub"}
            </button>
          </form>
```

New card, placed before "Passkeys":

```heex
      <section id="sign-in-methods" class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body gap-4">
          <h2 class="text-lg font-semibold tracking-tight">Sign-in methods</h2>

          <div class="flex items-center justify-between gap-3">
            <span>Password</span>
            <span class="text-sm text-base-content/70">
              {if @current_user.password_set, do: "Set", else: "Not set"}
            </span>
          </div>

          <div
            :for={{provider, label, linked, name} <- [
              {:hex, "Hex.pm", @hex_linked, @current_user.hex_username},
              {:github, "GitHub", @github_linked, @current_user.github_username}
            ]}
            id={"sign-in-#{provider}"}
            class="flex items-center justify-between gap-3"
          >
            <span>
              {label}
              <span :if={linked} class="font-mono text-sm text-base-content/70">{name}</span>
            </span>
            <form :if={@reauth_fresh} method="post" action={
              if linked,
                do: ~p"/settings/providers/#{provider}/unlink",
                else: ~p"/settings/providers/#{provider}/link"
            }>
              <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
              <button
                type="submit"
                class="btn btn-sm btn-outline whitespace-nowrap"
                disabled={linked and @ways_in -- [provider] == []}
              >
                {if linked, do: "Unlink #{label}", else: "Link #{label}"}
              </button>
            </form>
            <span :if={not @reauth_fresh} class="text-sm text-base-content/60">
              {if linked, do: "Linked", else: "Not linked"}
            </span>
          </div>
        </div>
      </section>
```

The test "the security page lists sign-in methods" uses a fresh step-up, so the "Link …" buttons render.

- [ ] **Step 5: Set a password on `/settings`**

`PageController`:

```elixir
  def set_password(conn, params) do
    user = settings_user(conn)

    cond do
      user.password_set ->
        conn
        |> put_flash(:error, "Change your password with your current one.")
        |> redirect(to: ~p"/settings")

      not Portal.Accounts.Mfa.reauth_fresh?(
        user,
        PortalWeb.UserAuth.reauth_method(conn),
        PortalWeb.UserAuth.reauth_at(conn)
      ) ->
        conn
        |> put_flash(:error, "Confirm it is you first.")
        |> redirect(to: ~p"/settings/security")

      true ->
        case Portal.Accounts.set_password(user, string_param(params, "new_password")) do
          {:ok, _} ->
            conn |> put_flash(:info, "Password set.") |> redirect(to: ~p"/settings")

          {:error, :invalid_password} ->
            conn
            |> put_flash(:error, "Use at least 12 characters.")
            |> redirect(to: ~p"/settings")
        end
    end
  end
```

`settings.html.heex`: wrap the existing "Change password" card in `:if={@current_user.password_set}` and add:

```heex
      <section
        :if={not @current_user.password_set}
        id="set-password"
        class="card border border-base-300 bg-base-100 shadow-sm"
      >
        <div class="card-body gap-6">
          <div class="space-y-1">
            <h2 class="text-lg font-semibold tracking-tight">Set a password</h2>
            <p class="text-sm leading-6 text-base-content/70">
              You sign in with Hex.pm or GitHub. A password gives you another way in.
              You may be asked to confirm it is you first.
            </p>
          </div>

          <form id="set-password-form" method="post" action={~p"/settings/password/set"} class="space-y-4">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <div class="form-control">
              <span class="label"><span class="label-text font-semibold">New password</span></span>
              <input
                id="set_new_password"
                name="new_password"
                type="password"
                autocomplete="new-password"
                minlength="12"
                required
                class="input input-bordered w-full"
              />
              <span class="label">
                <span class="label-text-alt text-base-content/60">At least 12 characters.</span>
              </span>
            </div>
            <button type="submit" class="btn btn-primary w-full">
              <.icon name="hero-key-mini" class="size-5" /> Set password
            </button>
          </form>
        </div>
      </section>
```

Also check `apply_settings_changes/2` / `maybe_change_password/3`: for a `password_set: false` account the old form is hidden, so nothing else changes.

- [ ] **Step 6: Run tests**

Run: `mix test apps/portal/test/portal_web/controllers/`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add apps/portal
git commit -m "feat(settings): link and unlink Hex.pm and GitHub, set a password"
```

---

### Task 6: `/admin/users` shows whether a password is set

**Files:**
- Modify: `apps/portal/lib/portal_web/controllers/page_html/admin_users.html.heex`
- Test: `apps/portal/test/portal_web/controllers/admin_sections_test.exs` (or the existing users-page test file)

- [ ] **Step 1: Failing test**

```elixir
  test "the users table says whether a password is set", %{conn: conn} do
    {:ok, _} = Portal.Accounts.Identities.sign_in(
      %Portal.Accounts.Identity{provider: :hex, uid: "nopw", username: "nopw", profile: %{}}
    )

    body = conn |> admin_session() |> get(~p"/admin/users") |> html_response(200)
    assert body =~ ~r/id="user-row-[^"]+"[\s\S]*nopw[\s\S]*No password/
  end
```

Use whatever admin-session helper `admin_sections_test.exs` already uses (look for its setup); if rows have no ids, assert on `"No password"` plus `"nopw"` appearing.

Run: `mix test apps/portal/test/portal_web/controllers/admin_sections_test.exs`
Expected: FAIL — "No password" missing.

- [ ] **Step 2: Implement** — add a "Password" column header and cell `{if user.password_set, do: "Set", else: "No password"}` with `whitespace-nowrap`, matching the table's existing cell classes.

- [ ] **Step 3: Run** the same test. Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add apps/portal
git commit -m "feat(admin): show whether each user has a password"
```

---

### Task 7: Docs, gates, release checks

**Files:**
- Modify: `docs/superpowers/specs/2026-10-06-linked-logins-design.md` (status line → "implemented"; note that the second step follows `Mfa.second_factor_required?/1`, i.e. TOTP; a passkey alone does not add a step, same as password sign-in)
- Modify: `CLAUDE.md` "Public Routes" (add `/auth/:provider/login`, `/auth/choose-username`, `/settings/providers/...`)

- [ ] **Step 1:** Update docs as above.
- [ ] **Step 2:** Run the gates script. Expected: all green.
- [ ] **Step 3:** Commit `docs: linked logins`.
- [ ] **Step 4 (release, before merge to main):** Run Task 1 Step 6's queries against prod (read-only) and show the results to the user. Expected: no duplicate `hex_username`, every link plausibly the same person, and the list of accounts that will get `password_set = false`. Do not merge if a link looks wrong; ask the user.
