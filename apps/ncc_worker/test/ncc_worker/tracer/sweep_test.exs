defmodule NccWorker.Tracer.SweepTest do
  # `:ncc_tracer_sweep`, which the trace driver's collector runs before each
  # window closes: a native build's `make` (or cmake, cargo, a rebar3 port
  # compiler) is an untraced program, and a process it leaves behind could
  # rewrite a later dependency's source while that one's window is open and
  # put it back before the window closes. Everything started after the
  # traced VM is killed, except that VM's own `erl_child_setup`; everything
  # older is the launch chain (the worker, `timeout`, `fakeroot` and its
  # `faked`), which the worker's own sweep left alone before the VM started.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @worker_start 50
  @vm 300
  @vm_start 1000

  defp stat_line(pid, comm, state, ppid, start) do
    "#{pid} (#{comm}) #{state} #{ppid} #{pid} #{pid} 0 -1 4194560 100 0 0 0 1 2 0 0 20 0 " <>
      "1 0 #{start} 1000000 100 18446744073709551615 0 0 0 0 0 0 0 0 0 0 0 0 17 0 0 0 0 0 0\n"
  end

  defp put_proc(root, {pid, comm, ppid, start, opts}) do
    dir = Path.join(root, Integer.to_string(pid))
    File.mkdir_p!(dir)
    state = Keyword.get(opts, :state, "S")
    File.write!(Path.join(dir, "stat"), stat_line(pid, comm, state, ppid, start))

    for {tid, thread_state} <- Keyword.get(opts, :threads, []) do
      task = Path.join([dir, "task", Integer.to_string(tid)])
      File.mkdir_p!(task)
      File.write!(Path.join(task, "stat"), stat_line(tid, comm, thread_state, ppid, start))
    end
  end

  defp put_proc(root, {pid, comm, ppid, start}), do: put_proc(root, {pid, comm, ppid, start, []})

  # The container as a firmware target's trace leaves it: the worker and its
  # helper, `timeout`, `fakeroot` and its daemon (reparented to pid 1), the
  # traced VM and its helper, plus `extra`.
  defp proc_root(dir, extra) do
    root = Path.join(dir, "proc")
    File.mkdir_p!(Path.join(root, "self"))

    Enum.each(
      [
        {1, "beam.smp", 0, @worker_start},
        {9, "erl_child_setup", 1, @worker_start + 1},
        {200, "timeout", 9, 900},
        {210, "fakeroot", 200, 910},
        {220, "faked-sysv", 1, 920},
        {@vm, "beam.smp", 210, @vm_start},
        {301, "erl_child_setup", @vm, @vm_start}
      ] ++ extra,
      &put_proc(root, &1)
    )

    root
  end

  defp killer(root) do
    test = self()

    fn pids ->
      send(test, {:killed, pids})
      Enum.each(pids, &File.rm_rf!(Path.join(root, Integer.to_string(&1))))
      :ok
    end
  end

  defp sweep(root, opts \\ %{}) do
    :ncc_tracer_sweep.sweep(
      ~c"#{@worker_start}",
      Map.merge(
        %{
          proc_root: String.to_charlist(root),
          self_pid: @vm,
          os_type: {:unix, :linux},
          kill: killer(root),
          interval_ms: 0
        },
        opts
      )
    )
  end

  test "kills what started after the traced VM and nothing of its launch chain",
       %{tmp_dir: dir} do
    root =
      proc_root(dir, [
        # A Makefile's `sleep 600 &`, reparented to pid 1.
        {400, "sleep", 1, 2000},
        # A port program the VM opened and closed, left to its helper.
        {401, "sh", 301, 2100},
        # A second helper of the VM: only the first is its own.
        {402, "erl_child_setup", @vm, 2200}
      ])

    assert {:ok, killed} = sweep(root)
    assert_received {:killed, pids}
    assert Enum.sort(pids) == [400, 401, 402]
    assert Enum.map(killed, & &1.pid) |> Enum.sort() == [400, 401, 402]

    for pid <- [1, 9, 200, 210, 220, @vm, 301],
        do: assert(File.dir?(Path.join(root, Integer.to_string(pid))), "#{pid} was killed")
  end

  test "a clean container is :ok with nothing killed", %{tmp_dir: dir} do
    assert {:ok, []} = sweep(proc_root(dir, []))
    refute_received {:killed, _}
  end

  test "a zombie is left alone unless one of its threads runs", %{tmp_dir: dir} do
    root =
      proc_root(dir, [
        {400, "defunct", 1, 2000, state: "Z", threads: [{400, "Z"}]},
        {410, "evil", 1, 2000, state: "Z", threads: [{410, "Z"}, {411, "S"}]}
      ])

    assert {:ok, [%{pid: 410}]} = sweep(root)
  end

  test "names what survives every round", %{tmp_dir: dir} do
    root = proc_root(dir, [{400, "sleep", 1, 2000}])

    assert {:survivors, [%{pid: 400, comm: "sleep"}], _killed} =
             sweep(root, %{kill: fn _ -> :ok end, rounds: 2})
  end

  test "kills what a stray forks while it dies", %{tmp_dir: dir} do
    root = proc_root(dir, [{400, "sh", 1, 2000}])
    test = self()

    kill = fn pids ->
      send(test, {:killed, pids})
      Enum.each(pids, &File.rm_rf!(Path.join(root, Integer.to_string(&1))))
      if pids == [400], do: put_proc(root, {401, "sh", 1, 2100})
      :ok
    end

    assert {:ok, _} = sweep(root, %{kill: kill})
    assert_received {:killed, [400]}
    assert_received {:killed, [401]}
  end

  describe "cannot run" do
    test "outside Linux", %{tmp_dir: dir} do
      assert {:unavailable, _} = sweep(proc_root(dir, []), %{os_type: {:unix, :darwin}})
    end

    # The worker passes its own start time: only in its container is pid 1
    # the worker, so a sweep elsewhere (a developer's machine, CI) never
    # kills anything.
    test "where pid 1 is not the worker that asked", %{tmp_dir: dir} do
      root = proc_root(dir, [{400, "sleep", 1, 2000}])

      for expected <- [~c"#{@worker_start + 1}", ~c"", ~c"x"] do
        assert {:unavailable, _} =
                 :ncc_tracer_sweep.sweep(expected, %{
                   proc_root: String.to_charlist(root),
                   self_pid: @vm,
                   os_type: {:unix, :linux},
                   kill: killer(root)
                 })
      end

      refute_received {:killed, _}
    end

    test "without a /proc", %{tmp_dir: dir} do
      assert {:unavailable, _} = sweep(Path.join(dir, "none"))
    end

    # Everything older than the traced VM is kept: a /proc whose start times
    # do not order the VM after the worker would keep everything.
    test "when start times do not order the traced VM after the worker", %{tmp_dir: dir} do
      root = proc_root(dir, [{400, "sleep", 1, 2000}])
      put_proc(root, {@vm, "beam.smp", 210, @worker_start})
      assert {:unavailable, _} = sweep(root)
      refute_received {:killed, _}
    end

    test "when the traced VM is not in it", %{tmp_dir: dir} do
      root = proc_root(dir, [{400, "sleep", 1, 2000}])
      assert {:unavailable, _} = sweep(root, %{self_pid: 999})
      refute_received {:killed, _}
    end
  end

  test "parse_stat/1 reads a command name holding blanks and parentheses" do
    assert {:ok, %{pid: 7, comm: "a) (b", state: "R", ppid: 1, start_time: 42}} =
             :ncc_tracer_sweep.parse_stat(stat_line(7, "a) (b", "R", 1, 42))

    assert :error = :ncc_tracer_sweep.parse_stat("garbage")
  end
end
