defmodule Portal.Workers.ToolchainBuildTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import ExUnit.CaptureLog

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.Package
  alias Portal.Workers.{Ingest, ToolchainBuild}

  # Mimics `Portal.Builder` (`config :portal, :build_runner`), as in
  # `Portal.Workers.BuildTest`.
  defmodule StubBuilder do
    def build(args, _opts \\ []) do
      send(self(), {:build_args, args})

      if root = Process.get(:stub_scratch_root) do
        out = Path.join([root, args.run_id, "out"])
        File.mkdir_p!(out)
        if log = Process.get(:stub_runner_log), do: File.write!(Path.join(out, "runner.log"), log)
      end

      Process.get(:stub_build_response)
    end

    def cleanup(run_id) do
      send(self(), {:cleanup, run_id})
      :ok
    end

    def image_digest(image) do
      send(self(), {:image_digest, image})
      "sha256:toolchain-image"
    end
  end

  @args %{
    "package" => "jason",
    "version" => "1.4.4",
    "toolchain" => "1.19/28",
    "image" => "ncc-worker:elixir-1.19-otp-28",
    "builder_version" => 1
  }

  setup do
    Application.put_env(:portal, :build_runner, StubBuilder)
    on_exit(fn -> Application.delete_env(:portal, :build_runner) end)
    :ok
  end

  defp respond(exit_code, log \\ "") do
    Process.put(
      :stub_build_response,
      {:ok,
       %{
         exit_code: exit_code,
         result: if(exit_code == 0, do: %{"toolchain_build" => %{"status" => "pass"}}),
         files_dir: "/scratch/files",
         output_dir: "/scratch/out",
         log: log
       }}
    )
  end

  defp package!(name) do
    Package
    |> Ash.Changeset.for_create(:create, %{name: name})
    |> Ash.create!(domain: Catalog)
  end

  defp rows(name) do
    Portal.Catalog.ToolchainBuild
    |> Ash.Query.filter(package.name == ^name)
    |> Ash.read!(domain: Catalog)
  end

  test "builds in toolchain mode on the job's image" do
    respond(0)
    assert :ok = perform_job(ToolchainBuild, @args)

    assert_received {:image_digest, "ncc-worker:elixir-1.19-otp-28"}
    assert_received {:build_args, build_args}

    assert %{
             package: "jason",
             version: "1.4.4",
             image: "ncc-worker:elixir-1.19-otp-28",
             image_digest: "sha256:toolchain-image",
             mode: "toolchain",
             toolchain: %{elixir: "1.19", otp: "28"}
           } = build_args

    assert "tc-jason-1.4.4-" <> _ = build_args.run_id
  end

  describe "image resolution" do
    setup do
      original = Application.fetch_env!(:portal, Portal.Toolchains)
      on_exit(fn -> Application.put_env(:portal, Portal.Toolchains, original) end)

      put_images = fn images ->
        Application.put_env(:portal, Portal.Toolchains, Keyword.put(original, :images, images))
      end

      %{put_images: put_images}
    end

    test "builds on this node's image for the toolchain, not the job's", %{put_images: put} do
      put.([%{toolchain: "1.19/28", image: "registry.local/ncc:1.19-28"}])
      respond(0)

      assert :ok = perform_job(ToolchainBuild, @args)

      assert_received {:image_digest, "registry.local/ncc:1.19-28"}
      assert_received {:build_args, %{image: "registry.local/ncc:1.19-28"}}
    end

    test "falls back to the job's image, with a warning, when this node lacks the toolchain",
         %{put_images: put} do
      put.([%{toolchain: "1.20/29", image: "ncc-worker:local"}])
      respond(0)

      log = capture_log(fn -> assert :ok = perform_job(ToolchainBuild, @args) end)

      assert log =~ "1.19/28 is not configured on this node"
      assert_received {:build_args, %{image: "ncc-worker:elixir-1.19-otp-28"}}
    end
  end

  test "exit 0 hands the build to a toolchain ingest on this node's queue" do
    respond(0)
    assert :ok = perform_job(ToolchainBuild, @args)
    assert_received {:build_args, %{run_id: run_id}}

    assert_enqueued(
      worker: Ingest,
      queue: Ingest.local_queue(),
      args: %{
        "kind" => "toolchain",
        "run_id" => run_id,
        "image_digest" => "sha256:toolchain-image",
        "toolchain" => "1.19/28",
        "builder_version" => 1
      }
    )

    # The ingest reads the scratch dir, so the build leaves it alone.
    refute_received {:cleanup, _}
  end

  test "exit 11 records a fail row and cancels" do
    package!("jason")
    respond(11)

    assert {:cancel, _reason} = perform_job(ToolchainBuild, @args)

    assert [%{status: :fail, reason: "lock policy violation", toolchain: "1.19/28"} = row] =
             rows("jason")

    assert row.builder_version == 1
    assert row.finished_at
    assert_received {:cleanup, _}
    refute_enqueued(worker: Ingest)
  end

  test "exit 10 before the last attempt retries without a row" do
    package!("jason")
    respond(10)

    capture_log(fn ->
      assert {:error, _} = perform_job(ToolchainBuild, @args, attempt: 1)
    end)

    assert rows("jason") == []
    assert_received {:cleanup, _}
  end

  test "exit 10 on the last attempt records an error row with the log excerpt" do
    package!("jason")
    respond(10, "** (CompileError) lib/jason.ex:1: boom\n")

    capture_log(fn ->
      assert {:error, _} = perform_job(ToolchainBuild, @args, attempt: 2)
    end)

    assert [%{status: :error, reason: reason}] = rows("jason")
    assert reason =~ "worker/runner exit 10"
    assert reason =~ "boom"
  end

  test "a runner error on the last attempt records an error row" do
    package!("jason")
    root = Path.join(System.tmp_dir!(), "tc-build-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    Process.put(:stub_scratch_root, root)
    Process.put(:stub_runner_log, "docker: daemon went away\n")
    Process.put(:stub_build_response, {:error, {:docker_execution_failed, :closed}})

    Application.put_env(:portal, Portal.Builder, scratch_root: root)
    on_exit(fn -> Application.delete_env(:portal, Portal.Builder) end)

    capture_log(fn ->
      assert {:error, _} = perform_job(ToolchainBuild, @args, attempt: 2)
    end)

    assert [%{status: :error, reason: reason}] = rows("jason")
    assert reason =~ "docker_execution_failed"
    assert reason =~ "daemon went away"
  end

  test "an error after the last attempt does not replace a passing build" do
    package = package!("jason")

    Portal.Catalog.ToolchainBuild
    |> Ash.Changeset.for_create(:create, %{
      package_id: package.id,
      version: "1.4.4",
      toolchain: "1.19/28",
      builder_version: 1,
      status: :pass
    })
    |> Ash.create!(domain: Catalog)

    respond(10)

    capture_log(fn ->
      assert {:error, _} = perform_job(ToolchainBuild, @args, attempt: 2)
    end)

    assert [%{status: :pass}] = rows("jason")
  end
end
