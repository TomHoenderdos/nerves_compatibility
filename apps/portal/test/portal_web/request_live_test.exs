defmodule PortalWeb.RequestLiveTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Portal.ScanRequests

  test "request live renders the Beacon status page", %{conn: conn} do
    {:ok, request} =
      ScanRequests.create_once(%{
        package_name: "vintage_net",
        source: :anonymous_manual,
        status: :pending,
        subject: "tester"
      })

    {:ok, _view, html} = live(conn, ~p"/requests/#{request.id}")

    assert html =~ "vintage_net"
    assert html =~ "Scan request"
    assert html =~ "Build progress"
    assert html =~ ~s(id="request-status")
  end

  test "request live shows status and updates when build progress broadcasts", %{conn: conn} do
    {:ok, request} =
      ScanRequests.create_once(%{
        package_name: "jason",
        version: "1.4.1",
        source: :hex_owner,
        status: :queued
      })

    {:ok, view, html} = live(conn, "/requests/#{request.id}")
    assert html =~ "jason"
    assert html =~ "queued"

    {:ok, _request} = ScanRequests.set_status(request, :built)

    Phoenix.PubSub.broadcast(
      Portal.PubSub,
      "request:#{request.id}",
      {:build_progress, :done, %{status: :pass}}
    )

    assert render(view) =~ "built"
    assert render(view) =~ "pass"
  end

  test "request live displays error log when build fails", %{conn: conn} do
    {:ok, request} =
      ScanRequests.create_once(%{
        package_name: "failing_package",
        source: :anonymous_manual,
        status: :pending
      })

    {:ok, _} =
      ScanRequests.set_status(request.id, :error,
        error_reason: "worker/runner exit 10",
        error_log: "== Compilation error in file lib/x.ex ==\n"
      )

    {:ok, view, _html} = live(conn, ~p"/requests/#{request.id}")

    assert has_element?(view, "#request-error-log", "Compilation error")
    assert has_element?(view, "#request-error-log", "worker/runner exit 10")
  end
end
