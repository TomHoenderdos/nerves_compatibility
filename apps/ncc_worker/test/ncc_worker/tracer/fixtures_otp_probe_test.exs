defmodule NccWorker.Tracer.FixturesOtpProbeTest do
  # Starts real `elixir` and `mix` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.{BuildIdentity, TracerFixtures}

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  # Mix compiles a dependency on a code path pruned to the applications its
  # closure lists (`Mix.Tasks.Compile.All`); Mix.install does not prune
  # (`prune_code_paths: false`, which the dependencies inherit). A probe of
  # an installed OTP application the package does not list answers `false`
  # in a Mix project and `true` under Mix.install, so the two compile
  # different code (vega_lite 0.1.11's `VegaLite.WxViewer` and `:wx`).
  # mnesia stands in for wx: every OTP build has it, and neither Mix, Hex
  # nor the tracer loads it.
  @refusal "compile-time probe of an OTP application outside the closure: "

  defp probe_fixture(dir, extra_applications, expr \\ "Code.ensure_loaded?(:mnesia)") do
    TracerFixtures.project(dir, ["fx_probe"], %{
      "fx_probe" => %{
        extra_applications: extra_applications,
        files: %{"lib/fx_probe.ex" => TracerFixtures.attr_module("FxProbe", expr)}
      }
    })
  end

  defp compile(proj) do
    {out, status} =
      System.cmd("mix", ["compile"],
        cd: proj,
        env: TracerFixtures.env(proj),
        stderr_to_stdout: true
      )

    assert status == 0, out
  end

  # What `FxProbe.x/0` returns in the build under `_build/host`.
  defp built_value(proj) do
    ebin = Path.join([proj, "_build", "host", "lib", "fx_probe", "ebin"])
    {out, 0} = System.cmd("elixir", ["-pa", ebin, "-e", "IO.write(inspect(FxProbe.x()))"])
    out
  end

  # The wrapper project as Mix.install configures its own: no pruning.
  defp unpruned!(proj) do
    path = Path.join(proj, "mix.exs")
    mix_exs = File.read!(path)

    File.write!(
      path,
      String.replace(mix_exs, "deps: [", "prune_code_paths: false, deps: [", global: false)
    )
  end

  defp published(proj) do
    lib = Path.join([proj, "_build", "host", "lib"])

    for path <- Path.wildcard(Path.join(lib, "*/{ebin,priv}/**")),
        File.regular?(path),
        into: %{},
        do: {Path.relative_to(path, lib), File.read!(path)}
  end

  defp probes(traced), do: Enum.filter(traced.report.events, &(&1["channel"] == "probe"))

  # Read from the installs' ebin dirs, not the code path: what Mix.install
  # finds. Not a module loaded before the tracer started, nor one it
  # loaded itself (`preloaded`), nor one of an application on every
  # compile's path.
  test "the tracer watches the installed modules off every compile's path" do
    mods =
      :ncc_tracer.installed_modules(%{mnesia_lib: true, lists: true}, %{"mnesia_log" => "mnesia"})

    assert mods["mnesia"] == "mnesia"
    assert mods["mnesia_tm"] == "mnesia"
    assert mods["Elixir.EEx"] == "eex"
    refute Map.has_key?(mods, "mnesia_lib")
    refute Map.has_key?(mods, "mnesia_log")
    refute Map.has_key?(mods, "lists")

    # Round 2 (R1-A): an every-path application's modules too, when not
    # loaded before the trace.
    assert mods["Elixir.URI"] == "elixir"
    assert mods["zip"] == "stdlib"
    assert mods["Elixir.Logger.Formatter"] == "logger"

    # Mix loads these in every compile (`:ncc_tracer.loaded_by_mix/0`).
    for m <- :ncc_tracer.loaded_by_mix(), do: refute(Map.has_key?(mods, Atom.to_string(m)))

    # The tracer's own modules are no installed application's; preloaded
    # ones (erlang, prim_file) are loaded before any trace starts.
    refute Map.has_key?(mods, "ncc_tracer")
  end

  test "a probe of an OTP application the package does not list is refused", %{tmp_dir: dir} do
    proj = probe_fixture(dir, [])

    # The class itself: the same project compiles `false` pruned, `true`
    # unpruned.
    compile(proj)
    assert built_value(proj) == "false"
    untraced = published(proj)

    File.rm_rf!(Path.join(proj, "_build"))
    traced = TracerFixtures.trace(proj, ["fx_probe"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log
    assert traced.report.problems == []
    # The trace builds what a Mix project builds.
    assert BuildIdentity.differences(published(proj), untraced) == []

    assert %{status: :skip, reason: reason} = TracerFixtures.judge(proj, "fx_probe", traced)
    assert reason == @refusal <> "mnesia via Code.ensure_loaded?/1"

    # A firmware target's trace refuses it too: `mix firmware` prunes, but
    # what an earlier compile loaded stays visible (below).
    firmware = TracerFixtures.judge(proj, "fx_probe", traced, [], target: "rpi4")
    assert %{status: :skip, reason: ^reason} = firmware

    # The event shape the judge reads (pinned on this toolchain). The code
    # server's own module_loaded/1 inside it is not written (round 2).
    mnesia = probes(traced) |> Enum.filter(&(&1["arg"]["module"] == "mnesia"))
    assert [event] = Enum.filter(mnesia, &(&1["mfa"] == "code:ensure_loaded/1"))
    assert [] = Enum.filter(mnesia, &(&1["mfa"] == "erlang:module_loaded/1"))
    assert event["arg"]["otp_app"] == "mnesia"
    assert event["arg"]["app"] == nil
    assert event["arg"]["checker"] == false
    assert event["caller"]["module"] == "Elixir.Code"
    assert event["caller"]["function"] == "ensure_loaded?"
    assert event["extent"] == "frame"
    refute Map.has_key?(traced.report.start["preloaded"], "mnesia")

    unpruned!(proj)
    File.rm_rf!(Path.join(proj, "_build"))
    compile(proj)
    assert built_value(proj) == "true"
  end

  # Why a pruned Mix project (`mix firmware` included) is no stand-in for
  # the builder: pruning decides only what can be newly found. fx_a lists
  # mnesia and loads it; fx_probe, compiled after it in the same VM, finds
  # it loaded although its own path is pruned. Built alone, as the builder
  # builds it, fx_probe finds nothing.
  test "an earlier dependency's load is visible to a pruned compile", %{tmp_dir: dir} do
    probe = TracerFixtures.attr_module("FxProbe", "Code.ensure_loaded?(:mnesia)")

    alone =
      TracerFixtures.project(Path.join(dir, "alone"), ["fx_probe"], %{
        "fx_probe" => %{files: %{"lib/fx_probe.ex" => probe}}
      })

    both =
      TracerFixtures.project(Path.join(dir, "both"), ["fx_a", "fx_probe"], %{
        "fx_a" => %{
          extra_applications: [:mnesia],
          files: %{
            "lib/fx_a.ex" => TracerFixtures.attr_module("FxA", "Code.ensure_loaded?(:mnesia)")
          }
        },
        "fx_probe" => %{files: %{"lib/fx_probe.ex" => probe}}
      })

    compile(alone)
    compile(both)
    assert built_value(alone) == "false"
    assert built_value(both) == "true"
  end

  test "a probe of an OTP application the package lists passes", %{tmp_dir: dir} do
    expr = "{Code.ensure_loaded?(:mnesia), is_list(:code.which(:mnesia_lib))}"
    proj = probe_fixture(dir, [:mnesia], expr)
    compile(proj)
    assert built_value(proj) == "{true, true}"
    untraced = published(proj)

    File.rm_rf!(Path.join(proj, "_build"))
    traced = TracerFixtures.trace(proj, ["fx_probe"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log
    assert BuildIdentity.differences(published(proj), untraced) == []
    assert %{status: :pass} = TracerFixtures.judge(proj, "fx_probe", traced)

    modules = traced |> probes() |> Enum.map(& &1["arg"]["module"])
    assert "mnesia" in modules and "mnesia_lib" in modules, inspect(modules)
  end

  # Calls the package makes only at run time, and a behaviour it declares,
  # of an application it does not list: the compiler's own lookups (the
  # type checker's, which also checks behaviours) reach its warnings only.
  test "run-time calls and a behaviour of an unlisted OTP application pass", %{tmp_dir: dir} do
    body = """
    defmodule FxProbe do
      @behaviour :mnesia_frag_hash
      def init_state(_tab, state), do: state
      def add_frag(state), do: {state, [], []}
      def del_frag(state), do: {state, [], []}
      def key_to_frag_number(_state, _key), do: 1
      def match_spec_to_frag_numbers(_state, _spec), do: [1]
      def x, do: :mnesia.system_info(:version)
      def y, do: :mnesia_lib.dir()
    end
    """

    proj =
      TracerFixtures.project(dir, ["fx_probe"], %{
        "fx_probe" => %{files: %{"lib/fx_probe.ex" => body}}
      })

    compile(proj)
    untraced = published(proj)
    File.rm_rf!(Path.join(proj, "_build"))
    traced = TracerFixtures.trace(proj, ["fx_probe"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log
    assert BuildIdentity.differences(published(proj), untraced) == []

    verdict = TracerFixtures.judge(proj, "fx_probe", traced)
    assert %{status: :pass} = verdict, inspect(Map.take(verdict, [:reason, :observations]))

    # The lookup `@behaviour` makes, pinned on this toolchain.
    assert [lookup] =
             Enum.filter(
               probes(traced),
               &(&1["arg"]["module"] == "mnesia_frag_hash" and &1["mfa"] == "code:ensure_loaded/1")
             )

    assert lookup["arg"]["attribute"] == true
    assert lookup["arg"]["otp_app"] == "mnesia"
    assert lookup["caller"]["module"] == "Elixir.Code"
    assert lookup["caller"]["function"] == "ensure_compiled"

    # And what makes it no concern: unpruned, the beams are the same.
    unpruned!(proj)
    File.rm_rf!(Path.join(proj, "_build"))
    compile(proj)
    assert BuildIdentity.differences(published(proj), untraced) == []
  end

  # The probe forms outside the module probes (round-1 review, F2): each
  # builds `false` pruned and `true` unpruned with mnesia unlisted, and
  # refuses with the function the package called. Application.spec/2's
  # answer is whatever an earlier compile loaded (the next test).
  @forms [
    {":code.where_is_file(~c\"mnesia.app\") != :non_existing", "application_controller",
     "code:where_is_file/1", "mnesia"},
    {":code.where_is_file(~c\"mnesia.beam\") != :non_existing", nil, "code:where_is_file/1",
     "mnesia"},
    {"Enum.any?(:code.all_available(), &(elem(&1, 0) == ~c\"mnesia\"))", nil, :host_read, nil},
    {"match?(:ok, Application.load(:mnesia))", nil, "application_controller:load_application/1",
     "mnesia"},
    {"Application.spec(:mnesia, :vsn) != nil", nil, "Application.spec/2", "mnesia"},
    {"match?({:ok, _}, Application.ensure_all_started(:mnesia))", nil,
     "application_controller:is_running/1", "mnesia"},
    # Round 2 (R1-D): loading a module by name.
    {"match?({:module, _}, :code.load_file(:mnesia))", nil, "code:load_file/1", "mnesia"},
    {"match?(:ok, :code.atomic_load([:mnesia]))", nil, :host_read_atomic, nil}
  ]

  for {{expr, _, via, app}, i} <- Enum.with_index(@forms) do
    @expr expr
    @via via
    @app app
    test "probe form #{i}: #{expr} refuses", %{tmp_dir: dir} do
      proj = probe_fixture(dir, [], @expr)
      traced = TracerFixtures.trace(proj, ["fx_probe"], mode: :host)
      assert {:ok, 0} = traced.result, traced.log
      assert %{status: :skip, reason: reason} = TracerFixtures.judge(proj, "fx_probe", traced)

      case @via do
        :host_read ->
          assert reason =~ "compile-time host read: code:all_available/0 in ", reason

        :host_read_atomic ->
          assert reason =~ "compile-time host read: code:atomic_load/1 in ", reason

        via ->
          assert reason == @refusal <> "#{@app} via #{via}"
      end
    end
  end

  # Record.extract/2's `from:` asks the code path for the file first; the
  # read of it that follows is judged as a read (here a relative path an
  # epp server opens, which refuses as it always did).
  test "Record.extract's code path lookup is no concern", %{tmp_dir: dir} do
    proj =
      TracerFixtures.project(dir, ["fx_probe"], %{
        "fx_probe" => %{
          files: %{
            "src/fx.hrl" => "-record(fx, {a = 1, b}).\n",
            "lib/fx_probe.ex" => """
            defmodule FxProbe do
              require Record
              Record.defrecord(:fx, Record.extract(:fx, from: "src/fx.hrl"))
              def x, do: fx()
            end
            """
          }
        }
      })

    traced = TracerFixtures.trace(proj, ["fx_probe"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log
    verdict = TracerFixtures.judge(proj, "fx_probe", traced)
    reasons = [verdict.reason | Enum.map(verdict.observations["refusals"], & &1["reason"])]
    refute Enum.any?(reasons, &(is_binary(&1) and &1 =~ "where_is_file")), inspect(reasons)

    assert [where] =
             Enum.filter(traced.report.events, &(&1["mfa"] == "code:where_is_file/1"))

    assert where["first"]["module"] == "Elixir.Record.Extractor"
    assert where["first"]["function"] == "from_file"
    assert where["first_kind"] == "toolchain"
  end

  test "an application spec answers what an earlier dependency's compile loaded",
       %{tmp_dir: dir} do
    probe = TracerFixtures.attr_module("FxProbe", "Application.spec(:mnesia, :vsn) != nil")

    alone =
      TracerFixtures.project(Path.join(dir, "alone"), ["fx_probe"], %{
        "fx_probe" => %{files: %{"lib/fx_probe.ex" => probe}}
      })

    # fx_a only lists mnesia: Mix's AppLoader loads the application to
    # compile fx_a, and fx_probe after it sees it loaded.
    both =
      TracerFixtures.project(Path.join(dir, "both"), ["fx_a", "fx_probe"], %{
        "fx_a" => %{
          extra_applications: [:mnesia],
          files: %{"lib/fx_a.ex" => TracerFixtures.attr_module("FxA", "1")}
        },
        "fx_probe" => %{files: %{"lib/fx_probe.ex" => probe}}
      })

    compile(alone)
    compile(both)
    assert built_value(alone) == "false"
    assert built_value(both) == "true"
  end

  test "application probes of the package's own and listed applications pass", %{tmp_dir: dir} do
    expr =
      "{Application.spec(:fx_probe, :vsn), Application.spec(:mnesia, :vsn) != nil, " <>
        "Application.spec(:elixir, :description), match?(:ok, Application.ensure_loaded(:mnesia))}"

    proj = probe_fixture(dir, [:mnesia], expr)
    compile(proj)
    untraced = published(proj)
    File.rm_rf!(Path.join(proj, "_build"))
    traced = TracerFixtures.trace(proj, ["fx_probe"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log
    assert BuildIdentity.differences(published(proj), untraced) == []

    verdict = TracerFixtures.judge(proj, "fx_probe", traced)
    assert %{status: :pass} = verdict, inspect(Map.take(verdict, [:reason, :observations]))

    apps =
      for %{"channel" => "app_probe", "arg" => %{"app" => app}} <- traced.report.events,
          do: app

    assert "mnesia" in apps and "fx_probe" in apps, inspect(apps)
  end

  # Round-2 ruling 3 (R1-A): a loaded-now probe of a module of an
  # every-path application that nothing loaded yet. Built alone, `false`;
  # after another compile used the module, `true`.
  test "a loaded-now probe of a not yet loaded stdlib module refuses unless ensured",
       %{tmp_dir: dir} do
    alone = probe_fixture(Path.join(dir, "a"), [], "function_exported?(:zip, :zip, 2)")
    traced = TracerFixtures.trace(alone, ["fx_probe"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log
    assert built_value(alone) == "false"

    assert %{status: :skip, reason: reason} = TracerFixtures.judge(alone, "fx_probe", traced)

    assert reason ==
             "compile-time probe of whether a module is loaded: zip via erlang:function_exported/3"

    ensured =
      probe_fixture(
        Path.join(dir, "b"),
        [],
        "Code.ensure_loaded?(:zip) and function_exported?(:zip, :zip, 2)"
      )

    traced = TracerFixtures.trace(ensured, ["fx_probe"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log
    verdict = TracerFixtures.judge(ensured, "fx_probe", traced)
    assert %{status: :pass} = verdict, inspect(Map.take(verdict, [:reason, :observations]))
  end

  # Round-2 ruling 3: the toolchain's own probes are not written (the judge
  # ignores them), but for code:ensure_loaded/1, which the judge reads for
  # `ensured`, written without its frames.
  test "the collector writes no probe the judge would ignore", %{tmp_dir: dir} do
    body = """
    defmodule FxProbe do
      @x %URI{} |> Map.keys() |> length()
      def x, do: @x
    end
    """

    proj =
      TracerFixtures.project(dir, ["fx_probe"], %{
        "fx_probe" => %{files: %{"lib/fx_probe.ex" => body}}
      })

    traced = TracerFixtures.trace(proj, ["fx_probe"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log
    assert %{status: :pass} = TracerFixtures.judge(proj, "fx_probe", traced)

    for %{"channel" => "probe", "arg" => arg} = e <- traced.report.events do
      cond do
        arg["by_package"] == true or is_binary(arg["app"]) ->
          :ok

        e["mfa"] == "code:ensure_loaded/1" ->
          refute Map.has_key?(e, "first"), inspect(e)
          assert is_binary(e["pid"]) and is_integer(e["ts"])

        true ->
          assert is_binary(arg["otp_app"]) and
                   arg["otp_app"] not in ~w(kernel stdlib compiler erts elixir mix iex ex_unit logger),
                 inspect(e)
      end
    end

    assert is_integer(traced.report.stats["dropped_probes"])
  end

  # A package's probe of a module no installed application holds (round-1
  # review, F3): under Mix.install every installed dependency is on the code
  # path, and in a Mix project a module an earlier dependency's compile-time
  # code loaded stays loaded, so only a module the package's closure holds
  # answers the same.
  test "a probe of a module only another dependency defines refuses", %{tmp_dir: dir} do
    proj =
      TracerFixtures.project(dir, ["fx_other", "fx_probe"], %{
        "fx_other" => %{
          files: %{"lib/fx_other.ex" => "defmodule FxOther do\n  def f, do: 1\nend\n"}
        },
        "fx_probe" => %{
          files: %{
            "lib/fx_probe.ex" =>
              TracerFixtures.attr_module("FxProbe", "Code.ensure_loaded?(FxOther)")
          }
        }
      })

    # Unpruned, as Mix.install compiles, fx_probe finds fx_other's module.
    mix_exs = File.read!(Path.join(proj, "mix.exs"))
    unpruned!(proj)
    compile(proj)
    assert built_value(proj) == "true"
    File.write!(Path.join(proj, "mix.exs"), mix_exs)
    File.rm_rf!(Path.join(proj, "_build"))

    # The builder compiles fx_probe's closure alone: nothing defines FxOther.
    traced = TracerFixtures.trace(proj, ["fx_probe"])
    assert {:ok, 0} = traced.result, traced.log
    assert built_value(proj) == "false"
    assert %{status: :skip, reason: reason} = TracerFixtures.judge(proj, "fx_probe", traced)

    assert reason ==
             "compile-time probe of a dependency outside the closure: Elixir.FxOther via " <>
               "Code.ensure_loaded?/1"

    assert [event | _] =
             Enum.filter(probes(traced), &(&1["arg"]["module"] == "Elixir.FxOther"))

    assert event["arg"]["by_package"] == true
    assert event["arg"]["otp_app"] == nil
    assert event["arg"]["app"] == nil
  end

  # Round-2 ruling 1: a probe of a module of a dependency the package
  # declares and this build lacks passes. The client's closure check keeps
  # a project that has the dependency (and so has it in the package's
  # closure) from the build. Known only from the dependency's tarball in the
  # run's Hex cache.
  test "a probe of an absent declared optional dependency's module passes", %{tmp_dir: dir} do
    home = Path.join(dir, "hex")

    req = [
      {"name", "fx_opt"},
      {"app", "fx_opt"},
      {"optional", true},
      {"requirement", "~> 0.1"},
      {"repository", "hexpm"}
    ]

    {app, release} =
      TracerFixtures.hex_release(home, "fx_probe", ["lib", "mix.exs"], %{}, [
        {"requirements", [req]}
      ])

    proj =
      TracerFixtures.project(Path.join(dir, "p"), ["fx_probe"], %{
        "fx_probe" => %{
          files: %{
            "lib/fx_probe.ex" =>
              TracerFixtures.attr_module("FxProbe", "Code.ensure_loaded?(FxOpt.Codec)")
          }
        }
      })

    traced = TracerFixtures.trace(proj, ["fx_probe"])
    assert {:ok, 0} = traced.result, traced.log
    opts = [releases: %{app => release}, hex_home: home]

    # fx_opt's tarball is not cached: its modules are unknown, so it refuses.
    assert %{status: :skip, reason: reason} =
             TracerFixtures.judge(proj, "fx_probe", traced, [], opts)

    assert reason ==
             "compile-time probe of a dependency outside the closure: Elixir.FxOpt.Codec via Code.ensure_loaded?/1"

    TracerFixtures.hex_release(home, "fx_opt", ["lib"], %{
      "lib/fx_opt.ex" => "defmodule FxOpt do\n  defmodule Codec do\n  end\nend\n"
    })

    verdict = TracerFixtures.judge(proj, "fx_probe", traced, [], opts)
    assert %{status: :pass} = verdict, inspect(Map.take(verdict, [:reason, :observations]))
  end

  # A closure dependency's module can be found the same way pruned or not;
  # whether it is loaded now is the earlier compiles' doing, unless the same
  # process ensure-loads it first.
  for {expr, verdict} <- [
        {"Code.ensure_loaded?(FxDep)", :pass},
        {"function_exported?(FxDep, :f, 0)", :skip},
        {"Code.ensure_loaded?(FxDep) and function_exported?(FxDep, :f, 0)", :pass}
      ] do
    @expr expr
    @verdict verdict
    test "a closure dependency's module: #{expr}", %{tmp_dir: dir} do
      proj =
        TracerFixtures.project(dir, ["fx_probe"], %{
          "fx_dep" => %{files: %{"lib/fx_dep.ex" => "defmodule FxDep do\n  def f, do: 1\nend\n"}},
          "fx_probe" => %{
            deps: ["fx_dep"],
            files: %{"lib/fx_probe.ex" => TracerFixtures.attr_module("FxProbe", @expr)}
          }
        })

      traced = TracerFixtures.trace(proj, ["fx_probe"])
      assert {:ok, 0} = traced.result, traced.log
      verdict = TracerFixtures.judge(proj, "fx_probe", traced)
      assert verdict.status == @verdict, inspect(Map.take(verdict, [:reason, :observations]))

      if @verdict == :skip do
        assert verdict.reason ==
                 "compile-time probe of whether a module is loaded: Elixir.FxDep via " <>
                   "erlang:function_exported/3"
      end
    end
  end

  # Round-2 ruling 2: a Spark-like DSL. The DSL module's body asks whether
  # an extension of the same package exports add_extensions/0, with no
  # ensure first: own modules are compiled by the same parallel compile on
  # both sides, so it passes.
  test "a loaded-now probe of the package's own module passes (Spark's DSL)", %{tmp_dir: dir} do
    body = """
    defmodule FxDsl.Ext do
      def add_extensions, do: []
    end

    defmodule FxDsl do
      @default_extensions Enum.flat_map([FxDsl.Ext], fn module ->
                            if function_exported?(module, :add_extensions, 0),
                              do: [module | module.add_extensions()],
                              else: [module]
                          end)
      def x, do: @default_extensions
    end
    """

    proj =
      TracerFixtures.project(dir, ["fx_probe"], %{
        "fx_probe" => %{files: %{"lib/fx_dsl.ex" => body}}
      })

    traced = TracerFixtures.trace(proj, ["fx_probe"])
    assert {:ok, 0} = traced.result, traced.log
    verdict = TracerFixtures.judge(proj, "fx_probe", traced)
    assert %{status: :pass} = verdict, inspect(Map.take(verdict, [:reason, :observations]))

    assert Enum.any?(
             probes(traced),
             &(&1["arg"]["module"] == "Elixir.FxDsl.Ext" and
                 &1["mfa"] == "erlang:function_exported/3")
           )
  end

  # Round-2 ruling 2: a plug pipeline. Plug.Builder's init_module_plug/4
  # calls `plug.init(opts)` and then asks `function_exported?(plug, :call,
  # 2)` (plug 1.5.0 and later, reviewed): the direct call loaded the module
  # on both sides. Here `plug` is a stand-in with that body, a Hex release
  # in the run's cache; an unreviewed plug release refuses the same probe.
  test "plug's pipeline asks about a module plug it just called", %{tmp_dir: dir} do
    home = Path.join(dir, "hex")

    builder = """
    defmodule Plug.Builder do
      def init_module_plug(plug, opts, guards, :compile) do
        initialized_opts = plug.init(opts)

        if function_exported?(plug, :call, 2) do
          {:module, plug, initialized_opts, guards}
        else
          raise ArgumentError, "\#{inspect(plug)} plug must implement call/2"
        end
      end
    end
    """

    proj =
      TracerFixtures.project(Path.join(dir, "p"), ["fx_probe"], %{
        "plug" => %{files: %{"lib/plug/builder.ex" => builder}},
        "fx_mod_plug" => %{
          files: %{
            "lib/fx_mod_plug.ex" =>
              "defmodule FxModPlug do\n  def init(o), do: o\n  def call(c, _), do: c\nend\n"
          }
        },
        "fx_probe" => %{
          deps: ["plug", "fx_mod_plug"],
          files: %{
            "lib/fx_probe.ex" =>
              TracerFixtures.attr_module(
                "FxProbe",
                "Plug.Builder.init_module_plug(FxModPlug, [], true, :compile)"
              )
          }
        }
      })

    traced = TracerFixtures.trace(proj, ["fx_probe"])
    assert {:ok, 0} = traced.result, traced.log

    assert Enum.any?(
             probes(traced),
             &(&1["arg"]["module"] == "Elixir.FxModPlug" and
                 &1["mfa"] == "erlang:function_exported/3" and
                 &1["caller"]["function"] == "init_module_plug")
           )

    judge = fn version ->
      {app, release} =
        TracerFixtures.hex_release(home, "plug", ["lib", "mix.exs"], %{}, [{"version", version}])

      TracerFixtures.judge(proj, "fx_probe", traced, [],
        releases: %{app => release},
        hex_home: home
      )
    end

    verdict = judge.("1.20.4")
    assert %{status: :pass} = verdict, inspect(Map.take(verdict, [:reason, :observations]))

    assert %{status: :skip, reason: reason} = judge.("1.4.5")

    assert reason ==
             "compile-time probe of whether a module is loaded: Elixir.FxModPlug via " <>
               "erlang:function_exported/3"
  end

  # The compiler's own lookups of a module nothing defines (a remote call,
  # an alias in a def body) decide only its warnings: no concern.
  test "the compiler's lookups of a missing module pass", %{tmp_dir: dir} do
    body = """
    defmodule FxProbe do
      alias FxMissing.Sub
      def x, do: FxMissing.f()
      def y, do: Sub.g(1)
    end
    """

    proj =
      TracerFixtures.project(dir, ["fx_probe"], %{
        "fx_probe" => %{files: %{"lib/fx_probe.ex" => body}}
      })

    traced = TracerFixtures.trace(proj, ["fx_probe"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log
    verdict = TracerFixtures.judge(proj, "fx_probe", traced)
    assert %{status: :pass} = verdict, inspect(Map.take(verdict, [:reason, :observations]))
  end

  # Whether a module is loaded now: untraced and pruned, nothing loads
  # mnesia; under Mix.install another compile may have.
  test "a loaded-now probe of an OTP application the package does not list is refused",
       %{tmp_dir: dir} do
    proj = probe_fixture(dir, [], "function_exported?(:mnesia, :start, 0)")
    traced = TracerFixtures.trace(proj, ["fx_probe"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log

    assert %{status: :skip, reason: reason} = TracerFixtures.judge(proj, "fx_probe", traced)
    assert reason == @refusal <> "mnesia via erlang:function_exported/3"
  end

  # easel 0.3.4's `optional_apps/0`: its mix.exs asks for :wx when
  # compile.all reads its application/0, on whatever code path the previous
  # dependency's compile left.
  test "a probe from a dependency's mix.exs is refused even when it lists the application",
       %{tmp_dir: dir} do
    mix_exs = """
    defmodule FxProbe.MixProject do
      use Mix.Project
      def project, do: [app: :fx_probe, version: "0.1.0", deps: []]
      def application, do: [extra_applications: [:logger] ++ optional_apps()]
      defp optional_apps, do: if(Code.ensure_loaded?(:mnesia), do: [:mnesia], else: [])
    end
    """

    proj =
      TracerFixtures.project(dir, ["fx_probe"], %{
        "fx_probe" => %{
          mix_exs: mix_exs,
          files: %{"lib/fx_probe.ex" => TracerFixtures.attr_module("FxProbe", "1")}
        }
      })

    traced = TracerFixtures.trace(proj, ["fx_probe"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log

    assert %{status: :skip, reason: reason} = TracerFixtures.judge(proj, "fx_probe", traced)
    assert reason == @refusal <> "mnesia via Code.ensure_loaded?/1 in mix.exs"
  end

  # A closure dependency's probe is a refusal in its window, which taints
  # every package that depends on it (R3), as any refusal there does.
  test "a closure dependency's probe taints the package", %{tmp_dir: dir} do
    proj =
      TracerFixtures.project(dir, ["fx_top"], %{
        "fx_top" => %{
          deps: ["fx_probe"],
          files: %{"lib/fx_top.ex" => "defmodule FxTop do\n  def f, do: FxProbe.x()\nend\n"}
        },
        "fx_probe" => %{
          files: %{
            "lib/fx_probe.ex" =>
              TracerFixtures.attr_module("FxProbe", "Code.ensure_loaded?(:mnesia)")
          }
        }
      })

    traced = TracerFixtures.trace(proj, ["fx_top"])
    assert {:ok, 0} = traced.result, traced.log

    assert %{status: :skip, reason: reason} = TracerFixtures.judge(proj, "fx_top", traced)

    assert reason ==
             "closure dependency observed the host: fx_probe (" <>
               @refusal <> "mnesia via Code.ensure_loaded?/1)"
  end
end
