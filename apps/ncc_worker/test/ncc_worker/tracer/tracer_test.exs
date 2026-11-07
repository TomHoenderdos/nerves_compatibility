defmodule NccWorker.TracerTest do
  # Starts real `elixir` VMs: one such module at a time (the :real_vm
  # group), alongside the unit suites, so their compiles do not contend.
  use ExUnit.Case, async: true, group: :real_vm

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

  test "every window is followed by the digest of what it built", %{tmp_dir: dir} do
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

    for app <- ["fx_leaf", "fx_top"] do
      build = Path.join([proj, "_build", "host", "lib", app])
      assert {:ok, digest, files} = :ncc_tracer_digest.dir(build)
      assert files >= 2
      assert traced.report.built[app] == %{digest: digest, files: files, error: nil}
    end
  end

  test "the config snapshot is the project's env, taken before a dependency's mix.exs runs",
       %{tmp_dir: dir} do
    # The dependency's mix.exs, which Mix evaluates while loading the
    # closure, rewrites the project's value and adds one of its own.
    mix_exs = """
    defmodule FxCfg.MixProject do
      use Mix.Project
      Application.put_env(:fx_cfg, :level, :from_dep)
      Application.put_env(:fx_cfg, :added, true)
      def project, do: [app: :fx_cfg, version: "0.1.0", deps: []]
    end
    """

    proj =
      TracerFixtures.project(dir, ["fx_cfg"], %{
        "fx_cfg" => TracerFixtures.lib("fx_cfg", "defmodule FxCfg do\nend\n", %{mix_exs: mix_exs})
      })

    File.mkdir_p!(Path.join(proj, "config"))

    File.write!(
      Path.join(proj, "config/config.exs"),
      "import Config\nconfig :fx_cfg, level: :from_project\n"
    )

    traced = TracerFixtures.trace(proj, ["fx_cfg"])
    assert {:ok, 0} = traced.result, traced.log
    assert traced.report.problems == []
    assert %{entries: entries, truncated: false} = traced.report.config_env

    expected =
      Base.url_encode64(:erlang.term_to_binary({:ok, :from_project}, [:deterministic]),
        padding: false
      )

    assert entries[{"fx_cfg", "level"}] == expected
    refute Map.has_key?(entries, {"fx_cfg", "added"})
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

  test "a requested package outside the closure fails the judge compile before it compiles",
       %{tmp_dir: dir} do
    proj =
      TracerFixtures.project(dir, ["fx_here"], %{
        "fx_here" => %{files: %{"lib/fx_here.ex" => "defmodule FxHere do\nend\n"}}
      })

    for packages <- [["fx_elsewhere"], [], ["fx_here", "fx_elsewhere"]] do
      traced = TracerFixtures.trace(proj, packages)
      assert {:ok, status} = traced.result
      assert status != 0, inspect(packages)
      assert %{"status" => "package_not_in_closure"} = traced.report.ending
      assert traced.report.windows == []
      refute File.exists?(Path.join(proj, "_build/host/lib/fx_here/ebin"))
    end
  end

  test "a Hex package name resolves to its OTP application", %{tmp_dir: dir} do
    proj =
      TracerFixtures.project(dir, ["fx_app"], %{
        "fx_app" => %{
          hex_name: "fx_hex_name",
          files: %{"lib/fx_app.ex" => "defmodule FxApp do\nend\n"}
        }
      })

    traced = TracerFixtures.trace(proj, ["fx_hex_name"])
    assert {:ok, 0} = traced.result, traced.log
    assert traced.report.problems == []
    assert %{"packages" => ["fx_app"]} = traced.report.closure
    assert Enum.map(traced.report.windows, & &1.app) == ["fx_app"]
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

  # The judge compile's process is not linked to the caller: whatever
  # happens to it is an error, never an exit signal that kills the worker.
  describe "a judge compile process that crashes" do
    test "raising, throwing or exiting is an error, and the caller lives on", %{tmp_dir: dir} do
      for crash <- [fn -> raise "boom" end, fn -> throw(:boom) end, fn -> exit(:boom) end] do
        cmd = fn _caller, _ref, _command, _argv, _log -> crash.() end
        assert {:error, _} = Tracer.run(dir, ["x"], trace_dir: Path.join(dir, "trace"), cmd: cmd)
      end
    end

    test "killed, it is an error, and the caller lives on", %{tmp_dir: dir} do
      cmd = fn _caller, _ref, _command, _argv, _log -> Process.exit(self(), :kill) end

      assert {:error, {:exited, :killed}} =
               Tracer.run(dir, ["x"], trace_dir: Path.join(dir, "trace"), cmd: cmd)

      refute_received {:EXIT, _, _}
    end

    test "Portability.run/3 makes it could-not-judge", %{tmp_dir: dir} do
      cmd = fn _caller, _ref, _command, _argv, _log -> Process.exit(self(), :kill) end

      verdict =
        NccWorker.Portability.run(dir, "x",
          env: [],
          releases: {:ok, %{}},
          trace_dir: Path.join(dir, "trace"),
          cmd: cmd
        )

      assert %{status: :skip, reason: "portability could not be judged"} = verdict
      assert verdict.observations["trace_stats"]["judge_compile"] == "not_finished"
    end
  end

  # A judge compile that exits 0 after writing `files` into the trace dir.
  defp writing_cmd(files) do
    fn _caller, _ref, _command, [_args, _dir, env], _log ->
      {_, trace_dir} = List.keyfind(env, "NCC_TRACE_DIR", 0)
      for {name, body} <- files, do: File.write!(Path.join(trace_dir, name), body)
      {:ok, 0}
    end
  end

  defp portability_run(dir, cmd) do
    NccWorker.Portability.run(dir, "x",
      env: [],
      releases: {:ok, %{}},
      trace_dir: Path.join(dir, "trace"),
      cmd: cmd
    )
  end

  describe "transient could-not-judge" do
    test "a crashed judge compile is transient", %{tmp_dir: dir} do
      cmd = fn _caller, _ref, _command, _argv, _log -> raise "boom" end
      verdict = portability_run(dir, cmd)
      assert %{status: :skip, reason: "portability could not be judged"} = verdict
      assert verdict.observations["trace_stats"]["transient"] == true
    end

    test "a report over its read budget is transient", %{tmp_dir: dir} do
      big = :binary.copy("x", 64 * 1024 * 1024 + 1)
      verdict = portability_run(dir, writing_cmd(%{"trace-main.jsonl" => big}))
      assert %{status: :skip, reason: "portability could not be judged"} = verdict
      assert verdict.observations["trace_stats"]["judge_compile"] == "finished"
      assert verdict.observations["trace_stats"]["report_over_budget"] == true
      assert verdict.observations["trace_stats"]["transient"] == true
    end

    test "a finished compile with a broken trace is not", %{tmp_dir: dir} do
      verdict = portability_run(dir, writing_cmd(%{"trace-main.jsonl" => "not json\n"}))
      assert %{status: :skip, reason: "portability could not be judged"} = verdict
      assert verdict.observations["trace_stats"]["judge_compile"] == "finished"
      assert verdict.observations["trace_stats"]["transient"] == false
    end

    test "a finished compile records its compile, report and judge times", %{tmp_dir: dir} do
      verdict = portability_run(dir, writing_cmd(%{"trace-main.jsonl" => "not json\n"}))
      stats = verdict.observations["trace_stats"]

      for key <- ["compile_ms", "report_ms", "judge_ms", "wall_ms"],
          do: assert(is_integer(stats[key]) and stats[key] >= 0, key)

      assert stats["tracer_error"] == nil
    end

    test "a compile that did not finish names the tracer's error", %{tmp_dir: dir} do
      killed = fn _caller, _ref, _command, _argv, _log -> {:ok, 137} end
      assert portability_run(dir, killed).observations["trace_stats"]["tracer_error"] == "killed"

      failed = fn _caller, _ref, _command, _argv, _log -> {:ok, 1} end
      stats = portability_run(dir, failed).observations["trace_stats"]
      assert stats["tracer_error"] == "exit_1"
      assert is_integer(stats["compile_ms"])
      refute Map.has_key?(stats, "judge_ms")
    end
  end

  test "a run with no time left does not start the judge compile", %{tmp_dir: dir} do
    started = System.monotonic_time(:second) - 110 * 60

    assert {:error, :run_budget_exhausted} =
             Tracer.run(dir, ["x"], trace_dir: Path.join(dir, "trace"), run_started_at: started)
  end

  test "install/1 writes every tracer module, read-only", %{tmp_dir: dir} do
    assert {:ok, ebin} = Tracer.install(Path.join(dir, "ebin"))
    assert %{mode: dir_mode} = File.stat!(ebin)
    assert Bitwise.band(dir_mode, 0o222) == 0

    for m <-
          ~w(ncc_tracer ncc_tracer_channels ncc_tracer_stack Elixir.Mix.Tasks.Ncc.TraceCompile) do
      path = Path.join(ebin, m <> ".beam")
      assert File.regular?(path), m
      assert Bitwise.band(File.stat!(path).mode, 0o222) == 0, m
    end

    # A second install over a sealed dir (a rerun) works, and so does removal.
    assert {:ok, ^ebin} = Tracer.install(ebin)
    File.chmod!(ebin, 0o755)
  end

  test "tracer beams changed during the judge compile fail the run", %{tmp_dir: dir} do
    body = """
    defmodule FxPatch do
      ebin = :ncc_tracer |> :code.which() |> List.to_string() |> Path.dirname()
      beam = Path.join(ebin, "ncc_tracer_stack.beam")
      IO.puts("PLAIN_WRITE=\#{inspect(File.write(beam, "x"))}")
      File.chmod!(ebin, 0o755)
      File.chmod!(beam, 0o644)
      File.write!(beam, "x")
    end
    """

    proj =
      TracerFixtures.project(dir, ["fx_patch"], %{
        "fx_patch" => TracerFixtures.lib("fx_patch", body)
      })

    traced = TracerFixtures.trace(proj, ["fx_patch"])
    assert {:error, {:tracer_modified, ["ncc_tracer_stack.beam"]}} = traced.result, traced.log
    assert traced.log =~ "PLAIN_WRITE={:error, :eacces}"
  end

  # The BEAM starts every port program (System.cmd, rebar3, make) in a
  # process group of its own, so timeout(1)'s group kill misses them; every
  # process still carrying the judge compile's MIX_BUILD_PATH is reaped
  # instead (/proc, so Linux: the worker's own platform).
  @tag skip: if(File.dir?("/proc/self"), do: false, else: "needs /proc")
  test "processes the judge compile left behind are killed", %{tmp_dir: dir} do
    pid_file = Path.join(dir, "bg.pid")

    body = """
    defmodule FxBg do
      {pid, 0} = System.cmd("sh", ["-c", "sleep 120 > /dev/null 2>&1 & echo $!"])
      File.write!(#{inspect(pid_file)}, String.trim(pid))
    end
    """

    proj = TracerFixtures.project(dir, ["fx_bg"], %{"fx_bg" => TracerFixtures.lib("fx_bg", body)})
    traced = TracerFixtures.trace(proj, ["fx_bg"])
    assert {:ok, 0} = traced.result, traced.log

    os_pid = File.read!(pid_file)
    # Gone, or a zombie until it is reaped: its environ then reads empty, or
    # the read fails with ESRCH, depending on the kernel.
    assert File.read("/proc/#{os_pid}/environ") in [
             {:error, :enoent},
             {:error, :esrch},
             {:ok, ""}
           ]
  end

  # A toolchain image may lack procps' kill(1); the cleanup must not need it.
  test "without a kill binary the judge compile is judged as usual", %{tmp_dir: dir} do
    proj =
      TracerFixtures.project(dir, ["fx_nokill"], %{
        "fx_nokill" => %{files: %{"lib/fx_nokill.ex" => "defmodule FxNokill do\nend\n"}}
      })

    no_kill = fn
      "kill" -> nil
      name -> System.find_executable(name)
    end

    traced = TracerFixtures.trace(proj, ["fx_nokill"], cleanup_find: no_kill)
    assert {:ok, 0} = traced.result, traced.log
    assert traced.report.problems == []
  end

  # With no way to signal at all, the run is judged only if it can see that
  # nothing was left to signal: /proc shows no survivor (Linux, the worker's
  # platform); without /proc it cannot tell, and that fails it.
  test "with no way to kill, only a cleanup it cannot verify fails the run", %{tmp_dir: dir} do
    proj =
      TracerFixtures.project(dir, ["fx_nosig"], %{
        "fx_nosig" => %{files: %{"lib/fx_nosig.ex" => "defmodule FxNosig do\nend\n"}}
      })

    traced = TracerFixtures.trace(proj, ["fx_nosig"], cleanup_find: fn _ -> nil end)

    if File.dir?("/proc/self"),
      do: assert({:ok, 0} = traced.result, traced.log),
      else: assert({:error, :cleanup_unverified} = traced.result)
  end

  @tag skip: if(File.dir?("/proc/self"), do: false, else: "needs /proc")
  test "without kill(1) a leftover process is still reaped; one that survives fails the run",
       %{tmp_dir: dir} do
    pid_file = Path.join(dir, "bg.pid")

    body = """
    defmodule FxBg2 do
      {pid, 0} = System.cmd("sh", ["-c", "sleep 120 > /dev/null 2>&1 & echo $!"])
      File.write!(#{inspect(pid_file)}, String.trim(pid))
    end
    """

    proj =
      TracerFixtures.project(dir, ["fx_bg2"], %{"fx_bg2" => TracerFixtures.lib("fx_bg2", body)})

    no_kill = fn
      "kill" -> nil
      name -> System.find_executable(name)
    end

    traced = TracerFixtures.trace(proj, ["fx_bg2"], cleanup_find: no_kill)
    assert {:ok, 0} = traced.result, traced.log
    os_pid = File.read!(pid_file)

    assert File.read("/proc/#{os_pid}/environ") in [
             {:error, :enoent},
             {:error, :esrch},
             {:ok, ""}
           ]

    traced = TracerFixtures.trace(proj, ["fx_bg2"], cleanup_find: fn _ -> nil end)
    os_pid = File.read!(pid_file)
    assert {:error, {:writers_survived, [^os_pid]}} = traced.result
    NccWorker.OsKill.kill([os_pid])
  end

  test "the judge compile's leftover processes are reaped by build path, and survivors fail it",
       %{tmp_dir: dir} do
    proj =
      TracerFixtures.project(dir, ["fx_reap"], %{
        "fx_reap" => %{files: %{"lib/fx_reap.ex" => "defmodule FxReap do\nend\n"}}
      })

    test_pid = self()
    build_path = proj |> TracerFixtures.env() |> Map.new() |> Map.fetch!("MIX_BUILD_PATH")

    reap = fn path ->
      send(test_pid, {:reaped, path})
      {:error, {:writers_survived, ["4242"]}}
    end

    traced = TracerFixtures.trace(proj, ["fx_reap"], reap: reap)
    assert_received {:reaped, ^build_path}
    assert {:error, {:writers_survived, ["4242"]}} = traced.result

    traced = TracerFixtures.trace(proj, ["fx_reap"], reap: fn _ -> :ok end)
    assert {:ok, 0} = traced.result
  end

  test "a missing or garbled trace file is a problem, not a crash", %{tmp_dir: dir} do
    # The reader also lists what the broken file lacks (no closure, no end).
    assert %{problems: ["trace-main.jsonl missing" | _]} = NccWorker.Tracer.Report.read(dir)

    File.write!(Path.join(dir, "trace-main.jsonl"), ~s({"kind":"start"}\nnot json\n))

    assert %{problems: ["unparsable line 2" | rest], start: %{"kind" => "start"}} =
             NccWorker.Tracer.Report.read(dir)

    assert "no end line" in rest
  end
end
