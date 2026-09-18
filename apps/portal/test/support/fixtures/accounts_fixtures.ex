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
