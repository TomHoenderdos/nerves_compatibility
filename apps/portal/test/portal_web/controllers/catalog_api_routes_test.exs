defmodule PortalWeb.CatalogApiRoutesTest do
  use PortalWeb.ConnCase, async: true

  # The schema-v2 catalog JSON API, the precompiled API and badges are all
  # served by `CatalogApiController`.
  for path <- [
        "/api/packages",
        "/api/packages/no_such_package",
        "/api/stats",
        "/api/precompiled/manifests/no_such_package.json",
        "/badge/no_such_package.svg"
      ] do
    test "#{path} is routed to the catalog API controller", %{conn: conn} do
      conn = get(conn, unquote(path))
      assert conn.private[:phoenix_controller] == PortalWeb.CatalogApiController
    end
  end
end
