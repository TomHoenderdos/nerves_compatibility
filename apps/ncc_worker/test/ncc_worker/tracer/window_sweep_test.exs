defmodule NccWorker.Tracer.WindowSweepTest do
  # Untraced steps run package code before a traced compile (`mix deps.get`,
  # `mix firmware`, Nerves's env), and any of them can leave a process behind.
  # One alive while the compile runs could rewrite a dependency's source for
  # the compile to read and put the tarball's bytes back before the window
  # closes, which neither the tree check nor the window-close digest would
  # see. So the container is swept (`NccWorker.ProcessSweep.clear/1`) before
  # the judge reads anything and again once the compile is over, and a
  # container that could not be shown clean is never judged.
  use ExUnit.Case, async: true

  alias NccWorker.{Portability, Tracer}

  @moduletag :tmp_dir

  @survivors {:error, {:survivors, [%{pid: 40, comm: "sh", ppid: 9, state: "S", start_time: 1}]}}

  # A sweep that reports each call and answers from `answers` in turn.
  defp sweep(answers) do
    test = self()
    left = :counters.new(1, [])

    fn ->
      :counters.add(left, 1, 1)
      n = :counters.get(left, 1)
      send(test, {:swept, n})
      Enum.at(answers, n - 1, List.last(answers))
    end
  end

  defp compile(status) do
    test = self()

    fn _caller, _ref, _command, _argv, _log ->
      send(test, :compiled)
      {:ok, status}
    end
  end

  defp judge(dir, opts) do
    Portability.run(
      dir,
      "x",
      [env: [], releases: {:ok, %{}}, trace_dir: Path.join(dir, "trace")] ++ opts
    )
  end

  defp stats(verdict), do: verdict.observations["trace_stats"]

  test "the container is swept before the compile and again after it", %{tmp_dir: dir} do
    judge(dir, cmd: compile(1), sweep: sweep([:ok]))

    # In the order they were sent: the compile's message comes from the
    # process that runs it, which answers the caller only after sending it.
    assert {:messages, [{:swept, 1}, :compiled, {:swept, 2}]} = Process.info(self(), :messages)
  end

  describe "a container not clean before the compile" do
    test "runs no compile, and nothing is judged", %{tmp_dir: dir} do
      cmd = fn _caller, _ref, _command, _argv, _log -> flunk("the compile ran") end
      verdict = judge(dir, cmd: cmd, sweep: sweep([@survivors]))

      assert %{status: :skip, reason: "portability could not be judged"} = verdict
      assert stats(verdict)["judge_compile"] == "not_run"
      assert stats(verdict)["tracer_error"] == "presweep_survived"
      assert stats(verdict)["transient"] == true
      assert [problem] = verdict.observations["problems"]
      assert problem =~ "40 (sh)"
      refute File.exists?(Path.join(dir, "trace"))
    end

    test "nor where the sweep cannot run in a portal build", %{tmp_dir: dir} do
      cmd = fn _caller, _ref, _command, _argv, _log -> flunk("the compile ran") end
      verdict = judge(dir, cmd: cmd, sweep: sweep([{:error, {:unavailable, "not Linux"}}]))

      assert %{status: :skip, reason: "portability could not be judged"} = verdict
      assert stats(verdict)["judge_compile"] == "not_run"
      assert stats(verdict)["tracer_error"] == "presweep_unavailable"
      assert ["process sweep could not run: not Linux" <> _] = verdict.observations["problems"]
    end

    test "is the same in a firmware target's trace", %{tmp_dir: dir} do
      cmd = fn _caller, _ref, _command, _argv, _log -> flunk("the compile ran") end

      verdict =
        Portability.target_inputs(dir, "x",
          env: [],
          releases: {:ok, %{}},
          trace_dir: Path.join(dir, "trace"),
          target: "rpi4",
          cmd: cmd,
          sweep: sweep([@survivors])
        )

      assert verdict.status == :skip
      assert stats(verdict)["tracer_error"] == "presweep_survived"
    end
  end

  describe "a container not clean after the compile" do
    test "fails the trace, even one that exited 0", %{tmp_dir: dir} do
      assert {:error, {:sweep_survived, [%{pid: 40}]}} =
               Tracer.run(dir, ["x"],
                 trace_dir: Path.join(dir, "trace"),
                 cmd: compile(0),
                 sweep: sweep([@survivors])
               )
    end

    test "comes before the compile's own error", %{tmp_dir: dir} do
      assert {:error, {:sweep_survived, _}} =
               Tracer.run(dir, ["x"],
                 trace_dir: Path.join(dir, "trace"),
                 cmd: compile(137),
                 sweep: sweep([@survivors])
               )
    end

    test "is could-not-judge, named as processes left running", %{tmp_dir: dir} do
      verdict = judge(dir, cmd: compile(0), sweep: sweep([:ok, @survivors]))

      assert %{status: :skip, reason: "portability could not be judged"} = verdict
      assert stats(verdict)["judge_compile"] == "not_finished"
      assert stats(verdict)["tracer_error"] == "sweep_survived"
      assert "sweep_survived" in Tracer.left_running()
      assert "presweep_survived" in Tracer.left_running()
    end

    test "a sweep that cannot run after the compile fails it too", %{tmp_dir: dir} do
      assert {:error, {:sweep_unavailable, "not Linux"}} =
               Tracer.run(dir, ["x"],
                 trace_dir: Path.join(dir, "trace"),
                 cmd: compile(0),
                 sweep: sweep([{:error, {:unavailable, "not Linux"}}])
               )
    end
  end

  # Inside the traced compile the driver sweeps again before each window
  # closes (`:ncc_tracer_sweep`), once the worker asks: it passes its own
  # start time as pid 1, which only its container can match.
  describe "the driver's window sweep" do
    defp env_of(dir, opts) do
      test = self()

      cmd = fn _caller, _ref, _command, [_args, _dir, env], _log ->
        send(test, {:env, env})
        {:ok, 1}
      end

      Tracer.run(dir, ["x"], [trace_dir: Path.join(dir, "trace"), cmd: cmd] ++ opts)
      assert_received {:env, env}
      env |> Enum.filter(fn {name, _} -> name == "NCC_TRACE_SWEEP" end) |> List.last()
    end

    test "is asked for with the worker's start time", %{tmp_dir: dir} do
      assert {"NCC_TRACE_SWEEP", "4242"} = env_of(dir, window_sweep: "4242")
    end

    test "is not asked for where the worker's own sweep cannot run", %{tmp_dir: dir} do
      # The test BEAM is never pid 1.
      assert {"NCC_TRACE_SWEEP", nil} = env_of(dir, [])
    end

    test "a trace whose window sweep failed is its own error", %{tmp_dir: dir} do
      assert {:error, :window_sweep_failed} =
               Tracer.run(dir, ["x"],
                 trace_dir: Path.join(dir, "trace"),
                 cmd: compile(Tracer.window_sweep_exit())
               )
    end
  end
end
