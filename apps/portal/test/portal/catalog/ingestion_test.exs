defmodule Portal.Catalog.IngestionTest do
  use Portal.DataCase, async: false

  require Ash.Query

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Portal.ArtifactStore
  alias Portal.Catalog.{Artifact, Ingestion, Package, Run, SystemResult}
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

  # The worker writes one log per system under out/logs/<system_pkg>.log.
  defp seed_output_dir(logs) do
    dir = Path.join(System.tmp_dir!(), "ingest-out-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "logs"))

    Enum.each(logs, fn {system, body} ->
      File.write!(Path.join([dir, "logs", "#{system}.log"]), body)
    end)

    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp logs_by_system(run_id) do
    SystemResult
    |> Ash.Query.filter(run_id == ^run_id)
    |> Ash.Query.load(:system_log)
    |> Ash.read!(domain: Portal.Catalog)
    |> Enum.filter(& &1.system_log)
    |> Map.new(&{&1.system_pkg, &1.system_log})
  end

  defp ingest_fixture(output_dir) do
    sha = "aaaa000000000000000000000000000000000000000000000000000000000001"

    Ingestion.ingest(load_fixture(), %{
      run_id: "log-jason-#{System.unique_integer([:positive])}",
      image_digest: "sha256:deadbeef",
      files_dir: seed_files_dir([sha]),
      output_dir: output_dir,
      log: "runner"
    })
  end

  describe "per-system log capture" do
    test "stores a log for the failed system and nothing for the passing ones" do
      output_dir =
        seed_output_dir(%{
          "nerves_system_rpi4" => "passing log",
          "nerves_system_x86_64" => "== Compilation error in file lib/x.ex ==",
          "host" => "host log"
        })

      {:ok, run} = ingest_fixture(output_dir)

      logs = logs_by_system(run.id)

      assert Map.keys(logs) == ["nerves_system_x86_64"]
      assert logs["nerves_system_x86_64"].body =~ "Compilation error"
      assert logs["nerves_system_x86_64"].byte_size == 40
      refute logs["nerves_system_x86_64"].truncated
    end

    test "a log containing invalid UTF-8 ingests cleanly" do
      output_dir =
        seed_output_dir(%{"nerves_system_x86_64" => <<"boom ", 0xFF, " here">>})

      assert {:ok, run} = ingest_fixture(output_dir)
      assert logs_by_system(run.id)["nerves_system_x86_64"].body == "boom � here"
    end

    test "a missing log file ingests cleanly and creates no row" do
      assert {:ok, run} = ingest_fixture(seed_output_dir(%{}))
      assert logs_by_system(run.id) == %{}
    end

    # The reviewer's reproduction: a database error on the log insert used to
    # abort the whole ingest transaction, which burns an Oban attempt and, at
    # exhaustion, discards the completed build. Fails without the SAVEPOINT in
    # `insert_log/3` — the CHECK constraint stands in for the transport errors
    # (pool timeout, dropped connection, statement timeout) that cause it in
    # production, since no log *content* can reach Postgres badly formed.
    test "a database error inserting the log still commits the run" do
      Portal.Repo.query!(
        "ALTER TABLE catalog_system_logs ADD CONSTRAINT ncc_probe_no_boom " <>
          "CHECK (body NOT LIKE '%rejected-by-postgres%')"
      )

      output_dir =
        seed_output_dir(%{"nerves_system_x86_64" => "rejected-by-postgres: build failed"})

      {run, _log} = with_log(fn -> ingest_fixture(output_dir) end)

      assert {:ok, run} = run

      # The log row is the only casualty.
      assert logs_by_system(run.id) == %{}

      # The run and every system result are readable, so the transaction
      # committed rather than rolling back.
      assert %Run{} = Ash.get!(Run, run.id, domain: Portal.Catalog)

      system_results =
        SystemResult
        |> Ash.Query.filter(run_id == ^run.id)
        |> Ash.read!(domain: Portal.Catalog)

      assert length(system_results) == 3
    end

    test "a system name that escapes the logs directory is skipped" do
      output_dir = seed_output_dir(%{})
      File.write!(Path.join(output_dir, "secret.log"), "host filesystem contents")

      result =
        load_fixture()
        |> Map.put("systems", %{
          "../../etc/passwd" => %{"status" => "fail"},
          "../secret" => %{"status" => "fail"}
        })

      {ingest, log} =
        with_log(fn ->
          Ingestion.ingest(result, %{
            run_id: "traversal-#{System.unique_integer([:positive])}",
            image_digest: "sha256:deadbeef",
            files_dir: seed_files_dir([]),
            output_dir: output_dir,
            log: "runner"
          })
        end)

      assert {:ok, run} = ingest
      assert logs_by_system(run.id) == %{}
      assert log =~ "Refusing to read a build log"
      refute log =~ "host filesystem contents"
    end

    test "an ingest with no output_dir at all still succeeds" do
      sha = "aaaa000000000000000000000000000000000000000000000000000000000001"

      assert {:ok, run} =
               Ingestion.ingest(load_fixture(), %{
                 run_id: "no-out-#{System.unique_integer([:positive])}",
                 image_digest: "sha256:deadbeef",
                 files_dir: seed_files_dir([sha]),
                 log: "runner"
               })

      assert logs_by_system(run.id) == %{}
    end
  end
end
