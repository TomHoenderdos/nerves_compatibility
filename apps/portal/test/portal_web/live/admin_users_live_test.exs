defmodule PortalWeb.AdminUsersLiveTest do
  use PortalWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  @pw "correct horse battery staple"

  setup %{conn: conn} do
    {:ok, admin} = Portal.Accounts.seed_admin_user("cinder_admin", "correct horse battery staple")
    Portal.Test.AccountsFixtures.add_test_passkey(admin)
    %{conn: init_test_session(conn, user_id: admin.id, login_method: :passkey), admin: admin}
  end

  # A step-up made just now, stored with the types `PortalWeb.UserAuth.mark_reauth/2`
  # writes: the method as an atom, the time as integer seconds.
  defp fresh(conn),
    do: init_test_session(conn, reauth_method: :passkey, reauth_at: System.system_time(:second))

  # The table loads with `start_async`, so its rows arrive after the mount.
  defp live_users(conn, path \\ ~p"/admin/users") do
    {:ok, view, _html} = live(conn, path)
    {view, render_async(view)}
  end

  # A successful action refreshes the table, which reloads with `start_async`
  # too; waiting for it keeps the reload from outliving the test's sandbox.
  defp click(view, event, params) do
    render_click(view, event, params)
    render_async(view)
  end

  describe "access" do
    test "anonymous visitors are sent to login" do
      assert redirected_to(get(build_conn(), ~p"/admin/users")) == ~p"/login"
      assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/admin/users")
    end

    test "a password-only admin and a non-admin are refused", %{admin: admin} do
      conn = build_conn() |> init_test_session(user_id: admin.id, login_method: :password)
      assert {:error, {:redirect, %{to: "/settings/security"}}} = live(conn, ~p"/admin/users")

      {:ok, user} = Portal.Accounts.register_user("plain_viewer", @pw)
      conn = build_conn() |> init_test_session(user_id: user.id, login_method: :password)
      assert {:error, {:redirect, %{to: "/request-scan"}}} = live(conn, ~p"/admin/users")
    end

    test "the users tab is marked current in the shared tabs", %{conn: conn} do
      {view, _html} = live_users(conn)
      assert has_element?(view, ~s(#admin-tabs a[aria-current="page"][href="/admin/users"]))
    end
  end

  describe "the table" do
    test "lists users and filters by username via the URL", %{conn: conn} do
      {:ok, _} = Portal.Accounts.register_user("alice_one", @pw)
      {:ok, _} = Portal.Accounts.register_user("bob_two", @pw)

      {_view, html} = live_users(conn)
      assert html =~ "alice_one" and html =~ "bob_two"
      assert html =~ "cinder_admin"

      {_view, html} = live_users(conn, ~p"/admin/users?username=alice")
      assert html =~ "alice_one"
      refute html =~ "bob_two"
    end

    test "a malformed page param does not crash the page", %{conn: conn} do
      for query <- ["page=oops", "page=-1", "page[]=2", "page=99999999999999999999"] do
        assert {:ok, view, _html} = live(conn, "/admin/users?" <> query)
        assert render_async(view) =~ "cinder_admin"
      end
    end

    test "a filter change goes into the URL, so a reload keeps it", %{conn: conn} do
      {:ok, _} = Portal.Accounts.register_user("alice_one", @pw)
      {:ok, _} = Portal.Accounts.register_user("bob_two", @pw)
      {view, _html} = live_users(conn)

      view
      |> form("#users-filter-form")
      |> render_change(%{"filters" => %{"username" => "bob"}})

      path = assert_patch(view)
      assert path =~ "username=bob"

      {_view, html} = live_users(conn, path)
      assert html =~ "bob_two"
      refute html =~ "alice_one"
    end

    test "a malformed filter param does not crash the page", %{conn: conn} do
      assert {:ok, view, _html} = live(conn, ~p"/admin/users?page=abc&sort=nonsense")
      assert render_async(view) =~ "cinder_admin"
    end

    # Cinder's boolean filter says True / False unless told otherwise, which
    # reads as nonsense under "Status" and "Password".
    test "the yes/no filters say what they mean", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/users")
      filters = view |> element("#users-filter-form") |> render()

      for label <- ["Admin", "Not admin", "Set", "No password"], do: assert(filters =~ label)
      refute filters =~ ~r/>\s*True\s*</
      refute filters =~ ~r/>\s*False\s*</
    end

    test "admins come first, then by username", %{conn: conn} do
      {:ok, _} = Portal.Accounts.register_user("aaa_plain", @pw)
      {:ok, _} = Portal.Accounts.seed_admin_user("zzz_admin", @pw)
      {_view, html} = live_users(conn)

      positions = Enum.map(~w(cinder_admin zzz_admin aaa_plain), &:binary.match(html, &1))
      assert positions == Enum.sort(positions)
    end

    test "flags an admin without a passkey and an account without a password", %{conn: conn} do
      {:ok, _} = Portal.Accounts.seed_admin_user("no_passkey_admin", @pw)

      {:ok, _} =
        Portal.Accounts.Identities.sign_in(%Portal.Accounts.Identity{
          provider: :hex,
          uid: "nopw",
          username: "nopw",
          profile: %{}
        })

      {_view, html} = live_users(conn)
      assert html =~ "needs a passkey"
      assert html =~ ~r/nopw[\s\S]*No password/
    end

    test "per-user actions: none on yourself", %{conn: conn, admin: admin} do
      {:ok, frank} = Portal.Accounts.register_user("sec_frank", @pw)
      {:ok, other} = Portal.Accounts.seed_admin_user("sec_other", @pw)
      {view, _html} = live_users(conn)

      # A plain user can be made admin or get a temporary password.
      assert has_element?(view, "#grant-admin-#{frank.id}")
      assert has_element?(view, "#reset-password-#{frank.id}")
      refute has_element?(view, "#revoke-admin-#{frank.id}")
      # Another admin can be revoked; you cannot revoke or reset yourself here.
      assert has_element?(view, "#revoke-admin-#{other.id}")
      refute has_element?(view, "#grant-admin-#{other.id}")
      refute has_element?(view, "#revoke-admin-#{admin.id}")
      refute has_element?(view, "#reset-password-#{admin.id}")
    end
  end

  describe "grant admin" do
    test "needs a fresh passkey confirmation", %{conn: conn} do
      {:ok, user} = Portal.Accounts.register_user("carol_three", @pw)
      {view, _html} = live_users(conn)

      assert {:error, {:redirect, %{to: "/settings/security"}}} =
               render_click(view, "grant_admin", %{"username" => user.username})

      assert %{"error" => "Confirm your passkey" <> _} =
               assert_redirect(view, ~p"/settings/security")

      refute Portal.Accounts.get_user_by_username("carol_three") |> elem(1) |> Map.get(:is_admin)
    end

    test "with a fresh confirmation", %{conn: conn} do
      {:ok, user} = Portal.Accounts.register_user("dave_four", @pw)
      {view, _html} = live_users(fresh(conn))

      assert click(view, "grant_admin", %{"username" => user.username}) =~
               "dave_four is now an admin."

      assert {:ok, %{is_admin: true}} = Portal.Accounts.get_user_by_username("dave_four")
    end

    test "a confirmation older than the window is refused", %{conn: conn} do
      stale = System.system_time(:second) - Portal.Accounts.Mfa.reauth_window_seconds() - 1
      conn = init_test_session(conn, reauth_method: :passkey, reauth_at: stale)
      {:ok, user} = Portal.Accounts.register_user("erin_five", @pw)
      {view, _html} = live_users(conn)

      assert {:error, {:redirect, %{to: "/settings/security"}}} =
               render_click(view, "grant_admin", %{"username" => user.username})

      assert {:ok, %{is_admin: false}} = Portal.Accounts.get_user_by_username("erin_five")
    end

    test "an admin demoted while the page is open is refused on the next click",
         %{conn: conn, admin: admin} do
      {:ok, user} = Portal.Accounts.register_user("gus_seven", @pw)
      {view, _html} = live_users(fresh(conn))

      {:ok, _} =
        admin
        |> Ash.Changeset.for_update(:set_admin, %{is_admin: false})
        |> Ash.update(domain: Portal.Accounts)

      assert {:error, {:redirect, %{to: "/request-scan"}}} =
               render_click(view, "grant_admin", %{"username" => user.username})

      assert {:ok, %{is_admin: false}} = Portal.Accounts.get_user_by_username("gus_seven")
    end

    test "an unknown username flashes an error", %{conn: conn} do
      {view, _html} = live_users(fresh(conn))

      assert click(view, "grant_admin", %{"username" => "ctl_nobody"}) =~
               "No account with that username"
    end

    test "a forged click without a username is refused, not a crash", %{conn: conn} do
      {view, _html} = live_users(fresh(conn))
      assert click(view, "grant_admin", %{}) =~ "Enter a username."
      assert click(view, "reset_password", %{"username" => ["x"]}) =~ "Enter a username."
      assert click(view, "revoke_admin", %{}) =~ "No account with that username"
    end
  end

  describe "revoke admin" do
    test "another admin, with a fresh confirmation", %{conn: conn} do
      {:ok, other} = Portal.Accounts.seed_admin_user("ctl_other", @pw)
      {view, _html} = live_users(fresh(conn))

      assert click(view, "revoke_admin", %{"id" => other.id}) =~
               "ctl_other is no longer an admin"

      assert {:ok, %{is_admin: false}} = Portal.Accounts.get_user_by_username("ctl_other")
    end

    test "needs a fresh passkey confirmation", %{conn: conn} do
      {:ok, other} = Portal.Accounts.seed_admin_user("ctl_other", @pw)
      {view, _html} = live_users(conn)

      assert {:error, {:redirect, %{to: "/settings/security"}}} =
               render_click(view, "revoke_admin", %{"id" => other.id})

      assert {:ok, %{is_admin: true}} = Portal.Accounts.get_user_by_username("ctl_other")
    end

    # The revoked admin's open tabs would otherwise keep paging this very
    # table on the actor they mounted with. The disconnect makes them
    # reconnect, and the reconnect is refused by the gate.
    test "disconnects the revoked admin's live sockets, not the revoker's", %{
      conn: conn,
      admin: admin
    } do
      {:ok, other} = Portal.Accounts.seed_admin_user("ctl_other", @pw)
      Portal.Test.AccountsFixtures.add_test_passkey(other)
      other_topic = "users_socket:#{other.id}"
      own_topic = "users_socket:#{admin.id}"
      PortalWeb.Endpoint.subscribe(other_topic)
      PortalWeb.Endpoint.subscribe(own_topic)

      other_conn = build_conn() |> init_test_session(user_id: other.id, login_method: :passkey)
      assert {:ok, _view, _html} = live(other_conn, ~p"/admin/users")

      {view, _html} = live_users(fresh(conn))
      click(view, "revoke_admin", %{"id" => other.id})

      assert_receive %Phoenix.Socket.Broadcast{topic: ^other_topic, event: "disconnect"}
      refute_received %Phoenix.Socket.Broadcast{topic: ^own_topic}

      assert {:error, {:redirect, %{to: "/request-scan"}}} = live(other_conn, ~p"/admin/users")
    end

    test "a refused revoke disconnects nobody", %{conn: conn, admin: admin} do
      {:ok, _} = Portal.Accounts.seed_admin_user("ctl_other", @pw)
      PortalWeb.Endpoint.subscribe("users_socket:#{admin.id}")

      {view, _html} = live_users(fresh(conn))
      click(view, "revoke_admin", %{"id" => admin.id})

      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 50
    end

    test "revoking yourself is refused with the existing text", %{conn: conn, admin: admin} do
      {:ok, _} = Portal.Accounts.seed_admin_user("ctl_other", @pw)
      {view, _html} = live_users(fresh(conn))

      assert click(view, "revoke_admin", %{"id" => admin.id}) =~
               "You cannot remove your own admin access."

      assert {:ok, %{is_admin: true}} = Portal.Accounts.get_user_by_username("cinder_admin")
    end
  end

  describe "reset password" do
    test "shows the temporary password on the page only", %{conn: conn} do
      {:ok, user} = Portal.Accounts.register_user("fay_six", @pw)
      {view, _html} = live_users(fresh(conn))

      html = click(view, "reset_password", %{"username" => user.username})
      assert has_element?(view, "#temporary-password")
      [_, temp] = Regex.run(~r/id="temporary-password-value"[^>]*>([^<]+)</, html)
      temp = String.trim(temp)

      assert {:ok, _} = Portal.Accounts.authenticate_user("fay_six", temp)
      flash = view |> element("#flash-group") |> render()
      assert flash =~ "fay_six has a temporary password."
      refute flash =~ temp
    end

    test "disconnects the reset user's live sockets", %{conn: conn} do
      {:ok, user} = Portal.Accounts.register_user("fay_six", @pw)
      topic = "users_socket:#{user.id}"
      PortalWeb.Endpoint.subscribe(topic)

      {view, _html} = live_users(fresh(conn))
      click(view, "reset_password", %{"username" => user.username})

      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    end

    test "the next action takes the temporary password off the page", %{conn: conn} do
      {:ok, fay} = Portal.Accounts.register_user("fay_six", @pw)
      {view, _html} = live_users(fresh(conn))

      click(view, "reset_password", %{"username" => fay.username})
      assert has_element?(view, "#temporary-password")

      click(view, "grant_admin", %{"username" => fay.username})
      refute has_element?(view, "#temporary-password")
    end

    test "needs a fresh passkey confirmation", %{conn: conn} do
      {:ok, _} = Portal.Accounts.register_user("pr_frank", @pw)
      {view, _html} = live_users(conn)

      assert {:error, {:redirect, %{to: "/settings/security"}}} =
               render_click(view, "reset_password", %{"username" => "pr_frank"})

      assert {:ok, _} = Portal.Accounts.authenticate_user("pr_frank", @pw)
    end

    test "an unknown username flashes an error", %{conn: conn} do
      {view, _html} = live_users(fresh(conn))

      assert click(view, "reset_password", %{"username" => "pr_nobody"}) =~
               "No account with that username"

      refute has_element?(view, "#temporary-password")
    end

    test "logging in with a temporary password lands on settings with a prompt" do
      conn = build_conn()
      {:ok, user} = Portal.Accounts.register_user("pr_frank", @pw)
      {:ok, _user, temp} = Portal.Accounts.set_temporary_password(user)

      conn = post(conn, ~p"/login", %{"username" => "pr_frank", "password" => temp})
      assert redirected_to(conn) == ~p"/settings"

      html = conn |> recycle() |> get(~p"/settings") |> html_response(200)
      assert html =~ ~s(id="password-reset-required")
    end
  end
end
