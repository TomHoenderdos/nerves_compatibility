defmodule NccWorker.ToolchainModeTest do
  use ExUnit.Case, async: true

  alias NccWorker.{CLI, FileArchiver, JsonWriter, Worker}

  @moduletag :tmp_dir

  @toolchain %{elixir: "1.19.1", erlang: "28", mix: "1.19.1", nerves_bootstrap: "absent"}

  @lock """
  %{
    "sample": {:hex, :sample, "1.0.0", "i-sample", [:mix], [{:dep, "~> 1.0", [hex: :dep, repo: "hexpm", optional: false]}], "hexpm", "o-sample"},
    "dep": {:hex, :dep, "1.2.0", "i-dep", [:mix], [], "hexpm", "o-dep"},
  }
  """

  # The project a toolchain run leaves behind: the package's sources under
  # `deps/<pkg>`, its host build under `_build/host/lib/<pkg>`, and the lock.
  defp project(work_dir, fixture) do
    project = Path.join(work_dir, "proj")
    source = Path.join([project, "deps", "sample"])
    File.mkdir_p!(Path.join(source, "lib"))
    File.write!(Path.join(source, "mix.exs"), "defmodule Sample.MixProject do end")
    File.write!(Path.join(source, "lib/sample.ex"), "defmodule Sample do end")

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

  describe "the compile-time trace (P1)" do
    test "a passing build records rule 1 and the trace's observations", %{tmp_dir: work_dir} do
      {project, _built} = project(work_dir, "circular_buffer-1.0.0")
      host = Map.put(passing_host(), :duration_sec, 12.0)
      build = Worker.toolchain_build(project, "sample", host, @toolchain, @traced_pass)

      assert %{status: "pass", portability_rule: 1, rule1_reason: nil} = build

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

      assert %{portability_rule: 1, rule1_reason: nil} = build

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
                 portability_rule: 1,
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

    test "a trace that raises, throws or exits is a transient could-not-judge, never a crash",
         %{tmp_dir: work_dir} do
      {project, _built} = project(work_dir, "circular_buffer-1.0.0")
      paths = %{work_dir: work_dir, output_dir: Path.join(work_dir, "out")}

      for failure <- [
            fn -> raise File.Error, reason: :eacces, action: "make directory", path: "/x" end,
            fn -> throw(:boom) end,
            fn -> exit(:boom) end
          ] do
        verdict =
          Worker.toolchain_portability(passing_host(), project, "sample", paths,
            releases: {:ok, %{}},
            trace: fn _, _, _, _ -> failure.() end
          )

        assert %{status: :skip, reason: "portability could not be judged"} = verdict
        assert ["portability failed: " <> _] = verdict.observations["problems"]

        assert %{"judge_compile" => "not_finished", "transient" => true} =
                 verdict.observations["trace_stats"]

        build = Worker.toolchain_build(project, "sample", passing_host(), @toolchain, verdict)
        assert %{status: "skipped", reason: "portability could not be judged"} = build
      end
    end

    test "a failed host compile is not traced", %{tmp_dir: work_dir} do
      trace = fn _, _, _, _ -> flunk("traced a failed host compile") end

      assert Worker.toolchain_portability(%{status: :error}, work_dir, "sample", %{},
               trace: trace
             ) ==
               nil
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
                 portability_rule: 1,
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
             "portability_rule" => 1,
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

  # The without variant never starts the optional dependencies pass, and
  # says so in the same shape the pass reports, so the portal can tell a build
  # made without them from one whose pass dropped them.
  describe "toolchain_optional_deps/5" do
    test "an excluded build reports the pass as not requested", %{tmp_dir: work_dir} do
      {project, _built} = project(work_dir, "circular_buffer-1.0.0")

      assert {:ok, %{added: [], dropped: [], skipped: [], reason: "not_requested"}} =
               Worker.toolchain_optional_deps("exclude", passing_host(), project, "sample", %{})
    end

    test "an excluded build reports the same after a failed compile", %{tmp_dir: work_dir} do
      {project, _built} = project(work_dir, "circular_buffer-1.0.0")
      host = %{status: :fail, error: "boom"}

      assert {:ok, %{reason: "not_requested"}} =
               Worker.toolchain_optional_deps("exclude", host, project, "sample", %{})
    end

    test "an included build with a failed compile reports no pass", %{tmp_dir: work_dir} do
      {project, _built} = project(work_dir, "circular_buffer-1.0.0")
      host = %{status: :fail, error: "boom"}

      assert {:ok, nil} = Worker.toolchain_optional_deps("include", host, project, "sample", %{})
    end
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

    test "an OS-specific source publishes no config reads", %{tmp_dir: work_dir} do
      {project, _built} = project(work_dir, "circular_buffer-1.0.0")
      source = Path.join([project, "deps", "sample", "lib", "sample.ex"])
      File.write!(source, "defmodule Sample do\n  def os, do: :os.type()\nend\n")
      verdict = Map.put(@traced_pass, :compile_env, @r5)

      result = Worker.pure_elixir_result(project, "sample", fn _ -> verdict end)

      assert %{compile_env_rule: nil} = result
      assert %{status: "skipped", reason: "OS-specific" <> _} = result.host_portability
      assert is_list(result.compile_env)
      refute hd(@r5) in result.compile_env
      refute Map.has_key?(result.beam_scan["footprint"], "file_manifest")
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
