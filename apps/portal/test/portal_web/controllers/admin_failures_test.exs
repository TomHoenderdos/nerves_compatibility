defmodule PortalWeb.AdminFailuresTest do
  use PortalWeb.ConnCase, async: false

  import Portal.Test.AccountsFixtures, only: [add_test_passkey: 1]

  alias Portal.ScanRequests

  defp signed_in_admin(conn) do
    {:ok, admin} = Portal.Accounts.seed_admin_user("fail_admin", "correct horse battery staple")
    init_test_session(conn, user_id: add_test_passkey(admin).id, login_method: :passkey)
  end

  defp failed(package, log) do
    {:ok, request} =
      ScanRequests.create_once(%{
        package_name: package,
        source: :anonymous_manual,
        status: :pending
      })

    {:ok, request} =
      ScanRequests.set_status(request.id, :error,
        error_reason: "worker/runner exit 1",
        error_log: log
      )

    request
  end

  test "recent_failures/1 lists errored requests newest first, with a summary" do
    failed("older_pkg", "** (RuntimeError) older\n")
    failed("newer_pkg", "** (ErlangError) {:invalid_byte, 130}\n    json.erl:543\n")

    assert [%{package_name: "newer_pkg", summary: summary}, %{package_name: "older_pkg"}] =
             ScanRequests.recent_failures(10)

    assert summary =~ "invalid_byte"
  end

  test "recent_failures/1 respects its limit" do
    for n <- 1..3, do: failed("pkg_#{n}", "** (RuntimeError) boom\n")
    assert [_, _] = ScanRequests.recent_failures(2)
  end

  test "the admin page shows recent failures linked to their request", %{conn: conn} do
    request = failed("max_31856", "** (ErlangError) {:invalid_byte, 130}\n")

    html = conn |> signed_in_admin() |> get(~p"/admin/failures") |> html_response(200)

    assert html =~ ~s(id="recent-failures")
    assert html =~ "max_31856"
    assert html =~ "invalid_byte, 130"
    assert html =~ ~s(href="/requests/#{request.id}")
  end
end
