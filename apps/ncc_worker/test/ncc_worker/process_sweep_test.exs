defmodule NccWorker.ProcessSweepTest do
  use ExUnit.Case, async: true

  alias NccWorker.ProcessSweep

  @beam 1

  # A fake `/proc`: one `<pid>/stat` per process, in the kernel's format.
  defp proc_root(procs) do
    root = Path.join(System.tmp_dir!(), "proc-sweep-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    Enum.each(procs, &put_proc(root, &1))
    # Not processes: skipped by the scan.
    File.mkdir_p!(Path.join(root, "self"))
    File.write!(Path.join(root, "uptime"), "1.0 1.0")
    root
  end

  defp put_proc(root, {pid, comm, ppid, opts}) do
    state = Keyword.get(opts, :state, "S")
    start = Keyword.get(opts, :start, 100)
    dir = Path.join(root, Integer.to_string(pid))
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "stat"),
      "#{pid} (#{comm}) #{state} #{ppid} #{pid} #{pid} 0 -1 4194560 100 0 0 0 1 2 0 0 20 0 " <>
        "1 0 #{start} 1000000 100 18446744073709551615 0 0 0 0 0 0 0 0 0 0 0 0 17 0 0 0 0 0 0\n"
    )
  end

  defp put_proc(root, {pid, comm, ppid}), do: put_proc(root, {pid, comm, ppid, []})

  # A kill that ends the process, as SIGKILL would.
  defp killer(root) do
    test = self()

    fn pids ->
      send(test, {:killed, pids})
      Enum.each(pids, &File.rm_rf!(Path.join(root, Integer.to_string(&1))))
    end
  end

  defp sweep(root, opts \\ []) do
    ProcessSweep.sweep(
      Keyword.merge(
        [enabled?: true, proc_root: root, self_pid: @beam, kill: killer(root), interval_ms: 0],
        opts
      )
    )
  end

  describe "parse_stat/1" do
    test "reads pid, comm, state, parent and start time" do
      line =
        "4242 (sh) S 1 4242 4242 0 -1 4194560 100 0 0 0 1 2 0 0 20 0 1 0 98765 1000 100 " <>
          "18446744073709551615 0 0 0 0 0 0 0 0 0 0 0 0 17 0 0 0 0 0 0\n"

      assert {:ok, %{pid: 4242, comm: "sh", state: "S", ppid: 1, start_time: 98_765}} =
               ProcessSweep.parse_stat(line)
    end

    test "reads a comm with spaces and parentheses up to the last one" do
      line = "7 (a) b (c) R 1 7 7 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 55 0 0\n"

      assert {:ok, %{pid: 7, comm: "a) b (c", state: "R", ppid: 1, start_time: 55}} =
               ProcessSweep.parse_stat(line)
    end

    test "rejects a line it cannot read" do
      assert ProcessSweep.parse_stat("garbage") == :error
      assert ProcessSweep.parse_stat("") == :error
    end
  end

  describe "sweep/1" do
    test "kills everything but the BEAM and its erl_child_setup" do
      root =
        proc_root([
          {@beam, "beam.smp", 0},
          {9, "erl_child_setup", @beam, start: 10},
          {40, "sh", 9},
          {41, "make", 40},
          {77, "sleep", @beam}
        ])

      assert :ok = sweep(root)
      assert_received {:killed, pids}
      assert Enum.sort(pids) == [40, 41, 77]
      assert File.dir?(Path.join(root, "1"))
      assert File.dir?(Path.join(root, "9"))
    end

    test "keeps only the first erl_child_setup the BEAM started" do
      root =
        proc_root([
          {@beam, "beam.smp", 0},
          {9, "erl_child_setup", @beam, start: 10},
          {300, "erl_child_setup", @beam, start: 5000}
        ])

      assert :ok = sweep(root)
      assert_received {:killed, [300]}
      assert File.dir?(Path.join(root, "9"))
    end

    test "kills an erl_child_setup that is not the BEAM's child" do
      root =
        proc_root([
          {@beam, "beam.smp", 0},
          {9, "erl_child_setup", @beam, start: 10},
          {50, "erl_child_setup", 9, start: 20}
        ])

      assert :ok = sweep(root)
      assert_received {:killed, [50]}
    end

    test "leaves zombies alone and does not count them" do
      root =
        proc_root([
          {@beam, "beam.smp", 0},
          {9, "erl_child_setup", @beam},
          {60, "defunct", @beam, state: "Z"}
        ])

      assert :ok = sweep(root)
      refute_received {:killed, _}
    end

    test "kills processes started between rounds" do
      root = proc_root([{@beam, "beam.smp", 0}, {9, "erl_child_setup", @beam}, {40, "sh", 9}])
      test = self()

      kill = fn pids ->
        send(test, {:killed, pids})
        Enum.each(pids, &File.rm_rf!(Path.join(root, Integer.to_string(&1))))
        # The first victim forked before it died.
        if pids == [40], do: put_proc(root, {41, "sh", @beam})
      end

      assert :ok = sweep(root, kill: kill)
      assert_received {:killed, [40]}
      assert_received {:killed, [41]}
    end

    test "reports what survives every round" do
      root = proc_root([{@beam, "beam.smp", 0}, {9, "erl_child_setup", @beam}, {40, "sh", 9}])

      assert {:error, {:survivors, [%{pid: 40, comm: "sh"}]}} =
               sweep(root, kill: fn _pids -> :ok end, rounds: 3)
    end

    test "does nothing outside the container's worker" do
      root = proc_root([{@beam, "beam.smp", 0}, {40, "sh", @beam}])

      assert :skipped = sweep(root, enabled?: false)
      refute_received {:killed, _}
      assert File.dir?(Path.join(root, "40"))
    end
  end

  test "container_worker?/0 is false for a BEAM that is not pid 1" do
    # The test BEAM is never pid 1, so no test can kill the developer's processes.
    refute System.pid() == "1"
    refute ProcessSweep.container_worker?()
  end

  describe "enforce/2" do
    defp result do
      %{
        run_id: "r",
        systems: %{
          "host" => %{status: :pass, error: nil, cache_candidates: [%{"key" => "k"}]},
          "nerves_system_rpi4" => %{status: :pass, error: nil}
        },
        toolchain_build: %{status: "pass", reason: nil, file_manifest: %{"ebin" => []}}
      }
    end

    test "returns the result unchanged when nothing else runs" do
      root = proc_root([{@beam, "beam.smp", 0}, {9, "erl_child_setup", @beam}])
      opts = [enabled?: true, proc_root: root, self_pid: @beam, interval_ms: 0]

      assert ProcessSweep.enforce(result(), opts) == result()
    end

    test "returns the result unchanged outside the container's worker" do
      assert ProcessSweep.enforce(result(), enabled?: false) == result()
    end

    test "makes nothing pass when a process survives" do
      root = proc_root([{@beam, "beam.smp", 0}, {9, "erl_child_setup", @beam}, {40, "sh", 9}])

      opts = [
        enabled?: true,
        proc_root: root,
        self_pid: @beam,
        kill: fn _pids -> :ok end,
        rounds: 2,
        interval_ms: 0
      ]

      tainted =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          send(self(), {:tainted, ProcessSweep.enforce(result(), opts)})
        end)

      assert tainted =~ "40 (sh)"
      assert_received {:tainted, tainted}

      for {_name, sys} <- tainted.systems do
        assert sys.status == :error
        assert sys.error =~ "could not be stopped"
        refute Map.has_key?(sys, :cache_candidates)
      end

      assert %{status: "error", file_manifest: nil, reason: reason} = tainted.toolchain_build
      assert reason =~ "40 (sh)"
    end

    # The portal tells this verdict from a failed compile by its reason's
    # start, so the toolchain build's reason begins with it.
    test "gives a toolchain build the sweep's own reason" do
      root = proc_root([{@beam, "beam.smp", 0}, {9, "erl_child_setup", @beam}, {40, "sh", 9}])

      opts = [
        enabled?: true,
        proc_root: root,
        self_pid: @beam,
        kill: fn _pids -> :ok end,
        rounds: 1,
        interval_ms: 0
      ]

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        send(self(), {:tainted, ProcessSweep.enforce(result(), opts)})
      end)

      assert_received {:tainted, tainted}
      assert "processes survived the sweep" <> _ = tainted.toolchain_build.reason
    end
  end

  # `enforce_and_report/2` is what the CLI runs: the sweep's verdict on the
  # result plus a top-level `process_sweep` saying how it went. A portal
  # build (NCC_INPUT set) whose sweep cannot run is tainted; a manual run
  # without NCC_INPUT is only told on stderr that nothing was swept.
  describe "enforce_and_report/2" do
    defp report_result do
      %{
        run_id: "r",
        systems: %{
          "host" => %{status: :pass, error: nil, cache_candidates: [%{"key" => "k"}]},
          "nerves_system_rpi4" => %{status: :pass, error: nil}
        },
        toolchain_build: %{status: "pass", reason: nil, file_manifest: %{"ebin" => []}}
      }
    end

    defp report(opts) do
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        send(self(), {:reported, ProcessSweep.enforce_and_report(report_result(), opts)})
      end)
      |> then(fn stderr ->
        assert_received {:reported, result}
        {result, stderr}
      end)
    end

    test "a portal build that swept clean reports ok and keeps its verdicts" do
      root = proc_root([{@beam, "beam.smp", 0}, {9, "erl_child_setup", @beam}])

      {result, _stderr} =
        report(
          portal_build?: true,
          environment: :ok,
          proc_root: root,
          self_pid: @beam,
          interval_ms: 0
        )

      assert result == Map.put(report_result(), :process_sweep, "ok")
    end

    test "a portal build whose sweep cannot run is tainted, with the sweep's own reason" do
      {result, stderr} =
        report(portal_build?: true, environment: {:unavailable, "the BEAM is pid 42, not 1"})

      assert result.process_sweep == "tainted"
      assert stderr =~ "process sweep could not run: the BEAM is pid 42, not 1"

      for {_name, sys} <- result.systems do
        assert sys.status == :error
        assert sys.error == "process sweep could not run: the BEAM is pid 42, not 1"
        refute Map.has_key?(sys, :cache_candidates)
      end

      assert %{status: "error", file_manifest: nil, reason: reason} = result.toolchain_build
      assert "process sweep could not run: " <> _ = reason
    end

    test "a manual run whose sweep cannot run is skipped, says so, and is otherwise unchanged" do
      {result, stderr} =
        report(portal_build?: false, environment: {:unavailable, "not Linux"})

      assert result == Map.put(report_result(), :process_sweep, "skipped")
      assert stderr =~ "Process sweep skipped"
      assert stderr =~ "not Linux"
    end

    test "survivors taint the result and report tainted" do
      root = proc_root([{@beam, "beam.smp", 0}, {9, "erl_child_setup", @beam}, {40, "sh", 9}])

      {result, stderr} =
        report(
          portal_build?: true,
          environment: :ok,
          proc_root: root,
          self_pid: @beam,
          kill: fn _pids -> :ok end,
          rounds: 1,
          interval_ms: 0
        )

      assert result.process_sweep == "tainted"
      assert stderr =~ "40 (sh)"
      assert "processes survived the sweep" <> _ = result.toolchain_build.reason
    end

    test "survivors in a manual run are still tainted" do
      root = proc_root([{@beam, "beam.smp", 0}, {9, "erl_child_setup", @beam}, {40, "sh", 9}])

      {result, _stderr} =
        report(
          portal_build?: false,
          environment: :ok,
          proc_root: root,
          self_pid: @beam,
          kill: fn _pids -> :ok end,
          rounds: 1,
          interval_ms: 0
        )

      assert result.process_sweep == "tainted"
    end
  end

  describe "use_erlang_resolver/0" do
    # The native resolver is a port program, `inet_gethost`, that the BEAM
    # starts through `erl_child_setup` the first time it looks a name up, and
    # restarts when it dies: a sweep would find it every time. With Erlang's
    # own resolver it never exists. Checked on a fresh node, since the test
    # node may already have started it.
    test "a worker that resolved a name never starts the native resolver" do
      {:ok, peer, node} =
        :peer.start_link(%{
          connection: :standard_io,
          args: Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
        })

      on_exit(fn -> if Process.alive?(peer), do: :peer.stop(peer) end)

      assert :ok = :peer.call(peer, ProcessSweep, :use_erlang_resolver, [])
      assert [:file, :dns] = :peer.call(peer, :inet_db, :res_option, [:lookup])
      assert {:ok, _} = :peer.call(peer, :inet, :gethostbyname, [~c"localhost"])

      children = :peer.call(peer, :supervisor, :which_children, [:kernel_safe_sup])
      refute List.keymember?(children, :inet_gethost_native_sup, 0)
      _ = node
    end

    test "a child of erl_child_setup is still a stray" do
      root =
        proc_root([
          {@beam, "beam.smp", 0},
          {9, "erl_child_setup", @beam},
          {50, "inet_gethost", 9}
        ])

      assert [%{pid: 50, comm: "inet_gethost"}] = ProcessSweep.strays(root, @beam)
    end
  end

  describe "portal_build?/1" do
    test "is true when NCC_INPUT is set, whatever its value" do
      assert ProcessSweep.portal_build?(fn "NCC_INPUT" -> "/work/input.json" end)
      assert ProcessSweep.portal_build?(fn "NCC_INPUT" -> "/elsewhere/in.json" end)
    end

    test "is false when NCC_INPUT is unset" do
      refute ProcessSweep.portal_build?(fn "NCC_INPUT" -> nil end)
    end
  end

  describe "environment/0" do
    test "names why the sweep cannot run outside the container's worker" do
      # The test BEAM is never pid 1.
      assert {:unavailable, why} = ProcessSweep.environment()
      assert is_binary(why) and why != ""
    end
  end
end
