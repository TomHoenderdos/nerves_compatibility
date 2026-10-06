defmodule PortalWeb.PackagePendingTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Portal.ScanRequests
  alias Portal.ScanRequests.ScanRequest

  defp seed_request(name, status, attrs \\ %{}) do
    {:ok, req} =
      ScanRequest
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(%{package_name: name, source: :anonymous_manual, status: status}, attrs)
      )
      |> Ash.create(domain: Portal.ScanRequests)

    req
  end

  test "a queued package has a page saying so, not 'Package not found'", %{conn: conn} do
    req = seed_request("waitingpkg", :queued)

    {:ok, view, _html} = live(conn, ~p"/packages/waitingpkg")

    assert has_element?(view, "#package-pending", "waitingpkg")
    assert has_element?(view, "#package-pending", "Queued")
    assert has_element?(view, ~s(#package-pending a[href="/requests/#{req.id}"]))
    assert has_element?(view, ~s(#package-pending a[href="https://hex.pm/packages/waitingpkg"]))
  end

  test "a failed package says why", %{conn: conn} do
    req = seed_request("brokenpkg", :pending)

    {:ok, _} =
      ScanRequests.set_status(req.id, :error,
        error_reason: "worker/runner exit 1",
        error_log:
          "noise\n** (ErlangError) Erlang error: {:invalid_byte, 130}\n    json.erl:543\n"
      )

    {:ok, view, _html} = live(conn, ~p"/packages/brokenpkg")

    assert has_element?(view, "#package-pending", "Build failed")
    assert has_element?(view, "#package-pending", "invalid_byte, 130")
    refute has_element?(view, "#package-pending", "noise")
  end

  test "the newest request decides the status", %{conn: conn} do
    seed_request("againpkg", :error)
    seed_request("againpkg", :queued)

    {:ok, view, _html} = live(conn, ~p"/packages/againpkg")
    assert has_element?(view, "#package-pending", "Queued")
    refute has_element?(view, "#package-pending", "Build failed")
  end

  test "a rejected-only package is still not found", %{conn: conn} do
    seed_request("nopepkg", :rejected)

    assert {:error, {:live_redirect, %{to: "/packages"}}} = live(conn, ~p"/packages/nopepkg")
  end

  test "an unknown package is still not found", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/packages"}}} = live(conn, ~p"/packages/nosuchpkg")
  end
end
