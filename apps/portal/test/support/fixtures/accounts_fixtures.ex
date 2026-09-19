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

  @doc """
  An admin who can actually reach `/admin`.

  `PortalWeb.Plugs.RequireAdmin` turns a passkey-less admin away, so a test
  that wants to exercise an admin page rather than the gate needs one of
  these. The row is a stub: enough for `Mfa.admin_satisfied?/1` to count it,
  not enough to sign an assertion with.
  """
  def admin_with_passkey_fixture(attrs \\ %{}) do
    attrs |> admin_fixture() |> add_test_passkey()
  end

  @doc """
  Hangs a stub passkey off an existing user and returns the user.
  """
  def add_test_passkey(user) do
    {:ok, _} =
      Portal.Accounts.Passkeys.create(user, %{
        credential_id: :crypto.strong_rand_bytes(16),
        public_key: :erlang.term_to_binary(%{3 => -7}),
        nickname: "test key"
      })

    user
  end
end
