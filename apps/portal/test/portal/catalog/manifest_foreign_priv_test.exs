defmodule Portal.Catalog.ManifestForeignPrivTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog
  alias Portal.BatchHooks
  alias Portal.Precompiled.{Batches, Manifests}
  alias Portal.Test.ForeignPrivFixtures, as: F

  import Portal.Test.ForeignPrivFixtures, only: [assert_contract!: 1]

  import Portal.PrecompiledFixtures, only: [ingest_toolchain_build: 3, ingest_with_artifact: 1]

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

  # Spec 3.8 row 2: a rebuild against another lock keeps the build it
  # replaced as an earlier build, its foreign entries with it, rendered under
  # `foreign_priv` like the row and its archives still served.
  test "an earlier build keeps its foreign entries and is listed under foreign_priv", %{
    writer: writer
  } do
    lock =
      Map.put(writer.deps_lock, "table", %{
        "version" => "0.1.2",
        "checksum" => String.duplicate("c", 64)
      })

    {:ok, rebuilt} = F.ingest!(%{"deps_lock" => lock})
    assert rebuilt.id == writer.id
    assert [%{"foreign_priv" => [_, _], "run_id" => run}] = rebuilt.earlier_builds
    assert run == writer.run_id

    on!()
    m = manifest("kino_vega_lite")
    assert_contract!(m)
    PortalWeb.ApiSpecAssertions.assert_api_schema(m, "ManifestV2")
    %{"builds_with_inputs" => entries} = m["versions"]["0.1.13"]["foreign_priv"]
    assert length(entries) == 2
    assert Enum.all?(entries, &(length(&1["foreign_priv"]) == 2))
    assert entries |> Enum.map(& &1["build"]["deps"]) |> Enum.uniq() |> length() == 2

    for %{"sha256" => sha} <- writer.foreign_priv, do: assert(Catalog.published_sha256?(sha))
  end

  # A full run of kino whose one published file is on a `pure_elixir`
  # result that records its config reads (rule 1) and has no compile input
  # to check: a result `Withheld` serves and format 1 would list.
  defp kino_pure_run do
    result =
      [__DIR__, "..", "..", "support", "fixtures", "result.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("deps_lock", %{"table" => %{"version" => "0.1.2", "checksum" => "abc"}})
      |> Map.put("package_checksum", "outer")
      |> Map.put("run_id", "kino-run-#{System.unique_integer([:positive])}")
      |> put_in(["package", "name"], "kino")
      |> put_in(["package", "version"], "0.19.1")

    pure =
      result["systems"]["nerves_system_rpi4"]
      |> Map.put("compile_env_rule", 1)
      |> Map.put("compile_env", [])
      |> Map.delete("compile_inputs")

    Map.update!(result, "systems", fn systems ->
      systems |> Map.delete("nerves_system_rpi4") |> Map.put("pure_elixir", pure)
    end)
  end

  # Phase 0b (plan ruling 1) for format 1: every client up to 0.7.3 reads a
  # package's format-1 document when the batch names no format-2 one, and
  # turns its entries into builds. kino's own run results are never in it,
  # setting or not; with the setting on they are under format 2's
  # `foreign_priv` object, where only 0.8.0 reads.
  @tag :tmp_dir
  test "format 1 never carries kino's own builds, setting or not", %{tmp_dir: dir} do
    ingest_with_artifact(kino_pure_run())
    BatchHooks.signing_key!(dir)

    for on? <- [false, true] do
      {:ok, _} = Portal.Settings.save(%{foreign_priv_enabled: on?})
      assert Catalog.precompiled_manifest("kino") == nil, inspect(on?)
      assert Catalog.precompiled_manifests("kino").v1 == nil, inspect(on?)

      {:ok, batch} = Batches.build_and_sign()
      refute Map.has_key?(Batches.manifests(batch), "kino"), inspect(on?)
      assert_contract!(manifest("kino"))
    end

    # With it on, the run result is listed, under `foreign_priv` only.
    builds = get_in(manifest("kino"), ["versions", "0.19.1", "foreign_priv", "builds"])
    assert Enum.any?(builds, &(&1["target"] == "pure_elixir")), inspect(builds)
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

    # A batch remembers a package's manifests only when its fingerprint read
    # before the renders equals the one read after: the setting turned on and
    # off again between the two must still read as a change (the settings
    # trigger counts it, `Portal.Catalog.precompiled_fingerprints/0`).
    test "the setting turned on and off again changes the fingerprints of kino and the writer only" do
      off!()
      before = Catalog.precompiled_fingerprints()
      on!()
      off!()
      now = Catalog.precompiled_fingerprints()
      changed = for {name, fp} <- now, before[name] != fp, do: name
      assert Enum.sort(changed) == ["kino", "kino_vega_lite"]
    end

    test "a toolchain or pinned row's foreign columns are in its fingerprint", %{writer: writer} do
      before = Catalog.precompiled_fingerprints()["kino_vega_lite"]

      Portal.Repo.query!(
        "UPDATE catalog_toolchain_builds SET foreign_priv_rule = 'kino_js_v0' WHERE id = $1",
        [Ecto.UUID.dump!(writer.id)]
      )

      changed = Catalog.precompiled_fingerprints()["kino_vega_lite"]
      refute changed == before

      Portal.Repo.query!(
        "UPDATE catalog_toolchain_builds SET foreign_priv_rule = 'kino_js_v1' WHERE id = $1",
        [Ecto.UUID.dump!(writer.id)]
      )

      # The pinned fixture's own package: its row, its foreign run mark.
      {:ok, pinned} = F.ingest_pinned!()
      pinned_before = Catalog.precompiled_fingerprints()["kino_vega_lite"]

      Portal.Repo.query!(
        "UPDATE catalog_pinned_builds SET foreign_priv_run_id = NULL WHERE id = $1",
        [Ecto.UUID.dump!(pinned.id)]
      )

      refute Catalog.precompiled_fingerprints()["kino_vega_lite"] == pinned_before
    end

    # Plan ruling 1 and spec 4.3: the setting decides whether the writer's
    # `foreign_priv` object and kino's own builds (0b) render. One turned on
    # after a batch's first fingerprint read and off again once its renders
    # read it must leave no manifest rendered while it was on.
    @tag :tmp_dir
    test "the setting turned on during a batch and off again leaves no stale manifest",
         %{tmp_dir: dir} do
      # Listed while the setting is off too, through a plain build.
      ingest_toolchain_build("kino_vega_lite", "0.1.12", compile_env_rule: 1)
      BatchHooks.signing_key!(dir)

      for name <- ["kino_vega_lite", "kino"] do
        on!()
        reads = BatchHooks.settings_reads(name)
        off!()

        hook = BatchHooks.flip_during_render(&on!/0, &off!/0, reads)
        {:ok, _b1} = Batches.build_and_sign()
        assert BatchHooks.flipped?(hook), name

        {:ok, b2} = Batches.build_and_sign()

        case {Batches.manifests_v2(b2)[name], Manifests.render_v2(name)} do
          {nil, :none} ->
            :ok

          {sha, {:ok, fresh}} when is_binary(sha) ->
            {:ok, bytes} = Manifests.read(sha)
            assert bytes == fresh, name
            refute bytes =~ "foreign_priv", name

          other ->
            flunk("#{name}: the batch and a fresh render differ: #{inspect(other)}")
        end
      end
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
