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

  # A session that re-authenticated with `method` a moment ago, as the
  # step-up gate on `/settings/security` and the provider routes wants.
  defp fresh_session(user, method) do
    init_test_session(build_conn(),
      user_id: user.id,
      login_method: :password,
      session_started_at: System.system_time(:microsecond),
      reauth_method: method,
      reauth_at: System.system_time(:second)
    )
  end

  defp confirm_totp(user) do
    at = ~U[2026-09-18 12:00:00.000000Z]
    {:ok, %{secret: secret}} = Accounts.Totp.start_enrolment(user)
    :ok = Accounts.Totp.confirm(user, NimbleTOTP.verification_code(secret, time: at), at)
    secret
  end

  defp subscribe_disconnect(user) do
    topic = Accounts.live_socket_id(user.id)
    PortalWeb.Endpoint.subscribe(topic)
    topic
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

      refused = get(conn, ~p"/admin")
      assert redirected_to(refused) == ~p"/login"
      # The admin gate drops the stale sign-in from the cookie, as the
      # signed-in pages' gate does.
      refute get_session(refused, :user_id)
      refute get_session(refused, :session_started_at)
      refute get_session(refused, :login_method)

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

    test "disconnects the account's open live sockets" do
      user = user_fixture()
      conn = log_in(user)
      topic = subscribe_disconnect(user)

      post(conn, ~p"/settings", %{
        "current_password" => @password,
        "new_password" => @new_password
      })

      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    end

    test "a refused change disconnects nothing" do
      user = user_fixture()
      conn = log_in(user)
      topic = subscribe_disconnect(user)

      post(conn, ~p"/settings", %{"current_password" => "wrong", "new_password" => @new_password})

      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 100
    end
  end

  describe "removing a passkey" do
    test "keeps the remover's session and refuses every other one" do
      user = add_test_passkey(user_fixture())
      [passkey] = Accounts.Passkeys.list_for_user(user)
      other = log_in(user)
      conn = passkey_session(user)

      topic = subscribe_disconnect(user)

      posted = post(conn, ~p"/settings/security/passkeys/#{passkey.id}/delete")
      assert redirected_to(posted) == ~p"/settings/security"
      conn = recycle(posted)

      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
      assert signed_in?(conn)
      refute signed_in?(other)

      # Re-stamped against the cutoff the removal wrote, never before it.
      cutoff = Ash.reload!(user, domain: Accounts).sessions_valid_after
      assert get_session(posted, :session_started_at) >= DateTime.to_unix(cutoff, :microsecond)
    end
  end

  describe "removing the authenticator app" do
    test "keeps the remover's session, refuses every other one and disconnects their sockets" do
      user = user_fixture()
      other = log_in(user)
      confirm_totp(user)
      # Adding the factor revoked nothing.
      assert signed_in?(other)
      conn = fresh_session(user, :totp)
      topic = subscribe_disconnect(user)

      posted = post(conn, ~p"/settings/security/totp/delete")
      assert redirected_to(posted) == ~p"/settings/security"
      conn = recycle(posted)

      refute Accounts.Totp.confirmed?(user)
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
      assert signed_in?(conn)
      assert live_signed_in?(conn)
      refute signed_in?(other)
      refute live_signed_in?(other)

      cutoff = Ash.reload!(user, domain: Accounts).sessions_valid_after
      assert get_session(posted, :session_started_at) >= DateTime.to_unix(cutoff, :microsecond)
    end

    test "dropping an enrolment never confirmed revokes nothing" do
      user = user_fixture()
      other = log_in(user)
      {:ok, _} = Accounts.Totp.start_enrolment(user)

      posted = post(fresh_session(user, :password), ~p"/settings/security/totp/delete")
      assert redirected_to(posted) == ~p"/settings/security"

      assert signed_in?(other)
      assert is_nil(Ash.reload!(user, domain: Accounts).sessions_valid_after)
    end
  end

  describe "regenerating recovery codes" do
    test "keeps the current session, refuses every other one and disconnects their sockets" do
      user = user_fixture()
      {:ok, _old_codes} = Accounts.RecoveryCodes.generate(user)
      other = log_in(user)
      conn = fresh_session(user, :password)
      topic = subscribe_disconnect(user)

      posted = post(conn, ~p"/settings/security/recovery-codes")
      assert html_response(posted, 200)
      conn = recycle(posted)

      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
      assert signed_in?(conn)
      assert live_signed_in?(conn)
      refute signed_in?(other)
      refute live_signed_in?(other)
    end

    test "the first set revokes nothing" do
      user = user_fixture()
      other = log_in(user)

      posted = post(fresh_session(user, :password), ~p"/settings/security/recovery-codes")
      assert html_response(posted, 200)

      assert signed_in?(other)
      assert is_nil(Ash.reload!(user, domain: Accounts).sessions_valid_after)
    end
  end

  describe "unlinking a sign-in provider" do
    test "keeps the current session, refuses every other one and disconnects their sockets" do
      identity = %Accounts.Identity{
        provider: :github,
        uid: 4242,
        username: "octo",
        profile: %{"id" => 4242, "login" => "octo"}
      }

      {:ok, user} = Accounts.Identities.link(user_fixture(), identity)
      other = log_in(user)
      # Adding the provider revoked nothing.
      assert signed_in?(other)
      conn = fresh_session(user, :password)
      topic = subscribe_disconnect(user)

      posted = post(conn, ~p"/settings/providers/github/unlink")
      assert redirected_to(posted) == ~p"/settings/security"
      conn = recycle(posted)

      reloaded = Ash.reload!(user, domain: Accounts)
      assert is_nil(reloaded.github_id)
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
      assert signed_in?(conn)
      assert live_signed_in?(conn)
      refute signed_in?(other)
      refute live_signed_in?(other)

      cutoff = reloaded.sessions_valid_after
      assert get_session(posted, :session_started_at) >= DateTime.to_unix(cutoff, :microsecond)
    end

    test "a refused unlink revokes nothing" do
      user = user_fixture()
      other = log_in(user)

      posted = post(fresh_session(user, :password), ~p"/settings/providers/hex/unlink")
      assert redirected_to(posted) == ~p"/settings/security"

      assert signed_in?(other)
      assert is_nil(Ash.reload!(user, domain: Accounts).sessions_valid_after)
    end
  end

  describe "a pending second-factor sign-in" do
    # The password step parks the user under `:pending_user_id` for up to
    # five minutes. A revocation inside that window -- a reset, a revoke,
    # "sign out everywhere" -- must end that half-finished sign-in as well,
    # or the second step would mint a fresh, valid session from it.
    test "is refused at the second step once the user's sessions are revoked" do
      user = user_fixture()
      at = ~U[2026-09-18 12:00:00.000000Z]
      {:ok, %{secret: secret}} = Accounts.Totp.start_enrolment(user)
      :ok = Accounts.Totp.confirm(user, NimbleTOTP.verification_code(secret, time: at), at)

      conn =
        init_test_session(build_conn(),
          pending_user_id: user.id,
          pending_started_at: System.system_time(:second) - 10
        )

      {:ok, _} = Accounts.revoke_sessions(user)

      conn = post(conn, ~p"/login/totp", %{"code" => NimbleTOTP.verification_code(secret)})

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_id)
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
