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
end
