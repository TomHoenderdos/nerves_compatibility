defmodule PortalWeb.ArgusExportControllerTest do
  use PortalWeb.ConnCase, async: false

  import Portal.Test.ArgusFixtures
  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    {:ok, admin} = Portal.Accounts.seed_admin_user("export_admin", "correct horse battery staple")
    Portal.Test.AccountsFixtures.add_test_passkey(admin)
    %{conn: init_test_session(conn, user_id: admin.id, login_method: :passkey), admin: admin}
  end

  defp lines(conn),
    do: conn.resp_body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  test "anonymous visitors are sent to login" do
    assert redirected_to(get(build_conn(), ~p"/admin/argus/export.ndjson")) == ~p"/login"
  end

  test "an admin signed in with a password is refused", %{admin: admin} do
    conn = build_conn() |> init_test_session(user_id: admin.id, login_method: :password)
    assert redirected_to(get(conn, ~p"/admin/argus/export.ndjson")) == ~p"/settings/security"
  end

  test "streams one JSON line per run as a download", %{conn: conn} do
    ingest("1.0.0", ok([finding()]), 1)
    ingest("2.0.0", ok([]), 2, "otherpkg")

    conn = get(conn, ~p"/admin/argus/export.ndjson")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/x-ndjson"

    assert get_resp_header(conn, "content-disposition") |> hd() =~
             ~s(attachment; filename="argus-latest-)

    assert [%{"package" => "tripkg"}, %{"package" => "otherpkg"}] = lines(conn)
  end

  test "scope and since are read from the query string", %{conn: conn} do
    ingest("1.0.0", ok([finding()]), 1)
    ingest("1.1.0", ok([finding()]), 30)

    assert [_, _] = conn |> get(~p"/admin/argus/export.ndjson?scope=all") |> lines()

    assert [%{"package_version" => "1.1.0"}] =
             conn
             |> get(~p"/admin/argus/export.ndjson?scope=all&since=2026-10-01T20:00:00Z")
             |> lines()
  end

  test "an unparseable since is a 400, not a crash", %{conn: conn} do
    conn = get(conn, ~p"/admin/argus/export.ndjson?since=yesterday")
    assert conn.status == 400
  end

  test "the triage page links to the export", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/admin/argus/findings")
    assert has_element?(view, ~s(a[href="/admin/argus/export.ndjson"]))
    assert has_element?(view, ~s(a[href="/admin/argus/export.ndjson?scope=all"]))
  end
end
