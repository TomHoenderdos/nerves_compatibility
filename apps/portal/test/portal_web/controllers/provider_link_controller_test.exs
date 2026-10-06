defmodule PortalWeb.ProviderLinkControllerTest do
  use PortalWeb.ConnCase, async: true

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.{Identities, Identity}

  defp hex(name),
    do: %Identity{provider: :hex, uid: name, username: name, profile: %{"username" => name}}

  defp github(uid, login),
    do: %Identity{
      provider: :github,
      uid: uid,
      username: login,
      profile: %{"id" => uid, "login" => login}
    }

  defp approve(identity), do: Process.put(:fake_provider_verify, {:ok, identity})

  defp signed_in(conn, user, opts \\ []) do
    fresh_at = if Keyword.get(opts, :fresh, true), do: System.system_time(:second), else: nil
    method = Keyword.get(opts, :method, :password)

    init_test_session(conn, %{
      user_id: user.id,
      login_method: method,
      reauth_method: method,
      reauth_at: fresh_at
    })
  end

  defp run_flow(conn, start_path, complete_path) do
    conn = post(conn, start_path)
    assert html_response(conn, 200) =~ "ABCD-1234"
    post(recycle(conn), complete_path)
  end

  test "the security page lists sign-in methods", %{conn: conn} do
    body = conn |> signed_in(user_fixture()) |> get(~p"/settings/security") |> html_response(200)
    assert body =~ "Sign-in methods"
    assert body =~ "Link Hex.pm"
    assert body =~ "Link GitHub"
  end

  test "linking Hex.pm with a fresh step-up", %{conn: conn} do
    user = user_fixture()
    approve(hex("mine"))

    conn =
      conn
      |> signed_in(user)
      |> run_flow(~p"/settings/providers/hex/link", ~p"/settings/providers/hex/link/complete")

    assert redirected_to(conn) == ~p"/settings/security"
    {:ok, user} = Portal.Accounts.get_user(user.id)
    assert user.hex_username == "mine"
  end

  test "linking without a fresh step-up is refused before the flow starts", %{conn: conn} do
    conn =
      conn |> signed_in(user_fixture(), fresh: false) |> post(~p"/settings/providers/hex/link")

    assert redirected_to(conn) == ~p"/settings/security"
    refute get_session(conn, :provider_flow)
  end

  test "an identity linked to someone else is refused", %{conn: conn} do
    {:ok, _} = Identities.link(user_fixture(), hex("theirs"))
    user = user_fixture()
    approve(hex("theirs"))

    conn =
      conn
      |> signed_in(user)
      |> run_flow(~p"/settings/providers/hex/link", ~p"/settings/providers/hex/link/complete")

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "linked to another"
    {:ok, user} = Portal.Accounts.get_user(user.id)
    assert is_nil(user.hex_username)
  end

  test "a login flow cannot be completed as a link", %{conn: conn} do
    user = user_fixture()
    approve(hex("x"))
    conn = conn |> signed_in(user) |> post(~p"/auth/hex/login")
    conn = post(recycle(conn), ~p"/settings/providers/hex/link/complete")
    assert redirected_to(conn) == ~p"/settings/security"
    {:ok, user} = Portal.Accounts.get_user(user.id)
    assert is_nil(user.hex_username)
  end

  test "unlink while a password remains", %{conn: conn} do
    {:ok, user} = Identities.link(user_fixture(), hex("gone"))
    conn = conn |> signed_in(user) |> post(~p"/settings/providers/hex/unlink")
    assert redirected_to(conn) == ~p"/settings/security"
    {:ok, user} = Portal.Accounts.get_user(user.id)
    assert is_nil(user.hex_username)
  end

  test "unlink refuses to remove the last way in", %{conn: conn} do
    {:ok, user} = Identities.sign_in(hex("only"))
    conn = conn |> signed_in(user, method: :hex) |> post(~p"/settings/providers/hex/unlink")
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "only way"
    {:ok, user} = Portal.Accounts.get_user(user.id)
    assert user.hex_username == "only"
  end

  test "unlink without step-up is refused", %{conn: conn} do
    {:ok, user} = Identities.link(user_fixture(), hex("stay"))
    conn = conn |> signed_in(user, fresh: false) |> post(~p"/settings/providers/hex/unlink")
    {:ok, user} = Portal.Accounts.get_user(user.id)
    assert user.hex_username == "stay"
    assert redirected_to(conn) == ~p"/settings/security"
  end

  test "a provider account confirms with its own provider", %{conn: conn} do
    {:ok, user} = Identities.sign_in(hex("conf"))
    approve(hex("conf"))

    conn =
      conn
      |> signed_in(user, method: :hex, fresh: false)
      |> run_flow(
        ~p"/settings/providers/hex/confirm",
        ~p"/settings/providers/hex/confirm/complete"
      )

    assert get_session(conn, :reauth_method) == :hex
    assert is_integer(get_session(conn, :reauth_at))
  end

  test "confirming with a different Hex.pm account is refused", %{conn: conn} do
    {:ok, user} = Identities.sign_in(hex("victim"))
    approve(hex("attacker"))

    conn =
      conn
      |> signed_in(user, method: :hex, fresh: false)
      |> run_flow(
        ~p"/settings/providers/hex/confirm",
        ~p"/settings/providers/hex/confirm/complete"
      )

    refute get_session(conn, :reauth_at)
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not the"
  end

  test "an account with a passkey cannot confirm with its linked Hex.pm", %{conn: conn} do
    # A passkey is the only step-up such an account accepts; a provider
    # approval, even of the right account, must not stand in for it.
    {:ok, user} = Identities.link(add_test_passkey(user_fixture()), hex("keyed"))

    conn =
      conn |> signed_in(user, fresh: false) |> post(~p"/settings/providers/hex/confirm")

    assert redirected_to(conn) == ~p"/settings/security"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "another way"
    refute get_session(conn, :provider_flow)

    # Even with a reauth flow already in the session and the matching
    # identity approved, completing it grants nothing.
    approve(hex("keyed"))

    flow = %{
      "provider" => "hex",
      "purpose" => "reauth",
      "device_code" => "dev",
      "user_code" => "ABCD-1234",
      "verification_uri" => "https://example.test/device",
      "verification_uri_complete" => nil
    }

    conn =
      build_conn()
      |> init_test_session(%{
        user_id: user.id,
        login_method: :password,
        provider_flow: flow
      })
      |> post(~p"/settings/providers/hex/confirm/complete")

    assert redirected_to(conn) == ~p"/settings/security"
    refute get_session(conn, :reauth_at)
    refute get_session(conn, :reauth_method)
  end

  test "a provider account sets a password after step-up", %{conn: conn} do
    # "pw" alone is below the 3-character username minimum
    # (`Portal.Accounts.valid_username?/1`), which would route `sign_in/1` to
    # `:choose_username` instead of creating the account this test needs.
    {:ok, user} = Identities.sign_in(hex("pw1"))

    conn =
      conn
      |> signed_in(user, method: :hex)
      |> post(~p"/settings/password/set", %{"new_password" => "a long enough password"})

    assert redirected_to(conn) == ~p"/settings"
    {:ok, user} = Portal.Accounts.get_user(user.id)
    assert user.password_set
  end

  test "setting a password without step-up is refused", %{conn: conn} do
    {:ok, user} = Identities.sign_in(hex("pw2"))

    conn
    |> signed_in(user, method: :hex, fresh: false)
    |> post(~p"/settings/password/set", %{"new_password" => "a long enough password"})

    {:ok, user} = Portal.Accounts.get_user(user.id)
    refute user.password_set
  end

  test "an account that has a password cannot use set-password to skip the current one", %{
    conn: conn
  } do
    user = user_fixture()

    conn =
      conn
      |> signed_in(user)
      |> post(~p"/settings/password/set", %{"new_password" => "another long password"})

    assert redirected_to(conn) == ~p"/settings"
    assert {:error, _} = Portal.Accounts.authenticate_user(user.username, "another long password")
  end

  test "settings shows Set a password for a provider account", %{conn: conn} do
    {:ok, user} = Identities.sign_in(hex("pw3"))
    body = conn |> signed_in(user, method: :hex) |> get(~p"/settings") |> html_response(200)
    assert body =~ "Set a password"
    refute body =~ "Current password"
  end

  # --- Task 5 brief: extra required coverage ---------------------------------

  test "linking GitHub from settings stores the integer uid and login", %{conn: conn} do
    user = user_fixture()
    approve(github(4242, "octo"))

    conn =
      conn
      |> signed_in(user)
      |> run_flow(
        ~p"/settings/providers/github/link",
        ~p"/settings/providers/github/link/complete"
      )

    assert redirected_to(conn) == ~p"/settings/security"
    {:ok, user} = Portal.Accounts.get_user(user.id)
    assert user.github_id == 4242
    assert user.github_username == "octo"
  end
end
