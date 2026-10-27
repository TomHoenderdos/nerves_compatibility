defmodule Portal.Accounts.GetUserTest do
  @moduledoc """
  `Portal.Accounts.get_user/1` runs on every signed-in request, LiveView mount
  and admin click (`Portal.Accounts.session_user/2`), with an id read from the
  session. It must be one lookup by primary key, and an id that is not a UUID
  -- tampered, or from some older cookie -- is nobody rather than a crash.
  """
  use Portal.DataCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts

  test "a known id is that user" do
    user = user_fixture()
    assert {:ok, %Accounts.User{id: id}} = Accounts.get_user(user.id)
    assert id == user.id
  end

  test "an unknown id is nobody" do
    assert Accounts.get_user(Ecto.UUID.generate()) == {:ok, nil}
  end

  test "an id that is not a UUID is nobody, not an error" do
    assert Accounts.get_user("not-a-uuid") == {:ok, nil}
    assert Accounts.get_user("") == {:ok, nil}
    assert Accounts.get_user("'; drop table portal_users; --") == {:ok, nil}
  end

  test "a lookup is one query, bounded by the id" do
    user = user_fixture()
    user_fixture()
    handler = "get-user-query-count-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        [:portal, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:query, metadata.query})
        end,
        nil
      )

    try do
      assert {:ok, %Accounts.User{}} = Accounts.get_user(user.id)
    after
      :telemetry.detach(handler)
    end

    assert_received {:query, sql}
    refute_received {:query, _another}
    assert sql =~ ~s("portal_users")
    assert sql =~ "WHERE"
  end
end
