defmodule Portal.AdminRolesTest do
  use Portal.DataCase, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Portal.Admin

  @pw "correct horse battery staple"

  defp admin(name) do
    {:ok, user} = Portal.Accounts.seed_admin_user(name, @pw)
    Portal.Test.AccountsFixtures.add_test_passkey(user)
  end

  defp user(name) do
    {:ok, user} = Portal.Accounts.register_user(name, @pw)
    user
  end

  describe "grant_admin/2" do
    test "makes an existing user an admin and logs who did it" do
      actor = admin("roles_actor")
      user("roles_frank")

      {{:ok, granted}, log} = with_log(fn -> Admin.grant_admin("roles_frank", actor) end)

      assert Portal.Accounts.admin?(granted)
      assert log =~ "roles_frank"
      assert log =~ "roles_actor"
    end

    test "is idempotent for someone who already is an admin" do
      actor = admin("roles_actor")
      admin("roles_other")
      assert {:ok, user} = Admin.grant_admin("roles_other", actor)
      assert Portal.Accounts.admin?(user)
    end

    test "refuses an unknown username instead of creating an account" do
      actor = admin("roles_actor")
      assert {:error, :unknown_user} = Admin.grant_admin("roles_nobody", actor)
      assert {:ok, nil} = Portal.Accounts.get_user_by_username("roles_nobody")
    end

    test "refuses a blank username" do
      assert {:error, :blank_username} = Admin.grant_admin("  ", admin("roles_actor"))
    end
  end

  describe "revoke_admin/2" do
    test "removes admin from another admin and logs who did it" do
      actor = admin("roles_actor")
      other = admin("roles_other")

      {{:ok, revoked}, log} = with_log(fn -> Admin.revoke_admin(other.id, actor) end)

      refute Portal.Accounts.admin?(revoked)
      assert log =~ "roles_other"
    end

    test "refuses to revoke yourself" do
      actor = admin("roles_actor")
      admin("roles_other")
      assert {:error, :self} = Admin.revoke_admin(actor.id, actor)
    end

    test "refuses to revoke the last admin" do
      actor = admin("roles_actor")
      other = admin("roles_other")
      {:ok, _} = Admin.revoke_admin(other.id, actor)

      # `actor` is now the only admin; revoking them is both self and last,
      # so check last-admin through a user who is not an admin themself.
      assert {:error, :last_admin} = Admin.revoke_admin(actor.id, other)
    end

    test "refuses a user who is not an admin" do
      actor = admin("roles_actor")
      plain = user("roles_plain")
      assert {:error, :not_admin} = Admin.revoke_admin(plain.id, actor)
    end

    test "refuses an unknown id" do
      assert {:error, :unknown_user} =
               Admin.revoke_admin(Ecto.UUID.generate(), admin("roles_actor"))
    end
  end

  test "list_admins/0 says who still needs a passkey" do
    admin("roles_ready")
    {:ok, _} = Portal.Accounts.seed_admin_user("roles_unready", @pw)

    admins = Map.new(Admin.list_admins(), &{&1.username, &1.passkey?})
    assert admins["roles_ready"] == true
    assert admins["roles_unready"] == false
  end
end
