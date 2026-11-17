defmodule NccWorker.Tracer.FixturesDeterministicTest do
  # The deterministic sibling on real traced compiles (judge revision 29):
  # a package with an Elixir module and an Erlang module that holds `?FILE`,
  # over a dependency, compiled as the run's host compile and then again with
  # `ERL_COMPILER_OPTIONS=deterministic` at the sibling's own build path,
  # judged on the snapshots taken before the first compile.
  # Starts real `elixir` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.{Deterministic, Portability, TracerFixtures, Worker}

  import NccWorker.TracerFixtures, only: [mix_exs: 2]

  @moduletag timeout: 900_000

  @toolchain %{elixir: "1.20.5", erlang: "28"}

  @det_files %{
    "lib/fx_det.ex" => "defmodule FxDet do\n  def base, do: FxBase.x()\nend\n",
    "src/fx_det_erl.erl" => "-module(fx_det_erl).\n-export([file/0]).\nfile() -> ?FILE.\n"
  }
  @base_files %{"lib/fx_base.ex" => "defmodule FxBase do\n  def x, do: 1\nend\n"}

  setup_all do
    root = Path.join(System.tmp_dir!(), "ncc-fixtures-det-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    home = Path.join(root, "hex")

    det_mix =
      "defmodule FxDet.MixProject do\n  use Mix.Project\n" <>
        "  def project, do: [app: :fx_det, version: \"0.1.0\", deps: [{:fx_base, path: \"../fx_base\"}]]\n" <>
        "end\n"

    base_mix = mix_exs("fx_base", "")
    det = Map.put(@det_files, "mix.exs", det_mix)
    base = Map.put(@base_files, "mix.exs", base_mix)

    releases =
      Map.new([
        TracerFixtures.hex_release(home, "fx_det", Map.keys(det), det),
        TracerFixtures.hex_release(home, "fx_base", Map.keys(base), base)
      ])

    deps = %{
      "fx_det" => %{mix_exs: det_mix, files: @det_files, deps: ["fx_base"]},
      "fx_base" => %{mix_exs: base_mix, files: @base_files}
    }

    proj = TracerFixtures.project(root, ["fx_det"], deps)
    trees = Portability.tree_snapshot(proj, releases: {:ok, releases}, hex_home: home)
    logs = Path.join(root, "logs")
    File.mkdir_p!(logs)

    verdict =
      Portability.run(proj, "fx_det",
        env: TracerFixtures.env(proj),
        mode: :host,
        releases: {:ok, releases},
        hex_home: home,
        trees: trees,
        trace_dir: Path.join(root, "trace"),
        log_file: Path.join(logs, "host-trace.log"),
        timeout_ms: 300_000,
        run_started_at: System.monotonic_time(:second)
      )

    host = %{status: :pass, duration_sec: 1.0}
    normal = Worker.toolchain_build(proj, "fx_det", host, @toolchain, verdict, hex_home: home)
    paths = %{work_dir: root, output_dir: root, logs_dir: logs}

    sibling =
      Deterministic.build(
        proj,
        "fx_det",
        paths,
        @toolchain,
        normal,
        [releases: {:ok, releases}, trees: trees],
        hex_home: home,
        run_started_at: System.monotonic_time(:second)
      )

    %{proj: proj, verdict: verdict, normal: normal, sibling: sibling, logs: logs}
  end

  defp beam(dir, module, app \\ "fx_det"),
    do: File.read!(Path.join([dir, "lib", app, "ebin", "#{module}.beam"]))

  # What the module's `?FILE` gives, from its own code.
  defp file_literal(bytes) do
    {:module, :fx_det_erl} = :code.load_binary(:fx_det_erl, ~c"fx_det_erl.beam", bytes)

    try do
      :fx_det_erl.file()
    after
      :code.purge(:fx_det_erl)
      :code.delete(:fx_det_erl)
      :code.purge(:fx_det_erl)
    end
  end

  defp line_chunk(bytes) do
    {:ok, {_, [{~c"Line", line}]}} = :beam_lib.chunks(bytes, [~c"Line"])
    line
  end

  test "the build passes, and so does its sibling", ctx do
    assert %{status: :pass} = ctx.verdict, inspect(ctx.verdict.observations, limit: 40)
    assert ctx.normal.status == "pass", inspect(ctx.normal.reason)

    assert {:ok, %{status: "pass", erl_compiler_options: ["deterministic"]} = sibling} =
             ctx.sibling,
           inspect(ctx.sibling, limit: 40) <> File.read!(Path.join(ctx.logs, "host.log"))

    assert sibling.compile_inputs == ctx.normal.compile_inputs
  end

  test "the sibling's Erlang module was compiled with the option; its Elixir module's code is the build's",
       ctx do
    host = Path.join([ctx.proj, "_build", "host"])
    det = Deterministic.build_path(ctx.proj)

    assert file_literal(beam(host, "fx_det_erl")) == ~c"src/fx_det_erl.erl"
    assert file_literal(beam(det, "fx_det_erl")) == ~c"fx_det_erl.erl"
    assert line_chunk(beam(host, "fx_det_erl")) =~ "src/fx_det_erl.erl"
    refute line_chunk(beam(det, "fx_det_erl")) =~ "src/"

    assert :beam_lib.md5(beam(host, "Elixir.FxDet")) == :beam_lib.md5(beam(det, "Elixir.FxDet"))
    assert beam(host, "Elixir.FxDet") != beam(det, "Elixir.FxDet")

    {:ok, {_, [compile_info: info]}} =
      :beam_lib.chunks(beam(det, "Elixir.FxBase", "fx_base"), [:compile_info])

    refute Keyword.has_key?(info, :source)
  end
end
