defmodule Portal.Workers.BuildTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import ExUnit.CaptureLog

  require Ash.Query

  alias Portal.Catalog.{Package, Run}
  alias Portal.ScanRequests
  alias Portal.Workers.{Build, Ingest, PackageMeta, WarmNerves}

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])

  defp fixture_result, do: @fixture |> File.read!() |> Jason.decode!()

  # A stub that mimics Portal.Builder.build/2 by returning a canned outcome.
  # Configured via `config :portal, :build_runner, StubBuilder` per-test.
  defmodule StubBuilder do
    def build(args, _opts \\ []) do
      send(self(), :stub_build_called)

      # Portal.Builder creates the scratch dir before it runs docker, so a
      # failure returned from here still leaves one on disk — including the
      # runner.log the failure paths read before cleanup.
      if root = Process.get(:stub_scratch_root) do
        out = Path.join([root, args.run_id, "out"])
        File.mkdir_p!(out)

        if log = Process.get(:stub_runner_log) do
          File.write!(Path.join(out, "runner.log"), log)
        end

        # What the container left in /out, e.g. build cache candidates.
        if fill = Process.get(:stub_fill_out), do: fill.(out)
      end

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

  defp previous_run!(name, version) do
    {:ok, _} =
      Portal.Catalog.Ingestion.ingest(
        %{
          "package" => %{"name" => name, "version" => version},
          "finished_at" => "2026-10-10T10:00:00Z",
          "systems" => %{"host" => %{"status" => "pass"}}
        },
        %{
          run_id: "prev-#{System.unique_integer([:positive])}",
          image_digest: "sha256:x",
          files_dir: System.tmp_dir!()
        }
      )
  end

  defp files_dir_with(shas) do
    dir = Path.join(System.tmp_dir!(), "build-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Enum.each(shas, fn sha -> File.write!(Path.join(dir, sha), "precompiled-beam") end)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  describe "scope_args/3" do
    test "a full or missing scope builds everything" do
      assert Build.scope_args("p", "1.0.0", %{}) == %{systems_filter: nil, mode: nil}

      assert Build.scope_args("p", "1.0.0", %{"scope" => "full"}) == %{
               systems_filter: nil,
               mode: nil
             }
    end

    test "a targets scope passes its systems when the latest run is on this version" do
      previous_run!("scoped", "1.0.0")

      assert Build.scope_args("scoped", "1.0.0", %{
               "scope" => "targets",
               "systems" => ["nerves_system_rpi4"]
             }) ==
               %{systems_filter: ["nerves_system_rpi4"], mode: nil}
    end

    test "argus-only passes the mode when the latest run is on this version" do
      previous_run!("scoped2", "1.0.0")

      assert Build.scope_args("scoped2", "1.0.0", %{"scope" => "argus_only"}) == %{
               systems_filter: nil,
               mode: "argus_only"
             }
    end

    # A partial run only makes sense on top of a full one for the same
    # version: there is nothing to carry from an older release.
    test "a partial scope on a new version becomes a full build" do
      previous_run!("scoped3", "1.0.0")

      assert Build.scope_args("scoped3", "2.0.0", %{"scope" => "argus_only"}) == %{
               systems_filter: nil,
               mode: nil
             }
    end

    test "a targets scope with no systems builds everything" do
      previous_run!("scoped4", "1.0.0")

      assert Build.scope_args("scoped4", "1.0.0", %{"scope" => "targets", "systems" => []}) == %{
               systems_filter: nil,
               mode: nil
             }
    end
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

    # The ingest reads the build's scratch dir off local disk, so it has to land
    # on this node's own queue, not the shared `:ingest` one another build host
    # could take it from.
    assert job.queue == Ingest.local_queue()

    Ingest.perform(%Oban.Job{args: job.args, attempt: 1, max_attempts: 5})
  end

  describe "perform/1 success" do
    test "exit 0 enqueues the ingest, which ingests and marks the request built" do
      {:ok, request} =
        ScanRequests.create_once(%{package_name: "jason", source: :hex_owner, status: :accepted})

      files_dir =
        files_dir_with(["ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"])

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

    # Every package that enters the catalog passes through the ingest, which is
    # what keeps hex.pm metadata in step without a scheduled sweep. Enqueued
    # after the rows commit and outside their transaction, so a hex.pm problem
    # can never roll back a finished build.
    test "a successful ingest queues the package's hex.pm metadata refresh" do
      files_dir =
        files_dir_with(["ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"])

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
                 "image_digest" => "sha256:deadbeef"
               })

      assert all_enqueued(worker: PackageMeta) == []
      assert :ok = run_enqueued_ingest()

      assert [%{args: %{"package" => "jason"}}] = all_enqueued(worker: PackageMeta)
    end
  end

  describe "build cache promotion" do
    @outer "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30684"

    setup do
      root = Path.join(System.tmp_dir!(), "build-promo-#{System.unique_integer([:positive])}")
      scratch = Path.join(root, "scratch")
      cache = Path.join(root, "cache")
      File.mkdir_p!(scratch)
      on_exit(fn -> File.rm_rf(root) end)

      Application.put_env(:portal, Portal.Builder, scratch_root: scratch, build_cache: cache)
      on_exit(fn -> Application.delete_env(:portal, Portal.Builder) end)
      on_exit(fn -> Application.delete_env(:portal, Portal.BuildCache.Promotion) end)
      Process.put(:stub_scratch_root, scratch)

      candidate = %{
        "dep" => "jason",
        "dep_lock" =>
          "1.4.5 2e3a008590b0b8d7388c20293e9dcc9cf3e5d642fd2a114e4cbbb52e595d940a #{@outer}",
        "target" => "host",
        "elixir" => "1.16.0",
        "otp" => "26",
        "closure" => []
      }

      {:ok, key} =
        Compatibility.BuildCacheKey.key(%{
          elixir: "1.16.0",
          otp: "26",
          target: "host",
          dep: "jason",
          dep_lock: candidate["dep_lock"],
          closure: []
        })

      candidate = Map.put(candidate, "key", key)

      Process.put(:stub_fill_out, fn out ->
        ebin = Path.join([out, "build-cache", key, "ebin"])
        File.mkdir_p!(ebin)
        File.write!(Path.join(ebin, "Elixir.Jason.beam"), "beam")
      end)

      files_dir = files_dir_with([])

      set_response(
        {:ok,
         %{
           exit_code: 0,
           result: Map.put(fixture_result(), "cache", %{"candidates" => [candidate]}),
           files_dir: files_dir,
           output_dir: files_dir,
           log: "ok"
         }}
      )

      %{cache: cache, key: key}
    end

    defp build_jason do
      perform_job(Build, %{
        "package" => "jason",
        "version" => "1.4.5",
        "image_digest" => "sha256:deadbeef"
      })
    end

    test "a successful build promotes its candidate before enqueuing the ingest", ctx do
      Application.put_env(:portal, Portal.BuildCache.Promotion,
        release_checksum: fn "jason", "1.4.5" -> {:ok, @outer} end,
        # The real copy runs in a container; the integration test covers it.
        copy: fn source, staging ->
          {_, 0} = System.cmd("cp", ["-a", source <> "/.", staging])
          :ok
        end
      )

      assert :ok = build_jason()

      assert File.regular?(
               Path.join([ctx.cache, "sha256_deadbeef", ctx.key, "ebin", "Elixir.Jason.beam"])
             )

      assert_enqueued(worker: Ingest)
    end

    # The cache is an optimisation: nothing promotion does may cost the build
    # its result.
    test "a promotion that raises still enqueues the ingest", ctx do
      Application.put_env(:portal, Portal.BuildCache.Promotion,
        release_checksum: fn _, _ -> raise "hex lookup exploded" end
      )

      log = capture_log(fn -> assert :ok = build_jason() end)

      assert log =~ "build cache promotion failed"
      assert_enqueued(worker: Ingest)
      refute File.exists?(Path.join([ctx.cache, "sha256_deadbeef", ctx.key]))
    end
  end

  describe "ingest retries" do
    test "a request completion error remains retryable after the run commits" do
      {:ok, run} =
        Portal.Catalog.Ingestion.ingest(fixture_result(), %{
          run_id: "completion-error",
          image_digest: "sha256:retry",
          files_dir: files_dir_with([])
        })

      set_response({:error, :missing_result_json})

      assert {:error, :not_found} =
               perform_job(Ingest, %{
                 run_id: run.run_id,
                 scan_request_id: Ecto.UUID.generate()
               })

      assert [%{id: id}] = Ash.read!(Run, domain: Portal.Catalog)
      assert id == run.id
    end

    for scratch_present? <- [true, false] do
      test "a committed ingest resumes completion with scratch present: #{scratch_present?}" do
        {:ok, request} = ScanRequests.create_once(%{package_name: "jason", source: :hex_owner})
        files_dir = files_dir_with([])
        run_id = "committed-retry"

        {:ok, run} =
          Portal.Catalog.Ingestion.ingest(fixture_result(), %{
            run_id: run_id,
            image_digest: "sha256:retry",
            files_dir: files_dir,
            scan_request_id: request.id
          })

        if unquote(scratch_present?) do
          set_response(
            {:ok,
             %{result: fixture_result(), files_dir: files_dir, output_dir: files_dir, log: "ok"}}
          )
        else
          set_response({:error, :missing_result_json})
        end

        args = %{run_id: run_id, image_digest: "sha256:retry", scan_request_id: request.id}
        assert :ok = perform_job(Ingest, args)
        assert :ok = perform_job(Ingest, args)
        assert [%{id: id}] = Ash.read!(Run, domain: Portal.Catalog)
        assert id == run.id
        assert {:ok, updated} = ScanRequests.get_request(request.id)
        assert updated.status == :built
        assert updated.run_id == run.id
        assert_enqueued(worker: PackageMeta, args: %{package: "jason"})
      end
    end

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

    test "a builder error frees the scratch dir instead of leaking it" do
      {:ok, request} =
        ScanRequests.create_once(%{package_name: "leaky", source: :hex_owner, status: :accepted})

      root = Path.join(System.tmp_dir!(), "build-scratch-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)

      Application.put_env(:portal, Portal.Builder, scratch_root: root)
      on_exit(fn -> Application.delete_env(:portal, Portal.Builder) end)
      Process.put(:stub_scratch_root, root)

      set_response({:error, :docker_unavailable})

      job = %Oban.Job{
        args: %{
          "package" => "leaky",
          "version" => "1.0.0",
          "image_digest" => "sha256:x",
          "scan_request_id" => request.id
        },
        attempt: 1,
        max_attempts: 3
      }

      assert {:error, :docker_unavailable} = Build.perform(job)

      # Nothing will ever read this build, so the tree must not survive the job.
      assert File.ls!(root) == []
    end

    test "a full disk snoozes instead of burning an attempt" do
      {:ok, request} =
        ScanRequests.create_once(%{
          package_name: "cramped",
          source: :hex_owner,
          status: :accepted
        })

      root = Path.join(System.tmp_dir!(), "build-scratch-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)

      Application.put_env(:portal, Portal.Builder, scratch_root: root)
      on_exit(fn -> Application.delete_env(:portal, Portal.Builder) end)
      Process.put(:stub_scratch_root, root)

      set_response({:error, {:insufficient_disk, 1_000_000, 20_000_000_000}})

      job = %Oban.Job{
        args: %{
          "package" => "cramped",
          "version" => "1.0.0",
          "image_digest" => "sha256:x",
          "scan_request_id" => request.id
        },
        # The last attempt: a plain {:error, _} here would mark the request
        # `:error` for a host condition that resolves itself.
        attempt: 3,
        max_attempts: 3
      }

      assert {:snooze, 900} = Build.perform(job)

      # Snoozing does not excuse leaking: nothing will read this tree.
      assert File.ls!(root) == []

      {:ok, updated} = ScanRequests.get_request(request.id)
      assert updated.status == :queued
    end

    test "a noexec scratch root snoozes instead of burning an attempt" do
      {:ok, request} =
        ScanRequests.create_once(%{
          package_name: "noexec",
          source: :hex_owner,
          status: :accepted
        })

      root = Path.join(System.tmp_dir!(), "build-scratch-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)

      Application.put_env(:portal, Portal.Builder, scratch_root: root)
      on_exit(fn -> Application.delete_env(:portal, Portal.Builder) end)
      Process.put(:stub_scratch_root, root)

      set_response({:error, :scratch_noexec})

      job = %Oban.Job{
        args: %{
          "package" => "noexec",
          "version" => "1.0.0",
          "image_digest" => "sha256:x",
          "scan_request_id" => request.id
        },
        # The last attempt: a plain {:error, _} here would mark the request
        # `:error` for a host condition that resolves itself.
        attempt: 3,
        max_attempts: 3
      }

      log = capture_log(fn -> assert {:snooze, 900} = Build.perform(job) end)

      # The log line is the only thing an operator sees; it names the version
      # like its `:insufficient_disk` sibling does.
      assert log =~ "refusing to build noexec 1.0.0"

      # Snoozing does not excuse leaking: nothing will read this tree.
      assert File.ls!(root) == []

      {:ok, updated} = ScanRequests.get_request(request.id)
      assert updated.status == :queued
    end

    test "a missing egress filter snoozes instead of burning an attempt" do
      {:ok, request} =
        ScanRequests.create_once(%{
          package_name: "sealed",
          source: :hex_owner,
          status: :accepted
        })

      root = Path.join(System.tmp_dir!(), "build-scratch-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)
      Application.put_env(:portal, Portal.Builder, scratch_root: root)
      on_exit(fn -> Application.delete_env(:portal, Portal.Builder) end)
      Process.put(:stub_scratch_root, root)

      set_response({:error, :egress_filter_missing})

      job = %Oban.Job{
        args: %{
          "package" => "sealed",
          "version" => "1.0.0",
          "image_digest" => "sha256:x",
          "scan_request_id" => request.id
        },
        # The last attempt: a plain {:error, _} would mark the request
        # `:error` for a host condition, and building would run unfiltered.
        attempt: 3,
        max_attempts: 3
      }

      log = capture_log(fn -> assert {:snooze, 900} = Build.perform(job) end)

      assert log =~ "egress filter missing on this host; refusing to build sealed 1.0.0"
      assert File.ls!(root) == []

      {:ok, updated} = ScanRequests.get_request(request.id)
      assert updated.status == :queued
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

    # The dedup is blind to status on purpose, so a failed build cannot be
    # repeated at the same image digest. That is right for a catalogue sweep and
    # wrong for `Portal.LogBackfill`, whose whole job is to reproduce a failure
    # in order to capture the log the first attempt did not store.
    test "force runs the build even though a run already exists" do
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
        overall_status: :fail
      })
      |> Ash.create!(domain: Portal.Catalog)

      files_dir = files_dir_with([])

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
                 "package" => "dup",
                 "version" => "1.0.0",
                 "image_digest" => "sha256:dup",
                 "force" => true
               })

      assert_received :stub_build_called
    end
  end

  describe "unique/1" do
    # A bulk rebuild's targets pass and argus-only pass for the same request
    # land inside the same 60 s window; they must get distinct jobs.
    test "two jobs for the same request differing only in scope are not coalesced" do
      {:ok, first} =
        Oban.insert(
          Build.new(%{"package" => "scoped", "version" => "1.0.0", "scope" => "targets"})
        )

      {:ok, second} =
        Oban.insert(
          Build.new(%{"package" => "scoped", "version" => "1.0.0", "scope" => "argus_only"})
        )

      refute second.conflict?
      assert first.id != second.id
    end
  end

  describe "backoff/1" do
    test "is capped so repeated snoozes cannot push a retry days out" do
      # Oban's default backoff is quartic in `attempt`, and every {:snooze, _}
      # increments `attempt` even though it preserves the retry budget.
      assert Build.backoff(%Oban.Job{attempt: 30, max_attempts: 3}) == 3600
      assert Build.backoff(%Oban.Job{attempt: 1, max_attempts: 3}) < 3600
    end
  end

  describe "runner.log capture on failure" do
    @header """
    ================================================================================
    Portal.Builder - Docker Execution Log
    Started: 2026-09-10T08:00:00Z
    Command: docker run --rm -v /var/lib/ncc/scratch/x:/work ncc-worker:local
    ================================================================================

    """

    defp scratch_root_for_test do
      root = Path.join(System.tmp_dir!(), "build-scratch-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      previous = Application.get_env(:portal, Portal.Builder, [])
      Application.put_env(:portal, Portal.Builder, Keyword.put(previous, :scratch_root, root))
      Process.put(:stub_scratch_root, root)

      on_exit(fn ->
        Application.put_env(:portal, Portal.Builder, previous)
        File.rm_rf(root)
      end)

      root
    end

    defp perform_final_attempt(request) do
      Build.perform(%Oban.Job{
        args: %{
          "package" => "jason",
          "version" => "1.0.0",
          "scan_request_id" => request.id
        },
        attempt: 5,
        max_attempts: 5
      })
    end

    test "a worker-exit failure stores the sanitized excerpt from the build map" do
      {:ok, request} =
        ScanRequests.create_once(%{package_name: "jason", source: :hex_owner, status: :accepted})

      scratch_root_for_test()

      set_response(
        {:ok,
         %{
           exit_code: 10,
           result: nil,
           files_dir: "/nonexistent",
           output_dir: "/nonexistent",
           log: @header <> "== Compilation error in file lib/x.ex ==\n"
         }}
      )

      capture_log(fn -> perform_final_attempt(request) end)

      {:ok, reloaded} = ScanRequests.get_request(request.id)

      assert reloaded.status == :error
      assert reloaded.error_log =~ "Compilation error"
      refute reloaded.error_log =~ "docker run"
      refute reloaded.error_log =~ "/var/lib/ncc/scratch"
    end

    test "a builder error reads runner.log off disk before cleanup" do
      {:ok, request} =
        ScanRequests.create_once(%{package_name: "jason", source: :hex_owner, status: :accepted})

      root = scratch_root_for_test()
      Process.put(:stub_runner_log, @header <> "docker: daemon not running\n")
      set_response({:error, :docker_unavailable})

      capture_log(fn -> perform_final_attempt(request) end)

      {:ok, reloaded} = ScanRequests.get_request(request.id)

      assert reloaded.status == :error
      assert reloaded.error_log =~ "daemon not running"
      refute reloaded.error_log =~ "docker run --rm"
      # Read happened before cleanup, and cleanup still ran.
      assert File.ls!(root) == []
    end

    test "a crash reads runner.log before cleanup" do
      {:ok, request} =
        ScanRequests.create_once(%{package_name: "jason", source: :hex_owner, status: :accepted})

      root = scratch_root_for_test()
      Process.put(:stub_runner_log, @header <> "** (File.Error) :enospc\n")
      set_response({:raise, %RuntimeError{message: "boom"}})

      capture_log(fn ->
        assert_raise RuntimeError, fn -> perform_final_attempt(request) end
      end)

      {:ok, reloaded} = ScanRequests.get_request(request.id)

      assert reloaded.status == :error
      assert reloaded.error_log =~ ":enospc"
      assert File.ls!(root) == []
    end

    test "exit 0 with no result.json stores the excerpt and marks the request" do
      {:ok, request} =
        ScanRequests.create_once(%{package_name: "jason", source: :hex_owner, status: :accepted})

      scratch_root_for_test()

      set_response(
        {:ok,
         %{
           exit_code: 0,
           result: nil,
           files_dir: "/nonexistent",
           output_dir: "/nonexistent",
           log: @header <> "worker exited without writing result.json\n"
         }}
      )

      capture_log(fn -> perform_final_attempt(request) end)

      {:ok, reloaded} = ScanRequests.get_request(request.id)

      assert reloaded.status == :error
      assert reloaded.error_log =~ "without writing result.json"
    end
  end

  describe "perform/1 Nerves tooling" do
    # No stub response is set: a call to build/2 would crash on nil.
    test "records a skip instead of building, and closes the request" do
      {:ok, request} =
        ScanRequests.create_once(%{
          package_name: "nerves_system_rpi4",
          source: :hex_owner,
          status: :accepted
        })

      assert :ok =
               perform_job(Build, %{
                 "package" => "nerves_system_rpi4",
                 "version" => "2.1.2",
                 "image_digest" => "sha256:deadbeef",
                 "scan_request_id" => request.id
               })

      refute_received :stub_build_called
      assert [run] = Ash.read!(Run, domain: Portal.Catalog)
      assert run.overall_status == :skipped

      {:ok, updated} = ScanRequests.get_request(request.id)
      assert updated.status == :built
      assert updated.run_id == run.id
    end

    # A blank version fails the run insert (Ash casts "" to nil on a required
    # attribute), which stands in for any database failure here.
    test "the last failed attempt marks the request errored" do
      {:ok, request} =
        ScanRequests.create_once(%{package_name: "nerves", source: :hex_owner, status: :accepted})

      args = %{
        "package" => "nerves",
        "version" => "",
        "image_digest" => "sha256:deadbeef",
        "scan_request_id" => request.id
      }

      assert {:error, _} = perform_job(Build, args, attempt: 1, max_attempts: 3)
      {:ok, still_open} = ScanRequests.get_request(request.id)
      refute still_open.status == :error

      assert {:error, _} = perform_job(Build, args, attempt: 3, max_attempts: 3)
      {:ok, errored} = ScanRequests.get_request(request.id)
      assert errored.status == :error
      assert errored.error_reason =~ "tooling skip failed"
      refute_received :stub_build_called
    end

    # A failed run already on file at this version is what the skip replaces,
    # so the dedup must not stand in its way.
    test "skips even when a real run exists for the version" do
      package =
        Package
        |> Ash.Changeset.for_create(:create, %{name: "nerves"})
        |> Ash.create!(domain: Portal.Catalog)

      Run
      |> Ash.Changeset.for_create(:create, %{
        run_id: "existing",
        package_id: package.id,
        version_tested: "2.0.0",
        image_digest: "sha256:dup",
        overall_status: :fail
      })
      |> Ash.create!(domain: Portal.Catalog)

      assert :ok =
               perform_job(Build, %{
                 "package" => "nerves",
                 "version" => "2.0.0",
                 "image_digest" => "sha256:dup"
               })

      refute_received :stub_build_called

      assert Run
             |> Ash.Query.filter(run_id == "tooling-nerves-2.0.0")
             |> Ash.exists?(domain: Portal.Catalog)
    end
  end

  describe "Nerves cache warm requests" do
    setup do
      # The recently-warmed memo is one node-wide ETS table (it has to
      # outlive the per-test DB sandbox rollback, see nerves_cache.ex), and
      # these tests share "sha256:deadbeef" across each other. Without this,
      # whichever test runs first poisons the rest for the same pair.
      if :ets.whereis(:portal_nerves_cache_warmed) != :undefined,
        do: :ets.delete_all_objects(:portal_nerves_cache_warmed)

      on_exit(fn -> Application.delete_env(:portal, Portal.NervesCache) end)
      :ok
    end

    defp nerves_owns(names) do
      Application.put_env(:portal, Portal.NervesCache,
        owners: fn name -> {:ok, if(name in names, do: ["nerves"], else: ["mallory"])} end
      )
    end

    defp np(name, version), do: %{"name" => name, "version" => version}

    defp build_reporting(report, version \\ "1.4.1") do
      files_dir =
        files_dir_with(["ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"])

      set_response(
        {:ok,
         %{
           exit_code: 0,
           result: Map.put(fixture_result(), "nerves_cache", report),
           files_dir: files_dir,
           output_dir: files_dir,
           log: "ok"
         }}
      )

      assert :ok =
               perform_job(Build, %{
                 "package" => "jason",
                 "version" => version,
                 "image_digest" => "sha256:deadbeef"
               })
    end

    test "a locked miss nerves owns is warmed on this node's queue, and ingest still runs" do
      nerves_owns(["nerves_system_rpi4"])
      pair = np("nerves_system_rpi4", "2.0.0")

      build_reporting(%{"misses" => [pair], "lock" => [pair]})

      assert [job] = all_enqueued(worker: WarmNerves)
      assert job.queue == WarmNerves.local_queue()
      assert job.args == %{"image_digest" => "sha256:deadbeef", "pairs" => [pair]}
      assert_enqueued(worker: Ingest)
    end

    test "pairs not in the lock, not owned by nerves, or beyond the cap are dropped" do
      owned = for b <- ~w(bbb rpi0 rpi4 rpi5 trellis), do: np("nerves_system_#{b}", "2.0.0")
      foreign = np("nerves_system_custom", "1.0.0")
      unlocked = np("nerves_system_x86_64", "2.0.0")

      nerves_owns(["nerves_system_x86_64" | Enum.map(owned, & &1["name"])])

      build_reporting(%{
        "misses" => [unlocked, foreign | owned],
        "lock" => [foreign | owned]
      })

      assert [job] = all_enqueued(worker: WarmNerves)
      assert job.args["pairs"] == Enum.take(owned, 4)
    end

    test "a run with no misses queues no warm" do
      nerves_owns(["nerves_system_rpi4"])

      build_reporting(%{"misses" => [], "lock" => [np("nerves_system_rpi4", "2.0.0")]})

      assert all_enqueued(worker: WarmNerves) == []
      assert_enqueued(worker: Ingest)
    end

    test "a pair already warmed for this image within the day is not warmed again" do
      nerves_owns(["nerves_system_rpi4", "nerves_system_bbb"])
      a = np("nerves_system_rpi4", "2.0.0")
      b = np("nerves_system_bbb", "2.0.0")

      build_reporting(%{"misses" => [a], "lock" => [a]}, "1.4.1")
      build_reporting(%{"misses" => [a, b], "lock" => [a, b]}, "1.4.2")

      pairs = all_enqueued(worker: WarmNerves) |> Enum.map(& &1.args["pairs"]) |> Enum.sort()
      assert pairs == Enum.sort([[a], [b]])
    end

    # The warm hook is best-effort (`Portal.Workers.Build.safely/2`): whatever
    # goes wrong requesting it must cost the next build a private extraction,
    # never this build its ingest.
    test "a nerves cache warm request that raises still enqueues ingest" do
      Application.put_env(:portal, Portal.NervesCache,
        owners: fn _name -> raise "hex is down" end
      )

      pair = np("nerves_system_rpi4", "2.0.0")

      assert capture_log(fn ->
               build_reporting(%{"misses" => [pair], "lock" => [pair]})
             end) =~ "nerves cache warm request failed"

      assert all_enqueued(worker: WarmNerves) == []
      assert_enqueued(worker: Ingest)
    end
  end

  # `perform_job/3` runs the job's `perform/1` directly, so these cover the
  # `after`-block broadcast the same way a real job attempt would reach it.
  describe "sweep broadcasts" do
    setup do
      :ok = Portal.AdminEvents.subscribe(:sweeps)
      :ok
    end

    test "a finished build job with a sweep id in meta announces :sweeps" do
      package =
        Package
        |> Ash.Changeset.for_create(:create, %{name: "swept"})
        |> Ash.create!(domain: Portal.Catalog)

      Run
      |> Ash.Changeset.for_create(:create, %{
        run_id: "existing-swept",
        package_id: package.id,
        version_tested: "1.0.0",
        image_digest: "sha256:dup",
        overall_status: :pass
      })
      |> Ash.create!(domain: Portal.Catalog)

      assert :ok =
               perform_job(
                 Build,
                 %{"package" => "swept", "version" => "1.0.0", "image_digest" => "sha256:dup"},
                 meta: %{sweep_id: "sweep-dedup"}
               )

      assert_receive {:admin_changed, :sweeps}
    end

    test "a build job without a sweep id does not announce" do
      package =
        Package
        |> Ash.Changeset.for_create(:create, %{name: "unswept"})
        |> Ash.create!(domain: Portal.Catalog)

      Run
      |> Ash.Changeset.for_create(:create, %{
        run_id: "existing-unswept",
        package_id: package.id,
        version_tested: "1.0.0",
        image_digest: "sha256:dup2",
        overall_status: :pass
      })
      |> Ash.create!(domain: Portal.Catalog)

      assert :ok =
               perform_job(Build, %{
                 "package" => "unswept",
                 "version" => "1.0.0",
                 "image_digest" => "sha256:dup2"
               })

      refute_receive {:admin_changed, :sweeps}
    end

    test "a successful build carries its sweep id into the ingest job" do
      files_dir =
        files_dir_with(["ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"])

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
               perform_job(
                 Build,
                 %{
                   "package" => "jason",
                   "version" => "1.4.1",
                   "image_digest" => "sha256:deadbeef"
                 },
                 meta: %{sweep_id: "sweep-ingest"}
               )

      assert_receive {:admin_changed, :sweeps}
      assert [job] = all_enqueued(worker: Ingest)
      assert job.meta["sweep_id"] == "sweep-ingest"
    end

    test "an ingest job with a sweep id in meta announces :sweeps when it finishes" do
      {:ok, run} =
        Portal.Catalog.Ingestion.ingest(fixture_result(), %{
          run_id: "sweep-committed",
          image_digest: "sha256:retry",
          files_dir: files_dir_with([])
        })

      assert :ok =
               perform_job(Ingest, %{"run_id" => run.run_id}, meta: %{sweep_id: "sweep-3"})

      assert_receive {:admin_changed, :sweeps}
    end

    test "an ingest job without a sweep id does not announce" do
      {:ok, run} =
        Portal.Catalog.Ingestion.ingest(fixture_result(), %{
          run_id: "sweep-committed2",
          image_digest: "sha256:retry2",
          files_dir: files_dir_with([])
        })

      assert :ok = perform_job(Ingest, %{"run_id" => run.run_id})

      refute_receive {:admin_changed, :sweeps}
    end
  end
end
