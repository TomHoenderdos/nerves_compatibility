defmodule Portal.Catalog.ManifestForeignPrivTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog
  alias Portal.Test.ForeignPrivFixtures, as: F

  import Portal.Test.ForeignPrivFixtures, only: [assert_contract!: 1]

  import Portal.PrecompiledFixtures, only: [ingest_toolchain_build: 3]

  defp on!, do: {:ok, _} = Portal.Settings.save(%{foreign_priv_enabled: true})
  defp off!, do: {:ok, _} = Portal.Settings.save(%{foreign_priv_enabled: false})

  defp manifest(name), do: Catalog.precompiled_manifest_v2(name)

  setup do
    {:ok, writer} = F.ingest!()
    # Recording its config reads (rule 1) keeps kino's build out of the
    # withheld list (`Portal.Precompiled.Withheld`), so 0b is what moves it.
    kino = ingest_toolchain_build("kino", "0.19.1", compile_env_rule: 1)
    plain = ingest_toolchain_build("jason", "1.4.4", compile_env_rule: 1)
    %{writer: writer, kino: kino, plain: plain}
  end

  test "setting on: the writer is listed only under foreign_priv, beside an empty builds" do
    on!()
    m = manifest("kino_vega_lite")
    assert_contract!(m)
    v = m["versions"]["0.1.13"]
    assert v["builds"] == []
    refute Map.has_key?(v, "builds_with_inputs")
    assert %{"builds" => [], "builds_with_inputs" => [entry]} = v["foreign_priv"]
    assert entry["target"] == "pure_elixir"
    assert entry["build"]["foreign_priv_rule"] == "kino_js_v1"

    assert Enum.map(entry["foreign_priv"], &Map.keys/1) |> Enum.uniq() == [
             ~w(app mode path sha256 size)
           ]

    PortalWeb.ApiSpecAssertions.assert_api_schema(m, "ManifestV2")
  end

  test "setting off: no foreign object, and the writer's version is not listed" do
    off!()
    m = manifest("kino_vega_lite")
    assert m == nil or not Map.has_key?(m["versions"], "0.1.13")
  end

  test "setting off or on, a package without foreign builds renders the same bytes", %{plain: _} do
    off!()
    off_bytes = Jason.encode!(manifest("jason"))
    on!()
    assert Jason.encode!(manifest("jason")) == off_bytes
  end

  # Phase 0b (ruling 2, plan Ruling 1): kino out of every 0.7.x list at deploy.
  test "0b: kino's own builds leave the regular lists, setting or not" do
    off!()
    off = manifest("kino")
    assert_contract!(off)

    assert off == nil or
             Enum.all?(off["versions"], fn {_v, v} ->
               v["builds"] == [] and not Map.has_key?(v, "builds_with_inputs")
             end)

    on!()
    m = manifest("kino")
    assert_contract!(m)
    assert %{"builds" => [entry]} = m["versions"]["0.19.1"]["foreign_priv"]
    assert entry["build"]["foreign_priv_target"] == "kino"
    refute Map.has_key?(entry, "foreign_priv")
    PortalWeb.ApiSpecAssertions.assert_api_schema(m, "ManifestV2")
  end

  test "a foreign blob that is not stored leaves the build out whole", %{writer: writer} do
    on!()
    [%{"sha256" => sha} | _] = writer.foreign_priv

    Portal.Repo.query!(
      "DELETE FROM catalog_artifact_memberships WHERE toolchain_build_id = $1 AND sha256 = $2",
      [Ecto.UUID.dump!(writer.id), sha]
    )

    m = manifest("kino_vega_lite")
    assert m == nil or not Map.has_key?(m["versions"], "0.1.13")
  end

  # An older release's rebuild replaces run_id and the verdict (an older
  # worker refuses every writer) and leaves the list: it counts for nothing.
  test "an old release's rebuild leaves a stale list that renders nothing", %{writer: writer} do
    on!()

    Portal.Repo.query!(
      "UPDATE catalog_toolchain_builds SET run_id = 'old-release-run', status = 'skipped' WHERE id = $1",
      [Ecto.UUID.dump!(writer.id)]
    )

    m = manifest("kino_vega_lite")
    assert_contract!(m)
    assert m == nil or not Map.has_key?(m["versions"], "0.1.13")
  end

  # Spec 4.3: a foreign build's sibling goes under the version's
  # `deterministic.foreign_priv` only, with its own archives.
  test "a foreign build's sibling is listed under deterministic.foreign_priv only" do
    {sibling, beams} = F.sibling()
    result = Map.put(F.writer_result(), "deterministic_build", sibling)
    {:ok, _row} = Catalog.Ingestion.ingest_toolchain(result, F.ingest_opts(F.files_dir!(beams)))
    {:ok, _} = Portal.Settings.save(%{deterministic_builds_enabled: true})

    off!()
    m = manifest("kino_vega_lite")
    assert m == nil or not Map.has_key?(m["versions"], "0.1.13")

    on!()
    m = manifest("kino_vega_lite")
    assert_contract!(m)
    PortalWeb.ApiSpecAssertions.assert_api_schema(m, "ManifestV2")
    d = m["versions"]["0.1.13"]["deterministic"]
    assert d["builds"] == []
    assert %{"builds" => [], "builds_with_inputs" => [entry]} = d["foreign_priv"]
    assert entry["build"]["erl_compiler_options"] == ["deterministic"]
    assert entry["build"]["foreign_priv_rule"] == "kino_js_v1"

    assert entry["foreign_priv"] |> Enum.map(& &1["sha256"]) |> Enum.sort() ==
             F.entries("otp29") |> Enum.map(& &1["sha256"]) |> Enum.sort()
  end

  test "format 1 never carries a foreign build or kino's own" do
    on!()

    # Format 1 lists run results only: neither package has a run here, so
    # neither has a format-1 manifest.
    for name <- ["kino_vega_lite", "kino"] do
      assert Catalog.precompiled_manifest(name) == nil, name
    end
  end

  describe "files route and fingerprints" do
    test "a foreign blob is served while the setting is on and the mark is the row's",
         %{writer: writer} do
      [%{"sha256" => sha} | _] = writer.foreign_priv
      off!()
      refute Catalog.published_sha256?(sha)
      on!()
      assert Catalog.published_sha256?(sha)
      assert "kino_vega_lite" in Catalog.packages_with_precompiled_files()

      Portal.Repo.query!(
        "UPDATE catalog_toolchain_builds SET run_id = 'old-release-run' WHERE id = $1",
        [Ecto.UUID.dump!(writer.id)]
      )

      refute Catalog.published_sha256?(sha)
    end

    test "a foreign blob of a revoked or withheld build is not served", %{writer: writer} do
      on!()
      [%{"sha256" => sha} | _] = writer.foreign_priv
      assert Catalog.published_sha256?(sha)

      Portal.Repo.query!(
        "UPDATE catalog_toolchain_builds SET revoked_at = now() WHERE id = $1",
        [Ecto.UUID.dump!(writer.id)]
      )

      refute Catalog.published_sha256?(sha)
    end

    test "a sibling's foreign blob is served with the sibling only" do
      {sibling, beams} = F.sibling()
      result = Map.put(F.writer_result(), "deterministic_build", sibling)
      {:ok, _row} = Catalog.Ingestion.ingest_toolchain(result, F.ingest_opts(F.files_dir!(beams)))
      {:ok, _} = Portal.Settings.save(%{deterministic_builds_enabled: true})
      [%{"sha256" => sha} | _] = F.entries("otp29")

      off!()
      refute Catalog.published_sha256?(sha)
      on!()
      assert Catalog.published_sha256?(sha)
    end

    test "flipping the setting changes the fingerprints of kino and the writer only" do
      off!()
      before = Catalog.precompiled_fingerprints()
      on!()
      now = Catalog.precompiled_fingerprints()
      changed = for {name, fp} <- now, before[name] != fp, do: name
      assert Enum.sort(changed) == ["kino", "kino_vega_lite"]
    end
  end
end
