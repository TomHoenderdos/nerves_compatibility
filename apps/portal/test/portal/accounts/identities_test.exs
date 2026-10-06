defmodule Portal.Accounts.IdentitiesTest do
  use Portal.DataCase, async: true

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.{Identities, Identity, Mfa}

  defp hex(name),
    do: %Identity{provider: :hex, uid: name, username: name, profile: %{"username" => name}}

  defp github(id, login),
    do: %Identity{
      provider: :github,
      uid: id,
      username: login,
      profile: %{"id" => id, "login" => login}
    }

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
      {:ok, old} = Identities.link(user_fixture(), github(7, "taken"))
      assert {:ok, new} = Identities.sign_in(github(8, "taken"))
      refute new.id == old.id
      # The old account's own login stays untouched -- the fresh local
      # username "taken" belongs only to the new account.
      {:ok, reloaded_old} = Portal.Accounts.get_user(old.id)
      assert reloaded_old.github_id == 7
      assert reloaded_old.github_username == "taken"
    end

    test "a provider name the local rules reject goes to choose-username" do
      assert {:error, :choose_username} = Identities.sign_in(github(9, "ab"))
    end

    test "a mixed-case GitHub login becomes a lower-case local name" do
      assert {:ok, user} = Identities.sign_in(github(10, "OctoCat"))
      assert user.username == "octocat"
      assert user.github_username == "OctoCat"
    end

    # The controller ruling this task also closes: legacy accounts created by
    # the old provider flows stored the login verbatim ("TomHoenderdos"), so
    # username lookup has to be case-insensitive or a new "tomhoenderdos"
    # identity would think the name is free and create a twin account.
    test "a legacy mixed-case local username blocks a lower-case identity sign-in" do
      user_fixture(%{username: "MixedCase"})
      assert {:error, :choose_username} = Identities.sign_in(hex("mixedcase"))
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
    test "signed in: the request is the current user's and nothing is linked" do
      user = user_fixture()
      assert {:ok, same} = Identities.for_scan_request(hex("owner"), user)
      assert same.id == user.id
      refute same.hex_username
      assert {:ok, nil} = Identities.find_user(hex("owner"))
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
      {:ok, user} = Identities.sign_in(hex("prov"))
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
      {:ok, user} = Identities.sign_in(hex("setter"))
      assert {:ok, user} = Portal.Accounts.set_password(user, "a long enough password")
      assert user.password_set
      assert {:ok, _} = Portal.Accounts.authenticate_user("setter", "a long enough password")
    end

    test "refuses a short one" do
      {:ok, user} = Identities.sign_in(hex("short"))
      assert {:error, :invalid_password} = Portal.Accounts.set_password(user, "short")
    end
  end
end
