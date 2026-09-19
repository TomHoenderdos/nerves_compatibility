defmodule PortalWeb.MfaControllerTest do
  use PortalWeb.ConnCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.{RecoveryCodes, Totp}

  @password "correct horse battery staple"

  defp user_with_totp do
    user = user_fixture(%{password: @password})
    at = ~U[2026-09-18 12:00:00.000000Z]
    {:ok, %{secret: secret}} = Totp.start_enrolment(user)
    :ok = Totp.confirm(user, NimbleTOTP.verification_code(secret, time: at), at)
    {user, secret}
  end

  defp code_now(secret), do: NimbleTOTP.verification_code(secret)

  test "a password login with no factor signs straight in", %{conn: conn} do
    user = user_fixture(%{password: @password})

    conn = post(conn, ~p"/login", %{"username" => user.username, "password" => @password})

    assert get_session(conn, :user_id) == user.id
    assert get_session(conn, :reauth_method) == :password
    assert is_integer(get_session(conn, :reauth_at))
    assert redirected_to(conn) == ~p"/request-scan"
  end

  test "a password login with TOTP stops at the second step", %{conn: conn} do
    {user, _secret} = user_with_totp()

    conn = post(conn, ~p"/login", %{"username" => user.username, "password" => @password})

    assert redirected_to(conn) == ~p"/login/totp"
    refute get_session(conn, :user_id)
    assert get_session(conn, :pending_user_id) == user.id
  end

  test "a pending session grants nothing on its own", %{conn: conn} do
    {user, _secret} = user_with_totp()

    conn = post(conn, ~p"/login", %{"username" => user.username, "password" => @password})
    conn = get(recycle(conn), ~p"/settings")

    assert redirected_to(conn) == ~p"/login"
    refute get_session(conn, :user_id)
  end

  test "a valid code promotes the pending session and rotates the session id", %{conn: conn} do
    {user, secret} = user_with_totp()

    conn = post(conn, ~p"/login", %{"username" => user.username, "password" => @password})
    before_id = conn.cookies["_portal_key"]

    conn = post(recycle(conn), ~p"/login/totp", %{"code" => code_now(secret)})

    assert get_session(conn, :user_id) == user.id
    assert get_session(conn, :reauth_method) == :totp
    refute get_session(conn, :pending_user_id)
    assert redirected_to(conn) == ~p"/request-scan"
    refute conn.cookies["_portal_key"] == before_id
  end

  test "a wrong code keeps the session pending", %{conn: conn} do
    {user, _secret} = user_with_totp()

    conn = post(conn, ~p"/login", %{"username" => user.username, "password" => @password})
    conn = post(recycle(conn), ~p"/login/totp", %{"code" => "000000"})

    refute get_session(conn, :user_id)
    assert get_session(conn, :pending_user_id) == user.id
    assert html_response(conn, 200) =~ "code"
  end

  test "lockout drops the pending session and sends the user back to the password step", %{
    conn: conn
  } do
    {user, _secret} = user_with_totp()

    conn = post(conn, ~p"/login", %{"username" => user.username, "password" => @password})

    conn =
      Enum.reduce(1..5, conn, fn _, acc ->
        post(recycle(acc), ~p"/login/totp", %{"code" => "000000"})
      end)

    assert redirected_to(conn) == ~p"/login"
    refute get_session(conn, :pending_user_id)
  end

  test "a recovery code is accepted at the second step and is then spent", %{conn: conn} do
    {user, _secret} = user_with_totp()
    {:ok, [recovery | _]} = RecoveryCodes.generate(user)

    conn = post(conn, ~p"/login", %{"username" => user.username, "password" => @password})
    conn = post(recycle(conn), ~p"/login/totp", %{"code" => recovery})

    assert get_session(conn, :user_id) == user.id
    assert get_session(conn, :reauth_method) == :recovery_code
    assert RecoveryCodes.remaining(user) == 9
  end

  test "an expired pending session is refused", %{conn: conn} do
    {user, secret} = user_with_totp()

    conn =
      conn
      |> init_test_session(%{})
      |> put_session(:pending_user_id, user.id)
      |> put_session(:pending_started_at, System.system_time(:second) - 301)

    conn = post(conn, ~p"/login/totp", %{"code" => code_now(secret)})

    assert redirected_to(conn) == ~p"/login"
    refute get_session(conn, :user_id)
  end

  test "the second-factor page is not reachable without a pending session", %{conn: conn} do
    conn = get(conn, ~p"/login/totp")

    assert redirected_to(conn) == ~p"/login"
  end

  test "a pending session whose user id no longer resolves is refused, not crashed", %{
    conn: conn
  } do
    conn =
      conn
      |> init_test_session(%{})
      |> put_session(:pending_user_id, Ecto.UUID.generate())
      |> put_session(:pending_started_at, System.system_time(:second))

    conn = post(conn, ~p"/login/totp", %{"code" => "000000"})

    assert redirected_to(conn) == ~p"/login"
  end
end
