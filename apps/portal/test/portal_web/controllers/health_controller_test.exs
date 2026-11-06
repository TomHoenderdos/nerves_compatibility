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

  describe "build_sha/1" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "health-build-sha-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "the file present gives the trimmed sha", %{dir: dir} do
      File.write!(Path.join(dir, "BUILD_SHA"), "abc123\n")
      assert HealthController.build_sha(dir) == "abc123"
    end

    test "a missing file gives nil", %{dir: dir} do
      assert HealthController.build_sha(dir) == nil
    end

    test "an empty file gives nil", %{dir: dir} do
      File.write!(Path.join(dir, "BUILD_SHA"), "")
      assert HealthController.build_sha(dir) == nil
    end
  end
end
