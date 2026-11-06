defmodule PortalWeb.HealthControllerTest do
  use PortalWeb.ConnCase, async: true

  alias PortalWeb.HealthController

  test "GET /health answers JSON without a session, CSRF or https header", %{conn: conn} do
    body = conn |> get("/health") |> json_response(200)
    assert Map.keys(body) |> Enum.sort() == ["builder_endpoint", "color", "sha"]
    assert body["builder_endpoint"] in ["bound", "off", "waiting"]
    assert is_nil(body["sha"]) or is_binary(body["sha"])
  end

  test "the colour comes from the node name" do
    assert HealthController.color(:portal_blue@host) == "blue"
    assert HealthController.color(:"portal_green@h.example.test") == "green"
    assert HealthController.color(:portal@host) == nil
    assert HealthController.color(:nonode@nohost) == nil
  end
end
