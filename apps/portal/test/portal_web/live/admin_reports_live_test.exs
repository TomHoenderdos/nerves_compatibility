defmodule PortalWeb.Admin.ReportsLiveTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Portal.Test.AccountsFixtures, only: [add_test_passkey: 1]
  import Portal.Test.ReportFixtures

  @pw "correct horse battery staple"

  setup %{conn: conn} do
    {:ok, admin} = Portal.Accounts.seed_admin_user("reports_admin", @pw)
    admin = add_test_passkey(admin)
    %{conn: init_test_session(conn, user_id: admin.id, login_method: :passkey), admin: admin}
  end

  defp live_reports(conn, path \\ ~p"/admin/reports") do
    {:ok, view, _html} = live(conn, path)
    {view, render_async(view)}
  end

  defp rows(html, id) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query("##{id} tbody tr[data-item-id]")
  end

  test "the reports tab is marked current", %{conn: conn} do
    {view, _html} = live_reports(conn)
    assert has_element?(view, ~s(#admin-tabs a[aria-current="page"][href="/admin/reports"]))
  end

  test "a password-only admin and a non-admin are refused", %{admin: admin} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/admin/reports")

    conn = build_conn() |> init_test_session(user_id: admin.id, login_method: :password)
    assert {:error, {:redirect, %{to: "/settings/security"}}} = live(conn, ~p"/admin/reports")

    {:ok, user} = Portal.Accounts.register_user("plain_reports_viewer", @pw)
    conn = build_conn() |> init_test_session(user_id: user.id, login_method: :password)
    assert {:error, {:redirect, %{to: "/request-scan"}}} = live(conn, ~p"/admin/reports")
  end

  test "an empty table says so", %{conn: conn} do
    {_view, html} = live_reports(conn)
    assert html =~ "No reports yet."
    assert html =~ "No reports in the last 30 days."
  end

  test "lists recent reports with client, target and counts", %{conn: conn} do
    record!(
      %{
        "client" => "0.5.0",
        "target" => "rpi4",
        "lines" => [
          line("jason", "1.4.5", "miss", "not_built_version", ["1.4.5"]),
          line("circuits_uart", "1.5.1", "fail", "fetch_failed", [])
        ]
      },
      reporter_key: "rk1"
    )

    {_view, html} = live_reports(conn)
    row = rows(html, "reports-table") |> LazyHTML.text()
    assert row =~ "0.5.0"
    assert row =~ "rpi4"
  end

  test "opening a report shows its lines and each one's requeue eligibility", %{conn: conn} do
    report_id =
      record!(
        %{
          "client" => "0.5.1",
          "lines" => [
            line("jason", "1.4.5", "miss", "not_built_version", ["1.4.5"]),
            line("circuits_uart", "1.5.1", "fail", "fetch_failed", [])
          ]
        },
        reporter_key: "rk2"
      )

    {view, _html} = live_reports(conn)

    view
    |> element("#report-view-#{report_id}")
    |> render_click()

    assert_patch(view, ~p"/admin/reports?report=#{report_id}")

    html = render(view)
    assert html =~ "Report lines"
    assert html =~ "jason"
    assert html =~ "not_built_version"
    # In `Portal.Reports.Requeue.codes/0`, so an undecided line still waits.
    assert html =~ "pending"
    assert html =~ "circuits_uart"
    assert html =~ "fetch_failed"
    # Not in `codes/0`: this line is never decided.
    assert html =~ "not eligible"
  end

  test "an id nobody has, or that is not a UUID, shows the list with nothing selected",
       %{conn: conn} do
    {_view, html} = live_reports(conn, ~p"/admin/reports?report=#{Ecto.UUID.generate()}")
    refute html =~ "Report lines"

    {_view, html} = live_reports(conn, ~p"/admin/reports?report=not-a-uuid")
    refute html =~ "Report lines"
  end

  test "contact and the reporter key never reach the page", %{conn: conn} do
    report_id =
      record!(
        %{
          "contact" => "secret@example.com",
          "lines" => [line("jason", "1.4.5", "miss", "not_built_version", ["1.4.5"])]
        },
        reporter_key: "rk3-secret"
      )

    {view, html} = live_reports(conn)
    refute html =~ "secret@example.com"
    refute html =~ "rk3-secret"

    view
    |> element("#report-view-#{report_id}")
    |> render_click()

    html = render(view)
    refute html =~ "secret@example.com"
    refute html =~ "rk3-secret"
  end

  test "the reason-code summary totals lines across reports", %{conn: conn} do
    record!(
      %{"lines" => [line("jason", "1.4.5", "miss", "not_built_version", ["1.4.5"])]},
      reporter_key: "rk4"
    )

    record!(
      %{"lines" => [line("plug", "1.4.0", "miss", "not_built_version", ["1.4.0"])]},
      reporter_key: "rk5"
    )

    {_view, html} = live_reports(conn)

    row =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#reason-not_built_version")
      |> LazyHTML.text()

    assert row =~ "not_built_version"
    assert row =~ "2"
  end
end
