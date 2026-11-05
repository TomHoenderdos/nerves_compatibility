defmodule Portal.Workers.IngestIdentityTest do
  # An ingest job records what the job it was enqueued for asked to build:
  # its package and version, and for a toolchain build its toolchain. The
  # build's result.json has to agree with that before anything is recorded or
  # published, and the job's identity, not the result's, is what the rows are
  # written under.
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import ExUnit.CaptureLog

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.{ArtifactMembership, Package, Run, ToolchainBuild}
  alias Portal.Workers.{Build, Ingest}

  # Replays the build the test put in the process dictionary, as the scratch
  # dir would.
  defmodule StubBuilder do
    def build(_args, _opts \\ []), do: Process.get(:identity_build_response)
    def cleanup(run_id), do: send(self(), {:cleanup, run_id}) && :ok
    def image_digest(_image), do: "sha256:identity"
    def docker_image, do: "ncc-worker:local"

    def load_run(_run_id) do
      case Process.get(:identity_build) do
        nil -> {:error, :missing_result_json}
        build -> {:ok, build}
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

  defp sha(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp unique(prefix),
    do:
      "#{prefix}_#{System.unique_integer([:positive])}_#{Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)}"

  defp files_dir_with(contents) do
    dir = Path.join(System.tmp_dir!(), "identity-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Enum.each(contents, &File.write!(Path.join(dir, sha(&1)), &1))
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp entry(path, content),
    do: %{
      "path" => path,
      "sha256" => sha(content),
      "size" => byte_size(content),
      "mode" => 33_188
    }

  # A full run's result.json for `name` `version`, publishing one host beam.
  defp run_result(name, version, beam) do
    %{
      "package" => %{"name" => name, "version" => version},
      "finished_at" => "2026-11-05T10:00:00Z",
      "scope" => "full",
      "systems" => %{
        "host" => %{
          "status" => "pass",
          "beam_scan" => %{
            "footprint" => %{"file_manifest" => %{"ebin" => [entry("ebin/#{name}.beam", beam)]}}
          }
        }
      }
    }
  end

  defp toolchain_result(name, version, beam, opts \\ []) do
    %{
      "scope" => "toolchain",
      "finished_at" => "2026-11-05T10:00:00Z",
      "package" => %{"name" => name, "version" => version},
      "systems" => %{},
      "toolchain_build" => %{
        "status" => "pass",
        "reason" => nil,
        "elixir" => Keyword.get(opts, :elixir, "1.19.1"),
        "otp" => Keyword.get(opts, :otp, "28"),
        "deps_lock" => %{},
        "package_checksum" => "outer",
        "compile_env" => [],
        "file_manifest" => %{"ebin" => [entry("ebin/#{name}.beam", beam)], "priv" => []}
      }
    }
  end

  defp replay(result, files_dir) do
    Process.put(:identity_build, %{
      exit_code: 0,
      result: result,
      files_dir: files_dir,
      output_dir: files_dir,
      log: "runner log"
    })
  end

  defp runs_of(name),
    do: Run |> Ash.Query.filter(package.name == ^name) |> Ash.read!(domain: Catalog)

  defp toolchain_rows_of(name),
    do: ToolchainBuild |> Ash.Query.filter(package.name == ^name) |> Ash.read!(domain: Catalog)

  defp membership?(content) do
    ArtifactMembership
    |> Ash.Query.filter(sha256 == ^sha(content))
    |> Ash.exists?(domain: Catalog)
  end

  defp package?(name),
    do: Package |> Ash.Query.filter(name == ^name) |> Ash.exists?(domain: Catalog)

  defp ingest(args) do
    Ingest.perform(%Oban.Job{args: args, attempt: 1, max_attempts: 5})
  end

  describe "the jobs that enqueue an ingest" do
    test "a build hands its package and version to the ingest" do
      Process.put(
        :identity_build_response,
        {:ok, %{exit_code: 0, result: %{}, files_dir: "/f", output_dir: "/o", log: ""}}
      )

      assert :ok =
               perform_job(Build, %{
                 "package" => "jason",
                 "version" => "1.4.4",
                 "image_digest" => "sha256:identity"
               })

      assert [job] = all_enqueued(worker: Ingest)
      assert %{"package" => "jason", "version" => "1.4.4"} = job.args
    end

    test "a toolchain build hands its package, version and toolchain to the ingest" do
      Process.put(
        :identity_build_response,
        {:ok,
         %{
           exit_code: 0,
           result: %{"toolchain_build" => %{"status" => "pass"}},
           files_dir: "/f",
           output_dir: "/o",
           log: ""
         }}
      )

      assert :ok =
               perform_job(Portal.Workers.ToolchainBuild, %{
                 "package" => "jason",
                 "version" => "1.4.4",
                 "toolchain" => "1.19/28",
                 "image" => "ncc-worker:elixir-1.19-otp-28",
                 "builder_version" => 1
               })

      assert [job] = all_enqueued(worker: Ingest)

      assert %{"package" => "jason", "version" => "1.4.4", "toolchain" => "1.19/28"} =
               job.args
    end
  end

  describe "a local run's ingest" do
    defp run_args(name, version) do
      %{
        "run_id" => "run-#{name}",
        "image_digest" => "sha256:identity",
        "package" => name,
        "version" => version
      }
    end

    test "records a result that matches its job, under the job's identity" do
      name = unique("idok")
      beam = "beam-#{name}"
      replay(run_result(name, "1.0.0", beam), files_dir_with([beam]))

      assert :ok = ingest(run_args(name, "1.0.0"))
      assert [%{version_tested: "1.0.0"}] = runs_of(name)
    end

    test "refuses a result for another package, and records nothing" do
      wanted = unique("idwanted")
      other = unique("idother")
      beam = "beam-#{other}"
      replay(run_result(other, "1.0.0", beam), files_dir_with([beam]))

      log = capture_log(fn -> refute ingest(run_args(wanted, "1.0.0")) == :ok end)

      assert runs_of(wanted) == []
      assert runs_of(other) == []
      refute package?(other)
      refute membership?(beam)
      assert log =~ wanted
      assert log =~ other
    end

    test "refuses a result for another version, and records nothing" do
      name = unique("idver")
      beam = "beam-#{name}"
      replay(run_result(name, "9.9.9", beam), files_dir_with([beam]))

      log = capture_log(fn -> refute ingest(run_args(name, "1.0.0")) == :ok end)

      assert runs_of(name) == []
      refute membership?(beam)
      assert log =~ "1.0.0"
      assert log =~ "9.9.9"
    end

    # Queued before jobs carried an identity: nothing to check the result
    # against, so it is not taken on trust.
    test "refuses a job that does not say what it built" do
      name = unique("idold")
      beam = "beam-#{name}"
      replay(run_result(name, "1.0.0", beam), files_dir_with([beam]))

      capture_log(fn ->
        refute ingest(%{"run_id" => "run-#{name}", "image_digest" => "sha256:identity"}) == :ok
      end)

      assert runs_of(name) == []
      refute membership?(beam)
    end
  end

  describe "a toolchain build's ingest" do
    defp toolchain_args(name, version, toolchain \\ "1.19/28") do
      %{
        "run_id" => "tc-#{name}",
        "image_digest" => "sha256:identity",
        "kind" => "toolchain",
        "package" => name,
        "version" => version,
        "toolchain" => toolchain,
        "builder_version" => 1
      }
    end

    test "records a result that matches its job" do
      name = unique("tcok")
      beam = "beam-#{name}"
      replay(toolchain_result(name, "1.0.0", beam), files_dir_with([beam]))

      assert :ok = ingest(toolchain_args(name, "1.0.0"))
      assert [%{version: "1.0.0", toolchain: "1.19/28", status: :pass}] = toolchain_rows_of(name)
    end

    test "refuses a result for another package, and publishes nothing" do
      wanted = unique("tcwanted")
      other = unique("tcother")
      beam = "beam-#{other}"
      replay(toolchain_result(other, "1.0.0", beam), files_dir_with([beam]))

      log = capture_log(fn -> refute ingest(toolchain_args(wanted, "1.0.0")) == :ok end)

      assert toolchain_rows_of(wanted) == []
      assert toolchain_rows_of(other) == []
      refute package?(other)
      refute membership?(beam)
      assert log =~ wanted
      assert log =~ other
    end

    test "refuses a result for another version, and publishes nothing" do
      name = unique("tcver")
      beam = "beam-#{name}"
      replay(toolchain_result(name, "9.9.9", beam), files_dir_with([beam]))

      capture_log(fn -> refute ingest(toolchain_args(name, "1.0.0")) == :ok end)

      assert toolchain_rows_of(name) == []
      refute membership?(beam)
    end

    # Built on another Elixir minor or OTP major than the job asked for: the
    # files would be served to clients of the wrong toolchain.
    test "refuses a result built on another toolchain, and publishes nothing" do
      name = unique("tctc")
      beam = "beam-#{name}"

      replay(
        toolchain_result(name, "1.0.0", beam, elixir: "1.20.0", otp: "29"),
        files_dir_with([beam])
      )

      capture_log(fn -> refute ingest(toolchain_args(name, "1.0.0", "1.19/28")) == :ok end)

      assert toolchain_rows_of(name) == []
      refute membership?(beam)
    end

    test "refuses a job that does not say which package it built" do
      name = unique("tcold")
      beam = "beam-#{name}"
      replay(toolchain_result(name, "1.0.0", beam), files_dir_with([beam]))

      capture_log(fn ->
        refute ingest(Map.delete(toolchain_args(name, "1.0.0"), "package")) == :ok
      end)

      assert toolchain_rows_of(name) == []
      refute membership?(beam)
    end
  end
end
