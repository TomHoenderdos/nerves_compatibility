defmodule Portal.Catalog.ManifestV2DeclaredTest do
  use Portal.DataCase, async: false

  require Ash.Query

  import Portal.PrecompiledFixtures
  import PortalWeb.ApiSpecAssertions

  alias Portal.Catalog

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])
  @deps %{"decimal" => %{"version" => "2.1.1", "checksum" => "abc"}}
  @run_sha "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"

  @declared [
    %{"app" => "jason", "name" => "jason", "requirement" => "~> 1.0", "optional" => true}
  ]

  # The fixture run with what format 2 requires (lock, checksum, compile_env)
  # and, when given, the package's declared dependencies.
  defp keyed_run(declared) do
    @fixture
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("deps_lock", @deps)
    |> Map.put("package_checksum", "outer")
    |> put_in(["systems", "nerves_system_rpi4", "compile_env"], [])
    |> put_declared(declared)
  end

  defp put_declared(result, nil), do: result
  defp put_declared(result, declared), do: Map.put(result, "declared", declared)

  defp publish_toolchain_build!(declared) do
    name = "decl_tc_#{System.unique_integer([:positive])}"
    ingest_toolchain_build(name, "0.3.0", declared: declared)
    name
  end

  defp publish_run_build!(declared) do
    ingest_with_artifact(keyed_run(declared))
    "jason"
  end

  defp builds(name) do
    %{"versions" => versions} = Catalog.precompiled_manifest_v2(name)
    versions |> Map.values() |> Enum.flat_map(& &1["builds"])
  end

  test "a toolchain build with declared publishes it" do
    name = publish_toolchain_build!(@declared)
    assert [build] = builds(name)
    assert build["build"]["declared"] == @declared
  end

  test "a toolchain build without it has no key" do
    name = publish_toolchain_build!(nil)
    assert [build] = builds(name)
    refute Map.has_key?(build["build"], "declared")
    refute Catalog.precompiled_manifest_v2(name) |> Jason.encode!() =~ "declared"
  end

  test "a run's system build publishes the run's declared" do
    name = publish_run_build!(@declared)
    assert [build] = builds(name)
    assert build["target"] == "nerves_system_rpi4"
    assert build["build"]["declared"] == @declared
  end

  test "a run without it renders no key" do
    name = publish_run_build!(nil)
    assert [build] = builds(name)
    refute Map.has_key?(build["build"], "declared")
  end

  test "format 1 never carries it" do
    name = publish_run_build!(@declared)
    v1 = Catalog.precompiled_manifest(name)
    assert %{versions: %{"1.4.1" => %{"nerves_system_rpi4" => _}}} = v1
    refute Jason.encode!(v1) =~ "declared"
  end

  # A carried result describes the run that built it, so it publishes that
  # run's list even when the carrying run recorded none.
  test "a carried system result publishes its builder's declared" do
    publish_run_build!(@declared)

    partial =
      nil
      |> keyed_run()
      |> Map.merge(%{
        "run_id" => "fixture-jason-targets",
        "scope" => "targets",
        "finished_at" => "2030-01-01T00:00:00Z"
      })
      |> Map.update!("systems", &Map.take(&1, ["nerves_system_x86_64"]))

    ingest_with_artifact(partial)
    restore_run_blob!()

    [original] =
      Catalog.SystemResult
      |> Ash.Query.filter(system_pkg == "nerves_system_rpi4" and is_nil(carried_from_run_id))
      |> Ash.read!(domain: Catalog)

    # Withdraw the original row, so the carried copy alone publishes.
    Portal.Repo.query!(
      "UPDATE catalog_system_results SET unpublished_at = now() WHERE id = $1",
      [Ecto.UUID.dump!(original.id)]
    )

    assert [build] = builds("jason")
    assert build["build"]["run_id"] == "fixture-jason-1.4.1"
    assert build["build"]["declared"] == @declared
  end

  test "the manifest validates against the OpenAPI schema" do
    assert_api_schema(
      Catalog.precompiled_manifest_v2(publish_toolchain_build!(@declared)),
      "ManifestV2"
    )

    assert_api_schema(
      Catalog.precompiled_manifest_v2(publish_run_build!(@declared)),
      "ManifestV2"
    )
  end

  # A batch reuses a package's manifest while its fingerprint is unchanged, so
  # recording a list on an existing row has to change it.
  test "a change to declared changes the package's fingerprint" do
    name = publish_toolchain_build!(nil)
    before = Catalog.precompiled_fingerprints()[name]

    Portal.Repo.query!(
      """
      UPDATE catalog_toolchain_builds SET declared = $1
      WHERE package_id = (SELECT id FROM catalog_packages WHERE name = $2)
      """,
      [@declared, name]
    )

    assert Catalog.precompiled_fingerprints()[name] != before
    assert [build] = builds(name)
    assert build["build"]["declared"] == @declared

    run_name = publish_run_build!(nil)
    before = Catalog.precompiled_fingerprints()[run_name]

    Portal.Repo.query!(
      """
      UPDATE catalog_runs SET declared = $1
      WHERE package_id = (SELECT id FROM catalog_packages WHERE name = $2)
      """,
      [@declared, run_name]
    )

    assert Catalog.precompiled_fingerprints()[run_name] != before
    assert [build] = builds(run_name)
    assert build["build"]["declared"] == @declared
  end

  defp restore_run_blob! do
    source = Path.join(System.tmp_dir!(), "declared-blob-#{System.unique_integer([:positive])}")
    File.write!(source, "precompiled-beam")
    on_exit(fn -> File.rm(source) end)
    assert {:ok, _} = Portal.ArtifactStore.put(@run_sha, source)
  end
end
