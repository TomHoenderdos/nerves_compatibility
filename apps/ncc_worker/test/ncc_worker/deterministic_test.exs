defmodule NccWorker.DeterministicTest do
  use ExUnit.Case, async: true

  alias NccWorker.{CLI, Deterministic, Worker}

  @moduletag :tmp_dir

  @toolchain %{elixir: "1.20.5", erlang: "28", mix: "1.20.5", nerves_bootstrap: "absent"}

  @lock """
  %{
    "sample": {:hex, :sample, "1.0.0", "i-sample", [:mix], [], "hexpm", "o-sample"},
  }
  """

  @pass %{
    status: :pass,
    reason: nil,
    observations: %{"trace_stats" => %{"judge_compile" => "finished"}},
    compile_env: [],
    compile_inputs: []
  }

  @option_read %{
    "kind" => "env",
    "name" => "ERL_COMPILER_OPTIONS",
    "value" => "g2QABWVycm9y",
    "set_by" => "host"
  }

  # A toolchain run's project after its host compile: the package's sources
  # under `deps/sample`, its build under `_build/host/lib/sample` (the
  # circular_buffer fixture's beams), the lock and the plain project's mix.exs.
  defp toolchain_run(dir) do
    proj = Path.join([dir, "work", "proj"])
    source = Path.join([proj, "deps", "sample"])
    File.mkdir_p!(Path.join(source, "lib"))
    File.write!(Path.join(source, "mix.exs"), "defmodule Sample.MixProject do end")
    File.write!(Path.join(source, "lib/sample.ex"), "defmodule Sample do end")
    built = Path.join([proj, "_build", "host", "lib", "sample"])
    File.mkdir_p!(Path.dirname(built))
    File.cp_r!(Path.join([__DIR__, "..", "fixture", "circular_buffer-1.0.0"]), built)
    [app] = Path.wildcard(Path.join(built, "ebin/*.app"))
    File.rename!(app, Path.join(built, "ebin/sample.app"))
    # The fixture's beams are stripped; a toolchain build's keep `CInf`.
    Enum.each(Path.wildcard(Path.join(built, "ebin/*.beam")), &File.rm!/1)
    put_beam(Path.join(built, "ebin"))
    File.write!(Path.join(proj, "mix.lock"), @lock)
    File.write!(Path.join(proj, "mix.exs"), "defp deps do\n  [{:sample, \"1.0.0\"}]\nend\n")

    out = Path.join(dir, "out")
    File.mkdir_p!(Path.join(out, "logs"))
    paths = %{work_dir: Path.join(dir, "work"), output_dir: out, logs_dir: Path.join(out, "logs")}

    input = %{
      run_id: "r1",
      mode: "toolchain",
      optional_deps: "exclude",
      deterministic: true,
      started_at: System.monotonic_time(:second),
      image: %{name: "x", digest: "sha256:x"},
      package: %{name: "sample", version: "1.0.0"},
      paths: %{work_dir: paths.work_dir, output_dir: out, files_dir: Path.join(out, "files")}
    }

    {proj, input, paths}
  end

  # The host compile: tells the test what it was judged on.
  defp host_trace(parent, verdict \\ @pass) do
    fn _project_dir, _package, _paths, opts ->
      send(parent, {:judged_on, Keyword.take(opts, [:releases, :trees])})
      %{host: %{status: :pass, error: nil}, verdict: verdict}
    end
  end

  # The sibling's traced compile: writes `_build/deterministic/lib/sample`
  # from the build's beams, each rewritten by `beam` (by default its CInf
  # without `options` and `source`, as the option leaves it).
  defp sibling_trace(parent, verdict \\ @pass, beam \\ &deterministic/1) do
    fn project_dir, package, opts ->
      send(parent, {:sibling, package, opts})
      from = Path.join([project_dir, "_build", "host", "lib", package])
      to = Path.join([project_dir, "_build", "deterministic", "lib", package])
      File.mkdir_p!(Path.dirname(to))
      File.cp_r!(from, to)

      for path <- Path.wildcard(Path.join(to, "ebin/*.beam")),
          do: File.write!(path, beam.(File.read!(path)))

      verdict
    end
  end

  defp deterministic(beam) do
    {:ok, _module, chunks} = :beam_lib.all_chunks(beam)

    chunks =
      Enum.map(chunks, fn
        {~c"CInf", bin} ->
          info = bin |> :erlang.binary_to_term() |> Keyword.drop([:options, :source])
          {~c"CInf", :erlang.term_to_binary(info)}

        chunk ->
          chunk
      end)

    {:ok, rebuilt} = :beam_lib.build_module(chunks)
    rebuilt
  end

  defp put_beam(ebin) do
    module = Module.concat([Sample, "M#{System.unique_integer([:positive])}"])
    source = "defmodule #{inspect(module)} do\n  def f(x), do: {x, __ENV__.file}\nend\n"
    [{^module, beam}] = Code.compile_string(source, "lib/sample.ex")
    :code.delete(module)
    :code.purge(module)
    File.write!(Path.join(ebin, "#{module}.beam"), beam)
  end

  defp run(proj, input, paths, opts),
    do: Worker.toolchain_project(proj, input, paths, @toolchain, opts)

  defp sha256(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  test "a run that does not ask for it compiles no sibling and records none", %{tmp_dir: dir} do
    {proj, input, paths} = toolchain_run(dir)
    never = fn _, _, _ -> flunk("compiled a sibling") end

    for value <- [nil, "true", false] do
      input =
        if value == nil,
          do: Map.delete(input, :deterministic),
          else: %{input | deterministic: value}

      opts = [host_trace: host_trace(self()), deterministic_trace: never]
      assert {:ok, result} = run(proj, input, paths, opts)
      refute Map.has_key?(result, :deterministic_build)
    end
  end

  test "a passing build gets a sibling compiled with the option at its own build path, " <>
         "judged on the build's own snapshots",
       %{tmp_dir: dir} do
    {proj, input, paths} = toolchain_run(dir)
    opts = [host_trace: host_trace(self()), deterministic_trace: sibling_trace(self())]

    assert {:ok, result} = run(proj, input, paths, opts)
    assert_received {:judged_on, judged}
    assert_received {:sibling, "sample", sibling_opts}

    env = Map.new(sibling_opts[:env])
    assert env["ERL_COMPILER_OPTIONS"] == "deterministic"
    assert env["MIX_BUILD_PATH"] == Path.join([proj, "_build", "deterministic"])
    assert env["MIX_ENV"] == "prod"
    assert sibling_opts[:mode] == :judge
    assert sibling_opts[:releases] == judged[:releases]
    assert sibling_opts[:trees] == judged[:trees]
    assert sibling_opts[:trace_dir] != Path.join(paths.work_dir, "trace")

    build = result.toolchain_build
    sibling = result.deterministic_build
    assert %{status: "pass", reason: nil, erl_compiler_options: ["deterministic"]} = sibling
    assert sibling.judge_revision == 29
    assert sibling.deps_lock == build.deps_lock
    assert sibling.compile_env == build.compile_env

    app = Path.join([proj, "_build", "deterministic", "lib", "sample"])

    for %{"path" => path, "sha256" => sum} <- sibling.file_manifest["ebin"] do
      assert sha256(Path.join(app, path)) == sum
    end

    assert Enum.map(sibling.file_manifest["ebin"], & &1["path"]) ==
             Enum.map(build.file_manifest["ebin"], & &1["path"])

    refute sibling.file_manifest == build.file_manifest
  end

  test "a build that did not pass gets a skipped sibling and no second compile",
       %{tmp_dir: dir} do
    {proj, input, paths} = toolchain_run(dir)
    refused = %{@pass | status: :skip, reason: "compile-time host read: os:type/0"}
    never = fn _, _, _ -> flunk("compiled a sibling") end
    opts = [host_trace: host_trace(self(), refused), deterministic_trace: never]

    assert {:ok, result} = run(proj, input, paths, opts)
    assert result.toolchain_build.status == "skipped"

    assert %{
             status: "skipped",
             reason: "the build without the option did not pass",
             erl_compiler_options: ["deterministic"],
             file_manifest: nil,
             judge_revision: 29
           } = result.deterministic_build
  end

  test "a build whose own compile reads or sets the variable gets no sibling" do
    pass = %{status: "pass", compile_inputs: [], compile_observations: %{}}
    reads = "the build's compile reads or sets ERL_COMPILER_OPTIONS"

    assert Deterministic.eligible(pass) == :ok
    assert Deterministic.eligible(%{pass | compile_inputs: [@option_read]}) == {:skip, reads}

    assert Deterministic.eligible(%{pass | compile_inputs: [%{"kind" => "env_all"}]}) ==
             {:skip, reads}

    write = %{"name" => "ERL_COMPILER_OPTIONS", "owner" => "sample"}
    writes = %{pass | compile_observations: %{"env_writes" => [write]}}
    assert Deterministic.eligible(writes) == {:skip, reads}

    full = for i <- 1..50, do: %{"name" => "V#{i}"}

    assert Deterministic.eligible(%{pass | compile_observations: %{"env_writes" => full}}) ==
             {:skip, reads}

    other = %{@option_read | "name" => "OTHER"}
    assert Deterministic.eligible(%{pass | compile_inputs: [other]}) == :ok

    assert Deterministic.eligible(%{pass | status: "skipped"}) ==
             {:skip, "the build without the option did not pass"}
  end

  test "a sibling the judge refused is skipped with the judge's reason", %{tmp_dir: dir} do
    {proj, input, paths} = toolchain_run(dir)
    refused = %{@pass | status: :skip, reason: "compile-time host read: os:type/0"}
    opts = [host_trace: host_trace(self()), deterministic_trace: sibling_trace(self(), refused)]

    assert {:ok, result} = run(proj, input, paths, opts)
    assert result.toolchain_build.status == "pass"

    assert %{status: "skipped", reason: "compile-time host read: os:type/0"} =
             result.deterministic_build
  end

  test "a sibling the option never reached, or whose inputs differ, is skipped",
       %{tmp_dir: dir} do
    {proj, input, paths} = toolchain_run(Path.join(dir, "a"))
    same = fn beam -> beam end
    trace = sibling_trace(self(), @pass, same)
    opts = [host_trace: host_trace(self()), deterministic_trace: trace]

    assert {:ok, result} = run(proj, input, paths, opts)
    assert result.deterministic_build.status == "skipped"
    assert result.deterministic_build.reason =~ "differs from the build: "
    assert result.deterministic_build.reason =~ "not compiled with the option"

    {proj, input, paths} = toolchain_run(Path.join(dir, "b"))
    inputs = %{@pass | compile_inputs: [%{@option_read | "name" => "OTHER"}]}
    opts = [host_trace: host_trace(self()), deterministic_trace: sibling_trace(self(), inputs)]

    assert {:ok, result} = run(proj, input, paths, opts)

    assert result.deterministic_build.reason ==
             "differs from the build: its compile_inputs differs"
  end

  test "a sibling trace that left processes running fails the run", %{tmp_dir: dir} do
    {proj, input, paths} = toolchain_run(dir)
    stats = %{"judge_compile" => "not_finished", "tracer_error" => "sweep_survived"}
    left = %{@pass | status: :skip, reason: "portability could not be judged"}
    left = put_in(left, [:observations, "trace_stats"], stats)
    opts = [host_trace: host_trace(self()), deterministic_trace: sibling_trace(self(), left)]

    assert run(proj, input, paths, opts) == {:error, :deterministic_left_running}
  end

  test "a sibling compile that changed the build's own files fails the run", %{tmp_dir: dir} do
    {proj, input, paths} = toolchain_run(dir)

    trace = fn project_dir, package, opts ->
      verdict = sibling_trace(self(), @pass).(project_dir, package, opts)
      ebin = Path.join([project_dir, "_build/host/lib", package, "ebin"])
      [beam | _] = Path.wildcard(Path.join(ebin, "*.beam"))
      File.write!(beam, "changed")
      verdict
    end

    opts = [host_trace: host_trace(self()), deterministic_trace: trace]
    assert {:error, {:deterministic_changed_build, "ebin/" <> _}} = run(proj, input, paths, opts)
  end

  test "the run archives the sibling's own files and writes it into result.json",
       %{tmp_dir: dir} do
    {proj, input, paths} = toolchain_run(dir)
    opts = [host_trace: host_trace(self()), deterministic_trace: sibling_trace(self())]

    assert :ok = CLI.run_input(input, &run(proj, &1, paths, opts))

    result = paths.output_dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()
    sibling = result["deterministic_build"]
    assert %{"status" => "pass", "erl_compiler_options" => ["deterministic"]} = sibling
    files = Path.join(paths.output_dir, "files")

    for %{"sha256" => sum} <-
          sibling["file_manifest"]["ebin"] ++ result["toolchain_build"]["file_manifest"]["ebin"] do
      assert File.exists?(Path.join(files, sum))
    end
  end

  test "a sibling file whose bytes no longer match its entry is not archived", %{tmp_dir: dir} do
    {proj, input, paths} = toolchain_run(dir)
    opts = [host_trace: host_trace(self()), deterministic_trace: sibling_trace(self())]
    assert {:ok, result} = run(proj, input, paths, opts)

    [entry | _] =
      Enum.filter(result.deterministic_build.file_manifest["ebin"], &(&1["path"] =~ ".beam"))

    File.write!(Path.join([proj, "_build/deterministic/lib/sample", entry["path"]]), "changed")

    files = Path.join(paths.output_dir, "files")
    assert {:ok, _} = NccWorker.FileArchiver.archive_manifest_files(files, result, paths.work_dir)
    refute File.exists?(Path.join(files, entry["sha256"]))
  end

  test "NCC_INPUT's deterministic key is read" do
    assert {:ok, %{deterministic: true}} = CLI.parse_input(~s({"deterministic": true}))
  end
end
