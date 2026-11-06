defmodule NccWorker.Tracer.FixturesReadsTest do
  # Fixture suite A (spec section 9, the rows P1 owns): independent path
  # dependencies of one project, compiled once under the real tracer and
  # judged one by one. Expected verdicts come from the spec; a publishable
  # fixture that refuses is a finding about the tracer, not a test to loosen.
  #
  # Every refusal is also matched to its owner (ruling M7), so a verdict
  # cannot pass on an observation from another fixture's window.
  use ExUnit.Case, async: true

  alias NccWorker.TracerFixtures

  import NccWorker.TracerFixtures, only: [lib: 2]

  @moduletag timeout: 600_000

  @cnj "portability could not be judged"
  @flag "compile-time tracing or system flag: "

  @deps %{
    "fx_runtime" =>
      lib("fx_runtime", """
      defmodule FxRuntime do
        def cmd, do: System.cmd("true", [])
        def port, do: Port.open({:spawn, "true"}, [])
        def os_cmd, do: :os.cmd(~c"true")
        def lookup, do: System.find_executable("sh")
        def os, do: :os.type()
      end
      """),
    "fx_attr" =>
      lib("fx_attr", """
      defmodule FxAttr do
        @os :os.type()
        @arch :erlang.system_info(:system_architecture)
        def os, do: {@os, @arch}
      end
      """),
    "fx_helper" =>
      lib("fx_helper", """
      defmodule FxHelper.H do
        def os, do: :os.type()
      end

      defmodule FxHelper do
        @x FxHelper.H.os()
        def x, do: @x
      end
      """),
    "fx_macro" =>
      lib("fx_macro", """
      defmodule FxMacro.M do
        defmacro m, do: Macro.escape(:os.type())
      end

      defmodule FxMacro do
        require FxMacro.M
        def os, do: FxMacro.M.m()
      end
      """),
    "fx_macro_tail" =>
      lib("fx_macro_tail", """
      defmodule FxMacroTail.M do
        defmacro m, do: :os.type()
      end

      defmodule FxMacroTail do
        require FxMacroTail.M
        def os, do: FxMacroTail.M.m()
      end
      """),
    "fx_after_compile" =>
      lib("fx_after_compile", """
      defmodule FxAfterCompile do
        @after_compile __MODULE__
        def __after_compile__(_env, _bytecode), do: :os.type()
      end
      """),
    "fx_task" =>
      lib("fx_task", """
      defmodule FxTask do
        @os Task.async(fn -> :os.type() end) |> Task.await()
        def os, do: @os
      end
      """),
    "fx_env" =>
      lib("fx_env", """
      defmodule FxEnv do
        if System.get_env("FX_FLAG") == "1" do
          def a, do: 1
        end
      end
      """),
    "fx_depth" =>
      lib("fx_depth", """
      defmodule FxDepth do
        :erlang.system_flag(:backtrace_depth, 1)
        @os :os.type()
        def os, do: @os
      end
      """),
    "fx_integrity" =>
      lib("fx_integrity", """
      defmodule FxIntegrity do
        _ = :trace.session_info(:all)
        _ = :dbg.stop()
        @os :os.type()
        def os, do: @os
      end
      """),
    "fx_truncated" =>
      lib("fx_truncated", """
      defmodule FxTruncated do
        deep = Enum.reduce(1..70, {:leaf, [], nil}, fn _, acc -> {:node, [], [acc]} end)
        @os Macro.prewalk(deep, fn
              {:leaf, _, _} -> :os.type()
              node -> node
            end)
        def os, do: @os
      end
      """),
    "fx_iowarn" =>
      lib("fx_iowarn", """
      defmodule FxIoWarn do
        IO.warn("fixture warning, expected")
        def x, do: :ok
      end
      """),
    "fx_config" =>
      lib("fx_config", """
      defmodule FxConfig do
        @k Application.get_env(:fx_config, :k)
        def k, do: @k
      end
      """),
    "fx_version" =>
      lib("fx_version", """
      defmodule FxVersion do
        @v Version.match?(System.version(), ">= 1.0.0")
        def v, do: @v
      end
      """),
    "fx_keep" => %{
      files: %{
        "README.md" => "fixture readme\n",
        "lib/fx_keep.ex" => """
        defmodule FxKeep.M do
          defmacro m, do: quote(location: :keep, do: 1 + 1)
        end

        defmodule FxKeep do
          @moduledoc File.read!("README.md")
          require FxKeep.M
          def two, do: FxKeep.M.m()
        end
        """
      }
    },
    # Split from fx_keep, so the two publishable shapes there stay pinned
    # while this one is a finding (see its test).
    "fx_record" =>
      lib("fx_record", """
      defmodule FxRecord do
        require Record
        Record.defrecord(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))
        def x, do: :ok
      end
      """)
  }

  # fx_depth and fx_integrity each get a project and a trace of their own:
  # a window that lost its backtrace depth is a problem of the whole trace,
  # and an integrity refusal outside a package's closure counts against
  # every package (Task 10 ruling), so in the shared project they would
  # make every other verdict "could not be judged" or refused.
  @alone ["fx_depth", "fx_integrity"]

  setup_all do
    root =
      Path.join(System.tmp_dir!(), "ncc-fixtures-reads-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)

    # A path dependency has no Hex tarball, and without a verified file list
    # no source file of a dependency is readable (spec R1 "Files"). fx_keep
    # reads its README at compile time, so it gets the release a Hex
    # dependency would have.
    hex_home = Path.join(root, "hex")

    {app, release} =
      TracerFixtures.hex_release(hex_home, "fx_keep", ["README.md", "lib", "mix.exs"])

    shared = @deps |> Map.drop(@alone) |> Map.keys()
    groups = [{"shared", shared} | Enum.map(@alone, &{&1, [&1]})]

    traced =
      groups
      |> Task.async_stream(fn {name, apps} -> {name, compile(Path.join(root, name), apps)} end,
        timeout: :infinity,
        ordered: false
      )
      |> Map.new(fn {:ok, {name, run}} -> {name, run} end)

    %{
      runs: traced,
      judge_opts: [releases: %{app => release}, hex_home: hex_home]
    }
  end

  defp compile(root, apps) do
    proj = TracerFixtures.project(root, apps, Map.take(@deps, apps))
    %{proj: proj, traced: TracerFixtures.trace(proj, apps)}
  end

  defp run_of(ctx, app), do: Map.get(ctx.runs, app, ctx.runs["shared"])

  defp verdict(ctx, app, opts \\ nil) do
    run = run_of(ctx, app)
    TracerFixtures.judge(run.proj, app, run.traced, [], opts || ctx.judge_opts)
  end

  # A refusal of `app` with `reason`, attributed to `app` itself (ruling M7).
  defp refused(ctx, app) do
    assert %{status: :skip, reason: reason, observations: %{"refusals" => refusals}} =
             v = verdict(ctx, app)

    assert Enum.any?(refusals, &(&1 == %{"owner" => app, "reason" => reason})),
           "#{app}: #{inspect(v, pretty: true)}"

    reason
  end

  defp passes(ctx, app) do
    v = verdict(ctx, app)
    assert %{status: :pass} = v, "#{app}: #{inspect(v.observations["refusals"], pretty: true)}"
    v
  end

  defp events(ctx, app, mfa) do
    report = run_of(ctx, app).traced.report
    windows = Enum.filter(report.windows, &(&1.app == app))

    Enum.filter(report.events, fn e ->
      e["mfa"] == mfa and Enum.any?(windows, &(e["ts"] >= &1.open and e["ts"] <= &1.close))
    end)
  end

  test "the traced compiles completed", ctx do
    for {name, %{traced: traced}} <- ctx.runs do
      assert {:ok, 0} = traced.result, "#{name}: #{traced.log}"
      assert %{"status" => "ok"} = traced.report.ending, name
    end

    assert ctx.runs["shared"].traced.report.problems == []
    assert ctx.runs["fx_integrity"].traced.report.problems == []
  end

  test "runtime-only calls are publishable", ctx do
    passes(ctx, "fx_runtime")
  end

  test "module attributes reading the OS refuse with file and line", ctx do
    reason = refused(ctx, "fx_attr")
    assert reason =~ "compile-time host read: os:type/0"
    assert reason =~ "fx_attr.ex:2"
  end

  test "a helper tail-calling the read is attributed to the module body", ctx do
    assert "compile-time host read: os:type/0" <> _ = refused(ctx, "fx_helper")
  end

  test "a macro reading the host refuses with its MACRO frame", ctx do
    reason = refused(ctx, "fx_macro")
    assert reason =~ "compile-time host read: os:type/0"
    assert reason =~ "MACRO-m"
  end

  test "tail calls from a macro and an @after_compile callback leave the dispatcher", ctx do
    for app <- ["fx_macro_tail", "fx_after_compile"] do
      assert "compile-time host read: os:type/0" <> _ = refused(ctx, app), app
    end
  end

  test "a task spawned by a module body is user extent", ctx do
    assert "compile-time host read: os:type/0" <> _ = refused(ctx, "fx_task")
  end

  test "an environment read deciding a definition refuses", ctx do
    assert "compile-time host read: os:getenv/1" <> _ = refused(ctx, "fx_env")
  end

  # The plan expected the system_flag refusal as the reason. The judge puts
  # an incomplete trace first (a window that lost its backtrace depth is a
  # Report problem), so the reason is "could not be judged"; the refusal is
  # still recorded against fx_depth, first. Either way nothing publishes.
  test "lowering backtrace_depth refuses, and the later read is still seen", ctx do
    assert %{status: :skip, reason: @cnj, observations: obs} = verdict(ctx, "fx_depth")
    assert "fx_depth's window lost its backtrace depth" in obs["problems"]

    assert [%{"owner" => "fx_depth", "reason" => @flag <> "erlang:system_flag/2"} | _] =
             obs["refusals"]

    assert [_ | _] = events(ctx, "fx_depth", "os:type/0")
  end

  test "reaching for the trace refuses, and tracing goes on", ctx do
    assert "compile-time tracing or system flag: trace:session_info/1" =
             refused(ctx, "fx_integrity")

    assert [_ | _] = events(ctx, "fx_integrity", "os:type/0")
  end

  test "a stack truncated with no user frame left counts as user extent", ctx do
    assert "compile-time host read: os:type/0" <> _ = refused(ctx, "fx_truncated")
    assert Enum.any?(events(ctx, "fx_truncated", "os:type/0"), &(&1["extent"] == "truncated"))
  end

  test "IO.warn, config and Elixir-version reads are observed in P1, never refused", ctx do
    passes(ctx, "fx_iowarn")

    assert %{observations: %{"config_reads" => reads}} = passes(ctx, "fx_config")

    assert Enum.any?(reads, &(&1["owner"] == "fx_config" and &1["arg"]["key"] == "k")),
           inspect(reads)

    assert %{observations: %{"elixir_version" => versions}} = passes(ctx, "fx_version")
    assert Enum.any?(versions, &(&1["owner"] == "fx_version")), inspect(versions)
  end

  test "keep metadata and a README moduledoc are publishable", ctx do
    passes(ctx, "fx_keep")
  end

  # Record.extract(from_lib: ...) runs the Erlang preprocessor in a process
  # the module body spawned, so its own work is user extent by lineage:
  # epp:predef_macros/2 reads erlang:system_info(machine) and (otp_release),
  # and filename:separators/0 reads os:type/0, with no user frame on the
  # stack. Ruling (Task 11): exactly those reads, in a process whose bottom
  # frame is epp's server, are toolchain.
  test "Record.extract from OTP is publishable", ctx do
    passes(ctx, "fx_record")

    assert Enum.any?(
             events(ctx, "fx_record", "erlang:system_info/1"),
             &match?(
               %{
                 "arg" => %{"key" => "machine"},
                 "extent" => "lineage",
                 "user" => nil,
                 "bottom" => %{"module" => "epp"}
               },
               &1
             )
           )
  end

  test "without its verified Hex file list, the README read refuses", ctx do
    assert "compile-time host read: file:" <> _ =
             refused_without_hex(ctx, "fx_keep")
  end

  defp refused_without_hex(ctx, app) do
    v = verdict(ctx, app, releases: %{}, hex_home: nil)
    assert %{status: :skip, reason: reason, observations: %{"refusals" => refusals}} = v
    assert Enum.any?(refusals, &(&1 == %{"owner" => app, "reason" => reason})), inspect(v)
    reason
  end
end
