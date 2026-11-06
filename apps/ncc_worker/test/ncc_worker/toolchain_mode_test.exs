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

  @traced_pass %{status: :pass, reason: nil, observations: %{"trace_stats" => %{"windows" => 2}}}
  @not_judged %{
    status: :skip,
    reason: "portability could not be judged",
    observations: %{"problems" => ["x"]}
  }
  @refused %{
    status: :skip,
    reason: "compile-time host read: os:type/0 in X.f/0 (lib/x.ex:2)",
    observations: %{}
  }

  describe "the compile-time trace (P1)" do
    test "a passing build records rule 1 and the trace's observations", %{tmp_dir: work_dir} do
      {project, _built} = project(work_dir, "circular_buffer-1.0.0")
      host = Map.put(passing_host(), :duration_sec, 12.0)
      build = Worker.toolchain_build(project, "sample", host, @toolchain, @traced_pass)

      assert %{status: "pass", portability_rule: 1, rule1_reason: nil} = build

      assert build.compile_observations == %{
               "trace_stats" => %{"windows" => 2, "host_compile_sec" => 12.0}
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
      assert build.compile_observations == %{"trace_stats" => %{"host_compile_sec" => nil}}
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
               "trace_stats" => %{"windows" => 2, "host_compile_sec" => nil}
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
end
