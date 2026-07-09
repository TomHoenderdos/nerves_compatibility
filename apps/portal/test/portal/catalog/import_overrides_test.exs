defmodule Portal.Catalog.ImportOverridesTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog.{ImportOverrides, PackageOverride}

  test "imports package overrides and global dependency skip list from metadata json" do
    path =
      Path.join(System.tmp_dir!(), "package-metadata-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      Jason.encode!(%{
        "skip_if_depends_on" => ["nerves_system_br", "nerves_toolchain_ctng"],
        "packages" => %{
          "nerves" => %{
            "forced_status" => "pass",
            "notes" => "tooling package"
          },
          "example_wifi_package" => %{
            "forced_status" => "skip",
            "allowed_systems" => [],
            "denied_systems" => ["nerves_system_grisp2"],
            "notes" => "requires WiFi"
          }
        }
      })
    )

    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{package_overrides: 2, global_overrides: 1}} = ImportOverrides.import_file(path)

    overrides = Ash.read!(PackageOverride, domain: Portal.Catalog)
    by_name = Map.new(overrides, &{&1.package_name, &1})

    assert by_name["nerves"].forced_status == :pass
    assert by_name["nerves"].notes == "tooling package"
    assert by_name["example_wifi_package"].forced_status == :skipped
    assert by_name["example_wifi_package"].deny_systems == ["nerves_system_grisp2"]

    assert by_name["__global__"].skip_if_depends_on == [
             "nerves_system_br",
             "nerves_toolchain_ctng"
           ]
  end
end
