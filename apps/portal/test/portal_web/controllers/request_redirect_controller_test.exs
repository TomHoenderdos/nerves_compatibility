defmodule PortalWeb.RequestRedirectControllerTest do
  use PortalWeb.ConnCase, async: true

  alias Portal.ScanRequests.ScanRequest

  # `/requests/:id` was a page of its own; the package page took it over, and
  # links already out in the world now land there.
  test "a request id redirects to its package page", %{conn: conn} do
    {:ok, request} =
      ScanRequest
      |> Ash.Changeset.for_create(:create, %{
        package_name: "redirectpkg",
        source: :anonymous_manual,
        status: :queued
      })
      |> Ash.create(domain: Portal.ScanRequests)

    conn = get(conn, ~p"/requests/#{request.id}")

    assert redirected_to(conn, 302) == "/packages/redirectpkg"
  end

  test "an unknown request id goes to the package list", %{conn: conn} do
    conn = get(conn, ~p"/requests/#{Ecto.UUID.generate()}")

    assert redirected_to(conn, 302) == "/packages"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Request not found"
  end

  test "a malformed request id goes to the package list", %{conn: conn} do
    conn = get(conn, "/requests/not-a-uuid")

    assert redirected_to(conn, 302) == "/packages"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Request not found"
  end
end
