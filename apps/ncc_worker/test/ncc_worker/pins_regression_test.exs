defmodule NccWorker.PinsRegressionTest do
  # Without `pins`, a toolchain run's result.json is the bytes it was before
  # pinned builds existed (lock-driven builds spec, section 1).
  use ExUnit.Case, async: true

  alias NccWorker.{JsonWriter, Worker}

  @moduletag :tmp_dir

  @toolchain %{elixir: "1.19.1", erlang: "28", mix: "1.19.1", nerves_bootstrap: "absent"}
  @golden Path.expand("../fixtures/pins/toolchain_result_without_pins.json", __DIR__)

  @lock """
  %{
    "sample": {:hex, :sample, "1.0.0", "i-sample", [:mix], [{:dep, "~> 1.0", [hex: :dep, repo: "hexpm", optional: false]}], "hexpm", "o-sample"},
    "dep": {:hex, :dep, "1.2.0", "i-dep", [:mix], [], "hexpm", "o-dep"},
  }
  """

  @traced_pass %{
    status: :pass,
    reason: nil,
    observations: %{"trace_stats" => %{"judge_compile" => "finished", "windows" => 2}},
    compile_env: [],
    compile_inputs: []
  }

  # A toolchain run's project after `deps.get`: the package's sources and
  # its host build from a fixture, and the lock.
  def toolchain_run(dir) do
    proj = Path.join([dir, "work", "proj"])
    source = Path.join([proj, "deps", "sample"])
    File.mkdir_p!(Path.join(source, "lib"))
    File.write!(Path.join(source, "mix.exs"), "defmodule Sample.MixProject do end")
    File.write!(Path.join(source, "lib/sample.ex"), "defmodule Sample do end")
    File.mkdir_p!(Path.join([proj, "deps", "dep", "lib"]))
    File.write!(Path.join([proj, "deps", "dep", "lib", "dep.ex"]), "defmodule Dep do end")

    built = Path.join([proj, "_build", "host", "lib", "sample"])
    File.mkdir_p!(Path.dirname(built))
    File.cp_r!(Path.join([__DIR__, "..", "fixture", "circular_buffer-1.0.0"]), built)
    [app] = Path.wildcard(Path.join(built, "ebin/*.app"))
    File.rename!(app, Path.join(built, "ebin/sample.app"))
    File.write!(Path.join(proj, "mix.lock"), @lock)
    File.write!(Path.join(proj, "mix.exs"), "defp deps do\n  [\n    {:sample, \"1.0.0\"}\n  ]\nend\n")

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

  def passing_trace(_project_dir, _package, _paths, _opts),
    do: %{host: %{status: :pass, error: nil}, verdict: @traced_pass}

  def written(result, dir) do
    out = Path.join(dir, "json")
    File.mkdir_p!(out)
    :ok = JsonWriter.write_result(out, %{result | finished_at: "2026-11-17T00:00:00Z"})
    File.read!(Path.join(out, "result.json"))
  end

  test "a toolchain run without pins writes the same result.json as before", %{tmp_dir: dir} do
    {proj, input, paths} = toolchain_run(dir)

    assert {:ok, result} =
             Worker.toolchain_project(proj, input, paths, @toolchain,
               host_trace: &passing_trace/4
             )

    json = written(result, dir)

    if System.get_env("NCC_WRITE_GOLDEN") == "1" do
      File.mkdir_p!(Path.dirname(@golden))
      File.write!(@golden, json)
    end

    assert json == File.read!(@golden)
  end
end
