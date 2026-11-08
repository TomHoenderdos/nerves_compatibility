defmodule NccWorker.ToolchainModeTest do
  use ExUnit.Case, async: true

  alias NccWorker.{CLI, FileArchiver, JsonWriter, Portability, Worker}

  @moduletag :tmp_dir

  @root? System.cmd("id", ["-u"]) |> elem(0) |> String.trim() == "0"

  @toolchain %{elixir: "1.19.1", erlang: "28", mix: "1.19.1", nerves_bootstrap: "absent"}

  @lock """
  %{
    "sample": {:hex, :sample, "1.0.0", "i-sample", [:mix], [{:dep, "~> 1.0", [hex: :dep, repo: "hexpm", optional: false]}], "hexpm", "o-sample"},
    "dep": {:hex, :dep, "1.2.0", "i-dep", [:mix], [], "hexpm", "o-dep"},
  }
  """

  # The project a toolchain run leaves behind: the package's sources under
  # `deps/<pkg>` and its dependency's under `deps/dep`, its host build under
  # `_build/host/lib/<pkg>`, and the lock.
  defp project(work_dir, fixture) do
    project = Path.join(work_dir, "proj")
    source = Path.join([project, "deps", "sample"])
    File.mkdir_p!(Path.join(source, "lib"))
    File.write!(Path.join(source, "mix.exs"), "defmodule Sample.MixProject do end")
    File.write!(Path.join(source, "lib/sample.ex"), "defmodule Sample do end")
    dep = Path.join([project, "deps", "dep"])
    File.mkdir_p!(Path.join(dep, "lib"))
    File.write!(Path.join(dep, "lib/dep.ex"), "defmodule Dep do end")

    built = Path.join([project, "_build", "host", "lib", "sample"])
    File.mkdir_p!(Path.dirname(built))
    File.cp_r!(Path.join([__DIR__, "..", "fixture", fixture]), built)

    # The fixture's `.app` is named after the fixture's own application.
    [app] = Path.wildcard(Path.join(built, "ebin/*.app"))
    File.rename!(app, Path.join(built, "ebin/sample.app"))
    File.write!(Path.join(project, "mix.lock"), @lock)
    {project, built}
  end

  defp sha256(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp passing_host, do: %{status: :pass, error: nil}

  @finished %{"judge_compile" => "finished"}
  # A pass always carries the config reads it observed, `[]` for none.
  @traced_pass %{
    status: :pass,
    reason: nil,
    observations: %{"trace_stats" => Map.put(@finished, "windows", 2)},
    compile_env: []
  }
  # The traced compile finished, but its trace could not be used.
  @not_judged %{
    status: :skip,
    reason: "portability could not be judged",
    observations: %{"problems" => ["x"], "trace_stats" => @finished}
  }
  # The traced compile did not finish: `_build` may be half-written.
  @unfinished %{
    status: :skip,
    reason: "portability could not be judged",
    observations: %{
      "problems" => ["tracer: :timeout"],
      "trace_stats" => %{"judge_compile" => "not_finished"}
    }
  }
  @r5 [%{app: "phoenix_live_view", path: ["root_tag_attribute"], value: "g3cFZXJyb3I"}]
  # Carries config reads so that a test can show a refusal never publishes them.
  @refused %{
    status: :skip,
    reason: "compile-time host read: os:type/0 in X.f/0 (lib/x.ex:2)",
    observations: %{"trace_stats" => @finished},
    compile_env: @r5
  }

  describe "the compile-time trace" do
    test "a passing build records rule 1 and the trace's observations", %{tmp_dir: work_dir} do
      {project, _built} = project(work_dir, "circular_buffer-1.0.0")
      host = Map.put(passing_host(), :duration_sec, 12.0)
      build = Worker.toolchain_build(project, "sample", host, @toolchain, @traced_pass)

      assert %{status: "pass", portability_rule: 2, rule1_reason: nil} = build

      assert build.compile_observations == %{
               "trace_stats" => %{
                 "windows" => 2,
                 "judge_compile" => "finished",
                 "host_compile_sec" => 12.0
               }
             }
    end

    test "a trace refusal skips a build rule 1 passes, with the trace's reason", %{
      tmp_dir: work_dir
    } do
      {project, _built} = project(work_dir, "circular_buffer-1.0.0")
      build = Worker.toolchain_build(project, "sample", passing_host(), @toolchain, @refused)

      assert %{
               status: "skipped",
               reason: "compile-time host read: os:type/0" <> _,
               file_manifest: nil
             } = build

      assert %{portability_rule: 2, rule1_reason: nil} = build

      assert build.compile_observations == %{
               "trace_stats" => %{"judge_compile" => "finished", "host_compile_sec" => nil}
             }
    end

    test "a trace that could not judge skips the build; it is never an error", %{
      tmp_dir: work_dir
    } do
      {project, _built} = project(work_dir, "circular_buffer-1.0.0")

      for verdict <- [@not_judged, nil] do
        build = Worker.toolchain_build(project, "sample", passing_host(), @toolchain, verdict)

        assert %{
                 status: "skipped",
                 reason: "portability could not be judged",
                 file_manifest: nil,
                 portability_rule: 2,
                 rule1_reason: nil
               } = build

        assert [_ | _] = build.compile_observations["problems"]
      end
    end

    test "no trace at all is a transient could-not-judge", %{tmp_dir: work_dir} do
      {project, _built} = project(work_dir, "circular_buffer-1.0.0")
      build = Worker.toolchain_build(project, "sample", passing_host(), @toolchain, nil)

      assert %{status: "skipped", reason: "portability could not be judged"} = build
      assert build.compile_observations["trace_stats"]["transient"] == true
    end

    test "rule 1's skip keeps its reason in rule1_reason", %{tmp_dir: work_dir} do
      {project, _built} = project(work_dir, "circuits_gpio-2.1.3")
      build = Worker.toolchain_build(project, "sample", passing_host(), @toolchain, @traced_pass)

      assert %{status: "skipped", reason: reason, rule1_reason: reason} = build
      assert is_binary(reason)
    end

    test "rule 1's skip reason is kept when the trace could not judge", %{tmp_dir: work_dir} do
      {project, _built} = project(work_dir, "circuits_gpio-2.1.3")
      build = Worker.toolchain_build(project, "sample", passing_host(), @toolchain, @not_judged)

      assert %{status: "skipped", reason: reason, rule1_reason: reason} = build
      assert reason != "portability could not be judged"
    end

    test "a traced compile that did not finish is not judged by rule 1 either", %{
      tmp_dir: work_dir
    } do
      # circuits_gpio skips under rule 1; a half-written build must not be
      # judged at all, so neither its reason nor a pass can come from it.
      for fixture <- ["circuits_gpio-2.1.3", "circular_buffer-1.0.0"] do
        File.rm_rf!(Path.join(work_dir, "proj"))
        {project, _built} = project(work_dir, fixture)
        build = Worker.toolchain_build(project, "sample", passing_host(), @toolchain, @unfinished)

        assert %{
                 status: "skipped",
                 reason: "portability could not be judged",
                 rule1_reason: nil,
                 portability_rule: 2,
                 file_manifest: nil
               } = build

        assert build.compile_observations["problems"] == ["tracer: :timeout"]
      end
    end

    test "a failed host compile records no trace fields", %{tmp_dir: work_dir} do
      {project, _built} = project(work_dir, "circular_buffer-1.0.0")
      host = %{status: :fail, error: "boom"}
      build = Worker.toolchain_build(project, "sample", host, @toolchain, nil)

      assert %{
               status: "error",
               portability_rule: nil,
               rule1_reason: nil,
               compile_observations: nil
             } = build
    end
  end

  # Adds a module whose function body runs a program to the host build.
  defp add_runtime_cmd(built) do
    name = "NccP4RuntimeCmd#{System.unique_integer([:positive])}"

    [{module, beam}] =
      Code.compile_string("defmodule #{name} do\n  def f, do: System.cmd(\"true\", [])\nend\n")

    :code.purge(module)
    :code.delete(module)
    File.write!(Path.join([built, "ebin", "#{module}.beam"]), beam)
    module
  end

  # Adds a module whose function body loads a NIF to the host build.
  defp add_nif_load(built) do
    name = "NccNifLoad#{System.unique_integer([:positive])}"

    [{module, beam}] =
      Code.compile_string(
        "defmodule #{name} do\n  def init, do: :erlang.load_nif(~c\"nif\", 0)\nend\n"
      )

    :code.purge(module)
    :code.delete(module)
    File.write!(Path.join([built, "ebin", "#{module}.beam"]), beam)
    module
  end

  describe "rule 2" do
    test "a runtime program call passes; rule 1's reason is recorded", %{tmp_dir: work_dir} do
      {project, built} = project(work_dir, "circular_buffer-1.0.0")
      module = add_runtime_cmd(built)
      build = Worker.toolchain_build(project, "sample", passing_host(), @toolchain, @traced_pass)

      assert %{status: "pass", portability_rule: 2, rule1_reason: "calls System.cmd/2"} = build
      assert Enum.any?(build.file_manifest["ebin"], &(&1["path"] == "ebin/#{module}.beam"))
    end

    test "an :os.type() in the sources passes; rule 1's reason is recorded",
         %{tmp_dir: work_dir} do
      {project, _built} = project(work_dir, "circular_buffer-1.0.0")
      source = Path.join([project, "deps", "sample", "lib", "sample.ex"])
      File.write!(source, "defmodule Sample do\n  def os, do: :os.type()\nend\n")
      build = Worker.toolchain_build(project, "sample", passing_host(), @toolchain, @traced_pass)

      assert %{status: "pass", portability_rule: 2} = build
      assert "OS-specific (lib/sample.ex: :os.type()" = build.rule1_reason
    end

    test "R0 still refuses a NIF with rule 1's own reason", %{tmp_dir: work_dir} do
      {project, _built} = project(work_dir, "circuits_gpio-2.1.3")
      build = Worker.toolchain_build(project, "sample", passing_host(), @toolchain, @traced_pass)

      assert %{status: "skipped", portability_rule: 2, reason: reason, rule1_reason: reason} =
               build

      assert is_binary(reason)
    end

    test "a trace refusal wins over a runtime call; could-not-judge stays could-not-judge",
         %{tmp_dir: work_dir} do
      {project, built} = project(work_dir, "circular_buffer-1.0.0")
      add_runtime_cmd(built)

      refused = Worker.toolchain_build(project, "sample", passing_host(), @toolchain, @refused)
      assert %{status: "skipped", reason: "compile-time host read: " <> _} = refused

      unjudged =
        Worker.toolchain_build(project, "sample", passing_host(), @toolchain, @not_judged)

      assert %{
               status: "skipped",
               reason: "portability could not be judged",
               rule1_reason: "calls System.cmd/2",
               portability_rule: 2
             } = unjudged
    end
  end

  describe "judge_releases/2" do
    @first {:ok, %{"sample" => %{name: "sample", version: "1.0.0", checksum: "o"}}}
    @second {:ok,
             %{
               "sample" => %{name: "sample", version: "1.0.0", checksum: "o"},
               "opt" => %{name: "opt", version: "2.0.0", checksum: "p"}
             }}

    test "the build with optional deps is judged against the snapshot taken after their deps.get" do
      info = %{added: ["opt"], dropped: [], reason: nil, skipped: [], lock_snapshot: @second}

      assert {@second, %{added: ["opt"], dropped: [], reason: nil, skipped: []} = clean} =
               Worker.judge_releases(@first, info)

      refute Map.has_key?(clean, :lock_snapshot)
    end

    test "every other build keeps the snapshot taken before the first compile" do
      for info <- [
            nil,
            %{added: [], dropped: [], reason: nil, skipped: []},
            %{added: [], dropped: ["opt"], reason: "host_compile_failed", skipped: []},
            %{added: [], dropped: [], reason: "not_requested", skipped: []},
            {:per_target, [], []}
          ] do
        assert {@first, ^info} = Worker.judge_releases(@first, info)
      end
    end
  end

  test "combine/2: refusals win, rule 1 keeps its reason when the trace could not judge" do
    assert :ok = Worker.combine(:ok, @traced_pass)
    assert {:skip, "compile-time host read: " <> _} = Worker.combine(:ok, @refused)
    assert {:skip, "portability could not be judged"} = Worker.combine(:ok, @not_judged)

    assert {:skip, "calls System.cmd/2"} =
             Worker.combine({:skip, "calls System.cmd/2"}, @traced_pass)

    assert {:skip, "compile-time host read: " <> _} =
             Worker.combine({:skip, "calls System.cmd/2"}, @refused)

    assert {:skip, "calls System.cmd/2"} =
             Worker.combine({:skip, "calls System.cmd/2"}, @not_judged)

    # A non-pass verdict without a reason never passes and never yields a nil reason.
    assert {:skip, "portability could not be judged"} =
             Worker.combine(:ok, %{status: :skip, reason: nil, observations: %{}})

    assert {:skip, "calls System.cmd/2"} =
             Worker.combine({:skip, "calls System.cmd/2"}, %{status: :skip, observations: %{}})
  end

  describe "toolchain_build/5" do
    test "a portable package passes with its own beams' manifest", %{tmp_dir: work_dir} do
      {project, built} = project(work_dir, "circular_buffer-1.0.0")

      build = Worker.toolchain_build(project, "sample", passing_host(), @toolchain, @traced_pass)

      assert %{status: "pass", reason: nil, elixir: "1.19.1", otp: "28"} = build
      assert build.deps_lock == %{"dep" => %{"version" => "1.2.0", "checksum" => "o-dep"}}
      assert build.package_checksum == "o-sample"
      assert is_list(build.compile_env)

      assert %{"ebin" => ebin, "priv" => []} = build.file_manifest
      beam = Enum.find(ebin, &(&1["path"] == "ebin/Elixir.CircularBuffer.beam"))
      assert beam["sha256"] == sha256(Path.join(built, "ebin/Elixir.CircularBuffer.beam"))
      assert %{"size" => size, "mode" => _} = beam
      assert is_integer(size) and size > 0
    end

    test "a package that is not portable is skipped with the reason", %{tmp_dir: work_dir} do
      {project, _built} = project(work_dir, "circuits_gpio-2.1.3")

      build = Worker.toolchain_build(project, "sample", passing_host(), @toolchain, @traced_pass)

      assert %{status: "skipped", file_manifest: nil} = build
      assert is_binary(build.reason) and build.reason != ""
    end

    test "a failed host compile is an error naming the failure", %{tmp_dir: work_dir} do
      {project, _built} = project(work_dir, "circular_buffer-1.0.0")
      host = %{status: :fail, error: "mix command exited with code 1"}

      build = Worker.toolchain_build(project, "sample", host, @toolchain, @traced_pass)

      assert %{status: "error", file_manifest: nil, deps_lock: nil} = build
      assert build.reason =~ "host compile failed"
      assert build.reason =~ "exited with code 1"
    end

    test "a missing host build is skipped, not a crash", %{tmp_dir: work_dir} do
      {project, built} = project(work_dir, "circular_buffer-1.0.0")
      File.rm_rf!(built)

      assert %{status: "skipped"} =
               Worker.toolchain_build(project, "sample", passing_host(), @toolchain, @traced_pass)
    end
  end

  test "the toolchain probe does not need nerves_bootstrap" do
    assert {:ok, %{nerves_bootstrap: "absent", elixir: elixir}} =
             Worker.detect_toolchain(:toolchain)

    assert elixir == System.version()
  end

  defp result(build) do
    %{
      run_id: "run-1",
      package: %{name: "sample", version: "1.0.0"},
      image: %{name: "ncc-worker:1.19-28", digest: "sha256:abc"},
      toolchain: @toolchain,
      systems: %{},
      finished_at: "2026-10-24T00:00:00Z",
      scope: "toolchain",
      toolchain_build: build,
      requested_toolchain: %{elixir: "1.19", otp: "28"}
    }
  end

  test "the archiver copies a toolchain build's files from the host build", %{tmp_dir: work_dir} do
    {project, built} = project(work_dir, "circular_buffer-1.0.0")
    build = Worker.toolchain_build(project, "sample", passing_host(), @toolchain, @traced_pass)
    archive = Path.join(work_dir, "files")

    assert {:ok, %{files_archived: 5, files_skipped: 0}} =
             FileArchiver.archive_manifest_files(archive, result(build), work_dir)

    for file <- File.ls!(Path.join(built, "ebin")) do
      path = Path.join([built, "ebin", file])
      assert File.read!(Path.join(archive, sha256(path))) == File.read!(path)
    end
  end

  test "the archiver ignores a toolchain_build outside a toolchain run", %{tmp_dir: work_dir} do
    {project, _built} = project(work_dir, "circular_buffer-1.0.0")
    build = Worker.toolchain_build(project, "sample", passing_host(), @toolchain, @traced_pass)
    archive = Path.join(work_dir, "files")

    assert {:ok, %{files_archived: 0}} =
             FileArchiver.archive_manifest_files(
               archive,
               %{result(build) | scope: "full"},
               work_dir
             )
  end

  test "result.json carries the toolchain build and the requested toolchain", %{
    tmp_dir: work_dir
  } do
    {project, _built} = project(work_dir, "circular_buffer-1.0.0")
    build = Worker.toolchain_build(project, "sample", passing_host(), @toolchain, @traced_pass)
    out = Path.join(work_dir, "out")
    File.mkdir_p!(out)

    assert :ok = JsonWriter.write_result(out, result(build))
    decoded = out |> Path.join("result.json") |> File.read!() |> JSON.decode!()

    assert %{"scope" => "toolchain", "systems" => systems} = decoded
    assert systems == %{}
    assert decoded["requested_toolchain"] == %{"elixir" => "1.19", "otp" => "28"}

    assert %{
             "status" => "pass",
             "reason" => nil,
             "elixir" => "1.19.1",
             "otp" => "28",
             "package_checksum" => "o-sample",
             "deps_lock" => %{"dep" => _},
             "compile_env" => _,
             "file_manifest" => %{"ebin" => [_ | _], "priv" => []},
             "portability_rule" => 2,
             "rule1_reason" => nil,
             "compile_observations" => %{
               "trace_stats" => %{
                 "windows" => 2,
                 "judge_compile" => "finished",
                 "host_compile_sec" => nil
               }
             }
           } = decoded["toolchain_build"]
  end

  describe "CLI outcome" do
    test "a written result exits 0 for pass, skipped and a failed compile" do
      assert CLI.result_outcome(result(%{status: "pass"})) == :ok
      assert CLI.result_outcome(result(%{status: "skipped"})) == :ok
      assert CLI.result_outcome(%{systems: %{}}) == :ok

      # Deterministic: the portal records it as a fail verdict, not a retry.
      assert CLI.result_outcome(result(%{status: "error", reason: "host compile failed"})) ==
               :ok
    end
  end

  describe "toolchain_compile/5" do
    defp tc_paths(dir) do
      File.mkdir_p!(Path.join([dir, "out", "logs"]))

      %{
        work_dir: Path.join(dir, "work"),
        output_dir: Path.join(dir, "out"),
        logs_dir: Path.join([dir, "out", "logs"])
      }
    end

    # Records each traced compile: whether optional deps were in mix.exs,
    # whether `_build/host` existed when it started, the releases it was
    # given and the option keys it received.
    defp recording_trace(test_pid, statuses) do
      {:ok, agent} = Agent.start_link(fn -> statuses end)

      fn project_dir, _package, _paths, opts ->
        {status, error} =
          agent |> Agent.get_and_update(fn [s | rest] -> {s, rest} end) |> outcome()

        mix = File.read!(Path.join(project_dir, "mix.exs"))

        send(
          test_pid,
          {:traced, String.contains?(mix, ":opt_dep"),
           File.exists?(Path.join(project_dir, "_build/host")), opts[:releases]}
        )

        send(test_pid, {:trace_opts, Keyword.keys(opts), opts[:run_started_at]})

        %{host: %{status: status, error: error}, verdict: @traced_pass}
      end
    end

    # A status alone, or `{status, error}` for a failure with its own error.
    defp outcome({_status, _error} = outcome), do: outcome
    defp outcome(status) when status in [:fail, :error], do: {status, "boom"}
    defp outcome(status), do: {status, nil}

    defp plain_project(dir) do
      proj = Path.join([dir, "work", "proj"])
      File.mkdir_p!(Path.join([proj, "_build", "host"]))

      File.write!(
        Path.join(proj, "mix.exs"),
        "defp deps do\n  [\n    {:sample, \"1.0.0\"}\n  ]\nend\n"
      )

      File.write!(Path.join(proj, "mix.lock"), @lock)
      proj
    end

    @opt [%{app: "opt_dep", package: "opt_dep", requirement: "~> 1.0"}]

    test "exclude: one traced compile, nothing added", %{tmp_dir: dir} do
      proj = plain_project(dir)

      assert {:ok, %{host: %{status: :pass}, optional_deps: od}} =
               Worker.toolchain_compile(proj, "exclude", "sample", tc_paths(dir),
                 releases: {:ok, :first},
                 host_trace: recording_trace(self(), [:pass])
               )

      assert_received {:traced, false, _, {:ok, :first}}
      refute_received {:traced, _, _, _}
      assert %{added: [], dropped: [], reason: "not_requested", skipped: []} = od
    end

    test "exclude reports the same when the compile fails", %{tmp_dir: dir} do
      proj = plain_project(dir)

      assert {:ok, %{host: %{status: :fail}, optional_deps: od}} =
               Worker.toolchain_compile(proj, "exclude", "sample", tc_paths(dir),
                 releases: {:ok, :first},
                 host_trace: recording_trace(self(), [:fail])
               )

      assert %{added: [], dropped: [], reason: "not_requested", skipped: []} = od
    end

    test "include: the optional deps are added before the only compile", %{tmp_dir: dir} do
      proj = plain_project(dir)

      assert {:ok, %{host: %{status: :pass}, optional_deps: od}} =
               Worker.toolchain_compile(proj, "include", "sample", tc_paths(dir),
                 releases: {:ok, :first},
                 host_trace: recording_trace(self(), [:pass]),
                 optional_deps: fn _p, _pkg -> {@opt, ["igniter"]} end,
                 deps_get: fn _p, _env -> :ok end
               )

      assert_received {:traced, true, _, releases}
      # The snapshot taken after their `deps.get`, before their compile.
      refute releases == {:ok, :first}
      assert releases == Portability.lock_snapshot(proj)
      refute_received {:traced, _, _, _}
      assert %{added: ["opt_dep"], dropped: [], reason: nil, skipped: ["igniter"]} = od
    end

    test "the traced compile gets the run's options, not the caller's injections",
         %{tmp_dir: dir} do
      proj = plain_project(dir)

      assert {:ok, _} =
               Worker.toolchain_compile(proj, "include", "sample", tc_paths(dir),
                 releases: {:ok, :first},
                 run_started_at: 42,
                 log_tail_bytes: 100,
                 host_trace: recording_trace(self(), [:pass]),
                 optional_deps: fn _p, _pkg -> {@opt, []} end,
                 deps_get: fn _p, _env -> :ok end
               )

      assert_received {:trace_opts, keys, 42}
      assert :log_tail_bytes in keys
      for key <- [:deps_get, :optional_deps, :host_trace], do: refute(key in keys)
    end

    test "a drop removes _build/host before the compile without them", %{tmp_dir: dir} do
      proj = plain_project(dir)

      assert {:ok, %{host: %{status: :pass}, optional_deps: od}} =
               Worker.toolchain_compile(proj, "include", "sample", tc_paths(dir),
                 releases: {:ok, :first},
                 host_trace: recording_trace(self(), [:fail, :pass]),
                 optional_deps: fn _p, _pkg -> {@opt, []} end,
                 deps_get: fn _p, _env -> :ok end
               )

      assert_received {:traced, true, _, _}
      assert_received {:traced, false, false, {:ok, :first}}
      assert %{added: [], dropped: ["opt_dep"], reason: "host_compile_failed"} = od
    end

    test "deps that break the lock policy are dropped before any compile with them",
         %{tmp_dir: dir} do
      proj = plain_project(dir)

      git_lock = fn p, _env ->
        File.write!(
          Path.join(p, "mix.lock"),
          ~s|%{"opt_dep": {:git, "https://example.invalid/opt_dep.git", "abc", []}}\n|
        )
      end

      assert {:ok, %{host: %{status: :pass}, optional_deps: od}} =
               Worker.toolchain_compile(proj, "include", "sample", tc_paths(dir),
                 releases: {:ok, :first},
                 host_trace: recording_trace(self(), [:pass]),
                 optional_deps: fn _p, _pkg -> {@opt, []} end,
                 deps_get: git_lock
               )

      assert_received {:traced, false, false, {:ok, :first}}
      refute_received {:traced, _, _, _}
      assert %{added: [], dropped: ["opt_dep"], reason: "lock_policy_violation"} = od
      assert File.read!(Path.join(proj, "mix.lock")) == @lock
    end

    test "a failed deps.get for them compiles once, without them", %{tmp_dir: dir} do
      proj = plain_project(dir)

      assert {:ok, %{host: %{status: :pass}, optional_deps: od}} =
               Worker.toolchain_compile(proj, "include", "sample", tc_paths(dir),
                 releases: {:ok, :first},
                 host_trace: recording_trace(self(), [:pass]),
                 optional_deps: fn _p, _pkg -> {@opt, []} end,
                 deps_get: fn _p, _env -> {:error, {:deps_get_failed, "nope"}} end
               )

      assert_received {:traced, false, false, {:ok, :first}}
      refute_received {:traced, _, _, _}
      assert %{added: [], dropped: ["opt_dep"], reason: "deps_get_failed"} = od
    end

    test "when the compile without them fails too, the host fails and optional_deps is nil",
         %{tmp_dir: dir} do
      proj = plain_project(dir)

      assert {:ok, %{host: %{status: :fail}, optional_deps: nil}} =
               Worker.toolchain_compile(proj, "include", "sample", tc_paths(dir),
                 releases: {:ok, :first},
                 host_trace: recording_trace(self(), [:fail, :fail]),
                 optional_deps: fn _p, _pkg -> {@opt, []} end,
                 deps_get: fn _p, _env -> :ok end
               )
    end

    test "no optional deps to add: one compile", %{tmp_dir: dir} do
      proj = plain_project(dir)

      assert {:ok, %{optional_deps: %{added: [], dropped: [], reason: nil, skipped: []}}} =
               Worker.toolchain_compile(proj, nil, "sample", tc_paths(dir),
                 releases: {:ok, :first},
                 host_trace: recording_trace(self(), [:pass]),
                 optional_deps: fn _p, _pkg -> {[], []} end
               )

      assert_received {:traced, false, _, {:ok, :first}}
      refute_received {:traced, _, _, _}
    end

    test "a failed compile with nothing to add reports no pass", %{tmp_dir: dir} do
      proj = plain_project(dir)

      assert {:ok, %{host: %{status: :fail}, optional_deps: nil}} =
               Worker.toolchain_compile(proj, "include", "sample", tc_paths(dir),
                 releases: {:ok, :first},
                 host_trace: recording_trace(self(), [:fail]),
                 optional_deps: fn _p, _pkg -> {[], []} end
               )
    end

    # Processes left running, or a `_build` that cannot be removed: the
    # environment, not the package, so a retryable worker failure.
    test "a host compile error is a worker failure, never a verdict", %{tmp_dir: dir} do
      proj = plain_project(dir)

      for request <- ["exclude", "include"] do
        assert {:error, {:host_compile_error, "boom"}} =
                 Worker.toolchain_compile(proj, request, "sample", tc_paths(dir),
                   releases: {:ok, :first},
                   host_trace: recording_trace(self(), [:error]),
                   optional_deps: fn _p, _pkg -> {[], []} end
                 )

        assert CLI.exit_code({:error, {:host_compile_error, "boom"}}) == 10
      end
    end

    test "a host compile error with the optional deps added is not retried without them",
         %{tmp_dir: dir} do
      proj = plain_project(dir)

      assert {:error, {:host_compile_error, "boom"}} =
               Worker.toolchain_compile(proj, "include", "sample", tc_paths(dir),
                 releases: {:ok, :first},
                 host_trace: recording_trace(self(), [:error, :pass]),
                 optional_deps: fn _p, _pkg -> {@opt, []} end,
                 deps_get: fn _p, _env -> :ok end
               )

      assert_received {:traced, true, _, _}
      refute_received {:traced, _, _, _}
    end

    test "a host compile that raises, throws or exits is a worker failure, never a crash",
         %{tmp_dir: dir} do
      proj = plain_project(dir)

      for failure <- [
            fn -> raise File.Error, reason: :eacces, action: "make directory", path: "/x" end,
            fn -> throw(:boom) end,
            fn -> exit(:boom) end
          ] do
        assert {:error, {:host_compile_crashed, why}} =
                 Worker.toolchain_compile(proj, "exclude", "sample", tc_paths(dir),
                   releases: {:ok, :first},
                   host_trace: fn _, _, _, _ -> failure.() end
                 )

        assert is_binary(why)
      end
    end

    # The compile with them used up the run, so the one without them had no
    # time: that says nothing about the package, and the run is retried.
    test "a compile without them that runs out of time is a worker failure", %{tmp_dir: dir} do
      for out_of_time <- [
            "no time left for the host compile",
            "the untraced host compile timed out"
          ] do
        proj = plain_project(Path.join(dir, Base.encode16(out_of_time)))

        assert {:error, {:no_time_left_without_optional_deps, ^out_of_time}} =
                 Worker.toolchain_compile(proj, "include", "sample", tc_paths(dir),
                   releases: {:ok, :first},
                   host_trace: recording_trace(self(), [:fail, {:fail, out_of_time}]),
                   optional_deps: fn _p, _pkg -> {@opt, []} end,
                   deps_get: fn _p, _env -> :ok end
                 )

        assert CLI.exit_code({:error, {:no_time_left_without_optional_deps, out_of_time}}) == 10
      end
    end

    # No compile ran before it, so the time it lacked is the package's own.
    test "a first compile that runs out of time is the package's verdict", %{tmp_dir: dir} do
      no_time = {:fail, "no time left for the host compile"}

      for {request, resolve} <- [
            {"exclude", fn _p, _pkg -> flunk("resolved for exclude") end},
            {"include", fn _p, _pkg -> {[], []} end}
          ] do
        proj = plain_project(Path.join(dir, request))

        assert {:ok, %{host: %{status: :fail, error: "no time left for the host compile"}}} =
                 Worker.toolchain_compile(proj, request, "sample", tc_paths(dir),
                   releases: {:ok, :first},
                   host_trace: recording_trace(self(), [no_time]),
                   optional_deps: resolve
                 )
      end
    end

    # Not reached by a deps.get or lock-policy drop: no compile with them ran.
    test "a drop before any compile keeps an out-of-time compile as the verdict",
         %{tmp_dir: dir} do
      proj = plain_project(dir)

      assert {:ok, %{host: %{status: :fail}, optional_deps: nil}} =
               Worker.toolchain_compile(proj, "include", "sample", tc_paths(dir),
                 releases: {:ok, :first},
                 host_trace:
                   recording_trace(self(), [{:fail, "no time left for the host compile"}]),
                 optional_deps: fn _p, _pkg -> {@opt, []} end,
                 deps_get: fn _p, _env -> {:error, {:deps_get_failed, "nope"}} end
               )
    end

    if @root? do
      @tag skip: "runs as root, where a read-only _build/ does not stop its removal"
    end

    test "a _build/host that cannot be removed after a drop is a worker failure",
         %{tmp_dir: dir} do
      proj = plain_project(dir)
      build_root = Path.join(proj, "_build")
      File.chmod!(build_root, 0o555)
      on_exit(fn -> File.chmod(build_root, 0o755) end)

      assert {:error, {:optional_deps_revert_failed, :eacces}} =
               Worker.toolchain_compile(proj, "include", "sample", tc_paths(dir),
                 releases: {:ok, :first},
                 host_trace: recording_trace(self(), [:fail, :pass]),
                 optional_deps: fn _p, _pkg -> {@opt, []} end,
                 deps_get: fn _p, _env -> :ok end
               )

      assert_received {:traced, true, _, _}
      refute_received {:traced, _, _, _}
      assert CLI.exit_code({:error, {:optional_deps_revert_failed, :eacces}}) == 10
    end
  end

  # The whole toolchain run after its project is set up, through the CLI:
  # a host compile that is a worker error leaves no result.json and exits 10.
  test "a toolchain run whose host compile is a worker error writes no result", %{
    tmp_dir: dir
  } do
    proj = Path.join([dir, "work", "proj"])
    File.mkdir_p!(Path.join([proj, "_build", "host"]))

    File.write!(
      Path.join(proj, "mix.exs"),
      "defp deps do\n  [\n    {:sample, \"1.0.0\"}\n  ]\nend\n"
    )

    File.write!(Path.join(proj, "mix.lock"), @lock)
    out = Path.join(dir, "out")
    File.mkdir_p!(Path.join(out, "logs"))
    paths = %{work_dir: Path.join(dir, "work"), output_dir: out, logs_dir: Path.join(out, "logs")}

    input = %{
      run_id: "r1",
      mode: "toolchain",
      optional_deps: "exclude",
      started_at: System.monotonic_time(:second),
      image: %{name: "x", digest: "sha256:x"},
      package: %{name: "sample", version: "1.0.0"},
      paths: %{work_dir: paths.work_dir, output_dir: out, files_dir: Path.join(out, "files")}
    }

    host_error = fn _, _, _, _ ->
      %{host: %{status: :error, error: "the traced host compile left processes running"}}
    end

    worker = fn input ->
      Worker.toolchain_project(proj, input, paths, @toolchain, host_trace: host_error)
    end

    assert {:error, {:host_compile_error, _}} = outcome = CLI.run_input(input, worker)
    assert CLI.exit_code(outcome) == 10
    refute File.exists?(Path.join(out, "result.json"))
  end

  # A toolchain run's project after `deps.get`: the plain project's mix.exs
  # and lock, with the package built under `_build/host`.
  defp toolchain_run(dir) do
    {proj, _built} = project(Path.join(dir, "work"), "circular_buffer-1.0.0")

    File.write!(
      Path.join(proj, "mix.exs"),
      "defp deps do\n  [\n    {:sample, \"1.0.0\"}\n  ]\nend\n"
    )

    out = Path.join(dir, "out")
    File.mkdir_p!(Path.join(out, "logs"))
    paths = %{work_dir: Path.join(dir, "work"), output_dir: out, logs_dir: Path.join(out, "logs")}

    input = %{
      run_id: "r1",
      mode: "toolchain",
      optional_deps: "exclude",
      started_at: System.monotonic_time(:second),
      image: %{name: "x", digest: "sha256:x"},
      package: %{name: "sample", version: "1.0.0"},
      paths: %{work_dir: paths.work_dir, output_dir: out, files_dir: Path.join(out, "files")}
    }

    {proj, input, paths}
  end

  defp passing_host_trace, do: %{host: passing_host(), verdict: @traced_pass}

  test "a named config variant's overlay is in place before the compile, and the result says which",
       %{tmp_dir: dir} do
    parent = self()
    {proj, input, paths} = toolchain_run(dir)

    host_trace = fn project_dir, _package, _paths, _opts ->
      send(parent, {:config, File.read(Path.join(project_dir, "config/config.exs"))})
      passing_host_trace()
    end

    input = Map.put(input, :config_variant, "phx_dev")

    assert {:ok, result} =
             Worker.toolchain_project(proj, input, paths, @toolchain, host_trace: host_trace)

    assert_received {:config, {:ok, text}}
    assert text =~ "debug_heex_annotations: true"
    assert result.toolchain_build.config_variant == "phx_dev"
  end

  test "without a config_variant nothing is written and the result is the default",
       %{tmp_dir: dir} do
    parent = self()
    {proj, input, paths} = toolchain_run(dir)

    host_trace = fn project_dir, _package, _paths, _opts ->
      send(parent, {:config, File.exists?(Path.join(project_dir, "config"))})
      passing_host_trace()
    end

    assert {:ok, result} =
             Worker.toolchain_project(proj, input, paths, @toolchain, host_trace: host_trace)

    assert_received {:config, false}
    assert result.toolchain_build.config_variant == "default"
  end

  test "a config variant whose overlay cannot be written is a worker failure", %{tmp_dir: dir} do
    {proj, input, paths} = toolchain_run(dir)
    File.mkdir_p!(Path.join(proj, "config"))
    File.write!(Path.join(proj, "config/config.exs"), "import Config\n")
    input = Map.put(input, :config_variant, "phx_dev")

    host_trace = fn _, _, _, _ -> flunk("compiled without its overlay") end

    assert {:error, {:config_overlay_failed, :config_exists}} =
             outcome =
             CLI.run_input(
               input,
               &Worker.toolchain_project(proj, &1, paths, @toolchain, host_trace: host_trace)
             )

    assert CLI.exit_code(outcome) == 10
    refute File.exists?(Path.join(paths.output_dir, "result.json"))
  end

  describe "compile-time config reads (R5)" do
    test "a passing trace's items join the .app's compile_env and mark the build",
         %{tmp_dir: work_dir} do
      {project, built} = project(work_dir, "circular_buffer-1.0.0")
      app = Path.join(built, "ebin/sample.app")
      before = File.read!(app)
      verdict = Map.put(@traced_pass, :compile_env, @r5)

      build = Worker.toolchain_build(project, "sample", passing_host(), @toolchain, verdict)

      assert %{status: "pass", compile_env_rule: 1} = build
      assert List.last(build.compile_env) == hd(@r5)
      assert File.read!(app) == before
    end

    test "a pass with no reads keeps the .app's list and is marked; a refusal is not",
         %{tmp_dir: work_dir} do
      {project, _built} = project(work_dir, "circular_buffer-1.0.0")

      no_reads =
        Worker.toolchain_build(project, "sample", passing_host(), @toolchain, @traced_pass)

      assert %{status: "pass", compile_env_rule: 1} = no_reads

      refused = Worker.toolchain_build(project, "sample", passing_host(), @toolchain, @refused)
      assert %{status: "skipped", compile_env_rule: nil} = refused
      assert refused.compile_env == no_reads.compile_env
      refute hd(@r5) in refused.compile_env
    end

    test "a pass that carries no config reads is not published", %{tmp_dir: work_dir} do
      {project, _built} = project(work_dir, "circular_buffer-1.0.0")

      for verdict <- [Map.delete(@traced_pass, :compile_env), %{@traced_pass | compile_env: nil}] do
        build = Worker.toolchain_build(project, "sample", passing_host(), @toolchain, verdict)

        assert %{status: "skipped", reason: "portability could not be judged"} = build
        assert %{compile_env_rule: nil, file_manifest: nil} = build
        assert is_list(build.compile_env)

        result = Worker.pure_elixir_result(project, "sample", fn _ -> verdict end)
        assert %{compile_env_rule: nil, host_portability: %{status: "skipped"}} = result
        refute Map.has_key?(result.beam_scan["footprint"] || %{}, "file_manifest")
      end
    end

    test "an :os.type() in a function body no longer withholds; the trace decides",
         %{tmp_dir: work_dir} do
      {project, _built} = project(work_dir, "circular_buffer-1.0.0")
      source = Path.join([project, "deps", "sample", "lib", "sample.ex"])
      File.write!(source, "defmodule Sample do\n  def os, do: :os.type()\nend\n")
      verdict = Map.put(@traced_pass, :compile_env, @r5)

      published = Worker.pure_elixir_result(project, "sample", fn _ -> verdict end)

      assert %{compile_env_rule: 1, host_portability: %{status: "pass", portability_rule: 2}} =
               published

      assert Map.has_key?(published.beam_scan["footprint"], "file_manifest")

      withheld = Worker.pure_elixir_result(project, "sample", fn _ -> @refused end)

      assert %{status: "skipped", reason: "compile-time host read: " <> _, portability_rule: 2} =
               withheld.host_portability

      refute Map.has_key?(withheld.beam_scan["footprint"], "file_manifest")
      assert published.status == withheld.status
      assert published.log_tail =~ "Assumed compatible: host compilation passed"
    end

    # The optional-dependency pass recompiles the package after `classify/4`
    # judged it: a NIF load that only compiles in when an optional dependency
    # is present is in the beams that would be published, so the static rules
    # judge those beams, as a toolchain build's.
    test "a NIF load the optional dependencies compiled in publishes nothing",
         %{tmp_dir: work_dir} do
      {project, built} = project(work_dir, "circular_buffer-1.0.0")
      verdict = Map.put(@traced_pass, :compile_env, @r5)

      # Written by the traced compile, which runs first: the static rules
      # judge the beams it left, the ones the scan would publish.
      result =
        Worker.pure_elixir_result(project, "sample", fn _ ->
          add_nif_load(built)
          verdict
        end)

      assert %{status: "skipped", reason: "calls erlang:load_nif/2", portability_rule: 2} =
               result.host_portability

      assert %{status: :pass, compile_env_rule: nil} = result
      refute Map.has_key?(result.beam_scan["footprint"], "file_manifest")
      assert result.log_tail =~ "Files not published: calls erlang:load_nif/2."
    end

    test "a pure_elixir result whose .app cannot be read publishes nothing",
         %{tmp_dir: work_dir} do
      {project, built} = project(work_dir, "circular_buffer-1.0.0")
      File.rm!(Path.join(built, "ebin/sample.app"))
      verdict = Map.put(@traced_pass, :compile_env, @r5)

      result = Worker.pure_elixir_result(project, "sample", fn _ -> verdict end)

      assert %{compile_env: nil, compile_env_rule: nil} = result

      assert %{status: "skipped", reason: "portability could not be judged"} =
               result.host_portability

      assert "compile_env unreadable: .app missing or unparsable" in result.host_portability.compile_observations[
               "problems"
             ]

      refute Map.has_key?(result.beam_scan["footprint"] || %{}, "file_manifest")
      assert result.log_tail =~ "Files not published: portability could not be judged."
    end

    test "r5_compile_env/2 never invents a list the .app could not give" do
      assert Worker.r5_compile_env(nil, %{status: :pass, compile_env: @r5}) == {nil, nil}
      assert Worker.r5_compile_env([], %{status: :skip, compile_env: nil}) == {[], nil}
      assert Worker.r5_compile_env([], %{status: :skip, reason: "x"}) == {[], nil}
      assert Worker.r5_compile_env([], %{status: :skip, compile_env: @r5}) == {[], nil}
      assert Worker.r5_compile_env([], @refused) == {[], nil}
      assert Worker.r5_compile_env([], %{status: :pass, compile_env: nil}) == {[], nil}
      assert Worker.r5_compile_env([], %{status: :pass}) == {[], nil}
      assert Worker.r5_compile_env([], nil) == {[], nil}
      assert Worker.r5_compile_env([], %{status: :pass, compile_env: @r5}) == {@r5, 1}
    end

    test "a published pure_elixir result carries the merged list and the mark",
         %{tmp_dir: work_dir} do
      {project, _built} = project(work_dir, "circular_buffer-1.0.0")
      verdict = Map.put(@traced_pass, :compile_env, @r5)

      result = Worker.pure_elixir_result(project, "sample", fn _ -> verdict end)

      assert %{compile_env_rule: 1, host_portability: %{status: "pass"}} = result
      assert List.last(result.compile_env) == hd(@r5)

      withheld = Worker.pure_elixir_result(project, "sample", fn _ -> @refused end)
      assert withheld.compile_env_rule == nil
      refute hd(@r5) in withheld.compile_env

      out = Path.join(work_dir, "out")
      File.mkdir_p!(out)
      run = %{run_id: "r", image: %{}, toolchain: %{}, finished_at: "x"}

      :ok = JsonWriter.write_result(out, Map.put(run, :systems, %{"pure_elixir" => result}))
      json = out |> Path.join("result.json") |> File.read!() |> JSON.decode!()
      assert get_in(json, ["systems", "pure_elixir", "compile_env_rule"]) == 1

      :ok = JsonWriter.write_result(out, Map.put(run, :systems, %{"pure_elixir" => withheld}))
      json = out |> Path.join("result.json") |> File.read!() |> JSON.decode!()
      refute Map.has_key?(json["systems"]["pure_elixir"], "compile_env_rule")
    end
  end
end
