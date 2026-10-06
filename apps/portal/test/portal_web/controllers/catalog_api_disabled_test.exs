defmodule PortalWeb.CatalogApiDisabledTest do
  use PortalWeb.ConnCase, async: true

  # Disabled 2026-10-06: unused, and an unauthenticated full dump of the
  # catalog. The routes are commented out in the router, not deleted.
  for path <- ["/api/packages", "/api/packages/jason", "/api/stats"] do
    test "#{path} is not routed", %{conn: conn} do
      conn = get(conn, unquote(path))
      assert conn.status == 404
      refute conn.private[:phoenix_controller] == PortalWeb.CatalogApiController
    end
  end

  test "the precompiled API is still routed", %{conn: conn} do
    conn = get(conn, "/api/precompiled/manifests/no_such_package.json")
    assert conn.status == 404
    assert conn.private[:phoenix_controller] == PortalWeb.CatalogApiController
  end

  test "badges are still routed", %{conn: conn} do
    conn = get(conn, "/badge/no_such_package.svg")
    assert conn.private[:phoenix_controller] == PortalWeb.CatalogApiController
  end
end
