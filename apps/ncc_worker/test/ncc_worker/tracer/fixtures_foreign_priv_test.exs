defmodule NccWorker.Tracer.FixturesForeignPrivTest do
  # Foreign priv builds (foreign priv spec 3.2-3.5) on real traced compiles
  # (`NccWorker.Portability.run/3`, `foreign_priv: true`) of real kino
  # 0.19.1 and table 0.1.2, as path dependencies with their real verified
  # Hex tarballs. kino's own Kino.JS writes in its own window no longer
  # taint it; a writer's in its window are observed and settled. A path
  # dependency's Kino.JS `cdn_url` is nil (`Kino.JS.__cdn_url__/1` names
  # repo.hex.pm only under Hex.SCM), so every writer here stops at the
  # content proof as inline assets: the passing writer is the Hex-backed
  # goldens test's (plan Ruling 4). Pins the event shapes on the running
  # Elixir (run it under 1.19 and 1.20), F5 included. Starts real `elixir`
  # VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias Compatibility.Portability, as: Reasons
  alias NccWorker.{Portability, TracerFixtures}

  @moduletag timeout: 3_600_000

  @hex Path.expand("../../fixtures/hex", __DIR__)

  # A real Hex release as a path dependency: its contents and the tarball.
  # Its mix.exs keeps everything but deps/0, which names the other fixtures
  # by path, so these trees are not their tarballs': the runs pass `trees:
  # :off`, as nothing here is about item 5e.
  defp real_dep(name, version, deps) do
    tar = File.read!(Path.join(@hex, "#{name}-#{version}.tar"))
    {:ok, outer} = :erl_tar.extract({:binary, tar}, [:memory])
    {_, gz} = List.keyfind(outer, ~c"contents.tar.gz", 0)
    {:ok, files} = :erl_tar.extract({:binary, gz}, [:memory, :compressed])
    files = Map.new(files, fn {path, bytes} -> {List.to_string(path), bytes} end)
    path_deps = Enum.map_join(deps, ", ", &~s({:#{&1}, path: "../#{&1}"}))

    mix_exs =
      Regex.replace(
        ~r/  defp deps do\n.*?\n  end\n/s,
        files["mix.exs"],
        "  defp deps, do: [#{path_deps}]\n"
      )

    {tar, %{files: Map.delete(files, "mix.exs"), mix_exs: mix_exs}}
  end

  defp writer(app, body, extra_files \\ %{}) do
    %{
      files:
        Map.merge(
          %{
            "lib/#{app}.ex" => body,
            "lib/assets/#{app}/main.js" => "export function init() {}\n"
          },
          extra_files
        ),
      deps: ["kino"]
    }
  end

  defp use_kino_js(module, app),
    do: "defmodule #{module} do\n  use Kino.JS, assets_path: \"lib/assets/#{app}\"\nend\n"

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "ncc-fixtures-foreign-priv-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    home = Path.join(root, "hex")
    {kino_tar, kino} = real_dep("kino", "0.19.1", ["table"])
    {table_tar, table} = real_dep("table", "0.1.2", [])

    deps = %{
      "kino" => kino,
      "table" => table,
      "fx_plain" => %{
        files: %{
          "lib/fx_plain.ex" =>
            "defmodule FxPlain do\n  def kino?, do: Code.ensure_loaded?(Kino)\nend\n"
        },
        deps: ["kino"]
      },
      "fx_writer" => writer("fx_writer", use_kino_js("FxWriter", "fx_writer")),
      "fx_gen" =>
        writer("fx_gen", """
        defmodule FxGen do
          File.write!(Path.join(__DIR__, "assets/fx_gen/main.js"), "export const generated = true\\n")
          use Kino.JS, assets_path: "lib/assets/fx_gen"
        end
        """),
      "fx_two" =>
        writer("fx_two", use_kino_js("FxTwo.A_B", "fx_two") <> use_kino_js("FxTwo_A.B", "fx_two")),
      "fx_first" => writer("fx_first", use_kino_js("FxW.X_Y", "fx_first")),
      "fx_second" =>
        Map.update!(
          writer("fx_second", use_kino_js("FxW_X.Y", "fx_second")),
          :deps,
          &["fx_first" | &1]
        ),
      "fx_reader" =>
        writer("fx_reader", """
        defmodule FxReader do
          @archives Path.wildcard(Path.join(:code.priv_dir(:kino), "assets/*/*.tar.gz"))
          def archives, do: @archives
        end
        """),
      "fx_extra" =>
        writer("fx_extra", """
        defmodule FxExtra do
          use Kino.JS, assets_path: "lib/assets/fx_extra"
          @after_compile __MODULE__
          def __after_compile__(_env, _bytecode) do
            File.write!(Path.join([:code.priv_dir(:kino), "assets", "FxExtra", "extra.txt"]), "x")
          end
        end
        """)
    }

    proj = TracerFixtures.project(Path.join(root, "p"), Map.keys(deps), deps)

    releases =
      Map.merge(
        %{
          "kino" => release(home, "kino", "0.19.1", kino_tar),
          "table" => release(home, "table", "0.1.2", table_tar)
        },
        for app <- Map.keys(deps), app not in ["kino", "table"], into: %{} do
          files = Map.keys(deps[app].files) ++ ["mix.exs"]
          contents = Map.new(deps[app].files)
          TracerFixtures.hex_release(home, app, files, contents)
        end
      )

    verdicts =
      for app <- ~w(fx_plain fx_writer fx_gen fx_two fx_second fx_reader fx_extra), into: %{} do
        {app, run(root, proj, home, releases, app)}
      end

    %{verdicts: verdicts}
  end

  defp release(home, name, version, tar) do
    dir = Path.join(home, "packages/hexpm")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{name}-#{version}.tar"), tar)

    %{
      name: name,
      version: version,
      checksum: :sha256 |> :crypto.hash(tar) |> Base.encode16(case: :lower)
    }
  end

  defp run(root, proj, home, releases, app) do
    Portability.run(proj, app,
      env: TracerFixtures.env(proj) ++ [{"HEX_HOME", home}],
      releases: releases,
      hex_home: home,
      trees: :off,
      foreign_priv: true,
      mode: :judge,
      trace_dir: Path.join(root, "trace-#{app}"),
      log_file: Path.join(root, "#{app}.log"),
      timeout_ms: 600_000,
      run_started_at: System.monotonic_time(:second),
      repro_root: Path.join(File.cwd!(), "tmp")
    )
  end

  defp log(ctx, app), do: inspect(ctx.verdicts[app].observations, pretty: true, limit: 80)

  defp refused?(v, owner, fun),
    do: Enum.any?(v.observations["refusals"], &(&1["owner"] == owner and fun.(&1["reason"])))

  # F5 (spec 3.2): a frameless stat right after an accepted call would show
  # here as a read refusal naming its mfa. If one does, add that mfa to
  # `ForeignPriv`'s `@frameless_stats` and keep this assertion.
  defp no_read_refusals(v),
    do:
      refute(
        Enum.any?(
          v.observations["refusals"],
          &String.starts_with?(&1["reason"], Reasons.foreign_priv_read())
        )
      )

  # kino 0.19.1's own compile probes Nx.Heatmap, of nx, an optional
  # dependency this closure lacks (fix/otp-app-probe round 1, F3). That
  # tainted every package with kino in its closure until S10 recorded it.
  # S10: kino's probe of `Nx.Heatmap`, which nothing in the build defines,
  # is a compile input client 0.9 checks, so kino taints nothing.
  test "a non-writer with kino in its closure: kino's own writes accepted", ctx do
    v = ctx.verdicts["fx_plain"]
    assert %{status: :pass, compile_inputs: inputs} = v, log(ctx, "fx_plain")

    assert %{
             "kind" => "probe",
             "of" => "module",
             "name" => "Elixir.Nx.Heatmap",
             "answer" => "absent",
             "definers" => []
           } in inputs

    assert v.observations["trace_stats"]["foreign_priv"] == "on"
    refute "built outside the trace: kino" in v.observations["problems"]

    # kino's own calls alone fill the cap of 50 (each Kino.JS module's
    # File.mkdir_p!/1 probes every directory from `/`), so its archive writes
    # can fall past it. kino untainted, with the gate open and its built
    # check equal, shows they were accepted: a refused one would taint it.
    calls =
      for %{"owner" => "kino", "call" => c} <- v.observations["foreign_priv"], uniq: true, do: c

    assert "rm_rf" in calls and "mkdir_p" in calls
    assert length(v.observations["foreign_priv"]) == 50
    assert v.observations["taint"] == %{}
    no_read_refusals(v)
  end

  test "a path writer's calls are each accepted, and it stops at the content proof", ctx do
    v = ctx.verdicts["fx_writer"]
    assert v.status == :skip

    calls =
      for %{"owner" => "fx_writer", "call" => c} <- v.observations["foreign_priv"],
          uniq: true,
          do: c

    assert Enum.sort(calls) -- ["stat"] == ["archive", "mkdir_p", "rm_rf", "stream"],
           log(ctx, "fx_writer")

    assert refused?(
             v,
             "fx_writer",
             &(&1 ==
                 Reasons.foreign_priv_refused() <>
                   "kino priv/assets/FxWriter: inline or unrecognised Kino.JS assets")
           ),
           log(ctx, "fx_writer")

    assert "built outside the trace: kino" in v.observations["problems"]
    no_read_refusals(v)
  end

  test "a writer that generates an asset at compile time refuses", ctx do
    v = ctx.verdicts["fx_gen"]

    assert refused?(
             v,
             "fx_gen",
             &(String.starts_with?(&1, "compile-time write outside ebin: ") and
                 &1 =~ "lib/assets/fx_gen/main.js")
           ),
           log(ctx, "fx_gen")
  end

  test "two modules of one writer packing one directory refuse", ctx do
    v = ctx.verdicts["fx_two"]
    assert refused?(v, "fx_two", &(&1 =~ "priv/assets/FxTwo_A_B")), log(ctx, "fx_two")
  end

  test "a second writer of a directory a dependency wrote refuses", ctx do
    v = ctx.verdicts["fx_second"]
    assert refused?(v, "fx_second", &(&1 =~ "priv/assets/FxW_X_Y")), log(ctx, "fx_second")
  end

  test "a writer reading kino's archives refuses", ctx do
    v = ctx.verdicts["fx_reader"]

    assert refused?(v, "fx_reader", &String.starts_with?(&1, Reasons.foreign_priv_read())),
           log(ctx, "fx_reader")
  end

  test "an extra file in a writer's directory refuses", ctx do
    v = ctx.verdicts["fx_extra"]

    assert refused?(
             v,
             "fx_extra",
             &(String.starts_with?(&1, "compile-time write outside ebin: ") and
                 &1 =~ "FxExtra/extra.txt")
           ),
           log(ctx, "fx_extra")
  end
end
