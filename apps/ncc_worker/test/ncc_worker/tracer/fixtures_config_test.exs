defmodule NccWorker.Tracer.FixturesConfigTest do
  # Spec R5 and the Elixir-patch rule on real compiles: path dependencies of
  # one project, compiled once under the real tracer and judged one by one.
  # Starts real `elixir` VMs: one such module at a time (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.AppFile
  alias NccWorker.Portability.ConfigReads
  alias NccWorker.TracerFixtures

  import NccWorker.TracerFixtures, only: [lib: 2, lib: 3]

  @moduletag timeout: 600_000

  @cnj "portability could not be judged"

  # The next patch of the Elixir running these tests, which is the one the
  # fixtures compile under.
  @next_patch (fn ->
                 v = Version.parse!(System.version())
                 "#{v.major}.#{v.minor}.#{v.patch + 1}"
               end).()

  @deps %{
    "fx_cfg_get" =>
      lib("fx_cfg_get", """
      defmodule FxCfgGet do
        @k Application.get_env(:fx_cfg_get, :k)
        def k, do: @k
      end
      """),
    "fx_cfg_compile" =>
      lib("fx_cfg_compile", """
      defmodule FxCfgCompile do
        @k Application.compile_env(:fx_cfg_compile, :k)
        def k, do: @k
      end
      """),
    "fx_cfg_all" =>
      lib("fx_cfg_all", """
      defmodule FxCfgAll do
        @all Application.get_all_env(:fx_cfg_all)
        def all, do: @all
      end
      """),
    "fx_cfg_iowarn" =>
      lib("fx_cfg_iowarn", """
      defmodule FxCfgIoWarn do
        IO.warn("fixture warning, expected")
        def x, do: :ok
      end
      """),
    "fx_cfg_logger" =>
      lib("fx_cfg_logger", """
      defmodule FxCfgLogger do
        require Logger
        def f, do: Logger.info("fixture")
        def g, do: Logger.debug("fixture")
      end
      """),
    "fx_cfg_d" =>
      lib("fx_cfg_d", """
      defmodule FxCfgD do
        @mode Application.get_env(:fx_cfg_d, :mode)
        def mode, do: @mode
      end
      """),
    "fx_cfg_user" =>
      lib(
        "fx_cfg_user",
        """
        defmodule FxCfgUser do
          @mode FxCfgD.mode()
          def mode, do: @mode
        end
        """,
        %{deps: ["fx_cfg_d"]}
      ),
    # Compile order: `fx_ord_b` has an env default in its .app. `fx_ord_c`
    # depends on it, so it is always loaded before `fx_ord_c` compiles;
    # `fx_ord_a` does not, so whether it is depends on the graph.
    "fx_ord_b" =>
      lib("fx_ord_b", "defmodule FxOrdB do\n  def b, do: :b\nend\n", %{
        mix_exs: """
        defmodule FxOrdB.MixProject do
          use Mix.Project
          def project, do: [app: :fx_ord_b, version: "0.1.0", deps: []]
          def application, do: [env: [k: 1]]
        end
        """
      }),
    "fx_ord_a" =>
      lib("fx_ord_a", """
      defmodule FxOrdA do
        @k Application.get_env(:fx_ord_b, :k)
        def k, do: @k
      end
      """),
    "fx_ord_c" =>
      lib(
        "fx_ord_c",
        """
        defmodule FxOrdC do
          @k Application.get_env(:fx_ord_b, :k)
          def k, do: @k
        end
        """,
        %{deps: ["fx_ord_b"]}
      ),
    # Reads nothing: the Mix and Hex reads of the compile around it must
    # leave it publishable.
    "fx_cfg_plain" => lib("fx_cfg_plain", "defmodule FxCfgPlain do\n  def x, do: 1\nend\n"),
    # An unset key of an application the package only names in
    # `extra_applications`: not in its tree, not preloaded by Mix.
    "fx_cfg_ssl" =>
      lib(
        "fx_cfg_ssl",
        """
        defmodule FxCfgSsl do
          @k Application.get_env(:ssl, :fx_cfg_unset_key)
          def k, do: @k
        end
        """,
        %{
          mix_exs: """
          defmodule FxCfgSsl.MixProject do
            use Mix.Project
            def project, do: [app: :fx_cfg_ssl, version: "0.1.0", deps: []]
            def application, do: [extra_applications: [:logger, :ssl]]
          end
          """
        }
      ),
    # Ordinary compile output through the toolchain: a compiler warning,
    # Mix's shell (which colours through IO.ANSI) and `dbg/1`.
    "fx_tc_warn" =>
      lib("fx_tc_warn", """
      defmodule FxTcWarn do
        def x(unused), do: 1
      end
      """),
    "fx_tc_shell" =>
      lib("fx_tc_shell", """
      defmodule FxTcShell do
        Mix.shell().info("fixture info, expected")
        def x, do: :ok
      end
      """),
    "fx_tc_dbg" =>
      lib("fx_tc_dbg", """
      defmodule FxTcDbg do
        def x(v), do: dbg(v)
      end
      """),
    # A Mix compiler a dependency ships (as elixir_make does), printing
    # through Mix's shell while the package that names it compiles.
    "fx_tc_comp" => %{
      files: %{
        "lib/mix/tasks/compile.fx_tc_comp.ex" => """
        defmodule Mix.Tasks.Compile.FxTcComp do
          use Mix.Task.Compiler
          def run(_args) do
            Mix.shell().info("fixture compiler, expected")
            {:ok, []}
          end
        end
        """
      }
    },
    "fx_tc_native" =>
      lib("fx_tc_native", "defmodule FxTcNative do\n  def x, do: 1\nend\n", %{
        deps: ["fx_tc_comp"],
        mix_exs: """
        defmodule FxTcNative.MixProject do
          use Mix.Project

          def project do
            [
              app: :fx_tc_native,
              version: "0.1.0",
              compilers: [:fx_tc_comp] ++ Mix.compilers(),
              deps: [{:fx_tc_comp, path: "../fx_tc_comp"}]
            ]
          end
        end
        """
      }),
    "fx_ver_minor" =>
      lib("fx_ver_minor", """
      defmodule FxVerMinor do
        @v Version.match?(System.version(), ">= 1.0.0")
        def v, do: @v
      end
      """),
    "fx_ver_patch" =>
      lib("fx_ver_patch", """
      defmodule FxVerPatch do
        @v Version.match?(System.version(), ">= #{@next_patch}")
        def v, do: @v
      end
      """),
    "fx_ver_string" =>
      lib("fx_ver_string", """
      defmodule FxVerString do
        @v System.version() >= "1.0.0"
        def v, do: @v
      end
      """),
    "fx_ver_info" =>
      lib("fx_ver_info", """
      defmodule FxVerInfo do
        @v System.build_info()[:version]
        def v, do: @v
      end
      """),
    # Compiled in a project of its own whose config sets the key.
    "fx_cfg_set" =>
      lib("fx_cfg_set", """
      defmodule FxCfgSet do
        @k Application.get_env(:fx_cfg_set, :k)
        def k, do: @k
      end
      """)
  }

  @alone ["fx_cfg_set"]

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "ncc-fixtures-config-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)

    shared = @deps |> Map.drop(@alone ++ ["fx_cfg_d", "fx_ord_b", "fx_tc_comp"]) |> Map.keys()

    runs = %{
      "shared" => compile(Path.join(root, "shared"), shared, Map.drop(@deps, @alone), nil),
      "fx_cfg_set" =>
        compile(
          Path.join(root, "set"),
          ["fx_cfg_set"],
          Map.take(@deps, ["fx_cfg_set"]),
          "config :fx_cfg_set, k: 42\n"
        )
    }

    %{runs: runs}
  end

  defp compile(root, top, deps, config) do
    proj = TracerFixtures.project(root, top, deps)
    if config, do: TracerFixtures.put_config(proj, config)
    %{proj: proj, traced: TracerFixtures.trace(proj, top)}
  end

  defp run_of(ctx, app), do: Map.get(ctx.runs, app, ctx.runs["shared"])

  defp verdict(ctx, app) do
    run = run_of(ctx, app)
    TracerFixtures.judge(run.proj, app, run.traced)
  end

  defp passes(ctx, app) do
    v = verdict(ctx, app)
    assert %{status: :pass} = v, "#{app}: #{inspect(v.observations, pretty: true)}"
    v
  end

  defp item(v, app, key), do: Enum.find(v.compile_env, &(&1.app == app and &1.path == [key]))

  defp enc(term),
    do: term |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)

  defp toolchain_reads(v, app) do
    for r <- v.observations["config_reads"],
        r["owner"] == app,
        r["first_kind"] == "toolchain",
        into: MapSet.new(),
        do: {r["arg"]["app_name"], r["arg"]["key_name"]}
  end

  test "the traced compiles completed and wrote a config snapshot", ctx do
    for {name, %{traced: traced}} <- ctx.runs do
      assert {:ok, 0} = traced.result, "#{name}: #{traced.log}"
      assert %{entries: %{}, truncated: false} = traced.report.config_env, name
    end
  end

  test "a module-body get_env is recorded with :error when the project leaves it unset", ctx do
    v = passes(ctx, "fx_cfg_get")

    assert item(v, "fx_cfg_get", "k") == %{
             app: "fx_cfg_get",
             path: ["k"],
             value: ConfigReads.unset()
           }
  end

  test "a key the project's config sets is recorded with that value", ctx do
    v = passes(ctx, "fx_cfg_set")
    assert item(v, "fx_cfg_set", "k").value == enc({:ok, 42})
  end

  test "a compile_env read is listed once, from the .app", ctx do
    v = passes(ctx, "fx_cfg_compile")
    run = run_of(ctx, "fx_cfg_compile")
    app = Path.join(run.proj, "_build/host/lib/fx_cfg_compile/ebin/fx_cfg_compile.app")
    app_items = AppFile.read_compile_env(app)
    merged = ConfigReads.merge(app_items, v.compile_env)

    assert [_] = Enum.filter(merged, &(&1.app == "fx_cfg_compile" and &1.path == ["k"]))
    assert hd(app_items) in merged
  end

  test "get_all_env at compile time refuses", ctx do
    assert %{status: :skip, reason: "compile-time config read: application:get_all_env/1" <> _} =
             verdict(ctx, "fx_cfg_all")
  end

  test "IO.warn at compile time records nothing", ctx do
    v = passes(ctx, "fx_cfg_iowarn")
    refute item(v, "elixir", "ansi_enabled")
    assert v.observations["config_unreviewed"] == []
  end

  test "Logger's compile-time reads are recorded with the value a client looks up", ctx do
    v = passes(ctx, "fx_cfg_logger")

    for {"logger", key} <- toolchain_reads(v, "fx_cfg_logger") do
      expected =
        case Application.fetch_env(:logger, String.to_existing_atom(key)) do
          {:ok, value} -> enc({:ok, value})
          :error -> ConfigReads.unset()
        end

      assert item(v, "logger", key).value == expected, key
    end

    assert v.observations["config_unreviewed"] == []
  end

  # The reviewed lists are what this toolchain's own code reads: a key that
  # appears or disappears on a new toolchain image fails here, and the lists
  # are changed only after reviewing what the key does to generated code.
  # Two reviewed entries are not read by these compiles on 1.19 or 1.20:
  # Logger's macros never read `:level`, and `IO.warn/1` emits through
  # `:elixir_errors` without reading `:ansi_enabled`; they are pinned here
  # by name so that a toolchain which starts reading either shows up too.
  test "the toolchain's own config reads are exactly the reviewed lists", ctx do
    observed =
      MapSet.union(
        toolchain_reads(passes(ctx, "fx_cfg_logger"), "fx_cfg_logger"),
        toolchain_reads(passes(ctx, "fx_cfg_iowarn"), "fx_cfg_iowarn")
      )

    %{record: record, drop: drop} = ConfigReads.reviewed(System.version())
    reviewed = MapSet.new(record ++ Enum.map(drop, fn {_first, app, key} -> {app, key} end))
    unread = MapSet.new([{"logger", "level"}, {"elixir", "ansi_enabled"}])

    assert observed == MapSet.difference(reviewed, unread), inspect(MapSet.to_list(observed))
    assert MapSet.subset?(unread, reviewed)
  end

  test "a compiler warning records nothing", ctx do
    v = passes(ctx, "fx_tc_warn")
    assert v.observations["config_reads"] == []
  end

  test "no Mix or Hex config read of the compile around a package is its own", ctx do
    for app <- ["fx_cfg_plain", "fx_tc_warn", "fx_cfg_get", "fx_cfg_logger"] do
      v = passes(ctx, app)

      assert Enum.all?(v.observations["config_reads"], &(&1["owner"] == app)),
             app

      refute Enum.any?(
               v.observations["config_reads"],
               &(&1["arg"]["app_name"] in ["mix", "hex"])
             ),
             app
    end
  end

  # Toolchain reads no reviewed list holds: the build is not judged rather
  # than published with a value a client cannot compare.
  test "dbg/1 reads :dbg_callback while expanding and cannot be judged", ctx do
    assert %{status: :skip, reason: @cnj, observations: obs} = verdict(ctx, "fx_tc_dbg")

    assert obs["problems"] == [
             "unreviewed toolchain config read: elixir dbg_callback from Elixir.Kernel"
           ]
  end

  test "printing through Mix's shell at compile time cannot be judged", ctx do
    for app <- ["fx_tc_shell", "fx_tc_native"] do
      assert %{status: :skip, reason: @cnj, observations: obs} = verdict(ctx, app), app

      assert obs["problems"] == [
               "unreviewed toolchain config read: elixir ansi_enabled from Elixir.IO.ANSI"
             ],
             app
    end
  end

  test "a dependency's Mix compiler runs in the window of the package that names it", ctx do
    v = verdict(ctx, "fx_tc_native")

    assert [%{"owner" => "fx_tc_native", "module" => "Elixir.Mix.Tasks.Compile.FxTcComp"}] =
             v.observations["config_reads"]
  end

  test "a dependency's config read is the package's match condition too", ctx do
    v = passes(ctx, "fx_cfg_user")

    assert item(v, "fx_cfg_d", "mode") == %{
             app: "fx_cfg_d",
             path: ["mode"],
             value: ConfigReads.unset()
           }
  end

  test "an unset key of a dependency in the reader's tree is recorded as unset", ctx do
    v = passes(ctx, "fx_ord_c")
    assert item(v, "fx_ord_b", "k").value == ConfigReads.unset()
  end

  test "an unset key of an application outside the reader's tree cannot be told", ctx do
    assert %{status: :skip, reason: @cnj, observations: obs} = verdict(ctx, "fx_ord_a")
    assert "config value cannot be told: fx_ord_b k" in obs["problems"], inspect(obs["problems"])
  end

  test "an unset key of an extra application cannot be told", ctx do
    assert %{status: :skip, reason: @cnj, observations: obs} = verdict(ctx, "fx_cfg_ssl")

    assert "config value cannot be told: ssl fx_cfg_unset_key" in obs["problems"],
           inspect(obs["problems"])
  end

  test "a package that reads no config publishes with no config items", ctx do
    v = passes(ctx, "fx_cfg_plain")
    assert v.compile_env == []
    assert v.observations["config_unreviewed"] == []
    assert v.observations["config_reads"] == []
  end

  test "the Elixir version compared at a minor boundary is publishable", ctx do
    passes(ctx, "fx_ver_minor")
  end

  test "a threshold above the built patch, a string compare and build_info refuse", ctx do
    for {app, mfa} <- [
          {"fx_ver_patch", "Version.match?/2"},
          {"fx_ver_string", "System.version/0"},
          {"fx_ver_info", "System.build_info/0"}
        ] do
      assert %{status: :skip, reason: "compile-time Elixir patch dependence: " <> rest} =
               verdict(ctx, app),
             app

      assert String.starts_with?(rest, mfa), "#{app}: #{rest}"
    end
  end
end
