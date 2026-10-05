defmodule PortalWeb.Admin.ArgusFindingsLiveTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Portal.Test.ArgusFixtures

  setup %{conn: conn} do
    {:ok, admin} = Portal.Accounts.seed_admin_user("triage_admin", "correct horse battery staple")
    Portal.Test.AccountsFixtures.add_test_passkey(admin)
    %{conn: init_test_session(conn, user_id: admin.id, login_method: :passkey), admin: admin}
  end

  test "anonymous visitors are sent to login" do
    assert redirected_to(get(build_conn(), ~p"/admin/argus/findings")) == ~p"/login"
  end

  test "an admin signed in with a password is refused", %{admin: admin} do
    conn = build_conn() |> init_test_session(user_id: admin.id, login_method: :password)
    assert redirected_to(get(conn, ~p"/admin/argus/findings")) == ~p"/settings/security"
  end

  test "a signed-in non-admin is refused" do
    {:ok, user} = Portal.Accounts.register_user("triage_viewer", "correct horse battery staple")
    conn = build_conn() |> init_test_session(user_id: user.id, login_method: :password)
    assert redirected_to(get(conn, ~p"/admin/argus/findings")) == ~p"/request-scan"
  end

  test "lists findings with counts", %{conn: conn} do
    ingest("1.0.0", ok([finding()]), 1)
    {:ok, view, _} = live(conn, ~p"/admin/argus/findings")
    assert has_element?(view, "#findings", "Catch-all rescue swallows exceptions")
    assert has_element?(view, "#triage-counts", "1 new")
  end

  test "changing a status saves it and updates the counts", %{conn: conn} do
    ingest("1.0.0", ok([finding()]), 1)
    [%{triage: row}] = Portal.Catalog.triage_list(%{})
    {:ok, view, _} = live(conn, ~p"/admin/argus/findings")

    view
    |> form("#triage-form-#{row.id}", triage: %{status: "confirmed", note: "real bug"})
    |> render_change()

    [%{triage: saved}] = Portal.Catalog.triage_list(%{})

    assert {saved.status, saved.note, saved.updated_by} ==
             {:confirmed, "real bug", "triage_admin"}

    assert has_element?(view, "#triage-counts", "1 confirmed")
  end

  test "filters patch the URL", %{conn: conn} do
    ingest("1.0.0", ok([finding()]), 1)
    {:ok, view, _} = live(conn, ~p"/admin/argus/findings")

    view |> form("#triage-filters", f: %{package: "nope"}) |> render_change()
    assert_patch(view, ~p"/admin/argus/findings?#{%{package: "nope"}}")
    refute has_element?(view, "#findings", "Catch-all")
  end

  test "status and severity are checkbox groups that show every choice", %{conn: conn} do
    ingest("1.0.0", ok([finding()]), 1)
    [%{triage: row}] = Portal.Catalog.triage_list(%{})
    Portal.Catalog.triage!(row.id, %{status: "false_positive", note: nil}, %{username: "tom"})

    {:ok, view, _} = live(conn, ~p"/admin/argus/findings")
    assert has_element?(view, "#filter-status-new[checked]")
    refute has_element?(view, "#filter-status-false_positive[checked]")
    assert has_element?(view, "#filter-severity-info[checked]")
    refute has_element?(view, "#findings", "Catch-all")

    view
    |> form("#triage-filters", f: %{status: ["new", "confirmed", "false_positive"]})
    |> render_change()

    assert_patch(view, ~p"/admin/argus/findings?#{%{status: ~w(new confirmed false_positive)}}")
    assert has_element?(view, "#filter-status-false_positive[checked]")
    assert has_element?(view, "#findings", "Catch-all")
  end

  test "a list longer than the cap says how many it shows", %{conn: conn} do
    ingest("1.0.0", ok(for(i <- 1..3, do: finding(%{"detail" => "d#{i}"}))), 1)
    previous = Application.get_env(:portal, PortalWeb.Admin.ArgusFindingsLive, [])
    Application.put_env(:portal, PortalWeb.Admin.ArgusFindingsLive, page_limit: 2)
    on_exit(fn -> Application.put_env(:portal, PortalWeb.Admin.ArgusFindingsLive, previous) end)

    {:ok, view, _} = live(conn, ~p"/admin/argus/findings")
    assert has_element?(view, "#triage-shown", "Showing 2 of 3")
  end

  test "stale findings show only with the filter", %{conn: conn} do
    ingest("1.0.0", ok([finding(), finding(%{"detail" => "gone later", "title" => "Gone"})]), 1)
    ingest("1.1.0", ok([finding()]), 2)

    {:ok, view, _} = live(conn, ~p"/admin/argus/findings")
    refute has_element?(view, "#findings", "Gone")

    {:ok, view, _} = live(conn, ~p"/admin/argus/findings?stale=true")
    assert has_element?(view, "#findings", "Gone")
    assert has_element?(view, "#findings", "no longer seen")
  end

  test "the admin page links to the list", %{conn: conn} do
    assert html_response(get(conn, ~p"/admin"), 200) =~ ~s(href="/admin/argus/findings")
  end
end
