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
