defmodule Compat.Index.LatestByPackageTest do
  use ExUnit.Case, async: true

  alias Compat.Index.LatestByPackage

  describe "load/1" do
    test "loads valid example data" do
      # Navigate from test/compat/index to project root (4 levels up)
      path = Path.expand("../../../../example_data/latest_by_pkg.json", __DIR__)

      assert {:ok, index} = LatestByPackage.load(path)
      assert index.schema == 2
      assert is_binary(index.generated_at)
      assert is_map(index.packages)
      assert map_size(index.packages) > 0
    end

    test "returns error for non-existent file" do
      assert {:error, :enoent} = LatestByPackage.load("/nonexistent/file.json")
    end
  end

  describe "parse/1" do
    test "parses valid data structure" do
      data = %{
        "schema" => 2,
        "generated_at" => "2025-12-23T10:30:00Z",
        "packages" => %{
          "test_pkg" => %{
            "description" => "Test package",
            "latest_version" => "1.0.0",
            "last_run_at" => "2025-12-23T09:00:00Z",
            "systems" => %{
              "nerves_system_rpi4@1.26.1" => %{
                "system_pkg" => "nerves_system_rpi4",
                "system_version" => "1.26.1",
                "status" => "pass",
                "hex_version_tested" => "1.0.0",
                "run_id" => "run_001",
                "log_path" => "logs/test.log"
              }
            }
          }
        }
      }

      assert {:ok, index} = LatestByPackage.parse(data)
      assert index.schema == 2
      assert index.generated_at == "2025-12-23T10:30:00Z"
      assert Map.has_key?(index.packages, "test_pkg")

      pkg = index.packages["test_pkg"]
      assert pkg.description == "Test package"
      assert pkg.latest_version == "1.0.0"

      sys_result = pkg.systems["nerves_system_rpi4@1.26.1"]
      assert sys_result.status == :pass
      assert sys_result.system_pkg == "nerves_system_rpi4"
    end

    test "returns error for invalid schema" do
      assert {:error, :invalid_schema} = LatestByPackage.parse(%{})
      assert {:error, :invalid_schema} = LatestByPackage.parse(%{"schema" => "wrong"})
    end
  end
end
