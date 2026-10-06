defmodule Portal.Accounts.ChangeUsernameTest do
  use Portal.DataCase, async: true

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts

  test "a rename cannot take another account's name in a different case" do
    # A legacy provider account stored its login verbatim.
    user_fixture(%{username: "TomHoenderdos"})
    user = user_fixture()

    assert {:error, :username_taken} = Accounts.change_username(user, "tomhoenderdos")
  end

  test "a user may change the case of their own name" do
    user = user_fixture(%{username: "Tom-Case"})

    assert {:ok, renamed} = Accounts.change_username(user, "tom-case")
    assert renamed.username == "tom-case"
  end

  test "an invalid name is refused" do
    assert {:error, :invalid_username} = Accounts.change_username(user_fixture(), "x")
  end
end
