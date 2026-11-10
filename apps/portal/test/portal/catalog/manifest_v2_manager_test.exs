defmodule Portal.Catalog.ManifestV2ManagerTest do
  use Portal.DataCase, async: false

  import Portal.PrecompiledFixtures
  import PortalWeb.ApiSpecAssertions

  alias Portal.Catalog

  defp builds(name) do
    %{"versions" => versions} = Catalog.precompiled_manifest_v2(name)
    versions |> Map.values() |> Enum.flat_map(& &1["builds"])
  end

  defp name, do: "mgr_tc_#{System.unique_integer([:positive])}"

  test "a toolchain build stores and publishes the manager the trace recorded" do
    name = name()
    tb = ingest_toolchain_build(name, "0.3.0", manager: "rebar3")
    assert tb.manager == "rebar3"
    assert [build] = builds(name)
    assert build["build"]["manager"] == "rebar3"
    assert_api_schema(Catalog.precompiled_manifest_v2(name), "ManifestV2")
  end

  test "an unknown or missing manager is stored as nil and renders no key" do
    for manager <- [nil, "cargo", 3] do
      name = name()
      tb = ingest_toolchain_build(name, "0.3.0", manager: manager)
      assert tb.manager == nil
      assert [build] = builds(name)
      refute Map.has_key?(build["build"], "manager"), inspect(manager)
    end
  end
end
