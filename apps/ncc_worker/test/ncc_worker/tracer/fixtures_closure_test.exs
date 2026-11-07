defmodule NccWorker.Tracer.FixturesClosureTest do
  # Fixture suite C (spec section 9): host taint through the closure (R3),
  # dependency mix.exs reads (R4), rebar3's static rules and child-trace
  # coverage, and a tracer that dies or trips a cap (Review Focus 1). Path
  # dependencies compiled under the real tracer; a project whose trace a
  # fixture poisons (a killed collector, a cap) is its own project, compiled
  # alongside the shared one.
  #
  # Spec section 9 still carries Rev 1's row "same D, the package calls
  # D.os() only at runtime: publishable", while Rev 2's R3 refuses a package
  # when ANY closure dependency is host-tainted. P1 follows Rev 2 (refuse):
  # fx_uses_d_runtime below pins that; P1's measurement of host-taint
  # refusals decides any narrowing.
  #
  # Refusals are matched to their owner (ruling M7).
  use ExUnit.Case, async: true

  alias NccWorker.{Portability, TracerFixtures}
  alias NccWorker.Tracer.Report

  import NccWorker.TracerFixtures, only: [lib: 2, lib: 3, mix_exs: 2, erl_module: 1]

  @moduletag timeout: 900_000

  @cnj "portability could not be judged"
  @taint "closure dependency observed the host: "
  @mix_read "compile-time host read in mix.exs: "

  @deps %{
    "fx_d_os" => lib("fx_d_os", "defmodule FxDOs do\n  @os :os.type()\n  def os, do: @os\nend\n"),
    "fx_uses_d" =>
      lib("fx_uses_d", "defmodule FxUsesD do\n  @os FxDOs.os()\n  def os, do: @os\nend\n", %{
        deps: ["fx_d_os"]
      }),
    "fx_uses_d_runtime" =>
      lib(
        "fx_uses_d_runtime",
        "defmodule FxUsesDRuntime do\n  def os, do: FxDOs.os()\nend\n",
        %{deps: ["fx_d_os"]}
      ),
    "fx_d_pt" =>
      lib("fx_d_pt", "defmodule FxDPt do\n  :persistent_term.put(:fx_os, :os.type())\nend\n"),
    "fx_uses_pt" =>
      lib(
        "fx_uses_pt",
        "defmodule FxUsesPt do\n  @os :persistent_term.get(:fx_os)\n  def os, do: @os\nend\n",
        %{deps: ["fx_d_pt"]}
      ),
    "fx_mix_deps" =>
      lib("fx_mix_deps", "defmodule FxMixDeps do\nend\n", %{
        mix_exs: """
        defmodule FxMixDeps.MixProject do
          use Mix.Project
          def project, do: [app: :fx_mix_deps, version: "0.1.0", deps: deps()]
          defp deps, do: if(System.get_env("FX_LOCAL"), do: [], else: [])
        end
        """
      }),
    "fx_mix_paths" =>
      lib("fx_mix_paths", "defmodule FxMixPaths do\nend\n", %{
        mix_exs: mix_exs("fx_mix_paths", ~S{, test_paths: [System.get_env("FX_TP") || "test"]})
      }),
    "fx_mix_opts" =>
      lib("fx_mix_opts", "defmodule FxMixOpts do\nend\n", %{
        mix_exs:
          mix_exs(
            "fx_mix_opts",
            ~S|, elixirc_options: [debug_info: System.get_env("FX_D") != "0"]|
          )
      }),
    # A slice reason that is not "sets <key>" passes through unchanged
    # (Task 7): a read in a bare module-body statement.
    "fx_mix_body" =>
      lib("fx_mix_body", "defmodule FxMixBody do\nend\n", %{
        mix_exs: """
        defmodule FxMixBody.MixProject do
          use Mix.Project
          System.get_env("FX_BODY")
          def project, do: [app: :fx_mix_body, version: "0.1.0", deps: []]
        end
        """
      }),
    # Running a program from a dependency's mix.exs refuses even when its
    # result only reaches `deps` (Task 8 ruling).
    "fx_mix_exec_deps" =>
      lib("fx_mix_exec_deps", "defmodule FxMixExecDeps do\nend\n", %{
        mix_exs: """
        defmodule FxMixExecDeps.MixProject do
          use Mix.Project
          def project, do: [app: :fx_mix_exec_deps, version: "0.1.0", deps: deps()]
          defp deps, do: if(elem(System.cmd("true", []), 1) == 0, do: [], else: [])
        end
        """
      }),
    "fx_uses_mix_opts" =>
      lib("fx_uses_mix_opts", "defmodule FxUsesMixOpts do\nend\n", %{deps: ["fx_mix_opts"]}),
    "fx_uses_mix_deps" =>
      lib("fx_uses_mix_deps", "defmodule FxUsesMixDeps do\nend\n", %{deps: ["fx_mix_deps"]}),
    "fx_r3_clean" => %{
      manager: :rebar3,
      files: %{"src/fx_r3_clean.erl" => erl_module("fx_r3_clean")}
    },
    "fx_r3_two" => %{
      manager: :rebar3,
      files: %{
        "src/fx_r3_two_a.erl" => erl_module("fx_r3_two_a"),
        "src/fx_r3_two_b.erl" => erl_module("fx_r3_two_b"),
        "src/fx_r3_two_c.erl" => erl_module("fx_r3_two_c")
      }
    },
    # Only the .app.src: rebar3 builds no beam.
    "fx_r3_empty" => %{manager: :rebar3, files: %{}},
    "fx_r3_pd" => %{
      manager: :rebar3,
      rebar_config: ~s({erl_opts, [{platform_define, "^nomatch$", 'NOPE'}]}.\n),
      files: %{"src/fx_r3_pd.erl" => erl_module("fx_r3_pd")}
    },
    "fx_r3_hooks" => %{
      manager: :rebar3,
      rebar_config: ~s({erl_opts, []}.\n{pre_hooks, [{compile, "true"}]}.\n),
      files: %{"src/fx_r3_hooks.erl" => erl_module("fx_r3_hooks")}
    },
    # Its Hex tarball's rebar.config names a plugin (`setup_all`); the
    # project on disk compiles without it, since a real plugin would be
    # fetched from Hex. The judge reads the tarball's.
    "fx_r3_plugin" => %{
      manager: :rebar3,
      files: %{"src/fx_r3_plugin.erl" => erl_module("fx_r3_plugin")}
    },
    "fx_uses_r3_pd" =>
      lib("fx_uses_r3_pd", "defmodule FxUsesR3Pd do\nend\n", %{deps: ["fx_r3_pd"]}),
    "fx_uses_r3_clean" =>
      lib("fx_uses_r3_clean", "defmodule FxUsesR3Clean do\nend\n", %{deps: ["fx_r3_clean"]}),
    "fx_uses_r3_two" =>
      lib("fx_uses_r3_two", "defmodule FxUsesR3Two do\nend\n", %{deps: ["fx_r3_two"]}),
    "fx_uses_r3_empty" =>
      lib("fx_uses_r3_empty", "defmodule FxUsesR3Empty do\nend\n", %{deps: ["fx_r3_empty"]}),
    "fx_uses_r3_plugin" =>
      lib("fx_uses_r3_plugin", "defmodule FxUsesR3Plugin do\nend\n", %{deps: ["fx_r3_plugin"]})
  }

  # Kills the Mix VM's trace collector from a dependency's compile.
  @kill %{
    "fx_kill_before" => lib("fx_kill_before", "defmodule FxKillBefore do\nend\n"),
    "fx_kill" =>
      lib(
        "fx_kill",
        """
        defmodule FxKill do
          Process.exit(:ncc_tracer.collector(), :kill)
          def x, do: :ok
        end
        """,
        %{deps: ["fx_kill_before"]}
      )
  }

  # Kills a rebar3 child VM's collector from a parse transform, which
  # rebar3 compiles first and runs while compiling the module that names it.
  @kill_child %{
    "fx_r3_kill" => %{
      manager: :rebar3,
      files: %{
        "src/fx_r3_kill_pt.erl" => """
        -module(fx_r3_kill_pt).
        -export([parse_transform/2]).
        parse_transform(Forms, _Options) ->
            exit(ncc_tracer:collector(), kill),
            Forms.
        """,
        "src/fx_r3_kill.erl" =>
          "-module(fx_r3_kill).\n-compile({parse_transform, fx_r3_kill_pt}).\n" <>
            "-export([f/0]).\nf() -> ok.\n"
      }
    },
    "fx_uses_r3_kill" =>
      lib("fx_uses_r3_kill", "defmodule FxUsesR3Kill do\nend\n", %{deps: ["fx_r3_kill"]})
  }

  # A closure of three dependencies whose last one, the package, makes a
  # hundred thousand traced calls at compile time: lowered caps trip inside
  # its window, as they would on a large real closure. The caps leave the
  # tracer's own start (under 100 calls, under 30k heap words) and the two
  # dependencies' compiles (about 10k calls) well clear.
  @capped %{
    "fx_cap_a" => lib("fx_cap_a", "defmodule FxCapA do\n  def a, do: :a\nend\n"),
    "fx_cap_b" => lib("fx_cap_b", "defmodule FxCapB do\n  def b, do: :b\nend\n"),
    "fx_cap" =>
      lib(
        "fx_cap",
        """
        defmodule FxCap do
          @n Enum.count(1..100_000, fn _ -> :os.type() end)
          def n, do: @n
        end
        """,
        %{deps: ["fx_cap_a", "fx_cap_b"]}
      )
  }

  # The heap cap is lowered to 8 MB and tripped by one event whose argument
  # alone is about 64 MB: an env var name of four million characters.
  @big_read """
  defmodule FxCap do
    @x :os.getenv(List.duplicate(?x, 4_000_000))
    def x, do: @x
  end
  """

  @caps %{
    "calls" => {[{"NCC_TRACE_MAX_CALLS", "50000"}], @capped},
    "user_events" => {[{"NCC_TRACE_MAX_USER_EVENTS", "1000"}], @capped},
    "queue" => {[{"NCC_TRACE_MAX_QUEUE", "10000"}], @capped},
    "heap" =>
      {[{"NCC_TRACE_MAX_HEAP_WORDS", "1000000"}],
       Map.put(@capped, "fx_cap", lib("fx_cap", @big_read, %{deps: ["fx_cap_a", "fx_cap_b"]}))}
  }

  setup_all do
    tmp = Portability.Context.realpath(System.tmp_dir!())

    root =
      Path.join(tmp, "ncc-fixtures-closure-#{System.pid()}-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)
    hex_home = Path.join(root, "hex")

    groups =
      [
        {"shared", @deps, Map.keys(@deps), []},
        {"kill", @kill, ["fx_kill"], []},
        {"kill_child", @kill_child, ["fx_uses_r3_kill"], []}
      ] ++
        for {cap, {env, deps}} <- @caps, do: {"cap_" <> cap, deps, ["fx_cap"], env}

    runs =
      groups
      |> Task.async_stream(
        fn {name, deps, packages, env} ->
          {name, compile(Path.join(root, name), deps, packages, env)}
        end,
        timeout: :infinity,
        ordered: false,
        max_concurrency: 4
      )
      |> Map.new(fn {:ok, {name, run}} -> {name, run} end)

    %{
      root: root,
      runs: runs,
      judge_opts: [releases: rebar3_releases(hex_home), hex_home: hex_home]
    }
  end

  # Every rebar3 fixture app as the Hex release it would be: the judge reads
  # a rebar3 app's rebar.config from its verified tarball only.
  defp rebar3_releases(home) do
    apps = Map.merge(@deps, @kill_child)

    plugin = %{rebar_config: "{erl_opts, []}.\n{plugins, [rebar3_hex]}.\n"}
    apps = Map.update!(apps, "fx_r3_plugin", &Map.merge(&1, plugin))

    for {app, %{manager: :rebar3} = spec} <- apps, into: %{} do
      config = Map.get(spec, :rebar_config, "{erl_opts, []}.\n")
      TracerFixtures.hex_release(home, app, ["src", "rebar.config"], %{"rebar.config" => config})
    end
  end

  defp compile(root, deps, packages, env) do
    proj = TracerFixtures.project(root, Map.keys(deps), deps)
    File.write!(Path.join(proj, "mix.lock"), "%{}\n")
    %{proj: proj, traced: TracerFixtures.trace(proj, packages, extra_env: env)}
  end

  defp verdict(ctx, app, run \\ "shared", traced \\ nil) do
    run = ctx.runs[run]
    TracerFixtures.judge(run.proj, app, traced || run.traced, [], ctx.judge_opts)
  end

  defp refused(ctx, app) do
    assert %{status: :skip, reason: reason, observations: %{"refusals" => refusals}} =
             v = verdict(ctx, app)

    assert %{"owner" => app, "reason" => reason} in refusals,
           "#{app}: #{inspect(v, pretty: true)}"

    reason
  end

  defp passes(ctx, app, run \\ "shared", traced \\ nil) do
    v = verdict(ctx, app, run, traced)
    assert %{status: :pass} = v, "#{app}: #{inspect(v.observations, pretty: true)}"
    v
  end

  test "the traced compile completed, rebar3 children included", ctx do
    traced = ctx.runs["shared"].traced
    assert {:ok, 0} = traced.result, traced.log
    assert %{"status" => "ok"} = traced.report.ending
    assert traced.report.problems == []

    for app <- ["fx_r3_clean", "fx_r3_two", "fx_r3_pd", "fx_r3_hooks", "fx_r3_empty"] do
      assert %{sentinel?: true, problems: []} = traced.report.children[app], app
    end
  end

  test "a dependency that observed the host refuses every package that has it (R3, Rev 2)",
       ctx do
    assert "compile-time host read: os:type/0" <> _ = taint = refused(ctx, "fx_d_os")

    for app <- ["fx_uses_d", "fx_uses_d_runtime"] do
      v = verdict(ctx, app)
      assert %{status: :skip, reason: @taint <> "fx_d_os (" <> rest} = v, app
      assert rest == taint <> ")"
      assert v.observations["taint"] == %{"fx_d_os" => taint}
      # The package's own window refused nothing: the refusal is the taint.
      assert for(%{"owner" => ^app} = r <- v.observations["refusals"], do: r) == [], app
    end
  end

  test "a host value passed through persistent_term refuses through taint", ctx do
    assert "compile-time host read: os:type/0" <> _ = refused(ctx, "fx_d_pt")
    assert %{status: :skip, reason: @taint <> "fx_d_pt (" <> _} = verdict(ctx, "fx_uses_pt")
  end

  test "mix.exs reads: deps and test_paths are allowed, elixirc_options refuses (R4)", ctx do
    v = passes(ctx, "fx_mix_deps")

    assert [%{"owner" => "fx_mix_deps", "mfa" => "os:getenv/1"} | _] =
             v.observations["mix_exs_allowed"]

    v = passes(ctx, "fx_mix_paths")
    assert [%{"owner" => "fx_mix_paths"} | _] = v.observations["mix_exs_allowed"]

    assert @mix_read <> "os:getenv/1 sets elixirc_options (" <> where =
             refused(ctx, "fx_mix_opts")

    assert where =~ "deps/fx_mix_opts/mix.exs:"

    assert %{status: :skip, reason: @taint <> "fx_mix_opts (" <> _} =
             verdict(ctx, "fx_uses_mix_opts")

    passes(ctx, "fx_uses_mix_deps")
  end

  test "mix.exs: a slice reason passes through; running a program refuses whatever it reaches",
       ctx do
    assert @mix_read <> "os:getenv/1 observation outside every definition (" <> where =
             refused(ctx, "fx_mix_body")

    assert where =~ "deps/fx_mix_body/mix.exs:3)"

    assert "compile-time host read: erlang:open_port/2" <> _ =
             reason =
             refused(ctx, "fx_mix_exec_deps")

    assert reason =~ "mix.exs"
  end

  test "rebar3: a clean package passes; platform_define and hooks refuse; as a dependency they taint",
       ctx do
    passes(ctx, "fx_r3_clean")
    passes(ctx, "fx_uses_r3_clean")
    passes(ctx, "fx_r3_two")
    passes(ctx, "fx_uses_r3_two")

    assert %{status: :skip, reason: "rebar3 build uses platform_define"} =
             verdict(ctx, "fx_r3_pd")

    assert %{status: :skip, reason: "rebar3 build runs pre_hooks"} = verdict(ctx, "fx_r3_hooks")

    assert %{status: :skip, reason: @taint <> "fx_r3_pd (rebar3 build uses platform_define)"} =
             verdict(ctx, "fx_uses_r3_pd")
  end

  test "rebar3: a plugin refuses, and taints a package that has it", ctx do
    assert %{status: :skip, reason: "rebar3 build runs plugins"} = verdict(ctx, "fx_r3_plugin")

    assert %{status: :skip, reason: @taint <> "fx_r3_plugin (rebar3 build runs plugins)"} =
             verdict(ctx, "fx_uses_r3_plugin")
  end

  # A copy of the shared trace whose child files `edit` rewrites:
  # `edit.(app, lines)` returns the lines to keep for that app's files.
  defp edited(ctx, name, edit) do
    copy = Path.join(ctx.root, "trace-" <> name)
    File.rm_rf!(copy)
    File.cp_r!(Path.join(ctx.root, "shared/trace"), copy)

    for file <- Path.wildcard(Path.join(copy, "trace-child-*.jsonl")) do
      [_, app] = Regex.run(~r/^trace-child-(.+)-\d+\.jsonl$/, Path.basename(file))
      lines = file |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

      case edit.(app, lines) do
        :drop -> File.rm!(file)
        kept -> File.write!(file, Enum.map(kept, &[JSON.encode!(&1), "\n"]))
      end
    end

    %{ctx.runs["shared"].traced | report: Report.read(copy)}
  end

  # The child's compile returns of `app`: those of `keep` modules, each
  # once, written as the real ones are; nothing else of `app` changes.
  defp compiles(app, keep) do
    fn
      ^app, lines ->
        template = Enum.find(lines, &(&1["kind"] == "compile"))
        assert template, "#{app} has no compile line to copy"
        rest = Enum.reject(lines, &(&1["kind"] == "compile"))
        rest ++ Enum.map(keep, &compile_line(template, &1))

      _app, lines ->
        lines
    end
  end

  defp compile_line(template, {module, result}) do
    source = Path.join(Path.dirname(template["source"]), module <> ".erl")
    %{template | "module" => module, "result" => result, "source" => source}
  end

  defp compile_line(template, module), do: compile_line(template, {module, "ok"})

  test "rebar3 coverage: one beam without a compile return is a gap, two taint (ruling M2)",
       ctx do
    one = edited(ctx, "one-gap", compiles("fx_r3_two", ["fx_r3_two_a", "fx_r3_two_b"]))
    v = passes(ctx, "fx_r3_two", "shared", one)

    assert v.observations["trace_stats"]["rebar3_untraced_last"] == %{
             "fx_r3_two" => "fx_r3_two_c"
           }

    v = passes(ctx, "fx_uses_r3_two", "shared", one)

    assert v.observations["trace_stats"]["rebar3_untraced_last"] == %{
             "fx_r3_two" => "fx_r3_two_c"
           }

    two = edited(ctx, "two-gaps", compiles("fx_r3_two", ["fx_r3_two_a"]))
    assert %{status: :skip, reason: @cnj} = v = verdict(ctx, "fx_r3_two", "shared", two)

    assert "fx_r3_two: rebar3 compile of fx_r3_two_b, fx_r3_two_c was not traced" in v.observations[
             "problems"
           ]

    assert %{
             status: :skip,
             reason:
               @taint <> "fx_r3_two (rebar3 compile of fx_r3_two_b, fx_r3_two_c was not traced)"
           } = verdict(ctx, "fx_uses_r3_two", "shared", two)
  end

  test "rebar3 coverage: a compile that returned an error could not be judged", ctx do
    errored =
      edited(
        ctx,
        "errored",
        compiles("fx_r3_two", ["fx_r3_two_a", "fx_r3_two_b", {"fx_r3_two_c", "error"}])
      )

    for app <- ["fx_r3_two", "fx_uses_r3_two"] do
      assert %{status: :skip, reason: @cnj} = v = verdict(ctx, app, "shared", errored)
      assert "fx_r3_two: rebar3 compile returned an error" in v.observations["problems"], app
    end
  end

  test "without its child trace a rebar3 package could not be judged; a dependent is tainted",
       ctx do
    none =
      edited(ctx, "no-child", fn
        app, _lines when app in ["fx_r3_clean", "fx_r3_empty"] -> :drop
        _app, lines -> lines
      end)

    assert %{status: :skip, reason: @cnj} = v = verdict(ctx, "fx_r3_clean", "shared", none)
    assert "fx_r3_clean: rebar3 compile was not traced" in v.observations["problems"]

    assert %{status: :skip, reason: @taint <> "fx_r3_clean (rebar3 compile was not traced)"} =
             verdict(ctx, "fx_uses_r3_clean", "shared", none)

    # Ruling: an empty ebin with no child trace proves nothing either.
    for app <- ["fx_r3_empty", "fx_uses_r3_empty"] do
      assert %{status: :skip, reason: @cnj} = v = verdict(ctx, app, "shared", none)

      assert "fx_r3_empty: rebar3 built nothing and was not traced" in v.observations["problems"],
             app
    end

    # With its trace, the empty package passes.
    passes(ctx, "fx_r3_empty")
    passes(ctx, "fx_uses_r3_empty")
  end

  describe "a tracer that dies or trips a cap: the compile still passes, nothing can be judged" do
    test "the Mix VM's collector killed by package code", ctx do
      %{proj: proj, traced: traced} = ctx.runs["kill"]
      assert {:ok, 0} = traced.result, traced.log
      assert_beams(proj, ["fx_kill_before", "fx_kill"])
      assert Enum.any?(traced.report.problems, &(&1 =~ "trace collector died: killed"))
      windows = traced.report.windows

      assert [%{app: "fx_kill_before", close: close}] =
               Enum.filter(windows, &(&1.app == "fx_kill_before"))

      assert is_integer(close)
      assert [%{app: "fx_kill", close: nil}] = Enum.filter(windows, &(&1.app == "fx_kill"))

      for app <- ["fx_kill", "fx_kill_before"] do
        assert %{status: :skip, reason: @cnj} = verdict(ctx, app, "kill"), app
      end
    end

    test "a rebar3 child VM's collector killed by a parse transform", ctx do
      %{proj: proj, traced: traced} = ctx.runs["kill_child"]
      assert {:ok, 0} = traced.result, traced.log
      assert_beams(proj, ["fx_r3_kill", "fx_uses_r3_kill"])

      assert Enum.any?(
               traced.report.problems,
               &(&1 =~ "child trace of fx_r3_kill: trace collector died")
             ),
             inspect(traced.report.problems)

      for app <- ["fx_r3_kill", "fx_uses_r3_kill"] do
        assert %{status: :skip, reason: @cnj} = verdict(ctx, app, "kill_child"), app
      end
    end

    for {cap, _env} <- @caps do
      @cap cap
      test "the #{cap} cap", ctx do
        run = "cap_" <> @cap
        %{proj: proj, traced: traced} = ctx.runs[run]
        assert {:ok, 0} = traced.result, traced.log
        assert_beams(proj, ["fx_cap_a", "fx_cap_b", "fx_cap"])
        assert_tripped(@cap, traced.report, Path.join(Path.dirname(proj), "trace"))

        for app <- ["fx_cap", "fx_cap_a", "fx_cap_b"] do
          assert %{status: :skip, reason: @cnj} = verdict(ctx, app, run), app
        end
      end
    end
  end

  # The cap tripped inside the package's window. A heap kill leaves that
  # window open and no end line. An overflow line comes between the
  # window's open and close lines: the collector handles its mailbox in
  # order, and a line's own `ts` is when it was handled, not when the call
  # that tripped the cap was made, so the file order is what says where.
  defp assert_tripped("heap", report, _trace_dir) do
    assert Enum.any?(report.problems, &(&1 =~ "trace collector died: killed")),
           inspect(report.problems)

    assert [%{app: "fx_cap", close: nil}] = Enum.filter(report.windows, &(&1.app == "fx_cap"))
    assert report.ending == nil
  end

  defp assert_tripped(cap, report, trace_dir) do
    assert [%{"what" => ^cap}] = report.overflow
    assert %{"overflow" => true, "status" => "ok"} = report.ending

    kinds =
      trace_dir
      |> Path.join("trace-main.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)
      |> Enum.map(&{&1["kind"], &1["app"]})

    at = &Enum.find_index(kinds, fn kind -> kind == &1 end)
    tripped = at.({"overflow", nil})
    assert at.({"window_open", "fx_cap"}) < tripped, "#{cap} tripped before the package's window"
    assert tripped < at.({"window_close", "fx_cap"}), "#{cap} tripped after the package's window"
  end

  defp assert_beams(proj, apps) do
    for app <- apps do
      beams = Path.wildcard(Path.join([proj, "_build/host/lib", app, "ebin/*.beam"]))
      assert beams != [], "#{app} built no beam"
    end
  end
end
