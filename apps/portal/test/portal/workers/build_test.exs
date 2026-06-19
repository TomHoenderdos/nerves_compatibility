defmodule Portal.Workers.BuildTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query

  alias Portal.Catalog.{Package, Run}
  alias Portal.ScanRequests
  alias Portal.Workers.Build

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])

  defp fixture_result, do: @fixture |> File.read!() |> Jason.decode!()

  # A stub that mimics Portal.Builder.build/2 by returning a canned outcome.
  # Configured via `config :portal, :build_runner, StubBuilder` per-test.
  defmodule StubBuilder do
    def build(_args, _opts \\ []) do
      send(self(), :stub_build_called)
      Process.get(:stub_build_response)
    end

    def cleanup(_run_id), do: :ok
    def image_digest(_image), do: "sha256:stub"
    def docker_image, do: "ncc-worker:local"
  end

  setup do
    Application.put_env(:portal, :build_runner, StubBuilder)
    on_exit(fn -> Application.delete_env(:portal, :build_runner) end)
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

  describe "perform/1 success" do
    test "exit 0 ingests result and marks the request built" do
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

      runs = Ash.read!(Run, domain: Portal.Catalog)
      assert length(runs) == 1
      run = hd(runs)
      assert run.overall_status == :pass

      {:ok, updated} = ScanRequests.get_request(request.id)
      assert updated.status == :built
      assert updated.run_id == run.id
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
      # Early attempt leaves it queued/accepted, not error
      assert updated.status == :accepted
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
