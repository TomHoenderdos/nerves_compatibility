defmodule Portal.Precompiled.WithheldTest do
  # Changes application env and ingests into the shared catalog.
  use Portal.DataCase, async: false

  alias Portal.Catalog
  alias Portal.Precompiled.Withheld

  import Portal.PrecompiledFixtures

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])
  @run_sha "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"
  @decimal %{"decimal" => %{"version" => "2.1.1", "checksum" => "abc"}}
  @liveview Map.put(@decimal, "phoenix_live_view", %{"version" => "1.1.0", "checksum" => "def"})

  # A full run with every key format 2 needs, its rpi4 result publishing one
  # file (`@run_sha`).
  defp run(deps_lock, system_deps_lock \\ nil) do
    result =
      @fixture
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("deps_lock", deps_lock)
      |> Map.put("package_checksum", "outer")
      |> put_in(["systems", "nerves_system_rpi4", "compile_env"], [])

    if system_deps_lock,
      do: put_in(result, ["systems", "nerves_system_rpi4", "deps_lock"], system_deps_lock),
      else: result
  end

  defp toolchain_sha(build), do: hd(build.file_manifest["ebin"])["sha256"]

  defp put_withheld(value) do
    old = Application.get_env(:portal, Withheld)
    on_exit(fn -> restore(old) end)
    Application.put_env(:portal, Withheld, value)
  end

  defp restore(nil), do: Application.delete_env(:portal, Withheld)
  defp restore(old), do: Application.put_env(:portal, Withheld, old)

  describe "packages/0" do
    test "defaults to phoenix_live_view" do
      put_withheld(nil)
      assert Withheld.packages() == ["phoenix_live_view"]
    end

    test "reads the configured list" do
      put_withheld(packages: ["b", "a"])
      assert Withheld.packages() == ["a", "b"]

      put_withheld(packages: [])
      assert Withheld.packages() == []
    end

    test "a malformed list falls back to the default" do
      put_withheld(packages: [:phoenix_live_view])
      assert Withheld.packages() == ["phoenix_live_view"]

      put_withheld(packages: "phoenix_live_view")
      assert Withheld.packages() == ["phoenix_live_view"]
    end
  end

  test "withheld?/3 matches the package itself or any locked dependency" do
    assert Withheld.withheld?("phoenix_live_view", nil, ["phoenix_live_view"])
    assert Withheld.withheld?("x", @liveview, ["phoenix_live_view"])
    refute Withheld.withheld?("x", @decimal, ["phoenix_live_view"])
    refute Withheld.withheld?("x", nil, ["phoenix_live_view"])
    refute Withheld.withheld?("x", @liveview, [])
  end

  describe "a full run's system result" do
    test "whose run lock has phoenix_live_view is in no manifest and its file is not served" do
      ingest_with_artifact(run(@liveview))

      assert Catalog.precompiled_manifest("jason") == nil
      assert Catalog.precompiled_manifest_v2("jason") == nil
      assert %{v1: nil, v2: nil} = Catalog.precompiled_manifests("jason")
      refute "jason" in Catalog.packages_with_precompiled_files()
      refute Catalog.published_sha256?(@run_sha)
    end

    test "whose own system lock has phoenix_live_view is withheld too" do
      ingest_with_artifact(run(@decimal, @liveview))

      assert Catalog.precompiled_manifest("jason") == nil
      assert Catalog.precompiled_manifest_v2("jason") == nil
      refute "jason" in Catalog.packages_with_precompiled_files()
      refute Catalog.published_sha256?(@run_sha)
    end

    test "without phoenix_live_view is published in both formats" do
      ingest_with_artifact(run(@decimal))

      assert %{versions: %{"1.4.1" => %{"nerves_system_rpi4" => _}}} =
               Catalog.precompiled_manifest("jason")

      assert %{"versions" => %{"1.4.1" => %{"builds" => [_]}}} =
               Catalog.precompiled_manifest_v2("jason")

      assert "jason" in Catalog.packages_with_precompiled_files()
      assert Catalog.published_sha256?(@run_sha)
    end

    test "follows the configured list" do
      put_withheld(packages: [])
      ingest_with_artifact(run(@liveview))

      assert Catalog.precompiled_manifest("jason")
      assert Catalog.precompiled_manifest_v2("jason")
      assert Catalog.published_sha256?(@run_sha)

      put_withheld(packages: ["decimal"])
      assert Catalog.precompiled_manifest("jason") == nil
      assert Catalog.precompiled_manifest_v2("jason") == nil
      refute "jason" in Catalog.packages_with_precompiled_files()
      refute Catalog.published_sha256?(@run_sha)
    end
  end

  describe "a toolchain build" do
    test "whose lock has phoenix_live_view is withheld; one without is published" do
      withheld = "tc_lv_#{System.unique_integer([:positive])}"
      kept = "tc_ok_#{System.unique_integer([:positive])}"
      withheld_build = ingest_toolchain_build(withheld, "0.1.0", deps_lock: @liveview)
      kept_build = ingest_toolchain_build(kept, "0.1.0", deps_lock: @decimal)

      assert Catalog.precompiled_manifest_v2(withheld) == nil
      assert %{v2: nil} = Catalog.precompiled_manifests(withheld)
      refute withheld in Catalog.packages_with_precompiled_files()
      refute Catalog.published_sha256?(toolchain_sha(withheld_build))

      assert %{"versions" => %{"0.1.0" => %{"builds" => [_]}}} =
               Catalog.precompiled_manifest_v2(kept)

      assert kept in Catalog.packages_with_precompiled_files()
      assert Catalog.published_sha256?(toolchain_sha(kept_build))
    end

    test "of phoenix_live_view itself is withheld" do
      build = ingest_toolchain_build("phoenix_live_view", "1.1.0", deps_lock: @decimal)

      assert Catalog.precompiled_manifest_v2("phoenix_live_view") == nil
      refute "phoenix_live_view" in Catalog.packages_with_precompiled_files()
      refute Catalog.published_sha256?(toolchain_sha(build))
    end

    test "follows the configured list" do
      name = "tc_cfg_#{System.unique_integer([:positive])}"
      build = ingest_toolchain_build(name, "0.1.0", deps_lock: @decimal)
      assert Catalog.precompiled_manifest_v2(name)

      put_withheld(packages: ["decimal"])
      assert Catalog.precompiled_manifest_v2(name) == nil
      refute name in Catalog.packages_with_precompiled_files()
      refute Catalog.published_sha256?(toolchain_sha(build))
    end
  end

  # A batch reuses a package's manifests while its fingerprint is unchanged,
  # so a change to the list has to change every fingerprint.
  test "the list is part of every precompiled fingerprint" do
    name = "tc_fp_#{System.unique_integer([:positive])}"
    ingest_toolchain_build(name, "0.1.0", deps_lock: @decimal)
    before = Catalog.precompiled_fingerprints()[name]

    put_withheld(packages: ["decimal"])
    assert Catalog.precompiled_fingerprints()[name] != before
  end
end
