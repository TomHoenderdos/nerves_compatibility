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
    # IO.warn's other forms: from a macro with the caller's env, with a
    # stacktrace, with the module's env.
    "fx_cfg_iowarn_forms" =>
      lib("fx_cfg_iowarn_forms", """
      defmodule FxCfgIoWarnForms.M do
        defmacro m do
          IO.warn("fixture macro warning, expected", __CALLER__)
          :ok
        end
      end

      defmodule FxCfgIoWarnForms do
        require FxCfgIoWarnForms.M
        IO.warn("fixture stacktrace warning, expected", [])
        IO.warn("fixture env warning, expected", __ENV__)
        def x, do: FxCfgIoWarnForms.M.m()
      end
      """),
    # Logger at compile time beyond its macros' expansion: logging from a
    # module body and a macro, and reading the level.
    "fx_cfg_logbody" =>
      lib("fx_cfg_logbody", """
      defmodule FxCfgLogBody.M do
        require Logger

        defmacro m do
          Logger.warning("fixture macro log, expected")
          :ok
        end
      end

      defmodule FxCfgLogBody do
        require Logger
        require FxCfgLogBody.M
        Logger.info("fixture body log, expected")
        @level Logger.level()
        def level, do: @level
        def x, do: FxCfgLogBody.M.m()
      end
      """),
    # Package code reading :elixir, :ansi_enabled itself, directly or
    # through IO.ANSI, and a macro tail-calling IO.ANSI.enabled?/0.
    "fx_ansi_own" =>
      lib("fx_ansi_own", """
      defmodule FxAnsiOwn do
        @enabled IO.ANSI.enabled?()
        def enabled, do: @enabled
      end
      """),
    "fx_ansi_read" =>
      lib("fx_ansi_read", """
      defmodule FxAnsiRead do
        @enabled Application.get_env(:elixir, :ansi_enabled)
        def enabled, do: @enabled
      end
      """),
    "fx_ansi_format" =>
      lib("fx_ansi_format", """
      defmodule FxAnsiFormat do
        @red IO.ANSI.format([:red, "x"])
        def red, do: @red
      end
      """),
    "fx_ansi_logfmt" =>
      lib("fx_ansi_logfmt", """
      defmodule FxAnsiLogFmt do
        {Logger.Formatter, config} = Logger.Formatter.new()
        event = %{level: :info, msg: {:string, "x"}, meta: %{time: 0}}
        @line IO.iodata_to_binary(Logger.Formatter.format(event, config))
        def line, do: @line
      end
      """),
    "fx_ansi_macro" =>
      lib("fx_ansi_macro", """
      defmodule FxAnsiMacro.M do
        defmacro m, do: IO.ANSI.enabled?()
      end

      defmodule FxAnsiMacro do
        require FxAnsiMacro.M
        def enabled, do: FxAnsiMacro.M.m()
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
    # Warnings the compiler's checker prints after a module compiles: a call
    # to a module that does not exist, and a clause the type checker finds
    # unused (1.20 only). The file has top-level code besides `defmodule`,
    # so the module is defined from package code and its checker process is
    # the package's: the diagnostics printer's read lands in its window.
    "fx_tc_checker" =>
      lib("fx_tc_checker", """
      defmodule FxTcChecker do
        def x, do: FxTcCheckerMissing.y()
        def z, do: check(%{k: 1})
        defp check(%{k: :never} = m), do: m
        defp check(m), do: m
      end

      if Code.ensure_loaded?(FxTcChecker) do
        defmodule FxTcChecker.Other do
          def y, do: FxTcCheckerMissing.z()
        end
      end
      """),
    # A call the type checker finds can never succeed: its warning colours
    # the offending argument while it is formatted. As in fx_tc_checker, the
    # file's top-level code makes the checker process the package's, so the
    # read lands in its window.
    "fx_tc_types" =>
      lib("fx_tc_types", """
      defmodule FxTcTypes do
        def f, do: Integer.to_string(:not_an_integer)
      end

      if Code.ensure_loaded?(FxTcTypes) do
        defmodule FxTcTypes.Other do
          def g, do: Integer.to_string(:not_an_integer_either)
        end
      end
      """),
    # The same warning in a compile the package starts itself, capturing
    # its diagnostics and keeping the message.
    "fx_tc_types_kept" =>
      lib("fx_tc_types_kept", """
      defmodule FxTcTypesKept do
        {_result, diagnostics} =
          Code.with_diagnostics(fn ->
            Code.compile_string(\"""
            defmodule FxTcTypesKept.Inner do
              def f, do: Integer.to_string(:not_an_integer)
            end
            \""", "fx_tc_types_kept_inner.ex")
          end)

        @messages Enum.map(diagnostics, & &1.message)
        def messages, do: @messages
      end
      """),
    # Mix's compile run from package code, its diagnostics kept: a Mix
    # compiler a dependency ships, running `compile.elixir` itself through
    # `Mix.Task.rerun/2` for the package that names it.
    "fx_rerun_comp" => %{
      files: %{
        "lib/mix/tasks/compile.fx_rerun_comp.ex" => """
        defmodule Mix.Tasks.Compile.FxRerunComp do
          use Mix.Task.Compiler
          def run(_args) do
            {_status, diagnostics} = Mix.Task.rerun("compile.elixir", ["--return-errors"])
            Process.put(:fx_rerun_comp, Enum.map(diagnostics, & &1.message))
            {:ok, []}
          end
        end
        """
      }
    },
    "fx_mix_rerun" =>
      lib(
        "fx_mix_rerun",
        """
        defmodule FxMixRerun do
          def f, do: Integer.to_string(:not_an_integer)
        end
        """,
        %{
          deps: ["fx_rerun_comp"],
          mix_exs: """
          defmodule FxMixRerun.MixProject do
            use Mix.Project

            def project do
              [
                app: :fx_mix_rerun,
                version: "0.1.0",
                compilers: [:fx_rerun_comp] ++ Mix.compilers(),
                deps: [{:fx_rerun_comp, path: "../fx_rerun_comp"}]
              ]
            end
          end
          """
        }
      ),
    # A hook on the compile that receives its diagnostics, registered from
    # the package's top-level code, beside a type warning of its own.
    "fx_mix_after" =>
      lib("fx_mix_after", """
      Mix.Task.Compiler.after_compiler(:elixir, fn {status, diagnostics} ->
        Process.put(:fx_mix_after, Enum.map(diagnostics, & &1.message))
        {status, diagnostics}
      end)

      defmodule FxMixAfter do
        def f, do: Integer.to_string(:not_an_integer)
      end
      """),
    # Package code asking the compiler for a formatted message and keeping
    # it: `SyntaxError.message/1` formats a snippet through `:elixir_errors`
    # and returns the coloured text.
    "fx_tc_snippet" =>
      lib("fx_tc_snippet", """
      defmodule FxTcSnippet do
        @msg (try do
                Code.string_to_quoted!("x = (1 +\\n2", file: "fixture.ex")
              rescue
                e -> Exception.message(e)
              end)
        def msg, do: @msg
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
    # OTP's certificate store and TLS stack read their own application env
    # when a compile loads the host's CA certificates, asks which TLS
    # versions this host's crypto supports, or opens a connection.
    "fx_net_cacerts" =>
      lib(
        "fx_net_cacerts",
        """
        defmodule FxNetCacerts do
          @n (try do
                length(:public_key.cacerts_get())
              rescue
                _ -> 0
              end)
          def n, do: @n
        end
        """,
        %{extra_applications: [:public_key]}
      ),
    "fx_net_tls" =>
      lib(
        "fx_net_tls",
        """
        defmodule FxNetTls do
          @v :ssl.versions()
          def v, do: @v
        end
        """,
        %{extra_applications: [:ssl]}
      ),
    "fx_net_connect" =>
      lib("fx_net_connect", """
      defmodule FxNetConnect do
        @r elem(:gen_tcp.connect(~c"127.0.0.1", 1, [], 100), 0)
        def r, do: @r
      end
      """),
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
    # Compiled in a project of its own: a package loading its own Mix.Shell.IO
    # and Logger.Formatter after Mix has used the real ones, then baking
    # their results.
    "fx_forge" =>
      lib("fx_forge", """
      {:module, _, shell, _} =
      defmodule Mix.Shell.IO do
        def print_app, do: :ok
        def info(message), do: IO.puts(IO.ANSI.format(message))
        def error(message), do: IO.puts(:stderr, IO.ANSI.format(message))
        def prompt(_message), do: ""
        def yes?(_message, _options \\\\ []), do: true
        def cmd(command, options \\\\ []), do: Mix.Shell.cmd(command, options, &IO.write/1)
        def styled(message), do: [IO.ANSI.format(message)]
      end

      {:module, _, formatter, _} =
      defmodule Logger.Formatter do
        def new(_options \\\\ []), do: {__MODULE__, %{}}
        def format(_event, _config), do: [IO.ANSI.format([:red, "forged"]), "\\n"]
      end

      here = String.to_charlist(__ENV__.file)
      {:module, _} = :code.load_binary(Mix.Shell.IO, here, shell)
      {:module, _} = :code.load_binary(Logger.Formatter, here, formatter)

      defmodule FxForge do
        require Logger
        @styled IO.iodata_to_binary(Mix.Shell.IO.styled([:red, "x"]))
        Logger.warning("fixture log through the forged formatter, expected")
        def styled, do: @styled
      end
      """),
    # Compiled in a project of its own: a package's formatter that
    # tail-calls IO.ANSI, so Logger's handler is the frame below the read.
    "fx_forge_tail" =>
      lib("fx_forge_tail", """
      {:module, _, formatter, _} =
        defmodule Logger.Formatter do
          def new(_options \\\\ []), do: {__MODULE__, %{}}
          def format(_event, _config), do: IO.ANSI.format([:red, "forged tail\\n"])
        end

      {:module, _} = :code.load_binary(Logger.Formatter, String.to_charlist(__ENV__.file), formatter)

      defmodule FxForgeTail do
        require Logger
        Logger.warning("fixture log through the forged formatter, expected")
        def x, do: :ok
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

  @alone [
    "fx_cfg_set",
    "fx_forge",
    "fx_forge_tail",
    "fx_mix_rerun",
    "fx_rerun_comp",
    "fx_mix_after"
  ]

  # The fixtures whose toolchain reads the reviewed lists are pinned by.
  @reviewed_fixtures [
    "fx_cfg_logger",
    "fx_cfg_iowarn",
    "fx_cfg_iowarn_forms",
    "fx_cfg_logbody",
    "fx_tc_shell",
    "fx_tc_native",
    "fx_tc_checker",
    "fx_tc_types",
    "fx_net_cacerts",
    "fx_net_tls",
    "fx_net_connect"
  ]

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "ncc-fixtures-config-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)

    # A path dependency has no Hex tarball, and without a verified file list
    # no source file of a dependency is readable. The diagnostics printer
    # reads the warned-about source line, so fx_tc_checker, fx_tc_types,
    # fx_mix_after and fx_mix_rerun get the release a Hex dependency would
    # have.
    hex_home = Path.join(root, "hex")

    releases =
      Map.new(
        ["fx_tc_checker", "fx_tc_types", "fx_mix_after", "fx_mix_rerun"],
        &TracerFixtures.hex_release(hex_home, &1, ["lib", "mix.exs"])
      )

    shared = @deps |> Map.drop(@alone ++ ["fx_cfg_d", "fx_ord_b", "fx_tc_comp"]) |> Map.keys()

    runs = %{
      "shared" => compile(Path.join(root, "shared"), shared, Map.drop(@deps, @alone), nil),
      "fx_cfg_set" =>
        compile(
          Path.join(root, "set"),
          ["fx_cfg_set"],
          Map.take(@deps, ["fx_cfg_set"]),
          "config :fx_cfg_set, k: 42\n"
        ),
      "fx_forge" =>
        compile(
          Path.join(root, "forge"),
          ["fx_forge"],
          Map.take(@deps, ["fx_forge"]),
          nil
        ),
      "fx_forge_tail" =>
        compile(
          Path.join(root, "forge_tail"),
          ["fx_forge_tail"],
          Map.take(@deps, ["fx_forge_tail"]),
          nil
        ),
      "fx_mix_rerun" =>
        compile(
          Path.join(root, "mix_rerun"),
          ["fx_mix_rerun"],
          Map.take(@deps, ["fx_mix_rerun", "fx_rerun_comp"]),
          nil
        ),
      "fx_mix_after" =>
        compile(
          Path.join(root, "mix_after"),
          ["fx_mix_after"],
          Map.take(@deps, ["fx_mix_after"]),
          nil
        )
    }

    %{runs: runs, judge_opts: [releases: releases, hex_home: hex_home]}
  end

  defp compile(root, top, deps, config) do
    proj = TracerFixtures.project(root, top, deps)
    if config, do: TracerFixtures.put_config(proj, config)
    %{proj: proj, traced: TracerFixtures.trace(proj, top)}
  end

  defp run_of(ctx, app), do: Map.get(ctx.runs, app, ctx.runs["shared"])

  defp verdict(ctx, app) do
    run = run_of(ctx, app)
    TracerFixtures.judge(run.proj, app, run.traced, [], ctx.judge_opts)
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

  test "Logger's compile-time reads are recorded with the value a client looks up", ctx do
    v = passes(ctx, "fx_cfg_logger")
    entries = run_of(ctx, "fx_cfg_logger").traced.report.config_env.entries
    reads = toolchain_reads(v, "fx_cfg_logger")
    assert MapSet.size(reads) > 0

    for {"logger", key} <- reads do
      expected = Map.get(entries, {"logger", key}, ConfigReads.unset())
      assert item(v, "logger", key).value == expected, key
    end

    assert v.observations["config_unreviewed"] == []
  end

  # The reviewed lists are what this toolchain's own code reads: a key that
  # appears or disappears on a new toolchain image fails here, and the lists
  # are changed only after reviewing what the key does to generated code.
  test "the toolchain's own config reads are exactly the reviewed lists", ctx do
    observed =
      for app <- @reviewed_fixtures,
          r <- verdict(ctx, app).observations["config_reads"],
          r["owner"] == app,
          r["first_kind"] == "toolchain",
          into: MapSet.new(),
          do: {r["first"], r["arg"]["app_name"], r["arg"]["key_name"]}

    %{record: record, drop: drop, refuse: refuse} = ConfigReads.reviewed(System.version())

    expected =
      MapSet.new(
        Enum.map(record, fn {app, key} -> {"Elixir.Logger", app, key} end) ++ drop ++ refuse
      )

    assert observed == expected, inspect(MapSet.to_list(observed))
  end

  test "IO.warn in any form records nothing", ctx do
    for app <- ["fx_cfg_iowarn", "fx_cfg_iowarn_forms"] do
      v = passes(ctx, app)
      assert v.observations["config_reads"] == [], app
    end
  end

  # Logger's handler formats a message logged at compile time in the
  # logging process, colouring it by :ansi_enabled: dropped, as output only.
  # Logger.level/0 reads Logger's primary config, not the application env.
  test "logging at compile time publishes; no read of Logger's :level", ctx do
    v = passes(ctx, "fx_cfg_logbody")
    assert v.observations["config_unreviewed"] == []
    refute item(v, "elixir", "ansi_enabled")
    refute Enum.any?(v.observations["config_reads"], &(&1["arg"]["key_name"] == "level"))

    assert Enum.any?(
             v.observations["config_reads"],
             &(&1["first"] == "logger_h_common" and &1["arg"]["key_name"] == "ansi_enabled")
           )
  end

  # The value a package reads itself selects what it compiles: a match
  # condition, never dropped, whether it reads the key or IO.ANSI does.
  test "package code reading :ansi_enabled, itself or through IO.ANSI, records it", ctx do
    for app <- [
          "fx_ansi_own",
          "fx_ansi_read",
          "fx_ansi_format",
          "fx_ansi_macro",
          "fx_ansi_logfmt"
        ] do
      v = passes(ctx, app)
      assert %{value: value} = item(v, "elixir", "ansi_enabled"), app

      assert value ==
               run_of(ctx, app).traced.report.config_env.entries[{"elixir", "ansi_enabled"}]

      assert v.observations["config_unreviewed"] == [], app

      for r <- v.observations["config_reads"],
          do: assert(r["first_kind"] in ["user", "glue"], "#{app}: #{inspect(r)}")
    end
  end

  # A compile that loads the host's CA certificates, asks which TLS versions
  # this host's crypto supports or opens a connection reaches the host: the
  # certificate store's and the TLS and socket code's own config reads say so
  # and refuse, beside the host read the same call makes.
  test "OTP's certificate, TLS and socket config reads refuse", ctx do
    for {app, reads} <- [
          {"fx_net_cacerts", [{"pubkey_os_cacerts", "public_key", "cacerts_path"}]},
          {"fx_net_tls",
           [
             {"tls_record", "ssl", "protocol_version"},
             {"dtls_record", "ssl", "dtls_protocol_version"}
           ]},
          {"fx_net_connect", [{"inet", "kernel", "inet_default_connect_options"}]}
        ] do
      v = verdict(ctx, app)
      assert %{status: :skip, observations: obs} = v
      assert obs["problems"] == [], "#{app}: #{inspect(obs["problems"])}"
      assert obs["config_unreviewed"] == [], app
      assert String.starts_with?(v.reason, "compile-time "), "#{app}: #{v.reason}"
      refusals = for %{"owner" => ^app, "reason" => r} <- obs["refusals"], do: r

      for {first, read_app, key} <- reads do
        assert Enum.any?(
                 refusals,
                 &(String.starts_with?(&1, "compile-time host read: ") and
                     &1 =~ "(#{read_app}) #{key} " and &1 =~ "(#{first})")
               ),
               "#{app}: #{inspect(refusals)}"
      end

      # The same call is a host read of its own, and both forms withdraw
      # an earlier `pure_elixir` publication (R1).
      assert Enum.any?(refusals, &String.starts_with?(&1, "compile-time host read: ")), app
      assert Enum.all?(refusals, &Compatibility.Portability.withdraws?/1), app
    end
  end

  test "a compiler warning records nothing", ctx do
    v = passes(ctx, "fx_tc_warn")
    assert v.observations["config_reads"] == []
  end

  # The compiler's diagnostics printer colours a checker warning by
  # :ansi_enabled and writes it to standard error: dropped, as output only.
  test "a checker warning printed in the package's process publishes", ctx do
    v = passes(ctx, "fx_tc_checker")
    assert v.compile_env == []
    assert v.observations["config_unreviewed"] == []
    refute item(v, "elixir", "ansi_enabled")

    assert [_ | _] = reads = v.observations["config_reads"]

    for r <- reads do
      assert %{"first" => "elixir_errors", "first_kind" => "toolchain"} = r
      assert r["arg"]["key_name"] == "ansi_enabled"
    end
  end

  # The type checker colours the offending argument of a bad call by
  # :ansi_enabled while formatting its warning, which Mix prints and keeps in
  # its manifest: dropped, as output only.
  test "a type-checker warning publishes and records nothing", ctx do
    v = passes(ctx, "fx_tc_types")
    assert v.compile_env == []
    assert v.observations["config_unreviewed"] == []
    refute item(v, "elixir", "ansi_enabled")
    assert [_ | _] = reads = v.observations["config_reads"]
    assert Enum.any?(reads, &(&1["first"] == "Elixir.Module.Types.Apply")), inspect(reads)

    for r <- reads do
      assert r["arg"]["key_name"] == "ansi_enabled"
      assert r["first"] in ["Elixir.Module.Types.Apply", "elixir_errors"], inspect(r)
      assert r["first_kind"] == "toolchain"
    end
  end

  # In a compile the package started and whose diagnostics it captured, the
  # coloured text reaches the package: the read is not dropped there.
  test "a type-checker warning the package captures cannot be judged", ctx do
    assert %{status: :skip, reason: @cnj, observations: obs} =
             verdict(ctx, "fx_tc_types_kept")

    assert Enum.any?(
             obs["problems"],
             &(&1 =~ "in a window with a nested compile" and
                 &1 =~ "elixir ansi_enabled from Elixir.Module.Types.Apply")
           ),
           inspect(obs["problems"])
  end

  defp nested_mfas(ctx, app) do
    traced = run_of(ctx, app).traced

    for e <- traced.report.events, e["channel"] == "nested_compile", uniq: true, do: e["mfa"]
  end

  # Running Mix's compile from package code hands the package the
  # compile's diagnostics: the window is marked, so the type checker's read
  # in it is not dropped.
  test "Mix's compile run from package code marks the window", ctx do
    assert %{status: :skip, reason: @cnj, observations: obs} = verdict(ctx, "fx_mix_rerun")
    assert Enum.any?(obs["problems"], &(&1 =~ "in a window with a nested compile")), inspect(obs)
    assert "Mix.Task.rerun/2" in nested_mfas(ctx, "fx_mix_rerun")
  end

  test "a hook on the compile's diagnostics registered from package code marks the window",
       ctx do
    assert %{status: :skip, reason: @cnj, observations: obs} = verdict(ctx, "fx_mix_after")

    assert Enum.any?(
             obs["problems"],
             &(&1 =~
                 "in a window with a nested compile (Mix.ProjectStack.prepend_after_compiler/2)" and
                 &1 =~ "elixir ansi_enabled from Elixir.Module.Types.Apply")
           ),
           inspect(obs["problems"])
  end

  # Mix's own compile pipeline (compile.all running compile.elixir, every
  # dependency's compile, a Mix compiler a dependency ships) marks nothing.
  test "Mix's own compile tasks mark no window of the shared project", ctx do
    mfas = nested_mfas(ctx, "fx_cfg_plain")
    refute Enum.any?(mfas, &String.starts_with?(&1, "Mix.")), inspect(mfas)
  end

  # The same formatter reached for a message the package keeps is not the
  # printer: its frames are skipped, the caller is first, and a toolchain
  # caller no reviewed list holds leaves the build unjudged.
  test "a compiler message a package keeps is not taken for the printer's", ctx do
    assert %{status: :skip, reason: @cnj, observations: obs} = verdict(ctx, "fx_tc_snippet")

    assert obs["problems"] == [
             "unreviewed toolchain config read: elixir ansi_enabled from Elixir.Exception"
           ]

    refute Enum.any?(obs["config_reads"], &(&1["first"] == "elixir_errors"))
  end

  test "no Mix config read of the compile around a package is its own", ctx do
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

  # Mix's shell colours its output by :ansi_enabled; nothing it prints
  # reaches the beam, so the read is dropped.
  test "printing through Mix's shell at compile time publishes with no config item", ctx do
    for app <- ["fx_tc_shell", "fx_tc_native"] do
      v = passes(ctx, app)
      assert v.compile_env == [], app
      assert v.observations["config_unreviewed"] == [], app

      assert [%{"first" => "Elixir.Mix.Shell.IO", "first_kind" => "toolchain"}] =
               v.observations["config_reads"]
    end
  end

  # A package's own Mix.Shell.IO or Logger.Formatter is not the toolchain's,
  # even once the real one has been seen: its reads are the package's.
  test "a package redefining Mix.Shell.IO or Logger.Formatter keeps its reads", ctx do
    v = passes(ctx, "fx_forge")
    reads = v.observations["config_reads"]

    forged =
      Enum.filter(reads, &(&1["first"] in ["Elixir.Mix.Shell.IO", "Elixir.Logger.Formatter"]))

    assert Enum.any?(forged, &(&1["first"] == "Elixir.Mix.Shell.IO")), inspect(reads)
    assert Enum.any?(forged, &(&1["first"] == "Elixir.Logger.Formatter")), inspect(reads)
    assert Enum.all?(forged, &(&1["first_kind"] == "user")), inspect(forged)
    refute Enum.any?(reads, &(&1["first"] == "logger_h_common"))
    assert %{value: _} = item(v, "elixir", "ansi_enabled")
  end

  # A formatter of the package's own that tail-calls IO.ANSI leaves no
  # frame between IO.ANSI and Logger's handler: the read is not the
  # handler's, and stays unreviewed.
  test "a package formatter tail-calling IO.ANSI is not taken for Logger's", ctx do
    assert %{status: :skip, reason: @cnj, observations: obs} = verdict(ctx, "fx_forge_tail")

    assert obs["problems"] == [
             "unreviewed toolchain config read: elixir ansi_enabled from Elixir.IO.ANSI"
           ]

    refute Enum.any?(obs["config_reads"], &(&1["first"] == "logger_h_common"))
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

  # fx_ord_b's shape: whether the other app's .app is loaded when the
  # read happens depends on the consumer's compile order. The build
  # publishes a config_order item: the other app's .app default and what
  # the read saw, which a client compares with its own predicted order.
  defp order_item(v, app, key),
    do:
      Enum.find(
        v.compile_inputs,
        &(&1["kind"] == "config_order" and &1["app"] == app and &1["path"] == [key])
      )

  test "an unset key of an application outside the reader's tree publishes a config_order item",
       ctx do
    v = passes(ctx, "fx_ord_a")

    assert %{"reader" => "fx_ord_a", "default" => default, "seen" => seen} =
             order_item(v, "fx_ord_b", "k")

    assert default == enc({:ok, 1})

    # Compiled after fx_ord_b, the read saw its default. Compiled before, it
    # saw get_env/3's own default, which cannot tell an unset key from one
    # set to nil while fx_ord_b's .app gives it a value.
    assert seen in [enc({:ok, 1}), "unrecordable"]
  end

  test "an unset key of an extra application publishes, with no .app default to record", ctx do
    assert %{"default" => "unrecordable"} =
             order_item(passes(ctx, "fx_cfg_ssl"), "ssl", "fx_cfg_unset_key")
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
