defmodule NccWorker.Tracer.FixturesBuildLayoutTest do
  # A firmware target's traced compile runs where and as that target's
  # firmware build ran (`NccWorker.FirmwareInputs`): the package's
  # `__DIR__` and build path, `System.argv/0`, and the env a dependency's
  # `mix.exs` and its compile see are the build's. A package that keys an env
  # read on any of them makes the same read in the trace, which records it.
  # Starts real `elixir` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.{FirmwareInputs, Portability, Tracer, TracerFixtures}

  import NccWorker.TracerFixtures, only: [lib: 3]

  @moduletag timeout: 600_000

  @target "rpi4"

  # Each reads its variable only where the firmware build runs.
  @keyed %{
    "fx_dir" => {"FX_DIR_VAR", ~s|String.contains?(__DIR__, "/deps_rpi4/")|},
    "fx_build" =>
      {"FX_BUILD_VAR", ~s|String.ends_with?(Mix.Project.build_path(), "/_build/rpi4")|},
    "fx_argv" => {"FX_ARGV_VAR", ~s|System.argv() == ["firmware"]|}
  }

  defp deps do
    keyed =
      Map.new(@keyed, fn {app, {var, cond}} ->
        module = Macro.camelize(app)

        body = """
        defmodule #{module} do
          @x if #{cond}, do: System.get_env(#{inspect(var)}, "a"), else: "a"
          def x, do: @x
        end
        """

        {app, lib(app, body, %{deps: ["fx_native"]})}
      end)

    # A Makefile makes it natively built, so the judge checks its tree where
    # the compile read it once the compile is over.
    native = %{
      files: %{
        "lib/fx_native.ex" => "defmodule FxNative do\n  def x, do: 1\nend\n",
        "Makefile" => "all:\n\t@true\n"
      }
    }

    # A compile-time probe of a module the tracer loads itself (httpc), whose
    # answer differs in the trace: the firmware judge withholds it.
    probe =
      lib(
        "fx_probe",
        "defmodule FxProbe do\n  @x :code.is_loaded(:httpc) != false\n  def x, do: @x\nend\n",
        %{}
      )

    keyed |> Map.put("fx_native", native) |> Map.put("fx_probe", probe)
  end

  @apps ["fx_native", "fx_probe" | Map.keys(@keyed)]

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "ncc-fixtures-layout-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    # Its real path (/tmp is a link on macOS): Mix expands a child's
    # `../<dep>` from there, and the wrapper's absolute path must match it.
    root = File.cd!(root, &File.cwd!/0)
    on_exit(fn -> File.rm_rf(root) end)
    proj = TracerFixtures.project(Path.join(root, "p"), @apps, deps())
    follow_deps_path(proj)
    home = Path.join(root, "hex")
    releases = Map.new(@apps, &release(home, proj, &1))
    trees = Portability.tree_snapshot(proj, releases: releases, hex_home: home)

    toolchain = Path.join([root, "artifacts", "nerves_toolchain_fx-1.0.0"])
    File.mkdir_p!(Path.join(toolchain, "bin"))

    nerves = [
      {"NERVES_TOOLCHAIN", toolchain},
      {"CROSSCOMPILE", toolchain <> "/bin/aarch64-nerves-linux-gnu"}
    ]

    env = [
      {"MIX_TARGET", @target},
      {"MIX_BUILD_PATH", Path.join([proj, "_build", @target])},
      {"MIX_DEPS_PATH", Path.join(proj, "deps_" <> @target)},
      {"MIX_ENV", "prod"}
    ]

    firmware_build!(proj, env ++ nerves)

    ctx = %{
      project_dir: proj,
      targets: %{},
      releases: releases,
      trees: trees,
      started_at: nil,
      work_dir: root,
      log_dir: root,
      hex_home: home
    }

    record = fn app ->
      FirmwareInputs.record("fx_sys", {@target, env}, Map.put(ctx, :package, app), %{},
        nerves_env: fn _proj, _env, _dir -> {:ok, nerves} end
      )
    end

    recorded = Map.new(Map.keys(@keyed), &{&1, record.(&1)})
    %{proj: proj, root: root, recorded: recorded, record: record}
  end

  # The wrapper's path dependencies live where `MIX_DEPS_PATH` says, as a
  # Hex dependency's would.
  defp follow_deps_path(proj) do
    mix_exs = Path.join(proj, "mix.exs")

    File.write!(
      mix_exs,
      String.replace(
        File.read!(mix_exs),
        ~s|path: "deps/|,
        ~s|path: (System.get_env("MIX_DEPS_PATH") \|\| "deps") <> "/|
      )
    )
  end

  # The target's firmware build, untraced: its own copy of the sources in
  # `deps_<target>`, built into `_build/<target>`. Each dir gets a marker
  # the trace's never has.
  defp firmware_build!(proj, env) do
    File.cp_r!(Path.join(proj, "deps"), Path.join(proj, "deps_" <> @target))
    elixir = System.find_executable("elixir")

    {out, status} =
      System.cmd(elixir, ["-S", "mix", "compile"], cd: proj, env: env, stderr_to_stdout: true)

    assert status == 0, out
    File.write!(Path.join(proj, "deps_#{@target}/.firmware_build"), "")
    File.write!(Path.join(proj, "_build/#{@target}/.firmware_build"), "")
  end

  defp release(home, proj, app) do
    dir = Path.join([proj, "deps", app])

    contents =
      for path <- Path.wildcard(Path.join(dir, "**"), match_dot: true),
          File.regular?(path),
          rel = Path.relative_to(path, dir),
          rel != "hex_metadata.config",
          into: %{},
          do: {rel, File.read!(path)}

    TracerFixtures.hex_release(home, app, Map.keys(contents), contents)
  end

  defp rec(term),
    do: term |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)

  for {app, {var, _cond}} <- @keyed do
    test "#{app} reads #{var} in the trace as it did in the firmware build", ctx do
      assert {:ok, %{compile_inputs: inputs}} = ctx.recorded[unquote(app)]

      assert %{
               "kind" => "env",
               "name" => unquote(var),
               "set_by" => "host",
               "value" => rec(:error)
             } in inputs,
             inspect(inputs, pretty: true)
    end
  end

  # Read where the trace compiled it: nothing the compile reads, so only the
  # check of a natively built tree after the compile can see it.
  test "a natively built dependency's tree is checked in the deps dir the trace used", ctx do
    extra = Path.join(ctx.proj, "deps/fx_native/notes.txt")
    File.write!(extra, "not in the tarball\n")

    try do
      assert {:skip, _reason, _texts} = ctx.record.("fx_dir")
    after
      File.rm!(extra)
    end
  end

  # The firmware judge (stream S8): the trace's verdict is the toolchain
  # judge's, and its texts name the probe the judge classes.
  test "a module body's probe of a module the trace loaded is a probe refusal", ctx do
    assert {:skip, reason, texts} = ctx.record.("fx_probe")
    assert reason =~ "could not be judged"

    assert Enum.any?(texts, &(&1 =~ "compile-time probe of a module the trace loaded: httpc")),
           inspect(texts)

    assert NccWorker.FirmwareJudge.classes(texts) == ["probe"]
  end

  test "the project is left as the firmware build left it", ctx do
    assert File.exists?(Path.join(ctx.proj, "deps_#{@target}/.firmware_build"))
    assert File.exists?(Path.join(ctx.proj, "_build/#{@target}/.firmware_build"))
    refute File.exists?(Path.join(ctx.proj, "deps/.firmware_build"))
    assert File.dir?(Path.join(ctx.proj, "deps/fx_dir"))
    refute File.exists?(Path.join(ctx.root, "fw-inputs-#{@target}"))
  end

  @seen_mix_exs """
  defmodule FxSeen.MixProject do
    use Mix.Project
    @at_load System.get_env("FX_LATE")
    def project do
      [app: :fx_seen, version: "0.1.0", deps: [], at_load: @at_load,
       at_push: System.get_env("FX_LATE")]
    end
    def application, do: [extra_applications: [:logger]]
  end
  """

  @seen_lib """
  defmodule FxSeen do
    for name <- [:argv, :at_load, :at_push, :at_compile],
        do: Module.register_attribute(__MODULE__, name, persist: true)

    @argv System.argv()
    @at_load Mix.Project.config()[:at_load]
    @at_push Mix.Project.config()[:at_push]
    @at_compile System.get_env("FX_LATE")
  end
  """

  # `mix firmware` loads the dependencies twice: `nerves_bootstrap.init`'s
  # `deps.loadpaths` before Nerves exports its env, and the compile's own
  # `deps.loadpaths` after it (`Mix.Dep.load_and_cache/0` converges anew at
  # the top every time). What a dependency is compiled with comes from that
  # second load: a rebar3 dependency's `rebar.config.script`, which Mix
  # evaluates as it loads and writes out as the `mix.rebar.config` rebar3
  # reads, and a Mix dependency's own `deps:`, from its `project/0`.
  @late_script """
  case os:getenv("FX_LATE") of
      false -> CONFIG;
      Late -> lists:keystore(erl_opts, 1, CONFIG, {erl_opts, [{d, 'LATE', Late}]})
  end.
  """

  @late_erl """
  -module(fx_rebar).
  -ifdef(LATE).
  -export([late/0]).
  late() -> ?LATE.
  -endif.
  """

  @late_deps_mix_exs """
  defmodule FxTop.MixProject do
    use Mix.Project
    def project, do: [app: :fx_top, version: "0.1.0", deps: deps(System.get_env("FX_LATE"))]
    def application, do: [extra_applications: [:logger]]
    defp deps(nil), do: []
    defp deps(_late), do: [{:fx_child, path: "../fx_child"}]
  end
  """

  @late_deps_lib """
  defmodule FxTop do
    Module.register_attribute(__MODULE__, :child, persist: true)
    @child Code.ensure_loaded?(FxChild)
  end
  """

  @tag :tmp_dir
  test "what the dependencies are compiled with is loaded once the late env is set",
       %{tmp_dir: dir} do
    deps = %{
      "fx_rebar" => %{
        manager: :rebar3,
        files: %{"rebar.config.script" => @late_script, "src/fx_rebar.erl" => @late_erl}
      },
      "fx_top" => %{mix_exs: @late_deps_mix_exs, files: %{"lib/fx_top.ex" => @late_deps_lib}},
      "fx_child" => lib("fx_child", "defmodule FxChild do\n  def x, do: 1\nend\n", %{})
    }

    proj = TracerFixtures.project(dir, ["fx_rebar", "fx_top"], deps)

    assert {:ok, 0} =
             Tracer.run(proj, ["fx_rebar", "fx_top"],
               trace_dir: Path.join(dir, "trace"),
               env: TracerFixtures.env(proj),
               argv: ["firmware"],
               late_env: [{"FX_LATE", "late"}],
               log_file: Path.join(dir, "trace.log"),
               timeout_ms: 240_000
             )

    ebin = &Path.join([proj, "_build/host/lib", &1, "ebin"])

    {:ok, {:fx_rebar, [exports: exports]}} =
      :beam_lib.chunks(~c"#{ebin.("fx_rebar")}/fx_rebar.beam", [:exports])

    {:ok, {FxTop, [attributes: attrs]}} =
      :beam_lib.chunks(~c"#{ebin.("fx_top")}/Elixir.FxTop.beam", [:attributes])

    assert {{:late, 0} in exports, attrs[:child]} == {true, [true]},
           File.read!(Path.join(dir, "trace.log"))
  end

  @tag :tmp_dir
  test "the driver sets argv first, and the late env once every mix.exs is loaded",
       %{tmp_dir: dir} do
    spec = %{mix_exs: @seen_mix_exs, files: %{"lib/fx_seen.ex" => @seen_lib}}
    proj = TracerFixtures.project(dir, ["fx_seen"], %{"fx_seen" => spec})

    assert {:ok, 0} =
             Tracer.run(proj, ["fx_seen"],
               trace_dir: Path.join(dir, "trace"),
               env: TracerFixtures.env(proj),
               argv: ["firmware"],
               late_env: [{"FX_LATE", "late"}],
               timeout_ms: 240_000
             )

    beam = Path.join(proj, "_build/host/lib/fx_seen/ebin/Elixir.FxSeen.beam")
    {:ok, {FxSeen, [attributes: attrs]}} = :beam_lib.chunks(~c"#{beam}", [:attributes])

    assert {attrs[:argv], attrs[:at_load], attrs[:at_push], attrs[:at_compile]} ==
             {["firmware"], [nil], ["late"], ["late"]}
  end
end
