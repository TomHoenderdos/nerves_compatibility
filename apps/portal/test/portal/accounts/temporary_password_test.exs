defmodule Portal.Accounts.TemporaryPasswordTest do
  use Portal.DataCase, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Portal.{Accounts, Admin}

  @pw "correct horse battery staple"

  defp admin(name) do
    {:ok, user} = Accounts.seed_admin_user(name, @pw)
    Portal.Test.AccountsFixtures.add_test_passkey(user)
  end

  test "an admin resets a user's password to a one-time temporary one" do
    actor = admin("tp_actor")
    {:ok, _} = Accounts.register_user("tp_frank", @pw)

    {{:ok, user, temp}, log} = with_log(fn -> Admin.reset_password("tp_frank", actor) end)

    assert byte_size(temp) >= 16
    assert user.password_reset_required
    assert {:ok, _} = Accounts.authenticate_user("tp_frank", temp)
    assert {:error, :invalid_credentials} = Accounts.authenticate_user("tp_frank", @pw)
    assert log =~ "tp_frank"
    assert log =~ "tp_actor"
    refute log =~ temp
  end

  test "each reset produces a different password" do
    actor = admin("tp_actor")
    {:ok, _} = Accounts.register_user("tp_frank", @pw)

    {:ok, _, first} = Admin.reset_password("tp_frank", actor)
    {:ok, _, second} = Admin.reset_password("tp_frank", actor)
    refute first == second
  end

  test "changing the password clears the reset requirement" do
    actor = admin("tp_actor")
    {:ok, _} = Accounts.register_user("tp_frank", @pw)
    {:ok, user, temp} = Admin.reset_password("tp_frank", actor)

    assert {:ok, changed} = Accounts.change_password(user, temp, "a brand new passphrase")
    refute changed.password_reset_required
  end

  test "refuses unknown and blank usernames" do
    actor = admin("tp_actor")
    assert {:error, :unknown_user} = Admin.reset_password("tp_nobody", actor)
    assert {:error, :blank_username} = Admin.reset_password(" ", actor)
  end

  test "refuses resetting your own password, which settings already does" do
    actor = admin("tp_actor")
    assert {:error, :own_password} = Admin.reset_password("tp_actor", actor)
  end
end
