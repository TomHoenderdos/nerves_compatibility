defmodule Portal.Accounts.UserTest do
  use Portal.DataCase, async: false

  alias Portal.Accounts.User

  test "records Hex identity metadata with an Argon2 password hash and without tokens" do
    password = "generated-internal-password"

    user =
      User
      |> Ash.Changeset.for_create(:create, %{
        username: "owner",
        hex_username: "owner",
        hex_profile: encode_profile(%{"username" => "owner", "email" => "owner@example.test"}),
        password_hash: Argon2.hash_pwd_salt(password),
        last_hex_login_at: ~U[2026-06-03 12:00:00Z]
      })
      |> Ash.create!(domain: Portal.Accounts)

    assert user.hex_username == "owner"
    assert decode_profile(user.hex_profile)["username"] == "owner"
    assert user.last_hex_login_at == ~U[2026-06-03 12:00:00Z]
    assert Argon2.verify_pass(password, user.password_hash)
    refute user.password_hash == password
    refute Map.has_key?(decode_profile(user.hex_profile), "access_token")
  end

  test "updates Hex profile on later login" do
    user =
      User
      |> Ash.Changeset.for_create(:create, %{
        username: "owner_update",
        hex_username: "owner_update",
        hex_profile: encode_profile(%{"username" => "owner_update"}),
        password_hash: Argon2.hash_pwd_salt("generated-internal-password"),
        last_hex_login_at: ~U[2026-06-03 12:00:00Z]
      })
      |> Ash.create!(domain: Portal.Accounts)

    updated =
      user
      |> Ash.Changeset.for_update(:record_hex_login, %{
        hex_profile: encode_profile(%{"username" => "owner_update", "name" => "Package Owner"}),
        last_hex_login_at: ~U[2026-06-03 13:00:00Z]
      })
      |> Ash.update!(domain: Portal.Accounts)

    assert updated.id == user.id
    assert decode_profile(updated.hex_profile)["name"] == "Package Owner"
    assert updated.last_hex_login_at == ~U[2026-06-03 13:00:00Z]
  end

  test "links an existing first-party account to Hex metadata" do
    {:ok, user} = Portal.Accounts.register_user("linkowner", "correct horse battery staple")

    linked =
      user
      |> Ash.Changeset.for_update(:record_hex_login, %{
        hex_username: "linkowner",
        hex_profile: encode_profile(%{"username" => "linkowner"}),
        last_hex_login_at: ~U[2026-06-03 13:00:00Z]
      })
      |> Ash.update!(domain: Portal.Accounts)

    assert linked.id == user.id
    assert linked.hex_username == "linkowner"
    assert decode_profile(linked.hex_profile)["username"] == "linkowner"
  end

  test "registers and authenticates a first-party account" do
    {:ok, user} = Portal.Accounts.register_user("LocalOwner", "correct horse battery staple")

    assert user.username == "localowner"
    assert is_nil(user.hex_username)
    refute user.is_admin
    assert Argon2.verify_pass("correct horse battery staple", user.password_hash)

    assert {:ok, authenticated} =
             Portal.Accounts.authenticate_user("localowner", "correct horse battery staple")

    assert authenticated.id == user.id

    assert {:error, :invalid_credentials} =
             Portal.Accounts.authenticate_user("localowner", "wrong password")
  end

  test "rejects duplicate usernames" do
    assert {:ok, _user} =
             Portal.Accounts.register_user("duplicate", "correct horse battery staple")

    assert {:error, :username_taken} =
             Portal.Accounts.register_user("DUPLICATE", "another correct password")
  end

  test "seeds admin accounts and promotes existing users" do
    {:ok, admin} =
      Portal.Accounts.seed_admin_user("SeedAdmin", "correct horse battery staple")

    assert admin.username == "seedadmin"
    assert admin.is_admin
    assert Portal.Accounts.admin?(admin)

    {:ok, user} = Portal.Accounts.register_user("seed_promote", "correct horse battery staple")
    refute user.is_admin

    assert {:ok, promoted} = Portal.Accounts.seed_admin_user("seed_promote")
    assert promoted.is_admin
  end

  test "requires a password when seeding a missing admin account" do
    assert {:error, :password_required} = Portal.Accounts.seed_admin_user("missing_admin")
  end

  defp encode_profile(profile), do: Jason.encode!(profile)

  defp decode_profile(profile), do: Jason.decode!(profile)
end
