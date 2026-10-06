defmodule PortalWeb.AdminPasswordResetTest do
  use PortalWeb.ConnCase, async: false

  import Portal.Test.AccountsFixtures, only: [add_test_passkey: 1]

  @pw "correct horse battery staple"

  defp signed_in_admin(conn, fresh? \\ true) do
    {:ok, admin} = Portal.Accounts.seed_admin_user("pr_admin", @pw)
    admin = add_test_passkey(admin)

    session =
      %{user_id: admin.id, login_method: :passkey}
      |> Map.merge(
        if fresh?,
          do: %{reauth_method: :passkey, reauth_at: System.system_time(:second)},
          else: %{}
      )

    init_test_session(conn, session)
  end

  test "the route is closed to anonymous visitors", %{conn: conn} do
    assert redirected_to(post(conn, ~p"/admin/users/reset-password", %{})) == ~p"/login"
  end

  test "a fresh step-up shows the temporary password once, outside the flash", %{conn: conn} do
    {:ok, _} = Portal.Accounts.register_user("pr_frank", @pw)

    conn =
      conn
      |> signed_in_admin()
      |> post(~p"/admin/users/reset-password", %{"username" => "pr_frank"})

    html = html_response(conn, 200)
    assert html =~ ~s(id="temporary-password")
    [_, temp] = Regex.run(~r/id="temporary-password-value"[^>]*>([^<]+)</, html)
    assert {:ok, _} = Portal.Accounts.authenticate_user("pr_frank", String.trim(temp))
    refute Phoenix.Flash.get(conn.assigns.flash, :info) =~ String.trim(temp)
  end

  test "without a fresh step-up it is refused", %{conn: conn} do
    {:ok, _} = Portal.Accounts.register_user("pr_frank", @pw)

    conn =
      conn
      |> signed_in_admin(false)
      |> post(~p"/admin/users/reset-password", %{"username" => "pr_frank"})

    assert redirected_to(conn) == ~p"/settings/security"
    assert {:ok, _} = Portal.Accounts.authenticate_user("pr_frank", @pw)
  end

  test "an unknown username flashes an error", %{conn: conn} do
    html =
      conn
      |> signed_in_admin()
      |> post(~p"/admin/users/reset-password", %{"username" => "pr_nobody"})
      |> html_response(200)

    assert html =~ "No account with that username"
  end

  test "logging in with a temporary password lands on settings with a prompt", %{conn: conn} do
    {:ok, user} = Portal.Accounts.register_user("pr_frank", @pw)
    {:ok, _user, temp} = Portal.Accounts.set_temporary_password(user)

    conn = post(conn, ~p"/login", %{"username" => "pr_frank", "password" => temp})
    assert redirected_to(conn) == ~p"/settings"

    html = conn |> recycle() |> get(~p"/settings") |> html_response(200)
    assert html =~ ~s(id="password-reset-required")
  end
end
