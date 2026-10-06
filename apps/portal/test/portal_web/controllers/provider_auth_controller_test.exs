defmodule PortalWeb.ProviderAuthControllerTest do
  use PortalWeb.ConnCase, async: true

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.{Identities, Identity, Totp}

  defp hex(name),
    do: %Identity{provider: :hex, uid: name, username: name, profile: %{"username" => name}}

  defp approve(identity), do: Process.put(:fake_provider_verify, {:ok, identity})

  defp start_login(conn, provider \\ "hex") do
    conn = post(conn, ~p"/auth/#{provider}/login")
    assert html_response(conn, 200) =~ "ABCD-1234"
    conn
  end

  defp finish(conn, provider \\ "hex"),
    do: post(recycle(conn), ~p"/auth/#{provider}/login/complete")

  test "login page offers both providers", %{conn: conn} do
    body = conn |> get(~p"/login") |> html_response(200)
    assert body =~ "Sign in with Hex.pm"
    assert body =~ "Sign in with GitHub"
  end

  test "an unknown provider is a 404", %{conn: conn} do
    assert_error_sent 404, fn -> post(conn, "/auth/gitlab/login") end
  end

  test "a linked Hex.pm account signs in", %{conn: conn} do
    {:ok, user} = Identities.link(user_fixture(), hex("frank"))
    approve(hex("frank"))

    conn = conn |> start_login() |> finish()

    assert get_session(conn, :user_id) == user.id
    assert get_session(conn, :login_method) == :hex
    assert redirected_to(conn) == ~p"/request-scan"
  end

  test "still pending re-renders the code with a check-again button", %{conn: conn} do
    conn = conn |> start_login() |> finish()
    body = html_response(conn, 200)
    assert body =~ "ABCD-1234"
    assert body =~ "Check again"
    refute get_session(conn, :user_id)
  end

  test "denied or expired shows a message and creates nothing", %{conn: conn} do
    Process.put(:fake_provider_verify, {:error, :access_denied})
    conn = conn |> start_login() |> finish()
    assert redirected_to(conn) == ~p"/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "denied"
    assert {:ok, nil} = Identities.find_user(hex("anyone"))
    refute get_session(conn, :user_id)
  end

  test "provider down at start shows a message", %{conn: conn} do
    Process.put(:fake_provider_start, {:error, :hex_oauth_unavailable})
    conn = post(conn, ~p"/auth/hex/login")
    assert redirected_to(conn) == ~p"/login"
  end

  test "complete without a started flow goes back to login", %{conn: conn} do
    conn = post(conn, ~p"/auth/hex/login/complete")
    assert redirected_to(conn) == ~p"/login"
  end

  test "a first sign-in with a free name creates the account and signs in", %{conn: conn} do
    approve(hex("newbie"))
    conn = conn |> start_login() |> finish()
    {:ok, user} = Portal.Accounts.get_user_by_username("newbie")
    assert get_session(conn, :user_id) == user.id
  end

  test "a taken name goes to choose-username, never to the local account", %{conn: conn} do
    local = user_fixture(%{username: "tom"})
    approve(hex("tom"))

    conn = conn |> start_login() |> finish()

    assert redirected_to(conn) == ~p"/auth/choose-username"
    refute get_session(conn, :user_id) == local.id
    refute get_session(conn, :user_id)

    page = conn |> recycle() |> get(~p"/auth/choose-username") |> html_response(200)
    assert page =~ "tom"
    assert page =~ "Already have an account here?"

    conn = post(recycle(conn), ~p"/auth/choose-username", %{"username" => "tom-hex"})
    {:ok, created} = Portal.Accounts.get_user_by_username("tom-hex")
    assert created.hex_username == "tom"
    assert get_session(conn, :user_id) == created.id
    refute get_session(conn, :pending_identity)
  end

  test "the pending identity is single use", %{conn: conn} do
    user_fixture(%{username: "tom"})
    approve(hex("tom"))
    conn = conn |> start_login() |> finish()
    conn = post(recycle(conn), ~p"/auth/choose-username", %{"username" => "tom-one"})

    # Replaying the old cookie: the identity is linked now, so it cannot make a second account.
    conn =
      build_conn()
      |> init_test_session(%{
        pending_identity:
          Map.put(Identity.to_session(hex("tom")), "at", System.system_time(:second))
      })
      |> post(~p"/auth/choose-username", %{"username" => "tom-two"})

    assert redirected_to(conn) == ~p"/login"
    assert {:ok, nil} = Portal.Accounts.get_user_by_username("tom-two")
  end

  test "a pending identity older than ten minutes is refused", %{conn: conn} do
    stale = Map.put(Identity.to_session(hex("old")), "at", System.system_time(:second) - 601)

    conn =
      conn
      |> init_test_session(%{pending_identity: stale})
      |> post(~p"/auth/choose-username", %{"username" => "old-name"})

    assert redirected_to(conn) == ~p"/login"
    assert {:ok, nil} = Portal.Accounts.get_user_by_username("old-name")
  end

  test "a taken choice re-renders with an error", %{conn: conn} do
    user_fixture(%{username: "tom"})
    approve(hex("tom"))
    conn = conn |> start_login() |> finish()
    conn = post(recycle(conn), ~p"/auth/choose-username", %{"username" => "tom"})
    assert html_response(conn, 200) =~ "taken"
  end

  test "an account with TOTP still owes the second step", %{conn: conn} do
    {:ok, user} = Identities.link(user_fixture(), hex("totp"))
    at = ~U[2026-09-18 12:00:00.000000Z]
    {:ok, %{secret: secret}} = Totp.start_enrolment(user)
    :ok = Totp.confirm(user, NimbleTOTP.verification_code(secret, time: at), at)
    approve(hex("totp"))

    conn = conn |> start_login() |> finish()

    assert redirected_to(conn) == ~p"/login/totp"
    refute get_session(conn, :user_id)
    assert get_session(conn, :pending_user_id) == user.id
  end

  test "an admin signed in with Hex.pm does not get into /admin", %{conn: conn} do
    {:ok, admin} = Identities.link(admin_with_passkey_fixture(), hex("boss"))
    approve(hex("boss"))

    conn = conn |> start_login() |> finish()
    assert get_session(conn, :user_id) == admin.id

    conn = get(recycle(conn), ~p"/admin")
    refute conn.status == 200
  end
end
