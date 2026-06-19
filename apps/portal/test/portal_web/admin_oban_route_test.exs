defmodule PortalWeb.AdminObanRouteTest do
  use PortalWeb.ConnCase, async: false

  test "GET /admin/oban redirects to login when not signed in", %{conn: conn} do
    conn = get(conn, ~p"/admin/oban")
    assert redirected_to(conn) == ~p"/login"
  end

  test "GET /admin/oban redirects non-admin user away", %{conn: conn} do
    {:ok, user} =
      Portal.Accounts.register_user("oban_nonadmin", "correct horse battery staple")

    conn =
      conn
      |> init_test_session(%{})
      |> put_session(:user_id, user.id)
      |> get(~p"/admin/oban")

    assert redirected_to(conn) == ~p"/request-scan"
  end

  test "GET /admin/oban passes admin auth (does not redirect) for an admin", %{conn: conn} do
    {:ok, admin} =
      Portal.Accounts.seed_admin_user("oban_admin_user", "correct horse battery staple")

    # Oban Web's dashboard LiveView requires Oban.Met to be running, which is
    # disabled under `Oban, testing: :manual`. We only care here that admin
    # auth lets the request through — we don't try to render the dashboard.
    try do
      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:user_id, admin.id)
        |> get(~p"/admin/oban")

      refute redirected_to(conn) in [~p"/login", ~p"/request-scan"]
    rescue
      RuntimeError -> :ok
    end
  end
end
