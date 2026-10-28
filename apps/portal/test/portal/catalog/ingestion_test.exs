defmodule Portal.Catalog.IngestionTest do
  use Portal.DataCase, async: false

  require Ash.Query

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Portal.ArtifactStore
  alias Portal.Catalog.{Artifact, ArtifactMembership, Ingestion, Package, Run, SystemResult}
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

    Enum.each(shas, fn
      {sha, bytes} -> File.write!(Path.join(dir, sha), bytes)
      sha -> File.write!(Path.join(dir, sha), "precompiled-beam")
    end)

    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "ingests a result.json into Package + Run + SystemResults + Artifacts" do
    result = load_fixture()
    sha = "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"
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

  test "a blob that is already registered is left alone but still gets a membership" do
    result = load_fixture()
    sha = "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"

    {:ok, run1} =
      Ingestion.ingest(result, %{
        run_id: "rid-shared-1",
        image_digest: "sha256:1",
        files_dir: seed_files_dir([sha]),
        scan_request_id: nil
      })

    [before] =
      Artifact
      |> Ash.Query.filter(sha256 == ^sha)
      |> Ash.read!(domain: Portal.Catalog)

    {:ok, run2} =
      Ingestion.ingest(result, %{
        run_id: "rid-shared-2",
        image_digest: "sha256:2",
        files_dir: seed_files_dir([sha]),
        scan_request_id: nil
      })

    [after_second] =
      Artifact
      |> Ash.Query.filter(sha256 == ^sha)
      |> Ash.read!(domain: Portal.Catalog)

    assert after_second.id == before.id
    assert after_second.updated_at == before.updated_at

    runs =
      ArtifactMembership
      |> Ash.Query.filter(sha256 == ^sha)
      |> Ash.Query.load(:system_result)
      |> Ash.read!(domain: Portal.Catalog)
      |> Enum.map(& &1.system_result.run_id)
      |> Enum.uniq()
      |> Enum.sort()

    assert runs == Enum.sort([run1.id, run2.id])
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
      sha = :crypto.hash(:sha256, "dependency-beam") |> Base.encode16(case: :lower)

      system_result =
        ingest_with_dep_scans(
          %{"jason" => dep_scan(sha)},
          seed_files_dir([{sha, "dependency-beam"}]),
          "rid-deps"
        )

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
      sha = :crypto.hash(:sha256, "dependency-beam") |> Base.encode16(case: :lower)
      files_dir = seed_files_dir([{sha, "dependency-beam"}])

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
    sha = "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"

    Ingestion.ingest(load_fixture(), %{
      run_id: "log-jason-#{System.unique_integer([:positive])}",
      image_digest: "sha256:deadbeef",
      files_dir: seed_files_dir([sha]),
      output_dir: output_dir,
      log: "runner"
    })
  end

  describe "runner.log on the run row" do
    test "a passing run stores no runner.log" do
      # `catalog_runs.log` has no reader anywhere in the app, and passing runs
      # were 97% of the bytes in it. The per-system logs are unaffected.
      assert {:ok, run} = ingest_fixture(seed_output_dir(%{}))
      assert run.overall_status == :pass
      assert run.log == nil
    end

    test "a failing run keeps its runner.log" do
      files_dir = seed_files_dir([])

      {:ok, run} =
        Ingestion.ingest(load_fixture() |> Map.put("forced_status", "fail"), %{
          run_id: "rid-failed-log",
          image_digest: "sha256:1",
          files_dir: files_dir,
          scan_request_id: nil,
          log: "runner output"
        })

      assert run.overall_status == :fail
      assert run.log == "runner output"
    end
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

    # Rejecting `..` in the system name covers the name only. /out is a
    # read-write bind mount and the container runs as the invoking host user,
    # so package code can leave the log itself as a symlink to any file that
    # user can read, and `File.read/1` would follow it into a public log body.
    # `system_pkg` is a key from a result.json written inside a container that
    # runs untrusted package code, and the bytes at the path it builds become a
    # publicly readable log body. Nothing today can steer the key, but the guard
    # is what keeps that true.
    test "a build log for a traversing system name is never read" do
      output_dir = seed_output_dir(%{})
      secret = Path.join(output_dir, "secret.txt")
      File.write!(secret, "host filesystem contents")

      result =
        load_fixture()
        |> Map.put("systems", %{"../secret.txt" => %{"status" => "fail"}})

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
      assert log =~ "Refusing to read a build log for suspicious system"
      refute log =~ "host filesystem contents"
    end

    test "a build log that is a symlink is skipped" do
      output_dir = seed_output_dir(%{})
      secret = Path.join(output_dir, "secret.txt")
      File.write!(secret, "host filesystem contents")
      File.ln_s!(secret, Path.join([output_dir, "logs", "nerves_system_rpi4.log"]))

      result =
        load_fixture()
        |> Map.put("systems", %{"nerves_system_rpi4" => %{"status" => "fail"}})

      {ingest, log} =
        with_log(fn ->
          Ingestion.ingest(result, %{
            run_id: "symlink-#{System.unique_integer([:positive])}",
            image_digest: "sha256:deadbeef",
            files_dir: seed_files_dir([]),
            output_dir: output_dir,
            log: "runner"
          })
        end)

      assert {:ok, run} = ingest
      assert logs_by_system(run.id) == %{}
      assert log =~ "Refusing a non-regular build log"
      refute log =~ "host filesystem contents"
    end

    test "an ingest with no output_dir at all still succeeds" do
      sha = "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"

      assert {:ok, run} =
               Ingestion.ingest(load_fixture(), %{
                 run_id: "no-out-#{System.unique_integer([:positive])}",
                 image_digest: "sha256:deadbeef",
                 files_dir: seed_files_dir([sha]),
                 log: "runner"
               })

      assert logs_by_system(run.id) == %{}
    end

    # NccWorker.Worker.deps_get_verdict/3's shape for a deterministic
    # `deps.get` failure of the package under test: every system the run
    # would have built is `"status": "error"`, `"error": "deps_get_failed"`,
    # no `"host"` key. Confirms ingestion needs no change for it to land as a
    # one-time `:error` run with every system's log stored, instead of being
    # retried forever (the bug this verdict shape fixes).
    test "a deterministic deps_get_failed verdict ingests as one error run with every log stored" do
      systems = %{
        "nerves_system_rpi4" => %{
          "status" => "error",
          "duration_sec" => 0.0,
          "firmware_size_bytes" => nil,
          "log_tail" => "reckon_db supports Erlang/OTP 28; this is OTP 29.",
          "system_version" => nil,
          "beam_scan" => nil,
          "dependency_scans" => nil,
          "error" => "deps_get_failed"
        },
        "nerves_system_x86_64" => %{
          "status" => "error",
          "duration_sec" => 0.0,
          "firmware_size_bytes" => nil,
          "log_tail" => "reckon_db supports Erlang/OTP 28; this is OTP 29.",
          "system_version" => nil,
          "beam_scan" => nil,
          "dependency_scans" => nil,
          "error" => "deps_get_failed"
        }
      }

      output_dir =
        seed_output_dir(%{
          "nerves_system_rpi4" => "reckon_db supports Erlang/OTP 28; this is OTP 29.",
          "nerves_system_x86_64" => "reckon_db supports Erlang/OTP 28; this is OTP 29."
        })

      result =
        load_fixture()
        |> Map.put("systems", systems)
        |> Map.put("scope", "full")

      {:ok, run} =
        Ingestion.ingest(result, %{
          run_id: "deps-get-failed-1",
          image_digest: "sha256:deadbeef",
          files_dir: seed_files_dir([]),
          output_dir: output_dir,
          scan_request_id: nil,
          log: "build log"
        })

      assert run.overall_status == :error

      system_results =
        SystemResult
        |> Ash.Query.filter(run_id == ^run.id)
        |> Ash.read!(domain: Portal.Catalog)

      assert length(system_results) == 2
      assert Enum.all?(system_results, &(&1.status == :error))
      assert Enum.all?(system_results, &(&1.log_tail =~ "reckon_db supports Erlang/OTP 28"))

      logs = logs_by_system(run.id)
      assert Map.keys(logs) |> Enum.sort() == ["nerves_system_rpi4", "nerves_system_x86_64"]
      assert logs["nerves_system_rpi4"].body =~ "reckon_db supports Erlang/OTP 28"
    end
  end

  test "stores the argus result on the run, and nil when the worker sent none" do
    argus = %{"status" => "ok", "version" => "0.20.1", "findings" => [%{"title" => "t"}]}
    sha = "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"

    {:ok, run} =
      Ingestion.ingest(load_fixture() |> Map.put("argus", argus), %{
        run_id: "argus-1",
        image_digest: "sha256:argus",
        files_dir: seed_files_dir([sha]),
        scan_request_id: nil,
        log: "build log"
      })

    assert run.argus == argus

    {:ok, old} =
      Ingestion.ingest(load_fixture(), %{
        run_id: "argus-2",
        image_digest: "sha256:argus2",
        files_dir: seed_files_dir([sha]),
        scan_request_id: nil,
        log: "build log"
      })

    assert old.argus == nil
  end

  test "a skipped argus result's reason is stored verbatim, like every other argus field" do
    argus = %{
      "status" => "skipped",
      "reason" => "host_compile_failed",
      "error" => "host status: fail"
    }

    sha = "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"

    {:ok, run} =
      Ingestion.ingest(load_fixture() |> Map.put("argus", argus), %{
        run_id: "argus-skip-1",
        image_digest: "sha256:argus-skip",
        files_dir: seed_files_dir([sha]),
        scan_request_id: nil,
        log: "build log"
      })

    assert run.argus == argus
  end

  test "a non-map argus field is dropped rather than failing the ingest" do
    sha = "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"

    {:ok, run} =
      Ingestion.ingest(load_fixture() |> Map.put("argus", "garbage"), %{
        run_id: "argus-3",
        image_digest: "sha256:argus3",
        files_dir: seed_files_dir([sha]),
        scan_request_id: nil,
        log: "build log"
      })

    assert run.argus == nil
  end

  describe "deps_lock" do
    defp ingest_deps_lock(result) do
      sha = "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"

      {:ok, run} =
        Ingestion.ingest(result, %{
          run_id: "deps-lock-#{System.unique_integer([:positive])}",
          image_digest: "sha256:deps",
          files_dir: seed_files_dir([sha]),
          scan_request_id: nil,
          log: "build log"
        })

      run
    end

    test "is stored on the run, and nil when the worker sent none" do
      deps_lock = %{
        "spark" => %{"version" => "2.7.8", "checksum" => "abc"},
        "sourceror" => %{"version" => "1.10.0", "checksum" => "def"}
      }

      assert ingest_deps_lock(Map.put(load_fixture(), "deps_lock", deps_lock)).deps_lock ==
               deps_lock

      assert ingest_deps_lock(Map.put(load_fixture(), "deps_lock", %{})).deps_lock == %{}
      assert ingest_deps_lock(load_fixture()).deps_lock == nil
    end

    # The worker writes the whole closure or no key at all, because a subset
    # could let a client match a build it should not. A malformed entry means
    # the container misbehaved, and dropping just that entry would publish
    # exactly such a subset, so the whole lock goes instead.
    test "any malformed entry drops the whole lock rather than failing the ingest" do
      good = %{"spark" => %{"version" => "2.7.8", "checksum" => "abc"}}

      for {name, entry} <- [
            {"no_checksum", %{"version" => "1.0.0"}},
            {"no_version", %{"checksum" => "x"}},
            {"bad_version", %{"version" => 1, "checksum" => "x"}},
            {"bad_checksum", %{"version" => "1.0.0", "checksum" => nil}},
            {"not_a_map", "1.0.0"}
          ] do
        result = Map.put(load_fixture(), "deps_lock", Map.put(good, name, entry))
        assert ingest_deps_lock(result).deps_lock == nil, name
      end

      # JSON keys are always strings, so a non-binary name can only reach the
      # function from a caller that did not decode JSON.
      bad_name = Map.put(good, 1, %{"version" => "1.0.0", "checksum" => "x"})
      assert ingest_deps_lock(Map.put(load_fixture(), "deps_lock", bad_name)).deps_lock == nil

      assert ingest_deps_lock(Map.put(load_fixture(), "deps_lock", ["spark"])).deps_lock == nil
    end

    test "strips extra keys from a well-formed entry" do
      deps_lock = %{"extra" => %{"version" => "1.0.0", "checksum" => "y", "inner" => "z"}}

      assert ingest_deps_lock(Map.put(load_fixture(), "deps_lock", deps_lock)).deps_lock ==
               %{"extra" => %{"version" => "1.0.0", "checksum" => "y"}}
    end
  end

  describe "system deps_lock" do
    defp ingest_system_deps_lock(sys_deps_lock) do
      sha = "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"

      result =
        load_fixture()
        |> put_in(["systems", "nerves_system_rpi4", "deps_lock"], sys_deps_lock)

      {:ok, run} =
        Ingestion.ingest(result, %{
          run_id: "sys-deps-lock-#{System.unique_integer([:positive])}",
          image_digest: "sha256:deps",
          files_dir: seed_files_dir([sha]),
          scan_request_id: nil,
          log: "build log"
        })

      SystemResult
      |> Ash.Query.filter(run_id == ^run.id and system_pkg == "nerves_system_rpi4")
      |> Ash.read_one!(domain: Portal.Catalog)
    end

    # Mirrors the per-target optional-dependency pass: a passing target's own
    # lock, the run's plus the optional deps it kept.
    test "a well-formed system deps_lock is stored on that system" do
      deps_lock = %{
        "jason" => %{"version" => "1.4.4", "checksum" => "abc"},
        "telemetry" => %{"version" => "1.3.0", "checksum" => "def"}
      }

      assert ingest_system_deps_lock(deps_lock).deps_lock == deps_lock
    end

    # Same all-or-nothing contract as the run's deps_lock: the worker writes
    # the whole closure or nothing, so a malformed entry drops the whole
    # system lock rather than failing the ingest or publishing a subset.
    test "a malformed system deps_lock stores nil rather than failing the ingest" do
      assert ingest_system_deps_lock(%{"jason" => %{"version" => "1.4.4"}}).deps_lock == nil
    end

    test "a system with no deps_lock key stores nil" do
      sha = "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"

      {:ok, run} =
        Ingestion.ingest(load_fixture(), %{
          run_id: "sys-deps-lock-none-#{System.unique_integer([:positive])}",
          image_digest: "sha256:deps",
          files_dir: seed_files_dir([sha]),
          scan_request_id: nil,
          log: "build log"
        })

      system =
        SystemResult
        |> Ash.Query.filter(run_id == ^run.id and system_pkg == "nerves_system_rpi4")
        |> Ash.read_one!(domain: Portal.Catalog)

      assert system.deps_lock == nil
    end
  end

  describe "partial runs" do
    defp full_result(name, version, systems) do
      %{
        "package" => %{"name" => name, "version" => version},
        "finished_at" => "2026-10-10T10:00:00Z",
        "scope" => "full",
        "systems" => systems
      }
    end

    defp ingest!(result) do
      {:ok, run} =
        Ingestion.ingest(result, %{
          run_id: "r-#{System.unique_integer([:positive])}",
          image_digest: "sha256:x",
          files_dir: System.tmp_dir!()
        })

      run
    end

    defp systems_of(run) do
      SystemResult
      |> Ash.Query.filter(run_id == ^run.id)
      |> Ash.read!(domain: Portal.Catalog)
      |> Map.new(&{&1.system_pkg, &1})
    end

    test "an argus-only run keeps every target result of the previous run" do
      first =
        ingest!(
          full_result("carrypkg", "1.0.0", %{
            "host" => %{"status" => "pass"},
            "nerves_system_rpi4" => %{"status" => "pass", "firmware_size_bytes" => 123},
            "nerves_system_bbb" => %{"status" => "fail", "log_tail" => "boom"}
          })
        )

      second =
        ingest!(%{
          "package" => %{"name" => "carrypkg", "version" => "1.0.0"},
          "finished_at" => "2026-10-11T10:00:00Z",
          "scope" => "argus_only",
          "systems" => %{"host" => %{"status" => "pass"}}
        })

      systems = systems_of(second)
      assert Map.keys(systems) |> Enum.sort() == ~w(host nerves_system_bbb nerves_system_rpi4)
      assert systems["host"].carried_from_run_id == nil
      assert systems["nerves_system_rpi4"].carried_from_run_id == first.id
      assert systems["nerves_system_rpi4"].firmware_size_bytes == 123
      assert systems["nerves_system_bbb"].status == :fail
      assert systems["nerves_system_bbb"].log_tail == "boom"
      assert second.overall_status == :pass
    end

    # NccWorker.Worker.deps_get_verdict/3's argus_only shape for a
    # deterministic deps.get failure: no system entries at all, not even
    # "host". Every system of the previous run -- including host -- must
    # carry forward untouched; none of them may flip to "error" just
    # because an advisory argus sweep could not fetch the package's deps.
    test "an argus-only deps_get_failed verdict (no systems) carries every previous status, none flip to error" do
      first =
        ingest!(
          full_result("depsgetargus", "1.0.0", %{
            "host" => %{"status" => "pass"},
            "nerves_system_rpi4" => %{"status" => "pass", "firmware_size_bytes" => 123},
            "nerves_system_bbb" => %{"status" => "fail", "log_tail" => "boom"}
          })
        )

      second =
        ingest!(%{
          "package" => %{"name" => "depsgetargus", "version" => "1.0.0"},
          "finished_at" => "2026-10-11T10:00:00Z",
          "scope" => "argus_only",
          "systems" => %{},
          "argus" => %{"status" => "skipped", "reason" => "deps_get_failed"}
        })

      systems = systems_of(second)
      assert Map.keys(systems) |> Enum.sort() == ~w(host nerves_system_bbb nerves_system_rpi4)
      assert Enum.all?(Map.values(systems), &(&1.carried_from_run_id == first.id))
      refute Enum.any?(Map.values(systems), &(&1.status == :error))

      assert systems["host"].status == :pass
      assert systems["nerves_system_rpi4"].status == :pass
      assert systems["nerves_system_rpi4"].firmware_size_bytes == 123
      assert systems["nerves_system_bbb"].status == :fail
      assert systems["nerves_system_bbb"].log_tail == "boom"

      assert second.overall_status == :pass
      assert second.argus == %{"status" => "skipped", "reason" => "deps_get_failed"}
    end

    test "an argus-only run keeps the previous run's footprint" do
      first =
        ingest!(%{
          full_result("footpkg", "1.0.0", %{"nerves_system_rpi4" => %{"status" => "pass"}})
          | "package" => %{
              "name" => "footpkg",
              "version" => "1.0.0",
              "footprint" => %{"total_bytes" => 42}
            }
        })

      # The worker's argus-only result carries an empty but non-nil footprint.
      second =
        ingest!(%{
          "package" => %{
            "name" => "footpkg",
            "version" => "1.0.0",
            "footprint" => %{"total_bytes" => 0}
          },
          "finished_at" => "2026-10-11T10:00:00Z",
          "scope" => "argus_only",
          "systems" => %{"host" => %{"status" => "pass"}}
        })

      assert first.footprint == %{"total_bytes" => 42}
      assert second.footprint == first.footprint
    end

    test "a targets run keeps its own footprint" do
      ingest!(%{
        full_result("footpkg2", "1.0.0", %{"nerves_system_rpi4" => %{"status" => "pass"}})
        | "package" => %{
            "name" => "footpkg2",
            "version" => "1.0.0",
            "footprint" => %{"total_bytes" => 42}
          }
      })

      second =
        ingest!(%{
          "package" => %{
            "name" => "footpkg2",
            "version" => "1.0.0",
            "footprint" => %{"total_bytes" => 7}
          },
          "finished_at" => "2026-10-11T10:00:00Z",
          "scope" => "targets",
          "systems" => %{"nerves_system_rpi4" => %{"status" => "pass"}}
        })

      assert second.footprint == %{"total_bytes" => 7}
    end

    test "a targets run replaces only the targets it built" do
      first =
        ingest!(
          full_result("carrypkg2", "1.0.0", %{
            "nerves_system_rpi4" => %{"status" => "fail"},
            "nerves_system_bbb" => %{"status" => "pass"}
          })
        )

      second =
        ingest!(%{
          "package" => %{"name" => "carrypkg2", "version" => "1.0.0"},
          "finished_at" => "2026-10-11T10:00:00Z",
          "scope" => "targets",
          "systems" => %{"nerves_system_rpi4" => %{"status" => "pass"}}
        })

      systems = systems_of(second)
      assert systems["nerves_system_rpi4"].status == :pass
      assert systems["nerves_system_rpi4"].carried_from_run_id == nil
      assert systems["nerves_system_bbb"].carried_from_run_id == first.id
      assert systems["nerves_system_bbb"].status == :pass
    end

    test "a carried-forward system result keeps its compile_env" do
      compile_env = [%{"app" => "sample", "path" => ["mode"], "value" => "g2gCZAACb2tkAARmYXN0"}]

      first =
        ingest!(
          full_result("carryenvpkg", "1.0.0", %{
            "nerves_system_rpi4" => %{"status" => "pass", "compile_env" => compile_env},
            "nerves_system_bbb" => %{"status" => "pass"}
          })
        )

      second =
        ingest!(%{
          "package" => %{"name" => "carryenvpkg", "version" => "1.0.0"},
          "finished_at" => "2026-10-11T10:00:00Z",
          "scope" => "targets",
          "systems" => %{"nerves_system_bbb" => %{"status" => "pass"}}
        })

      systems = systems_of(second)
      assert systems["nerves_system_rpi4"].carried_from_run_id == first.id
      assert systems["nerves_system_rpi4"].compile_env == compile_env
    end

    test "a carried-forward system result keeps its own deps_lock" do
      deps_lock = %{"jason" => %{"version" => "1.4.4", "checksum" => "abc"}}

      first =
        ingest!(
          full_result("carrydepslockpkg", "1.0.0", %{
            "nerves_system_rpi4" => %{"status" => "pass", "deps_lock" => deps_lock},
            "nerves_system_bbb" => %{"status" => "pass"}
          })
        )

      second =
        ingest!(%{
          "package" => %{"name" => "carrydepslockpkg", "version" => "1.0.0"},
          "finished_at" => "2026-10-11T10:00:00Z",
          "scope" => "targets",
          "systems" => %{"nerves_system_bbb" => %{"status" => "pass"}}
        })

      systems = systems_of(second)
      assert systems["nerves_system_rpi4"].carried_from_run_id == first.id
      assert systems["nerves_system_rpi4"].deps_lock == deps_lock
      assert systems["nerves_system_bbb"].deps_lock == nil
    end

    test "keeps the original provenance across a chain of partial runs" do
      first =
        ingest!(
          full_result("chainpkg", "1.0.0", %{"nerves_system_rpi4" => %{"status" => "pass"}})
        )

      partial = fn ->
        ingest!(%{
          "package" => %{"name" => "chainpkg", "version" => "1.0.0"},
          "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "scope" => "argus_only",
          "systems" => %{"host" => %{"status" => "pass"}}
        })
      end

      partial.()
      third = partial.()

      assert systems_of(third)["nerves_system_rpi4"].carried_from_run_id == first.id
    end

    test "does not carry across versions" do
      ingest!(full_result("verpkg", "1.0.0", %{"nerves_system_rpi4" => %{"status" => "pass"}}))

      second =
        ingest!(%{
          "package" => %{"name" => "verpkg", "version" => "1.1.0"},
          "finished_at" => "2026-10-11T10:00:00Z",
          "scope" => "argus_only",
          "systems" => %{"host" => %{"status" => "fail"}}
        })

      assert Map.keys(systems_of(second)) == ["host"]
      # Nothing to carry, so the host compile is the only verdict there is.
      assert second.overall_status == :fail
    end

    test "with no previous run the partial run stands alone" do
      run =
        ingest!(%{
          "package" => %{"name" => "freshpkg", "version" => "1.0.0"},
          "finished_at" => "2026-10-11T10:00:00Z",
          "scope" => "argus_only",
          "systems" => %{"host" => %{"status" => "pass"}}
        })

      assert Map.keys(systems_of(run)) == ["host"]
      assert run.overall_status == :pass
    end

    test "a full run carries nothing" do
      ingest!(full_result("fullpkg", "1.0.0", %{"nerves_system_rpi4" => %{"status" => "pass"}}))
      second = ingest!(full_result("fullpkg", "1.0.0", %{"host" => %{"status" => "pass"}}))

      assert Map.keys(systems_of(second)) == ["host"]
    end

    test "copies the stored log and artifact memberships of a carried system" do
      first =
        ingest!(full_result("logpkg", "1.0.0", %{"nerves_system_bbb" => %{"status" => "fail"}}))

      [old] = Map.values(systems_of(first))
      sha = String.duplicate("ab", 32)

      Ash.create!(
        Portal.Catalog.SystemLog,
        %{system_result_id: old.id, body: "the log", byte_size: 7},
        action: :create,
        domain: Portal.Catalog
      )

      Ash.create!(ArtifactMembership, %{system_result_id: old.id, sha256: sha},
        action: :create,
        domain: Portal.Catalog
      )

      second =
        ingest!(%{
          "package" => %{"name" => "logpkg", "version" => "1.0.0"},
          "finished_at" => "2026-10-11T10:00:00Z",
          "scope" => "argus_only",
          "systems" => %{"host" => %{"status" => "pass"}}
        })

      assert {:ok, %{body: "the log"}} = Portal.Catalog.system_log("logpkg", "nerves_system_bbb")

      carried = systems_of(second)["nerves_system_bbb"]

      assert [%{sha256: ^sha}] =
               ArtifactMembership
               |> Ash.Query.filter(system_result_id == ^carried.id)
               |> Ash.read!(domain: Portal.Catalog)
    end
  end
end
