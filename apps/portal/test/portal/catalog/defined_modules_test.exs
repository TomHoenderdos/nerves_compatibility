defmodule Portal.Catalog.DefinedModulesTest do
  # S10 fix round 1: a passing toolchain build's modules its compile defined
  # outside its ebin (`NccWorker.Portability.DefinedModules`), stored and
  # served in format 2 beside the ebin, so client 0.10 reads a dependency's
  # exact module list.
  use Portal.DataCase, async: false

  import Portal.PrecompiledFixtures
  import PortalWeb.ApiSpecAssertions

  alias Portal.Catalog

  defp name, do: "dm_tc_#{System.unique_integer([:positive])}"

  test "a pass stores the list and format 2 serves it beside the ebin" do
    name = name()
    list = ["Elixir.Pkg.MixHelper", "Elixir.Pkg.MixProject"]
    tb = ingest_toolchain_build(name, "0.3.0", defined_modules: list)
    assert tb.defined_modules == list

    manifest = Catalog.precompiled_manifest_v2(name)
    assert [entry] = manifest["versions"]["0.3.0"]["builds"]
    assert entry["build"]["defined_modules"] == list
    assert [%{"path" => "ebin/" <> _}] = entry["ebin"]
    assert_api_schema(manifest, "ManifestV2")

    # An empty list is a list: the ebin is the whole module set.
    other = name()
    ingest_toolchain_build(other, "0.3.0", defined_modules: [])
    [entry] = Catalog.precompiled_manifest_v2(other)["versions"]["0.3.0"]["builds"]
    assert entry["build"]["defined_modules"] == []
  end

  test "no list, a malformed one or a skipped build is no list: the key is left out" do
    for {opts, label} <- [
          {[], "absent"},
          {[defined_modules: nil], "nil"},
          {[defined_modules: ["Elixir.Bad Name"]], "bad name"},
          {[defined_modules: ["Elixir.B", "Elixir.A"]], "unsorted"},
          {[defined_modules: ["Elixir.A", "Elixir.A"]], "repeated"},
          {[defined_modules: "Elixir.A"], "not a list"}
        ] do
      name = name()
      tb = ingest_toolchain_build(name, "0.3.0", opts)
      assert tb.defined_modules == nil, label
      [entry] = Catalog.precompiled_manifest_v2(name)["versions"]["0.3.0"]["builds"]
      refute Map.has_key?(entry["build"], "defined_modules"), label
    end

    skipped = ingest_toolchain_build(name(), "0.3.0", status: "skipped", defined_modules: [])
    assert skipped.defined_modules == nil
  end
end
