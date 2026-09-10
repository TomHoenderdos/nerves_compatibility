defmodule Portal.Catalog.IngestionTest do
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.ArtifactStore
  alias Portal.Catalog.{Artifact, Ingestion, Package, SystemResult}
  alias Portal.ScanRequests

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])

  defp load_fixture do
    @fixture |> File.read!() |> Jason.decode!()
  end

  # Create a files_dir containing the content-addressed blob referenced by the
  # fixture's beam_scan manifest so artifact registration has something to move.
  defp seed_files_dir(shas) do
    dir = Path.join(System.tmp_dir!(), "ingest-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Enum.each(shas, fn sha -> File.write!(Path.join(dir, sha), "blob-#{sha}") end)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "ingests a result.json into Package + Run + SystemResults + Artifacts" do
    result = load_fixture()
    sha = "aaaa000000000000000000000000000000000000000000000000000000000001"
    files_dir = seed_files_dir([sha])

    {:ok, run} =
      Ingestion.ingest(result, %{
        run_id: "fixture-jason-1.4.1",
        image_digest: "sha256:deadbeef",
        files_dir: files_dir,
        scan_request_id: nil,
        log: "build log"
      })

    # Package upserted
    package = Ash.get!(Package, run.package_id, domain: Portal.Catalog)
    assert package.name == "jason"
    assert package.latest_version == "1.4.1"
    refute is_nil(package.last_run_at)

    # Run envelope
    assert run.version_tested == "1.4.1"
    assert run.image_digest == "sha256:deadbeef"
    # at least one system passed → overall pass
    assert run.overall_status == :pass
    assert run.footprint["file_count"] == 12

    # System results: 3 systems including host
    system_results =
      SystemResult
      |> Ash.Query.filter(run_id == ^run.id)
      |> Ash.read!(domain: Portal.Catalog)

    assert length(system_results) == 3
    statuses = Map.new(system_results, &{&1.system_pkg, &1.status})
    assert statuses["nerves_system_rpi4"] == :pass
    assert statuses["nerves_system_x86_64"] == :fail
    assert statuses["host"] == :pass

    # Per-system duration is the only signal that says which target costs what.
    durations = Map.new(system_results, &{&1.system_pkg, &1.duration_sec})
    assert durations["nerves_system_rpi4"] == 245.3
    assert durations["host"] == 5.0

    # Artifact registered + blob moved into the store
    artifacts = Ash.read!(Artifact, domain: Portal.Catalog)
    assert Enum.any?(artifacts, &(&1.sha256 == sha))
    assert File.exists?(ArtifactStore.blob_path(sha))
    # source moved out of files_dir
    refute File.exists?(Path.join(files_dir, sha))
  end

  test "links the run to a scan_request when given" do
    result = load_fixture()
    files_dir = seed_files_dir([])

    {:ok, request} =
      ScanRequests.create_once(%{
        package_name: "jason",
        source: :hex_owner,
        status: :accepted
      })

    {:ok, run} =
      Ingestion.ingest(result, %{
        run_id: "rid-linked",
        image_digest: "sha256:1",
        files_dir: files_dir,
        scan_request_id: request.id,
        log: nil
      })

    assert run.scan_request_id == request.id
  end

  test "overall_status honours a top-level forced_status" do
    result = load_fixture() |> Map.put("forced_status", "skipped")
    files_dir = seed_files_dir([])

    {:ok, run} =
      Ingestion.ingest(result, %{
        run_id: "rid-forced",
        image_digest: "sha256:1",
        files_dir: files_dir,
        scan_request_id: nil
      })

    assert run.overall_status == :skipped
  end

  test "upserts the package on a second run rather than duplicating" do
    result = load_fixture()
    files_dir = seed_files_dir([])

    {:ok, run1} =
      Ingestion.ingest(result, %{
        run_id: "rid-a",
        image_digest: "sha256:1",
        files_dir: files_dir,
        scan_request_id: nil
      })

    {:ok, run2} =
      Ingestion.ingest(
        Map.put(result, "package", Map.put(result["package"], "version", "1.4.2")),
        %{
          run_id: "rid-b",
          image_digest: "sha256:2",
          files_dir: files_dir,
          scan_request_id: nil
        }
      )

    assert run1.package_id == run2.package_id

    package = Ash.get!(Package, run2.package_id, domain: Portal.Catalog)
    assert package.latest_version == "1.4.2"

    packages = Ash.read!(Package, domain: Portal.Catalog)
    assert Enum.count(packages, &(&1.name == "jason")) == 1
  end

  # A dependency scan shaped the way the worker emits one: analysis keys, plus a
  # footprint whose `file_manifest` names every file that dependency produced.
  defp dep_scan(sha) do
    %{
      "flags" => ["nif"],
      "beam_count" => 3,
      "languages" => ["c"],
      "protocols" => [],
      "footprint" => %{
        "total_bytes" => 12_345,
        "file_manifest" => %{
          "ebin" => [
            %{"path" => "ebin/dep.beam", "mode" => 33_188, "size" => 347, "sha256" => sha}
          ],
          "priv" => []
        }
      }
    }
  end

  defp ingest_with_dep_scans(scans, files_dir, run_id) do
    result =
      load_fixture()
      |> update_in(["systems", "nerves_system_rpi4"], &Map.put(&1, "dependency_scans", scans))

    {:ok, run} =
      Ingestion.ingest(result, %{
        run_id: run_id,
        image_digest: "sha256:1",
        files_dir: files_dir,
        scan_request_id: nil
      })

    SystemResult
    |> Ash.Query.filter(run_id == ^run.id and system_pkg == "nerves_system_rpi4")
    |> Ash.read_one!(domain: Portal.Catalog)
  end

  describe "dependency_scans" do
    test "keeps the analysis but drops the file manifest" do
      sha = "bbbb000000000000000000000000000000000000000000000000000000000001"

      system_result =
        ingest_with_dep_scans(%{"jason" => dep_scan(sha)}, seed_files_dir([sha]), "rid-deps")

      scan = system_result.dependency_scans["jason"]

      assert scan["flags"] == ["nif"]
      assert scan["beam_count"] == 3
      assert scan["languages"] == ["c"]
      assert scan["footprint"]["total_bytes"] == 12_345

      refute Map.has_key?(scan["footprint"], "file_manifest")
    end

    test "still registers the artifacts that manifest named" do
      # The manifest is dropped from the column, not from the ingest: its shas
      # are staged into the artifact store before the transaction opens.
      sha = "bbbb000000000000000000000000000000000000000000000000000000000002"
      files_dir = seed_files_dir([sha])

      ingest_with_dep_scans(%{"jason" => dep_scan(sha)}, files_dir, "rid-deps-artifacts")

      artifacts = Ash.read!(Artifact, domain: Portal.Catalog)
      assert Enum.any?(artifacts, &(&1.sha256 == sha))
      assert File.exists?(ArtifactStore.blob_path(sha))
      refute File.exists?(Path.join(files_dir, sha))
    end

    test "leaves a scan that carries no footprint untouched" do
      scan = %{"flags" => [], "beam_count" => 0}

      system_result =
        ingest_with_dep_scans(%{"jason" => scan}, seed_files_dir([]), "rid-deps-nofootprint")

      assert system_result.dependency_scans["jason"] == scan
    end

    test "leaves the error map the worker emits when the scan itself failed" do
      # `analyze_dependency_beam_scans/2` returns `%{"__errors__" => [...]}` on
      # failure, so the values are not always scan maps.
      scans = %{"__errors__" => ["dependency beam scan failed: :enoent"]}

      system_result = ingest_with_dep_scans(scans, seed_files_dir([]), "rid-deps-errors")

      assert system_result.dependency_scans == scans
    end
  end
end
