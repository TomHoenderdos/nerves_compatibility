defmodule PortalWeb.SessionRevocationTest do
  @moduledoc """
  The session store is the signed cookie, so no server-side session exists to
  end. A session is revoked instead by the user's `sessions_valid_after`: a
  session whose `:session_started_at` is older is treated as signed out on
  the next request and the next LiveView mount, wherever the cookie is.
  """
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Portal.Test.AccountsFixtures

  alias Portal.Accounts

  @password "correct horse battery staple"
  @new_password "an entirely different passphrase"

  # A real password login, so the session carries whatever `complete_login/3`
  # writes. `recycle/1` hands the cookie to the next request, as a browser
  # would.
  defp log_in(user, password \\ @password) do
    build_conn()
    |> post(~p"/login", %{"username" => user.username, "password" => password})
    |> recycle()
  end

  # An admin session opened with a passkey, as `complete_login/3` stamps it.
  defp passkey_session(user) do
    init_test_session(build_conn(),
      user_id: user.id,
      login_method: :passkey,
      session_started_at: System.system_time(:microsecond),
      reauth_method: :passkey,
      reauth_at: System.system_time(:second)
    )
  end

  defp signed_in?(conn), do: conn |> get(~p"/settings") |> Map.fetch!(:status) == 200

  # The public LiveView's mount resolves `current_user` from the session; the
  # nav shows Logout only when it found one.
  defp live_signed_in?(conn) do
    {:ok, _view, html} = live(conn, ~p"/")
    html =~ "Logout"
  end

  describe "login" do
    test "a password login stamps when the session started" do
      user = user_fixture()
      before = System.system_time(:microsecond)

      conn =
        post(build_conn(), ~p"/login", %{"username" => user.username, "password" => @password})

      started = get_session(conn, :session_started_at)
      assert is_integer(started) and started >= before
    end

    test "registration stamps when the session started", %{conn: conn} do
      conn =
        post(conn, ~p"/register", %{"username" => "fresh_signup", "password" => @password})

      assert is_integer(get_session(conn, :session_started_at))
    end
  end

  describe "an admin password reset" do
    test "refuses the target's existing session on the next request and mount" do
      admin = admin_with_passkey_fixture()
      target = user_fixture()
      conn = log_in(target)
      assert signed_in?(conn)
      assert live_signed_in?(conn)

      {:ok, _updated, _temp} = Portal.Admin.reset_password(target.username, admin)

      refused = get(conn, ~p"/settings")
      assert redirected_to(refused) == ~p"/login"
      # The stale sign-in is dropped from the cookie, not just ignored.
      refute get_session(refused, :user_id)
      refute get_session(refused, :session_started_at)
      refute live_signed_in?(conn)
    end
  end

  describe "an admin revoke" do
    test "refuses the revoked admin's existing session on the next request and mount" do
      actor = admin_with_passkey_fixture()
      target = admin_with_passkey_fixture()
      conn = passkey_session(target)
      assert {:ok, _view, _html} = live(conn, ~p"/admin/users")

      {:ok, _} = Portal.Admin.revoke_admin(target.id, actor)

      assert redirected_to(get(conn, ~p"/admin")) == ~p"/login"
      assert redirected_to(get(conn, ~p"/settings")) == ~p"/login"
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/admin/users")
    end

    # The disconnect broadcast is best-effort; a page that missed it is
    # still refused on its next click, by the timestamp.
    test "an open admin page refuses the next click once its session is revoked" do
      admin = admin_with_passkey_fixture()
      other = admin_with_passkey_fixture()
      {:ok, view, _html} = live(passkey_session(admin), ~p"/admin/users")
      render_async(view)

      {:ok, _} = Accounts.revoke_sessions(admin)

      assert {:error, {:redirect, %{to: "/login"}}} =
               render_click(view, "revoke_admin", %{"id" => other.id})

      assert Accounts.admin?(Ash.reload!(other, domain: Accounts))
    end
  end

  describe "the user's own password change" do
    test "keeps the current session and refuses every other one" do
      user = user_fixture()
      other = log_in(user)
      conn = log_in(user)

      conn =
        conn
        |> post(~p"/settings", %{"current_password" => @password, "new_password" => @new_password})
        |> recycle()

      assert signed_in?(conn)
      assert live_signed_in?(conn)
      refute signed_in?(other)
      refute live_signed_in?(other)
    end
  end

  describe "removing a passkey" do
    test "keeps the remover's session and refuses every other one" do
      user = add_test_passkey(user_fixture())
      [passkey] = Accounts.Passkeys.list_for_user(user)
      other = log_in(user)
      conn = passkey_session(user)

      conn = post(conn, ~p"/settings/security/passkeys/#{passkey.id}/delete")
      assert redirected_to(conn) == ~p"/settings/security"
      conn = recycle(conn)

      assert signed_in?(conn)
      refute signed_in?(other)
    end
  end

  describe "sign out everywhere" do
    test "keeps the current session, refuses the others and disconnects their sockets" do
      user = user_fixture()
      other = log_in(user)
      conn = log_in(user)
      topic = Accounts.live_socket_id(user.id)
      PortalWeb.Endpoint.subscribe(topic)

      conn = post(conn, ~p"/settings/security/sign-out-everywhere")
      assert redirected_to(conn) == ~p"/settings/security"
      conn = recycle(conn)
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
      assert signed_in?(conn)
      assert live_signed_in?(conn)
      refute signed_in?(other)
      refute live_signed_in?(other)
    end

    test "is offered on the security page" do
      html = log_in(user_fixture()) |> get(~p"/settings/security") |> html_response(200)
      assert html =~ ~s(action="/settings/security/sign-out-everywhere")
    end
  end

  describe "a session from before session timestamps" do
    test "stays valid until the user's sessions are revoked, then is refused" do
      user = user_fixture()
      conn = init_test_session(build_conn(), user_id: user.id, login_method: :password)
      assert signed_in?(conn)
      assert live_signed_in?(conn)

      {:ok, _} = Accounts.revoke_sessions(user)

      refute signed_in?(conn)
      refute live_signed_in?(conn)
    end
  end

  describe "plain logout" do
    test "ends this session only; the user's other sessions stay signed in" do
      user = user_fixture()
      other = log_in(user)
      conn = log_in(user) |> post(~p"/logout") |> recycle()

      refute signed_in?(conn)
      assert signed_in?(other)
      assert is_nil(Ash.reload!(user, domain: Accounts).sessions_valid_after)
    end
  end
end
