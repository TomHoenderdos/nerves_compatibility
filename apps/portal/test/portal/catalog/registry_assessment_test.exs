defmodule Portal.Catalog.RegistryAssessmentTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog.RegistryAssessment

  test "records a registry_deps pass the catalog reads like any run" do
    assert {:ok, run} = RegistryAssessment.record("tiny_pure", "1.2.0", nil)
    assert run.overall_status == :pass
    assert run.image_digest == "registry"
    assert run.run_id == "registry-tiny_pure-1.2.0"

    %{packages: %{"tiny_pure" => package}} = Portal.Catalog.latest_by_pkg_json("tiny_pure")
    assert package.native_components["compatibility_basis"] == "registry_deps"

    # `latest_by_pkg_json/1` keys `systems` by `"#{system_pkg}@#{system_version}"`
    # (see `Portal.Catalog.system_key/1`); a registry assessment carries no
    # `system_version`, so the key isn't the bare string `"registry_deps"`.
    # Assert on the single value's fields instead — same intent (one system,
    # named `registry_deps`, passing) without depending on that key format.
    assert [system] = Map.values(package.systems)
    assert system.system_pkg == "registry_deps"
    assert system.status == "pass"

    assert Portal.Catalog.precompiled_manifest("tiny_pure") == nil
  end

  test "recording the same version twice returns the existing run" do
    assert {:ok, first} = RegistryAssessment.record("tiny_pure", "1.2.0", nil)
    assert {:ok, second} = RegistryAssessment.record("tiny_pure", "1.2.0", nil)
    assert first.id == second.id
  end

  test "a new version adds a run and becomes the latest" do
    assert {:ok, _} = RegistryAssessment.record("tiny_pure", "1.2.0", nil)
    assert {:ok, _} = RegistryAssessment.record("tiny_pure", "1.3.0", nil)

    %{packages: %{"tiny_pure" => package}} = Portal.Catalog.latest_by_pkg_json("tiny_pure")
    assert package.latest_version == "1.3.0"
  end
end
