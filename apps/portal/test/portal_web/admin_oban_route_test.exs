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

    # An admin without a passkey is redirected to `/settings/security`, which
    # would slip past the `refute` below without ever reaching the dashboard.
    Portal.Test.AccountsFixtures.add_test_passkey(admin)

    # Oban Web's dashboard LiveView requires Oban.Met, which is not running
    # under `Oban, testing: :manual`, so the render raises. Reaching that raise
    # *is* the pass: every gate — the `:admin` pipeline and the `on_mount` hook
    # — has already let the request through by then. The rescue asserts on the
    # message rather than swallowing any `RuntimeError`, so an unrelated crash
    # cannot masquerade as a successful admission.
    try do
      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:user_id, admin.id)
        |> put_session(:login_method, :passkey)
        |> get(~p"/admin/oban")

      refute redirected_to(conn) in [~p"/login", ~p"/request-scan", ~p"/settings/security"]
    rescue
      error in RuntimeError -> assert Exception.message(error) =~ "Oban.Met"
    end
  end

  # The pipeline runs on the dead render and never again: a LiveView reconnect
  # is authenticated by the signed session token from that render, which
  # LiveView honours for up to 14 days. This assertion is what makes the
  # `on_mount/4` tests in `PortalWeb.Plugs.RequireAdminTest` load-bearing —
  # drop the `:on_mount` option from `oban_dashboard/2` and they still pass,
  # while this fails.
  test "every /admin/oban live route re-checks the policy on mount" do
    live_routes =
      PortalWeb.Router.__routes__()
      |> Enum.filter(&String.starts_with?(&1.path, "/admin/oban"))
      |> Enum.filter(
        &match?(
          {_view, _action, _opts, %{extra: %{on_mount: _}}},
          &1.metadata[:phoenix_live_view]
        )
      )

    assert live_routes != []

    for route <- live_routes do
      {_view, _action, _opts, %{extra: %{on_mount: hooks}}} = route.metadata.phoenix_live_view
      ids = Enum.map(hooks, & &1.id)

      assert {PortalWeb.Plugs.RequireAdmin, :require_admin_passkey} in ids,
             "#{route.path} mounts without re-checking the admin passkey policy"

      # Oban's own hook falls back to `:all` access for everyone, so ours has
      # to decide first or a refusal never happens.
      assert Enum.find_index(ids, &(&1 == {PortalWeb.Plugs.RequireAdmin, :require_admin_passkey})) <
               Enum.find_index(ids, &(&1 == {Oban.Web.Authentication, :default})),
             "#{route.path} runs Oban's hook before ours"
    end
  end
end
