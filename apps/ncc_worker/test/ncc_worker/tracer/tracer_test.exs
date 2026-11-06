defmodule NccWorker.TracerTest do
  use ExUnit.Case, async: true

  alias NccWorker.{Tracer, TracerFixtures}

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  test "the judge compile recompiles the closure one window at a time", %{tmp_dir: dir} do
    proj =
      TracerFixtures.project(dir, ["fx_top"], %{
        "fx_top" => %{
          deps: ["fx_leaf"],
          files: %{"lib/fx_top.ex" => "defmodule FxTop do\n  def f, do: FxLeaf.f()\nend\n"}
        },
        "fx_leaf" => %{
          files: %{"lib/fx_leaf.ex" => "defmodule FxLeaf do\n  def f, do: :ok\nend\n"}
        }
      })

    traced = TracerFixtures.trace(proj, ["fx_top"])
    assert {:ok, 0} = traced.result, traced.log
    report = traced.report

    assert report.problems == []
    assert Enum.map(report.windows, & &1.app) == ["fx_leaf", "fx_top"]

    assert Enum.all?(
             report.windows,
             &(&1.depth_ok == true and &1.integrity_ok == true and is_integer(&1.close))
           )

    for w <- report.windows do
      assert Enum.any?(
               report.sentinels,
               &(&1.app == w.app and &1.ts >= w.open and &1.ts <= w.close)
             )
    end

    assert %{"packages" => ["fx_top"], "deps" => deps} = report.closure
    assert Enum.map(deps, & &1["app"]) == ["fx_leaf", "fx_top"]
    assert %{"children" => ["fx_leaf"], "manager" => "mix"} = List.last(deps)

    assert %{"status" => "ok", "final_sentinel" => true, "integrity_ok" => true} =
             report.ending

    assert File.regular?(Path.join(proj, "_build/host/lib/fx_top/ebin/Elixir.FxTop.beam"))
  end

  test "a set partition count stops the judge compile before anything compiles",
       %{tmp_dir: dir} do
    proj =
      TracerFixtures.project(dir, ["fx_one"], %{
        "fx_one" => %{files: %{"lib/fx_one.ex" => "defmodule FxOne do\nend\n"}}
      })

    traced =
      TracerFixtures.trace(proj, ["fx_one"],
        extra_env: [{"MIX_OS_DEPS_COMPILE_PARTITION_COUNT", "2"}]
      )

    assert {:ok, status} = traced.result
    assert status != 0
    assert %{"why" => "partitions"} = traced.report.refused_start
    refute File.exists?(Path.join(proj, "_build/host/lib/fx_one/ebin"))
  end

  test "a failing compile exits non-zero and ends the trace as failed", %{tmp_dir: dir} do
    proj =
      TracerFixtures.project(dir, ["fx_bad"], %{
        "fx_bad" => %{files: %{"lib/fx_bad.ex" => "defmodule FxBad do\n  def f, do: \nend\n"}}
      })

    traced = TracerFixtures.trace(proj, ["fx_bad"])
    assert {:ok, status} = traced.result
    assert status != 0
    assert %{"status" => "compile_failed"} = traced.report.ending
  end

  # Mix prunes the code path to a dependency's own applications before it
  # compiles it, so a module of an app the dependency does not list (httpc,
  # in inets) cannot be loaded from inside its compile. The tracer loads
  # every pattern's module at start, before the first compile, and a loaded
  # module stays loaded and traced whatever the code path says later.
  test "a call into an OTP app the dependency does not list is still traced",
       %{tmp_dir: dir} do
    body = """
    defmodule FxNet do
      IO.puts("INETS_ON_PATH=\#{Enum.any?(:code.get_path(), &(List.to_string(&1) =~ ~r{/inets-}))}")
      @x (try do
            :httpc.request(~c"not a url")
          catch
            _, _ -> :error
          end)
      def x, do: @x
    end
    """

    proj =
      TracerFixtures.project(dir, ["fx_net"], %{"fx_net" => TracerFixtures.lib("fx_net", body)})

    traced = TracerFixtures.trace(proj, ["fx_net"])
    assert {:ok, 0} = traced.result, traced.log
    assert traced.report.problems == []
    assert traced.log =~ "INETS_ON_PATH=false"

    [window] = traced.report.windows

    assert Enum.any?(
             traced.report.events,
             &(&1["mfa"] == "httpc:request/1" and &1["ts"] >= window.open and
                 &1["ts"] <= window.close)
           ),
           inspect(Enum.map(traced.report.events, & &1["mfa"]))
  end

  # The driver keeps the tracer's token in its own variables. Everything a
  # module body can read without a stack walk (every process dictionary,
  # persistent_term, application env, readable ETS tables) is searched for
  # token-shaped binaries, and each one is tried against the tracer.
  test "compile-time code finds no token that the tracer accepts", %{tmp_dir: dir} do
    out = Path.join(dir, "candidates.txt")

    body = """
    defmodule FxSnoop do
      @leaked (
        dicts = for p <- Process.list(), {:dictionary, d} <- [Process.info(p, :dictionary)], do: d
        envs = for {app, _, _} <- :application.loaded_applications(), do: :application.get_all_env(app)
        ets =
          for t <- :ets.all(), :ets.info(t, :protection) in [:public, :protected] do
            try do
              :ets.tab2list(t)
            catch
              _, _ -> []
            end
          end

        text = inspect({dicts, :persistent_term.get(), envs, ets}, limit: :infinity, printable_limit: :infinity)
        candidates = ~r/[0-9A-Fa-f]{32}/ |> Regex.scan(text) |> List.flatten() |> Enum.uniq()
        File.write!(#{inspect(out)}, Integer.to_string(length(candidates)))
        Enum.filter(candidates, &(:ncc_tracer.window_open(&1, "snoop") == :ok))
      )
      def leaked, do: @leaked
      IO.puts("LEAKED=\#{inspect(@leaked)}")
    end
    """

    proj =
      TracerFixtures.project(dir, ["fx_snoop"], %{
        "fx_snoop" => TracerFixtures.lib("fx_snoop", body)
      })

    traced = TracerFixtures.trace(proj, ["fx_snoop"])
    assert {:ok, 0} = traced.result, traced.log
    assert File.exists?(out), traced.log
    assert traced.log =~ "LEAKED=[]"
  end

  # timeout(1) stops the compile VM itself: an Elixir-side wait that gave up
  # would leave it running, rewriting _build after the run moved on.
  test "a judge compile past its timeout is killed and reported as a timeout",
       %{tmp_dir: dir} do
    pid_file = Path.join(dir, "compile.pid")
    expr = "(File.write!(#{inspect(pid_file)}, System.pid()); Process.sleep(120_000))"

    proj =
      TracerFixtures.project(dir, ["fx_slow"], %{
        "fx_slow" => TracerFixtures.lib("fx_slow", TracerFixtures.attr_module("FxSlow", expr))
      })

    started = System.monotonic_time(:millisecond)
    traced = TracerFixtures.trace(proj, ["fx_slow"], timeout_ms: 4_000)
    assert {:error, :timeout} = traced.result, traced.log
    assert System.monotonic_time(:millisecond) - started < 30_000
    assert traced.report.ending == nil

    os_pid = File.read!(pid_file)
    assert {_, status} = System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true)
    assert status != 0, "the compile VM #{os_pid} outlived its timeout"
  end

  test "the timeout is bounded by what is left of the run" do
    assert Tracer.timeout_sec(30 * 60 * 1000, nil) == 1800
    assert Tracer.timeout_sec(1500, nil) == 2
    assert Tracer.timeout_sec(30 * 60 * 1000, 0) == 1800
    assert Tracer.timeout_sec(30 * 60 * 1000, 100 * 60) == 300
    assert Tracer.timeout_sec(30 * 60 * 1000, 105 * 60 - 30) == :exhausted
    assert Tracer.timeout_sec(30 * 60 * 1000, 200 * 60) == :exhausted
  end

  test "a run with no time left does not start the judge compile", %{tmp_dir: dir} do
    started = System.monotonic_time(:second) - 110 * 60

    assert {:error, :run_budget_exhausted} =
             Tracer.run(dir, ["x"], trace_dir: Path.join(dir, "trace"), run_started_at: started)
  end

  test "install/1 writes every tracer module", %{tmp_dir: dir} do
    assert {:ok, ebin} = Tracer.install(Path.join(dir, "ebin"))

    for m <-
          ~w(ncc_tracer ncc_tracer_channels ncc_tracer_stack Elixir.Mix.Tasks.Ncc.TraceCompile) do
      assert File.regular?(Path.join(ebin, m <> ".beam")), m
    end
  end

  test "a missing or garbled trace file is a problem, not a crash", %{tmp_dir: dir} do
    assert %{problems: ["trace-main.jsonl missing"]} = NccWorker.Tracer.Report.read(dir)

    File.write!(Path.join(dir, "trace-main.jsonl"), ~s({"kind":"start"}\nnot json\n))

    assert %{problems: ["unparsable line 2"], start: %{"kind" => "start"}} =
             NccWorker.Tracer.Report.read(dir)
  end
end
