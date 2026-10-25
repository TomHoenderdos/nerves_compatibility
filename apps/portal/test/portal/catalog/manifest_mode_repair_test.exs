defmodule Portal.Catalog.ManifestModeRepairTest do
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.{ArtifactStore, Catalog}
  alias Portal.Catalog.{Ingestion, ManifestModeRepair, SystemResult}

  @rw 0o100644
  @rwx 0o100755
  @rpi4 "nerves_system_rpi4"
  @bbb "nerves_system_bbb"

  defp sha(content), do: Base.encode16(:crypto.hash(:sha256, content), case: :lower)

  defp entry(path, content, mode),
    do: %{"path" => path, "sha256" => sha(content), "size" => byte_size(content), "mode" => mode}

  # A run of `name` whose beam scans published every file as 0644 while the run
  # footprint kept the real modes, which is the state production is in.
  #
  # Options:
  #   * `:systems` - systems the run builds (`[rpi4]`)
  #   * `:per_system` - footprint `per_system` keys, `nil` for no `per_system`
  #     (default: `:systems`)
  #   * `:top_level` - footprint top-level `file_manifest` (none)
  #   * `:beam_scan_mode`, `:built_mode` - the priv file's two modes
  #   * `:scope`, `:finished_at`, `:run_id`
  defp ingest_run(name, opts \\ []) do
    beam = "beam-#{name}"
    port = "port-#{name}"
    systems = Keyword.get(opts, :systems, [@rpi4])
    per_system = Keyword.get(opts, :per_system, systems)
    beam_scan_mode = Keyword.get(opts, :beam_scan_mode, @rw)
    built_mode = Keyword.get(opts, :built_mode, @rwx)

    published = %{
      "ebin" => [entry("ebin/#{name}.beam", beam, @rw)],
      "priv" => [entry("priv/if_monitor", port, beam_scan_mode)]
    }

    built = %{
      "ebin" => [entry("ebin/#{name}.beam", beam, @rw)],
      "priv" => [entry("priv/if_monitor", port, built_mode)]
    }

    dir = Path.join(System.tmp_dir!(), "mmr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    for content <- [beam, port] do
      _ = File.rm(ArtifactStore.blob_path(sha(content)))
      File.write!(Path.join(dir, sha(content)), content)
    end

    footprint =
      %{"file_count" => 2, "total_bytes" => 10}
      |> then(fn fp ->
        if per_system,
          do: Map.put(fp, "per_system", Map.new(per_system, &{&1, %{"file_manifest" => built}})),
          else: fp
      end)
      |> then(fn fp ->
        case Keyword.get(opts, :top_level) do
          nil -> fp
          top -> Map.put(fp, "file_manifest", top.(built))
        end
      end)

    result =
      %{
        "run_id" => Keyword.get(opts, :run_id, "mmr-#{name}"),
        "package" => %{"name" => name, "version" => "1.0.0", "footprint" => footprint},
        "finished_at" => Keyword.get(opts, :finished_at, "2026-10-20T10:00:00Z"),
        "systems" =>
          Map.new(systems, fn system ->
            {system,
             %{
               "status" => "pass",
               "system_version" => "1.24.0",
               "beam_scan" => %{"footprint" => %{"file_manifest" => published}}
             }}
          end)
      }
      |> then(fn r ->
        case Keyword.get(opts, :scope) do
          nil -> r
          scope -> Map.put(r, "scope", scope)
        end
      end)

    {:ok, run} =
      Ingestion.ingest(result, %{
        run_id: result["run_id"],
        image_digest: "sha256:mmr",
        files_dir: dir,
        log: "l"
      })

    run
  end

  defp manifest_of(run, system \\ @rpi4) do
    SystemResult
    |> Ash.Query.filter(run_id == ^run.id and system_pkg == ^system)
    |> Ash.Query.select([:beam_scan])
    |> Ash.read_one!(domain: Catalog)
    |> Map.fetch!(:beam_scan)
    |> get_in(["footprint", "file_manifest"])
  end

  defp published_priv(name, system \\ @rpi4),
    do: Catalog.precompiled_manifest(name).versions["1.0.0"][system]["priv"]

  test "copies the footprint's mode into the published manifest by path and sha" do
    name = "mmr_fix_#{System.unique_integer([:positive])}"
    run = ingest_run(name)

    assert [%{"mode" => @rw}] = published_priv(name)

    assert %{results_scanned: 1, results_updated: 1, files_updated: 1, by_mode: %{@rwx => 1}} =
             ManifestModeRepair.run()

    manifest = manifest_of(run)
    assert [%{"path" => "priv/if_monitor", "mode" => @rwx}] = manifest["priv"]
    assert [%{"mode" => @rw}] = manifest["ebin"]

    published = Catalog.precompiled_manifest(name).versions["1.0.0"][@rpi4]
    assert [%{"path" => "priv/if_monitor", "mode" => @rwx}] = published["priv"]
    assert [%{"mode" => @rw}] = published["ebin"]
  end

  # After a partial rebuild the latest run carries the systems it left out,
  # and its own footprint covers only what it rebuilt.
  test "a carried row is repaired from the footprint of the run that built it" do
    name = "mmr_carry_#{System.unique_integer([:positive])}"
    ingest_run(name, systems: [@rpi4, @bbb])

    carrier =
      ingest_run(name,
        systems: [@bbb],
        scope: "targets",
        run_id: "mmr-#{name}-targets",
        finished_at: "2026-10-21T10:00:00Z"
      )

    assert [%{"mode" => @rw}] = manifest_of(carrier, @rpi4)["priv"]
    assert [%{"mode" => @rw}] = published_priv(name, @rpi4)

    # rpi4 and bbb of the full run, bbb rebuilt and rpi4 carried by the partial one.
    assert %{results_scanned: 4, results_updated: 4, results_skipped: 0} =
             ManifestModeRepair.run()

    assert [%{"mode" => @rwx}] = manifest_of(carrier, @rpi4)["priv"]
    assert [%{"mode" => @rwx}] = published_priv(name, @rpi4)
  end

  test "a second run is a no-op" do
    run = ingest_run("mmr_twice_#{System.unique_integer([:positive])}")

    assert %{files_updated: 1} = ManifestModeRepair.run()
    before = manifest_of(run)

    assert %{results_scanned: 1, results_updated: 0, files_updated: 0, by_mode: by_mode} =
             ManifestModeRepair.run()

    assert by_mode == %{}
    assert manifest_of(run) == before
  end

  test "dry_run reports the counts and changes nothing" do
    run = ingest_run("mmr_dry_#{System.unique_integer([:positive])}")
    before = manifest_of(run)

    assert %{results_scanned: 1, results_updated: 1, files_updated: 1, by_mode: %{@rwx => 1}} =
             ManifestModeRepair.run(dry_run: true)

    assert manifest_of(run) == before
    assert %{files_updated: 1} = ManifestModeRepair.run()
  end

  test "a result whose run footprint has no manifest at all is skipped and counted" do
    runs =
      for {label, per_system} <- [{"empty", []}, {"none", nil}] do
        ingest_run("mmr_old_#{label}_#{System.unique_integer([:positive])}",
          per_system: per_system
        )
      end

    before = Enum.map(runs, &manifest_of/1)

    assert %{results_scanned: 2, results_updated: 0, files_updated: 0, results_skipped: 2} =
             ManifestModeRepair.run()

    assert Enum.map(runs, &manifest_of/1) == before
  end

  test "a footprint keyed by target name is matched across its entries by path and sha" do
    run = ingest_run("mmr_target_#{System.unique_integer([:positive])}", per_system: ["rpi4"])

    assert %{results_fallback: 1, results_updated: 1, files_updated: 1, results_skipped: 0} =
             ManifestModeRepair.run()

    assert [%{"mode" => @rwx}] = manifest_of(run)["priv"]
  end

  test "the fallback reads the footprint's top-level manifest too" do
    run =
      ingest_run("mmr_top_#{System.unique_integer([:positive])}",
        per_system: nil,
        top_level: & &1
      )

    assert %{results_fallback: 1, results_updated: 1} = ManifestModeRepair.run()
    assert [%{"mode" => @rwx}] = manifest_of(run)["priv"]
  end

  test "the fallback leaves a file alone when footprint entries disagree on its mode" do
    run =
      ingest_run("mmr_conflict_#{System.unique_integer([:positive])}",
        per_system: ["rpi4"],
        top_level: fn built ->
          update_in(built, ["priv"], fn entries ->
            Enum.map(entries, &Map.put(&1, "mode", 0o100700))
          end)
        end
      )

    before = manifest_of(run)

    assert %{results_fallback: 1, files_conflicting: 1, results_updated: 0} =
             ManifestModeRepair.run()

    assert manifest_of(run) == before
  end

  test "a row whose modes differ only in bits a manifest does not publish is counted, not rewritten" do
    run =
      ingest_run("mmr_cosmetic_#{System.unique_integer([:positive])}", built_mode: 0o100664)

    before = manifest_of(run)

    assert %{results_cosmetic: 1, results_updated: 0, files_updated: 0} =
             ManifestModeRepair.run()

    assert manifest_of(run) == before
  end

  test "a revoked run is left alone" do
    revoked = ingest_run("mmr_revoked_#{System.unique_integer([:positive])}")
    control = ingest_run("mmr_control_#{System.unique_integer([:positive])}")
    {:ok, _} = Catalog.revoke_run(revoked.run_id)
    before = manifest_of(revoked)

    assert %{results_scanned: 1, results_updated: 1, files_updated: 1} = ManifestModeRepair.run()
    assert manifest_of(revoked) == before
    assert [%{"mode" => @rwx}] = manifest_of(control)["priv"]
  end

  test "an entry with no mode is filled in from the footprint" do
    run = ingest_run("mmr_nil_#{System.unique_integer([:positive])}", beam_scan_mode: nil)

    assert %{files_updated: 1, by_mode: %{@rwx => 1}} = ManifestModeRepair.run()
    assert [%{"mode" => @rwx}] = manifest_of(run)["priv"]
  end

  test "stores the real mode and publishes it reduced to 0755" do
    name = "mmr_775_#{System.unique_integer([:positive])}"
    run = ingest_run(name, built_mode: 0o100775)

    assert %{files_updated: 1, by_mode: %{0o100775 => 1}} = ManifestModeRepair.run()
    assert [%{"mode" => 0o100775}] = manifest_of(run)["priv"]
    assert [%{"mode" => @rwx}] = published_priv(name)
  end

  test "limit bounds the results scanned and must be a positive integer" do
    ingest_run("mmr_lim_a_#{System.unique_integer([:positive])}")
    ingest_run("mmr_lim_b_#{System.unique_integer([:positive])}")

    assert %{results_scanned: 1, files_updated: 1} = ManifestModeRepair.run(limit: 1)
    assert %{results_scanned: 2, files_updated: 1} = ManifestModeRepair.run()

    for bad <- [0, -1, "10", 1.5] do
      assert_raise ArgumentError, fn -> ManifestModeRepair.run(limit: bad) end
    end
  end
end
