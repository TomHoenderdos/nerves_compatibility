defmodule PortalWeb.AdminRolesControllerTest do
  use PortalWeb.ConnCase, async: false

  import Portal.Test.AccountsFixtures, only: [add_test_passkey: 1]

  @pw "correct horse battery staple"

  # An admin signed in with a passkey; `fresh?` adds a step-up made just now.
  defp signed_in_admin(conn, username, fresh? \\ true) do
    {:ok, admin} = Portal.Accounts.seed_admin_user(username, @pw)
    admin = add_test_passkey(admin)

    session =
      %{user_id: admin.id, login_method: :passkey}
      |> Map.merge(
        if fresh?,
          do: %{reauth_method: :passkey, reauth_at: System.system_time(:second)},
          else: %{}
      )

    {init_test_session(conn, session), admin}
  end

  test "the routes are closed to anonymous visitors", %{conn: conn} do
    for path <- [~p"/admin/admins", ~p"/admin/admins/#{Ecto.UUID.generate()}/revoke"] do
      assert redirected_to(post(recycle(conn), path)) == ~p"/login"
    end
  end

  test "the admin page lists admins and flags a missing passkey", %{conn: conn} do
    {conn, _admin} = signed_in_admin(conn, "ctl_actor")
    {:ok, _} = Portal.Accounts.seed_admin_user("ctl_nopasskey", @pw)

    html = html_response(get(conn, ~p"/admin/users"), 200)
    assert html =~ ~s(id="admin-users")
    assert html =~ "ctl_actor"
    assert html =~ "ctl_nopasskey"
    assert html =~ "needs a passkey"
  end

  test "granting with a fresh step-up makes the user an admin", %{conn: conn} do
    {conn, _admin} = signed_in_admin(conn, "ctl_actor")
    {:ok, _} = Portal.Accounts.register_user("ctl_frank", @pw)

    html = conn |> post(~p"/admin/admins", %{"username" => "ctl_frank"}) |> html_response(200)

    assert html =~ "ctl_frank is now an admin"
    assert {:ok, %{is_admin: true}} = Portal.Accounts.get_user_by_username("ctl_frank")
  end

  test "granting without a fresh step-up is refused", %{conn: conn} do
    {conn, _admin} = signed_in_admin(conn, "ctl_actor", false)
    {:ok, _} = Portal.Accounts.register_user("ctl_frank", @pw)

    conn = post(conn, ~p"/admin/admins", %{"username" => "ctl_frank"})

    assert redirected_to(conn) == ~p"/settings/security"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Confirm"
    assert {:ok, %{is_admin: false}} = Portal.Accounts.get_user_by_username("ctl_frank")
  end

  test "a stale step-up older than the window is refused", %{conn: conn} do
    {conn, _admin} = signed_in_admin(conn, "ctl_actor", false)

    conn =
      conn
      |> put_session(:reauth_method, :passkey)
      |> put_session(:reauth_at, System.system_time(:second) - 601)

    {:ok, _} = Portal.Accounts.register_user("ctl_frank", @pw)

    assert redirected_to(post(conn, ~p"/admin/admins", %{"username" => "ctl_frank"})) ==
             ~p"/settings/security"
  end

  test "an unknown username flashes an error", %{conn: conn} do
    {conn, _admin} = signed_in_admin(conn, "ctl_actor")
    html = conn |> post(~p"/admin/admins", %{"username" => "ctl_nobody"}) |> html_response(200)
    assert html =~ "No account with that username"
  end

  test "revoking another admin with a fresh step-up", %{conn: conn} do
    {conn, _admin} = signed_in_admin(conn, "ctl_actor")
    {:ok, other} = Portal.Accounts.seed_admin_user("ctl_other", @pw)

    html = conn |> post(~p"/admin/admins/#{other.id}/revoke") |> html_response(200)

    assert html =~ "ctl_other is no longer an admin"
    assert {:ok, %{is_admin: false}} = Portal.Accounts.get_user_by_username("ctl_other")
  end

  test "revoking yourself is refused", %{conn: conn} do
    {conn, admin} = signed_in_admin(conn, "ctl_actor")
    {:ok, _} = Portal.Accounts.seed_admin_user("ctl_other", @pw)

    html = conn |> post(~p"/admin/admins/#{admin.id}/revoke") |> html_response(200)

    assert html =~ "You cannot remove your own admin access"
    assert {:ok, %{is_admin: true}} = Portal.Accounts.get_user_by_username("ctl_actor")
  end
end
