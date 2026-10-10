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
    {:ok, _} = set_links(user_fixture(), %{hex_username: "alice"})
    assert {:error, _} = set_links(user_fixture(), %{hex_username: "alice"})
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

    assert {:ok, %Identity{provider: :github, uid: 42, username: "octo"}} =
             Identity.from_session(session)
  end

  test "a tampered or foreign session value is not an identity" do
    assert :error =
             Identity.from_session(%{"provider" => "gitlab", "uid" => 1, "username" => "x"})

    assert :error = Identity.from_session(nil)
  end
end
