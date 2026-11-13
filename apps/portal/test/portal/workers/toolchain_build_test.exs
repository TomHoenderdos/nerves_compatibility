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
      Process.get(:stub_image_digest, "sha256:toolchain-image")
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

  defp job_args(extra), do: Map.merge(@args, extra)

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

  test "follows the run id's millisecond with a node-unique integer" do
    respond(0)
    assert :ok = perform_job(ToolchainBuild, @args)
    assert_received {:build_args, %{run_id: first}}

    # The millisecond is not enough: a package's builds on two toolchains
    # can start together, and the run id names the scratch dir and container.
    assert first =~ ~r/^tc-jason-1\.4\.4-\d+-\d+$/
  end

  test "snoozes without a build or a row when the image has no digest" do
    package!("jason")
    Process.put(:stub_image_digest, "sha256:" <> String.duplicate("0", 64))
    respond(0)

    log = capture_log(fn -> assert {:snooze, 900} = perform_job(ToolchainBuild, @args) end)

    assert log =~ ~s(image "ncc-worker:elixir-1.19-otp-28" has no digest)
    refute_received {:build_args, _}
    assert rows("jason") == []
  end

  test "a host without a build memory limit snoozes and cleans up" do
    Process.put(:stub_build_response, {:error, :build_memory_limit_missing})

    log = capture_log(fn -> assert {:snooze, 900} = perform_job(ToolchainBuild, @args) end)

    assert log =~ "No build memory limit"
    assert_received {:cleanup, _run_id}
  end

  test "a missing egress filter snoozes and cleans up" do
    Process.put(:stub_build_response, {:error, :egress_filter_missing})

    log = capture_log(fn -> assert {:snooze, 900} = perform_job(ToolchainBuild, @args) end)

    assert log =~ "egress filter missing"
    assert_received {:cleanup, _run_id}
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
        "version" => "1.4.4",
        "toolchain" => "1.19/28",
        "builder_version" => 1
      }
    )

    # The ingest reads the scratch dir, so the build leaves it alone.
    refute_received {:cleanup, _}
  end

  describe "config variants" do
    test "a named config variant reaches the builder and the ingest job" do
      respond(0)
      assert :ok = perform_job(ToolchainBuild, job_args(%{"config_variant" => "phx_prod"}))
      assert_received {:build_args, %{config_variant: "phx_prod"}}

      assert [%Oban.Job{args: %{"config_variant" => "phx_prod"}}] =
               all_enqueued(worker: Ingest)
    end

    test "a default job sends no config variant to the worker" do
      respond(0)
      assert :ok = perform_job(ToolchainBuild, job_args(%{}))
      assert_received {:build_args, build_args}
      assert Map.get(build_args, :config_variant) == nil

      assert [%Oban.Job{args: %{"config_variant" => "default"}}] =
               all_enqueued(worker: Ingest)
    end

    test "an explicit default job sends no config variant to the worker" do
      respond(0)
      assert :ok = perform_job(ToolchainBuild, job_args(%{"config_variant" => "default"}))
      assert_received {:build_args, build_args}
      assert Map.get(build_args, :config_variant) == nil
    end

    test "an unknown config variant is cancelled before anything runs" do
      respond(0)

      assert {:cancel, "unknown config variant \"phx_staging\""} =
               perform_job(ToolchainBuild, job_args(%{"config_variant" => "phx_staging"}))

      refute_received {:image_digest, _}
      refute_received {:build_args, _}
      refute_enqueued(worker: Ingest)
    end

    test "an unknown optional-deps variant is cancelled before anything runs" do
      respond(0)

      for variant <- ["world_phx", "default", nil, 1] do
        assert {:cancel, "unknown variant " <> _} =
                 perform_job(ToolchainBuild, job_args(%{"variant" => variant}))
      end

      refute_received {:image_digest, _}
      refute_received {:build_args, _}
      refute_enqueued(worker: Ingest)
      assert rows("jason") == []
    end

    test "a job without a variant is a with build; with and without build as named" do
      for {extra, optional_deps} <- [
            {%{}, "include"},
            {%{"variant" => "with"}, "include"},
            {%{"variant" => "without"}, "exclude"}
          ] do
        respond(0)
        assert :ok = perform_job(ToolchainBuild, job_args(extra))
        assert_received {:build_args, %{optional_deps: ^optional_deps}}
      end
    end

    test "a default job and a named job of one version are both queued" do
      base = %{
        package: "p",
        version: "1.0.0",
        toolchain: "1.19/28",
        image: "i",
        builder_version: 1,
        variant: "with"
      }

      insert = fn config_variant ->
        base |> Map.put(:config_variant, config_variant) |> ToolchainBuild.new() |> Oban.insert()
      end

      assert {:ok, %Oban.Job{conflict?: false}} = insert.("phx_prod")
      assert {:ok, %Oban.Job{conflict?: false}} = insert.("default")
      assert {:ok, %Oban.Job{conflict?: true}} = insert.("default")
    end

    test "a named failure records its row under the named variant" do
      Portal.PrecompiledFixtures.drop_legacy_identity_index!()
      package!("jason")
      respond(11)

      assert {:cancel, _} =
               perform_job(ToolchainBuild, job_args(%{"config_variant" => "phx_prod"}))

      assert [%{status: :fail, config_variant: "phx_prod"}] = rows("jason")
    end
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

    previous_builder = Application.get_env(:portal, Portal.Builder)
    Application.put_env(:portal, Portal.Builder, scratch_root: root)
    on_exit(fn -> restore_builder_env(previous_builder) end)

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

  # The cap counts transient results in a row; an error that is not one
  # breaks the run, so the kept row goes back to the weekly retry.
  test "an error after the last attempt resets a kept row's transient count" do
    package = package!("jason")

    Portal.Catalog.ToolchainBuild
    |> Ash.Changeset.for_create(:create, %{
      package_id: package.id,
      version: "1.4.4",
      toolchain: "1.19/28",
      builder_version: 1,
      status: :pass,
      transient_attempts: 1
    })
    |> Ash.create!(domain: Catalog)

    respond(10)

    capture_log(fn ->
      assert {:error, _} = perform_job(ToolchainBuild, @args, attempt: 2)
    end)

    assert [%{status: :pass, transient_attempts: 0, attempted_at: %DateTime{}}] = rows("jason")
  end

  describe "transient attempts" do
    # Two transient could-not-judge ingests of the job's identity: an `:error`
    # row counting 2.
    defp two_transients! do
      result = %{
        "scope" => "toolchain",
        "finished_at" => "2026-10-24T11:00:00Z",
        "package" => %{"name" => "jason", "version" => "1.4.4"},
        "systems" => %{},
        "toolchain_build" => %{
          "status" => "skipped",
          "reason" => "portability could not be judged",
          "elixir" => "1.19.1",
          "otp" => "28",
          "compile_observations" => %{
            "trace_stats" => %{"judge_compile" => "not_finished", "transient" => true}
          }
        }
      }

      for n <- 1..2 do
        opts = %{
          package: "jason",
          version: "1.4.4",
          toolchain: "1.19/28",
          builder_version: 1,
          run_id: "tc-transient-#{n}",
          image_digest: "sha256:toolchain-image",
          files_dir: System.tmp_dir!(),
          output_dir: System.tmp_dir!()
        }

        assert {:ok, _} = Portal.Catalog.Ingestion.ingest_toolchain(result, opts)
      end

      assert [%{status: :error, transient_attempts: 2}] = rows("jason")
    end

    test "an error on the last attempt keeps the count" do
      two_transients!()
      respond(10)

      capture_log(fn ->
        assert {:error, _} = perform_job(ToolchainBuild, @args, attempt: 2)
      end)

      assert [%{status: :error, reason: reason, transient_attempts: 2}] = rows("jason")
      assert reason =~ "worker/runner exit 10"
    end

    test "a policy violation is a verdict and resets the count" do
      two_transients!()
      respond(11)

      assert {:cancel, _reason} = perform_job(ToolchainBuild, @args)
      assert [%{status: :fail, transient_attempts: 0}] = rows("jason")
    end
  end

  # Puts back the Portal.Builder config the test found, the test.exs defaults
  # included (the image label stub among them). Deleting it instead left every
  # later test without those defaults, so a Portal.BuilderTest that ran
  # afterwards asked a real Docker daemon for the image label.
  defp restore_builder_env(nil), do: Application.delete_env(:portal, Portal.Builder)
  defp restore_builder_env(previous), do: Application.put_env(:portal, Portal.Builder, previous)

  describe "run memory" do
    @describetag :capture_log

    defp memory_rows, do: Ash.read!(Portal.Catalog.RunMemory, domain: Catalog)

    test "a successful build writes one toolchain row" do
      respond(0)
      assert :ok = perform_job(ToolchainBuild, @args)

      assert [row] = memory_rows()
      assert %{kind: :toolchain, exit_code: 0, oom_killed: false, toolchain: "1.19/28"} = row
      assert %{package: "jason", version: "1.4.4", image_digest: "sha256:toolchain-image"} = row
      assert "tc-jason-1.4.4-" <> _ = row.run_id
    end

    test "an OOM-killed container writes a row marked oom_killed" do
      respond(137)
      assert {:error, _} = perform_job(ToolchainBuild, @args)

      assert [%{kind: :toolchain, exit_code: 137, oom_killed: true}] = memory_rows()
    end

    test "a host-condition snooze ran no container and writes no row" do
      Process.put(:stub_build_response, {:error, :scratch_noexec})

      assert {:snooze, 900} = perform_job(ToolchainBuild, @args)
      assert memory_rows() == []
    end

    test "a runner failure ran no container and writes no row" do
      Process.put(:stub_build_response, {:error, :docker_unavailable})

      assert {:error, :docker_unavailable} = perform_job(ToolchainBuild, @args)
      assert memory_rows() == []
    end
  end

  # A toolchain run gets the smaller `NCC_TOOLCHAIN_MEMORY`; one OOM-killed
  # there retries at the build limit (`Portal.Workers.OomRetry`).
  describe "OOM retry" do
    @describetag :capture_log

    setup do
      previous = Application.get_env(:portal, Portal.Builder)

      Application.put_env(
        :portal,
        Portal.Builder,
        Keyword.merge(previous || [], memory: "6g", toolchain_memory: "2g")
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:portal, Portal.Builder, previous),
          else: Application.delete_env(:portal, Portal.Builder)
      end)

      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)

      package!("jason")
      respond(137)
      :ok
    end

    defp oom_job(error) do
      ToolchainBuild
      |> Oban.Testing.build_job(@args, attempt: 2)
      |> Map.put(:errors, [
        %{
          "attempt" => 1,
          "at" => "2026-11-12T10:00:00Z",
          "error" => "** (Oban.PerformError) Portal.Workers.ToolchainBuild failed with #{error}"
        }
      ])
    end

    test "attempt 2 after an exit 137 runs at the build memory limit" do
      job = oom_job(~s({:error, "worker/runner exit 137"}))

      log =
        capture_log([level: :info], fn ->
          assert {:error, _} = ToolchainBuild.perform(job)
        end)

      assert_received {:build_args, %{memory: "6g"} = args}
      refute Map.has_key?(args, :build_concurrency)
      assert log =~ "Retrying toolchain build jason 1.4.4"
      assert log =~ "after exit 137 at the build memory limit"
    end

    test "attempt 2 after another error keeps the toolchain limit" do
      job = oom_job(~s({:error, "worker/runner exit 10"}))
      capture_log(fn -> assert {:error, _} = ToolchainBuild.perform(job) end)

      assert_received {:build_args, args}
      refute Map.has_key?(args, :memory)
    end
  end
end
