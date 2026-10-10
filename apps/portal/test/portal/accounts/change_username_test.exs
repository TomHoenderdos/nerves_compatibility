defmodule Portal.Accounts.ChangeUsernameTest do
  use Portal.DataCase, async: true

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts

  test "a rename cannot take another account's name in a different case" do
    # A legacy provider account stored its login verbatim.
    user_fixture(%{username: "JaneDoe"})
    user = user_fixture()

    assert {:error, :username_taken} = Accounts.change_username(user, "janedoe")
  end

  test "a user may change the case of their own name" do
    user = user_fixture(%{username: "Alice-Case"})

    assert {:ok, renamed} = Accounts.change_username(user, "alice-case")
    assert renamed.username == "alice-case"
  end

  test "an invalid name is refused" do
    assert {:error, :invalid_username} = Accounts.change_username(user_fixture(), "x")
  end
end
