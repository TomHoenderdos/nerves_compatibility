defmodule Portal.Workers.BuildTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import ExUnit.CaptureLog

  require Ash.Query

  alias Portal.Catalog.{Package, Run}
  alias Portal.ScanRequests
  alias Portal.Workers.{Build, Ingest}

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])

  defp fixture_result, do: @fixture |> File.read!() |> Jason.decode!()

  # A stub that mimics Portal.Builder.build/2 by returning a canned outcome.
  # Configured via `config :portal, :build_runner, StubBuilder` per-test.
  defmodule StubBuilder do
    def build(_args, _opts \\ []) do
      send(self(), :stub_build_called)

      case Process.get(:stub_build_response) do
        # Portal.Builder raises rather than returns for some failures — a full
        # disk makes IO.binwrite/2 raise :enospc while streaming docker output.
        {:raise, exception} -> raise exception
        response -> response
      end
    end

    def cleanup(_run_id), do: :ok

    def image_digest(_image), do: "sha256:stub"
    def docker_image, do: "ncc-worker:local"

    # The ingest job re-reads the build from its scratch dir. There is no
    # scratch dir here, so replay whatever build/2 was told to return.
    def load_run(_run_id) do
      case Process.get(:stub_build_response) do
        {:ok, build} -> {:ok, build}
        _ -> {:error, :missing_result_json}
      end
    end
  end

  defmodule StubVersions do
    def latest_version(_package), do: {:ok, "1.0.0"}
  end

  setup do
    Application.put_env(:portal, :build_runner, StubBuilder)
    Application.put_env(:portal, :package_version_resolver, StubVersions)

    on_exit(fn ->
      Application.delete_env(:portal, :build_runner)
      Application.delete_env(:portal, :package_version_resolver)
    end)

    :ok
  end

  defp set_response(resp), do: Process.put(:stub_build_response, resp)

  defp files_dir_with(shas) do
    dir = Path.join(System.tmp_dir!(), "build-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Enum.each(shas, fn sha -> File.write!(Path.join(dir, sha), "blob") end)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  describe "classify/1" do
    test "maps exit codes to outcomes per the contract" do
      assert Build.classify(0) == :ingest
      assert Build.classify(11) == {:reject, "non-Hex dep"}
      assert Build.classify(10) == :retry
      assert Build.classify(20) == :retry
      assert Build.classify(21) == :retry
      assert Build.classify(99) == :retry
    end
  end

  # The build job hands off to Portal.Workers.Ingest rather than writing rows
  # itself, so a success case has to drain that queue too. Both run in the test
  # process, which owns the sandbox connection.
  defp run_enqueued_ingest do
    assert [job] = all_enqueued(worker: Ingest)
    Ingest.perform(%Oban.Job{args: job.args, attempt: 1, max_attempts: 5})
  end

  describe "perform/1 success" do
    test "exit 0 enqueues the ingest, which ingests and marks the request built" do
      {:ok, request} =
        ScanRequests.create_once(%{package_name: "jason", source: :hex_owner, status: :accepted})

      files_dir =
        files_dir_with(["aaaa000000000000000000000000000000000000000000000000000000000001"])

      set_response(
        {:ok,
         %{
           exit_code: 0,
           result: fixture_result(),
           files_dir: files_dir,
           output_dir: files_dir,
           log: "ok"
         }}
      )

      assert :ok =
               perform_job(Build, %{
                 "package" => "jason",
                 "version" => "1.4.1",
                 "image_digest" => "sha256:deadbeef",
                 "scan_request_id" => request.id
               })

      assert_received :stub_build_called

      # Nothing is in the Catalog until the ingest job runs.
      assert Ash.read!(Run, domain: Portal.Catalog) == []
      assert :ok = run_enqueued_ingest()

      runs = Ash.read!(Run, domain: Portal.Catalog)
      assert length(runs) == 1
      run = hd(runs)
      assert run.overall_status == :pass

      {:ok, updated} = ScanRequests.get_request(request.id)
      assert updated.status == :built
      assert updated.run_id == run.id
    end
  end

  describe "ingest retries" do
    test "a failed ingest retries on its own without touching the build" do
      files_dir = files_dir_with([])

      # A result the Ingestion cannot map to Catalog rows.
      set_response(
        {:ok,
         %{
           exit_code: 0,
           result: %{"garbage" => true},
           files_dir: files_dir,
           output_dir: files_dir,
           log: "ok"
         }}
      )

      assert :ok =
               perform_job(Build, %{
                 "package" => "jason",
                 "version" => "1.4.1",
                 "image_digest" => "sha256:deadbeef"
               })

      assert [job] = all_enqueued(worker: Ingest)

      assert {:error, _reason} =
               Ingest.perform(%Oban.Job{args: job.args, attempt: 1, max_attempts: 5})

      # The retry is the ingest job's, not the build's: no second build was run.
      assert_received :stub_build_called
      refute_received :stub_build_called
    end
  end

  describe "perform/1 policy rejection (exit 11)" do
    test "cancels without retry and marks the request rejected" do
      {:ok, request} =
        ScanRequests.create_once(%{package_name: "gitdep", source: :hex_owner, status: :accepted})

      files_dir = files_dir_with([])

      set_response(
        {:ok,
         %{exit_code: 11, result: nil, files_dir: files_dir, output_dir: files_dir, log: "policy"}}
      )

      assert {:cancel, "non-Hex dep"} =
               perform_job(Build, %{
                 "package" => "gitdep",
                 "version" => "1.0.0",
                 "image_digest" => "sha256:x",
                 "scan_request_id" => request.id
               })

      # No run ingested
      assert Ash.read!(Run, domain: Portal.Catalog) == []

      {:ok, updated} = ScanRequests.get_request(request.id)
      assert updated.status == :rejected
      assert updated.error_reason == "non-Hex dep"
    end
  end

  describe "perform/1 retryable failure (exit 10)" do
    test "returns error to trigger retry; request not yet errored on early attempt" do
      {:ok, request} =
        ScanRequests.create_once(%{package_name: "flaky", source: :hex_owner, status: :accepted})

      files_dir = files_dir_with([])

      set_response(
        {:ok,
         %{exit_code: 10, result: nil, files_dir: files_dir, output_dir: files_dir, log: "boom"}}
      )

      job = %Oban.Job{
        args: %{
          "package" => "flaky",
          "version" => "1.0.0",
          "image_digest" => "sha256:x",
          "scan_request_id" => request.id
        },
        attempt: 1,
        max_attempts: 3
      }

      assert {:error, _reason} = Build.perform(job)

      {:ok, updated} = ScanRequests.get_request(request.id)
      # Early attempt leaves it queued, not error
      assert updated.status == :queued
    end

    test "marks request error on the final attempt" do
      {:ok, request} =
        ScanRequests.create_once(%{package_name: "doomed", source: :hex_owner, status: :accepted})

      files_dir = files_dir_with([])

      set_response(
        {:ok,
         %{exit_code: 21, result: nil, files_dir: files_dir, output_dir: files_dir, log: "x"}}
      )

      job = %Oban.Job{
        args: %{
          "package" => "doomed",
          "version" => "1.0.0",
          "image_digest" => "sha256:x",
          "scan_request_id" => request.id
        },
        attempt: 3,
        max_attempts: 3
      }

      assert {:error, _reason} = Build.perform(job)

      {:ok, updated} = ScanRequests.get_request(request.id)
      assert updated.status == :error
    end

    test "a crashing build still frees the scratch dir and marks the request" do
      {:ok, request} =
        ScanRequests.create_once(%{
          package_name: "crasher",
          source: :hex_owner,
          status: :accepted
        })

      set_response({:raise, %ErlangError{original: :enospc}})

      job = %Oban.Job{
        args: %{
          "package" => "crasher",
          "version" => "1.0.0",
          "image_digest" => "sha256:x",
          "scan_request_id" => request.id
        },
        attempt: 3,
        max_attempts: 3
      }

      # The exception must still reach Oban, so it records the real error.
      log = capture_log(fn -> assert_raise ErlangError, fn -> Build.perform(job) end end)

      # Proves the crash path ran its bookkeeping. `Portal.Builder.cleanup/1` is
      # called directly rather than through the stub, so the log is the seam.
      assert log =~ "Build crashed for run"

      {:ok, updated} = ScanRequests.get_request(request.id)
      assert updated.status == :error
    end

    test "a crash before the last attempt frees scratch but leaves the request retryable" do
      {:ok, request} =
        ScanRequests.create_once(%{
          package_name: "crasher2",
          source: :hex_owner,
          status: :accepted
        })

      set_response({:raise, %ErlangError{original: :enospc}})

      job = %Oban.Job{
        args: %{
          "package" => "crasher2",
          "version" => "1.0.0",
          "image_digest" => "sha256:x",
          "scan_request_id" => request.id
        },
        attempt: 1,
        max_attempts: 3
      }

      log = capture_log(fn -> assert_raise ErlangError, fn -> Build.perform(job) end end)

      # The scratch dir goes either way; only the terminal status waits for the
      # attempts to be spent.
      assert log =~ "Build crashed for run"

      {:ok, updated} = ScanRequests.get_request(request.id)
      refute updated.status == :error
    end
  end

  describe "perform/1 dedupe" do
    test "skips build when a run already exists for (package, version, image_digest)" do
      package =
        Package
        |> Ash.Changeset.for_create(:create, %{name: "dup"})
        |> Ash.create!(domain: Portal.Catalog)

      Run
      |> Ash.Changeset.for_create(:create, %{
        run_id: "existing",
        package_id: package.id,
        version_tested: "1.0.0",
        image_digest: "sha256:dup",
        overall_status: :pass
      })
      |> Ash.create!(domain: Portal.Catalog)

      # No stub response set: if build/2 were called it would crash with nil.
      assert :ok =
               perform_job(Build, %{
                 "package" => "dup",
                 "version" => "1.0.0",
                 "image_digest" => "sha256:dup"
               })

      refute_received :stub_build_called
    end
  end
end
