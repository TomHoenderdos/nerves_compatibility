defmodule PortalWeb.AdminSectionsTest do
  use PortalWeb.ConnCase, async: false

  import Portal.Test.AccountsFixtures, only: [add_test_passkey: 1]

  @pw "correct horse battery staple"
  @tabs [
    {"/admin", "Overview"},
    {"/admin/queue", "Queue"},
    {"/admin/users", "Users"},
    {"/admin/failures", "Failures"},
    {"/admin/argus", "Argus"},
    {"/admin/maintenance", "Maintenance"}
  ]

  setup %{conn: conn} do
    {:ok, admin} = Portal.Accounts.seed_admin_user("sec_admin", @pw)
    admin = add_test_passkey(admin)
    %{conn: init_test_session(conn, user_id: admin.id, login_method: :passkey), admin: admin}
  end

  test "every admin section renders with the shared tabs, marking itself", %{conn: conn} do
    for {path, label} <- @tabs do
      html = conn |> get(path) |> html_response(200)

      for {tab_path, _} <- @tabs do
        assert html =~ ~s(href="#{tab_path}"), "#{path} lacks a tab to #{tab_path}"
      end

      assert html =~ ~r/aria-current="page"[^>]*>\s*#{label}/, "#{path} does not mark #{label}"
    end
  end

  test "the overview links each section with its numbers", %{conn: conn} do
    html = conn |> get(~p"/admin") |> html_response(200)

    assert html =~ ~s(id="admin-overview")
    assert html =~ "Needs review"
    assert html =~ "Current queue"
    assert html =~ "Recent failures"
    assert html =~ ~s(href="/admin/argus/findings")
  end

  test "sections hold what used to share one page", %{conn: conn} do
    assert conn |> get(~p"/admin/queue") |> html_response(200) =~ "Queue a scan"
    assert conn |> get(~p"/admin/queue") |> html_response(200) =~ "Anonymous approvals"
    assert conn |> get(~p"/admin/failures") |> html_response(200) =~ ~s(id="recent-failures")
    assert conn |> get(~p"/admin/argus") |> html_response(200) =~ ~s(id="argus-settings")
    assert conn |> get(~p"/admin/maintenance") |> html_response(200) =~ "hex.pm update check"
    refute conn |> get(~p"/admin") |> html_response(200) =~ "Queue a scan"
  end

  test "the users page lists every account with per-user actions", %{conn: conn, admin: admin} do
    {:ok, frank} = Portal.Accounts.register_user("sec_frank", @pw)
    {:ok, other} = Portal.Accounts.seed_admin_user("sec_other", @pw)

    html = conn |> get(~p"/admin/users") |> html_response(200)

    assert html =~ ~s(id="user-#{frank.id}")
    assert html =~ ~s(id="user-#{other.id}")
    assert html =~ ~s(id="user-#{admin.id}")

    # A plain user can be made admin or get a temporary password.
    assert html =~ ~r/id="user-#{frank.id}".*?name="username" value="sec_frank"/s
    assert html =~ ~s(action="/admin/admins")
    assert html =~ ~s(action="/admin/users/reset-password")
    # Another admin can be revoked; you cannot revoke or reset yourself here.
    assert html =~ ~s(action="/admin/admins/#{other.id}/revoke")
    refute html =~ ~s(action="/admin/admins/#{admin.id}/revoke")
    assert html =~ "needs a passkey"
  end

  test "the users table says whether a password is set", %{conn: conn} do
    {:ok, _} =
      Portal.Accounts.Identities.sign_in(%Portal.Accounts.Identity{
        provider: :hex,
        uid: "nopw",
        username: "nopw",
        profile: %{}
      })

    body = conn |> get(~p"/admin/users") |> html_response(200)
    assert body =~ ~r/id="user-[^"]+"[\s\S]*nopw[\s\S]*No password/
  end

  test "resetting from the users page shows the password there", %{conn: conn} do
    {:ok, _} = Portal.Accounts.register_user("sec_frank", @pw)

    html =
      conn
      |> put_session(:reauth_method, :passkey)
      |> put_session(:reauth_at, System.system_time(:second))
      |> post(~p"/admin/users/reset-password", %{"username" => "sec_frank"})
      |> html_response(200)

    assert html =~ ~s(id="temporary-password")
    assert html =~ ~s(id="admin-users")
  end

  test "queue pagination links stay on the queue section", %{conn: conn} do
    for n <- 1..60 do
      {:ok, _} =
        Portal.ScanRequests.ScanRequest
        |> Ash.Changeset.for_create(:create, %{
          package_name: "pg_pkg_#{n}",
          source: :anonymous_manual,
          status: :accepted
        })
        |> Ash.create(domain: Portal.ScanRequests)
    end

    html = conn |> get(~p"/admin/queue") |> html_response(200)
    assert html =~ ~s(href="/admin/queue?queue_page=2)
  end
end
