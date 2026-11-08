defmodule NccWorker.HostTraceTest do
  use ExUnit.Case, async: true

  alias NccWorker.HostTrace

  @moduletag :tmp_dir

  defp paths(dir) do
    out = Path.join(dir, "out")
    File.mkdir_p!(Path.join(out, "logs"))
    %{work_dir: Path.join(dir, "work"), output_dir: out}
  end

  defp project(dir) do
    proj = Path.join([dir, "work", "proj"])
    File.mkdir_p!(Path.join([proj, "_build", "host", "lib", "pkg", "ebin"]))
    proj
  end

  defp build_dir(proj), do: Path.join([proj, "_build", "host"])

  defp opts(extra) do
    [
      releases: {:ok, %{}},
      deps_get: fn _proj, _env, _log -> :ok end,
      fallback: fn _proj, _env, _log, _sec -> flunk("no fallback expected") end,
      reap: fn _build_path -> :ok end
    ]
    |> Keyword.merge(extra)
  end

  # A traced compile that exits with `status` and writes no trace.
  defp exiting(status), do: fn _caller, _ref, _command, _argv, _log -> {:ok, status} end

  # A traced compile that exits 0 after writing a start line of `mode`.
  defp finishing(mode) do
    fn _caller, _ref, _command, [_args, _dir, env], _log ->
      {_, trace_dir} = List.keyfind(env, "NCC_TRACE_DIR", 0)

      File.write!(
        Path.join(trace_dir, "trace-main.jsonl"),
        ~s({"kind":"start","mode":"#{mode}"}\n)
      )

      {:ok, 0}
    end
  end

  defp stats(verdict), do: verdict.observations["trace_stats"]

  test "a traced compile that did not finish falls back to an untraced compile for the status",
       %{tmp_dir: dir} do
    proj = project(dir)
    test_pid = self()

    fallback = fn ^proj, _env, _log, sec ->
      send(test_pid, {:fallback, sec, File.exists?(build_dir(proj))})
      :ok
    end

    %{host: host, verdict: verdict} =
      HostTrace.compile(proj, "pkg", paths(dir), opts(cmd: exiting(137), fallback: fallback))

    assert_received {:fallback, sec, false}
    assert is_integer(sec) and sec > 0
    assert %{status: :pass, error: nil} = host
    assert %{status: :skip, reason: "portability could not be judged"} = verdict
    assert stats(verdict)["transient"] == true
    assert stats(verdict)["host_build"] == "untraced"
  end

  test "the untraced fallback is bounded only by what is left of the run", %{tmp_dir: dir} do
    proj = project(dir)
    test_pid = self()
    started = System.monotonic_time(:second) - 10 * 60

    fallback = fn _proj, _env, _log, sec ->
      send(test_pid, {:fallback, sec})
      :ok
    end

    HostTrace.compile(
      proj,
      "pkg",
      paths(dir),
      opts(cmd: exiting(1), fallback: fallback, run_started_at: started)
    )

    assert_received {:fallback, sec}
    # More than the traced compile's own 30 minutes, at most the run's 95 left.
    assert sec > 30 * 60 and sec <= 95 * 60
  end

  test "an untraced fallback that fails is the host failure", %{tmp_dir: dir} do
    proj = project(dir)
    fallback = fn _proj, _env, _log, _sec -> {:error, "mix command exited with code 1"} end

    %{host: host, verdict: verdict} =
      HostTrace.compile(proj, "pkg", paths(dir), opts(cmd: exiting(1), fallback: fallback))

    assert %{status: :fail, error: "mix command exited with code 1"} = host
    assert verdict.status == :skip
    assert stats(verdict)["tracer_error"] == "exit_1"
  end

  test "a traced compile that did not run in host mode is not the build", %{tmp_dir: dir} do
    proj = project(dir)
    test_pid = self()

    fallback = fn _proj, _env, _log, _sec ->
      send(test_pid, {:fallback, File.exists?(build_dir(proj))})
      :ok
    end

    %{host: host, verdict: verdict} =
      HostTrace.compile(
        proj,
        "pkg",
        paths(dir),
        opts(cmd: finishing("judge"), fallback: fallback)
      )

    assert_received {:fallback, false}
    assert %{status: :pass, error: nil} = host
    assert %{status: :skip, reason: "portability could not be judged"} = verdict
    assert stats(verdict)["transient"] == true
    assert stats(verdict)["host_build"] == "untraced"
  end

  describe "processes left running" do
    test "a group that survived fails the host compile, with no fallback", %{tmp_dir: dir} do
      proj = project(dir)
      survivors = fn _caller, _ref, _command, _argv, _log -> {:error, {:group_survived, [1]}} end

      %{host: host, verdict: verdict} =
        HostTrace.compile(proj, "pkg", paths(dir), opts(cmd: survivors))

      assert %{status: :error, error: "the traced host compile left processes running"} = host
      assert verdict.status == :skip
      assert stats(verdict)["host_build"] == "none"
      # Nothing was removed while they may still write.
      assert File.exists?(build_dir(proj))
    end

    test "writers that survived the reap fail the host compile, with no fallback",
         %{tmp_dir: dir} do
      proj = project(dir)
      reap = fn _build_path -> {:error, {:writers_survived, ["1"]}} end

      %{host: host} =
        HostTrace.compile(proj, "pkg", paths(dir), opts(cmd: exiting(1), reap: reap))

      assert %{status: :error, error: "the traced host compile left processes running"} = host
      assert File.exists?(build_dir(proj))
    end

    test "writers hidden behind a timeout fail the host compile, with no fallback",
         %{tmp_dir: dir} do
      proj = project(dir)
      test_pid = self()

      # The tracer reports the kill first; the reap before the fallback
      # still finds the writers.
      reap = fn build_path ->
        send(test_pid, {:reaped, build_path})
        {:error, {:writers_survived, ["1"]}}
      end

      %{host: host, verdict: verdict} =
        HostTrace.compile(proj, "pkg", paths(dir), opts(cmd: exiting(137), reap: reap))

      assert stats(verdict)["tracer_error"] == "killed"
      assert %{status: :error, error: "the traced host compile left processes running"} = host
      assert_received {:reaped, path}
      assert path == build_dir(proj)
      assert File.exists?(build_dir(proj))
    end

    test "writers the untraced fallback left fail the host compile", %{tmp_dir: dir} do
      proj = project(dir)

      fallback = fn _proj, _env, _log, _sec ->
        Process.put(:fallback_ran, true)
        :ok
      end

      reap = fn _build_path ->
        if Process.get(:fallback_ran),
          do: {:error, {:writers_survived, ["1"]}},
          else: :ok
      end

      %{host: host, verdict: verdict} =
        HostTrace.compile(
          proj,
          "pkg",
          paths(dir),
          opts(cmd: exiting(1), fallback: fallback, reap: reap)
        )

      assert %{status: :error, error: "the host compile left processes running"} = host
      assert verdict.status == :skip
    end
  end

  test "a build that cannot be removed is not rebuilt", %{tmp_dir: dir} do
    proj = project(dir)
    build_root = Path.join(proj, "_build")
    File.chmod!(build_root, 0o555)
    on_exit(fn -> File.chmod(build_root, 0o755) end)

    %{host: host, verdict: verdict} =
      HostTrace.compile(proj, "pkg", paths(dir), opts(cmd: exiting(1)))

    File.chmod!(build_root, 0o755)
    assert %{status: :error, error: "the traced host compile's build could not be removed"} = host
    assert verdict.status == :skip
  end

  test "a finished traced compile is the host pass", %{tmp_dir: dir} do
    proj = project(dir)

    %{host: host, verdict: verdict} =
      HostTrace.compile(proj, "pkg", paths(dir), opts(cmd: finishing("host")))

    assert %{
             status: :pass,
             error: nil,
             cache_candidates: [],
             firmware_size_bytes: nil,
             beam_scan: nil,
             dependency_scans: nil,
             system_version: nil
           } = host

    assert host.phase_timings == %{cache_restored: 0.0, cache_candidates: 0.0}

    assert Map.has_key?(host, :compile_env)
    assert is_float(host.duration_sec)
    assert is_binary(host.log_tail)
    # The near-empty trace is a could-not-judge, but the build itself compiled.
    assert stats(verdict)["judge_compile"] == "finished"
    assert stats(verdict)["trace_mode"] == "host"
    assert stats(verdict)["host_build"] == "traced"
    assert File.exists?(build_dir(proj))
  end

  test "a failed deps.get is the host failure and nothing is traced", %{tmp_dir: dir} do
    proj = project(dir)

    %{host: host, verdict: verdict} =
      HostTrace.compile(
        proj,
        "pkg",
        paths(dir),
        opts(
          deps_get: fn _p, _e, _l -> {:error, "deps.get failed"} end,
          cmd: fn _, _, _, _, _ -> flunk("nothing is traced") end
        )
      )

    assert %{status: :fail, error: "deps.get failed"} = host
    assert stats(verdict)["judge_compile"] == "not_run"
    assert stats(verdict)["host_build"] == "none"
  end

  test "with no time left there is no fallback", %{tmp_dir: dir} do
    proj = project(dir)
    started = System.monotonic_time(:second) - 110 * 60

    %{host: host, verdict: verdict} =
      HostTrace.compile(proj, "pkg", paths(dir), opts(run_started_at: started, cmd: exiting(0)))

    assert %{status: :fail, error: "no time left for the host compile"} = host
    assert stats(verdict)["tracer_error"] == "run_budget_exhausted"
  end
end
