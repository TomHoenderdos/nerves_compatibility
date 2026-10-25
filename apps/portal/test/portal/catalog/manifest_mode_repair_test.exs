defmodule Portal.Catalog.ManifestModeRepairTest do
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.{ArtifactStore, Catalog}
  alias Portal.Catalog.{Ingestion, ManifestModeRepair, SystemResult}

  @rw 0o100644
  @rwx 0o100755

  defp sha(content), do: Base.encode16(:crypto.hash(:sha256, content), case: :lower)

  defp entry(path, content, mode),
    do: %{"path" => path, "sha256" => sha(content), "size" => byte_size(content), "mode" => mode}

  # A run of `name` whose rpi4 beam scan published every file as 0644 while the
  # run footprint kept the real modes, which is the state production is in.
  # `footprint_systems` names the systems the run footprint covers.
  defp ingest_run(name, opts \\ []) do
    beam = "beam-#{name}"
    port = "port-#{name}"
    footprint_systems = Keyword.get(opts, :footprint_systems, ["nerves_system_rpi4"])
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

    result = %{
      "run_id" => "mmr-#{name}",
      "package" => %{
        "name" => name,
        "version" => "1.0.0",
        "footprint" => %{
          "file_count" => 2,
          "total_bytes" => 10,
          "file_manifest" => built,
          "per_system" =>
            Map.new(footprint_systems, &{&1, %{"file_count" => 2, "file_manifest" => built}})
        }
      },
      "finished_at" => "2026-10-20T10:00:00Z",
      "systems" => %{
        "nerves_system_rpi4" => %{
          "status" => "pass",
          "system_version" => "1.24.0",
          "beam_scan" => %{"footprint" => %{"file_manifest" => published}}
        }
      }
    }

    {:ok, run} =
      Ingestion.ingest(result, %{
        run_id: result["run_id"],
        image_digest: "sha256:mmr",
        files_dir: dir,
        log: "l"
      })

    run
  end

  defp manifest_of(run) do
    SystemResult
    |> Ash.Query.filter(run_id == ^run.id and system_pkg == "nerves_system_rpi4")
    |> Ash.Query.select([:beam_scan])
    |> Ash.read_one!(domain: Catalog)
    |> Map.fetch!(:beam_scan)
    |> get_in(["footprint", "file_manifest"])
  end

  test "copies the footprint's mode into the published manifest by path and sha" do
    name = "mmr_fix_#{System.unique_integer([:positive])}"
    run = ingest_run(name)

    assert [%{"mode" => @rw}] =
             Catalog.precompiled_manifest(name).versions["1.0.0"]["nerves_system_rpi4"]["priv"]

    assert %{results_scanned: 1, results_updated: 1, files_updated: 1, by_mode: %{@rwx => 1}} =
             ManifestModeRepair.run()

    manifest = manifest_of(run)
    assert [%{"path" => "priv/if_monitor", "mode" => @rwx}] = manifest["priv"]
    assert [%{"mode" => @rw}] = manifest["ebin"]

    published = Catalog.precompiled_manifest(name).versions["1.0.0"]["nerves_system_rpi4"]
    assert [%{"path" => "priv/if_monitor", "mode" => @rwx}] = published["priv"]
    assert [%{"mode" => @rw}] = published["ebin"]
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

  test "a result whose run footprint lacks its system is skipped and counted" do
    run = ingest_run("mmr_old_#{System.unique_integer([:positive])}", footprint_systems: [])
    before = manifest_of(run)

    assert %{results_scanned: 1, results_updated: 0, files_updated: 0, results_skipped: 1} =
             ManifestModeRepair.run()

    assert manifest_of(run) == before
  end

  test "a revoked run is left alone" do
    run = ingest_run("mmr_revoked_#{System.unique_integer([:positive])}")
    {:ok, _} = Catalog.revoke_run(run.run_id)
    before = manifest_of(run)

    assert %{results_scanned: 0, files_updated: 0} = ManifestModeRepair.run()
    assert manifest_of(run) == before
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

    assert [%{"mode" => @rwx}] =
             Catalog.precompiled_manifest(name).versions["1.0.0"]["nerves_system_rpi4"]["priv"]
  end

  test "limit bounds the results scanned" do
    ingest_run("mmr_lim_a_#{System.unique_integer([:positive])}")
    ingest_run("mmr_lim_b_#{System.unique_integer([:positive])}")

    assert %{results_scanned: 1, files_updated: 1} = ManifestModeRepair.run(limit: 1)
    assert %{results_scanned: 2, files_updated: 1} = ManifestModeRepair.run()
  end
end
