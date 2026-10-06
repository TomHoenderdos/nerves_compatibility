defmodule Portal.Accounts.SetPasswordTest do
  use Portal.DataCase, async: true

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts
  alias Portal.Accounts.{Identities, Identity}

  test "an account without a password gets one" do
    {:ok, user} =
      Identities.sign_in(%Identity{
        provider: :hex,
        uid: "setpw",
        username: "setpw",
        profile: %{"username" => "setpw"}
      })

    refute user.password_set
    assert {:ok, user} = Accounts.set_password(user, "a long enough password")
    assert user.password_set
    assert {:ok, _} = Accounts.authenticate_user("setpw", "a long enough password")
  end

  test "an account that already has a password is refused" do
    user = user_fixture()

    assert {:error, :password_already_set} =
             Accounts.set_password(user, "another long password")

    assert {:error, _} = Accounts.authenticate_user(user.username, "another long password")
  end
end
