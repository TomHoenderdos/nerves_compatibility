defmodule Portal.Oban.NodeSweepTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import ExUnit.CaptureLog

  alias Portal.NodeQueue
  alias Portal.Oban.NodeSweep
  alias Portal.Workers.Sweep

  defp conf(queues), do: %{Oban.Config.new(repo: Portal.Repo) | queues: queues}

  defp set!(job, fields), do: Repo.update_all(where(Oban.Job, id: ^job.id), set: fields)

  describe "the sweep job" do
    test "goes on this node's own queue unless told otherwise" do
      assert Ecto.Changeset.get_field(Sweep.new(%{}), :queue) == NodeQueue.name()
      assert Ecto.Changeset.get_field(Sweep.new(%{}, queue: "node_b"), :queue) == "node_b"
    end

    # Two sweeps of one disk would both delete the same directories; two
    # nodes' sweeps touch different disks and must not hold each other off.
    test "is unique per node queue" do
      {:ok, a} = Oban.insert(Sweep.new(%{}, queue: "node_a"))
      {:ok, b} = Oban.insert(Sweep.new(%{}, queue: "node_b"))
      {:ok, again} = Oban.insert(Sweep.new(%{}, queue: "node_a"))

      refute b.conflict?
      assert again.conflict?
      assert again.id == a.id
    end
  end

  describe "start_link/1" do
    # The web host has no scratch dirs or build caches: a sweep there would
    # report a clean disk forever.
    test "starts nothing on a node without a node queue" do
      assert NodeSweep.start_link(conf: conf(intake: [limit: 5]), name: nil) == :ignore
    end

    test "starts on a node that runs its node queue" do
      queue = String.to_atom(NodeQueue.name())
      assert {:ok, pid} = NodeSweep.start_link(conf: conf([{queue, [limit: 2]}]), name: nil)
      GenServer.stop(pid)
    end
  end

  describe "validate/1" do
    test "takes a minute past the hour" do
      assert NodeSweep.validate(minute: 23) == :ok
      assert {:error, _} = NodeSweep.validate(minute: 60)
      assert {:error, _} = NodeSweep.validate(minute: "23")
      assert {:error, _} = NodeSweep.validate(hour: 1)
    end
  end

  describe "next_tick_ms/3" do
    test "waits for the minute this hour, or the next hour once it has passed" do
      assert NodeSweep.next_tick_ms(~U[2026-11-17 10:00:00Z], 23) == :timer.minutes(23)
      assert NodeSweep.next_tick_ms(~U[2026-11-17 10:23:00Z], 23) == :timer.minutes(60)
      assert NodeSweep.next_tick_ms(~U[2026-11-17 10:30:30Z], 23) == :timer.seconds(52 * 60 + 30)
    end

    # The timer runs on monotonic time and the target is wall-clock time, so a
    # wall clock stepped back (an NTP step, a resumed VM) fires the :23 tick at
    # :22:59. Counted from there, the next tick would come a second later,
    # find this hour's sweep still outstanding and warn of a skipped hour.
    test "after a tick, counts from the time it was aimed at, so an early fire does not tick twice" do
      aimed = ~U[2026-11-17 10:23:00Z]

      assert NodeSweep.next_tick_ms(~U[2026-11-17 10:22:59Z], 23, aimed) == :timer.seconds(3601)
      assert NodeSweep.next_tick_ms(~U[2026-11-17 10:22:59.999Z], 23, aimed) == 3_600_001
      # A late fire counts from now, as before.
      assert NodeSweep.next_tick_ms(~U[2026-11-17 10:23:02Z], 23, aimed) == :timer.seconds(3598)
    end
  end

  describe "a tick" do
    test "that fires early schedules the next hour's, not this hour's again" do
      queue = String.to_atom(NodeQueue.name())
      now = DateTime.utc_now()
      # The next whole minute, up to a minute ahead: the tick below fires early.
      aimed = %{DateTime.add(now, 60, :second) | second: 0, microsecond: {0, 0}}

      {:ok, pid} =
        NodeSweep.start_link(conf: conf([{queue, [limit: 2]}]), name: nil, minute: aimed.minute)

      :sys.replace_state(pid, &Map.put(&1, :at, aimed))
      send(pid, :tick)

      assert :sys.get_state(pid).at == DateTime.add(aimed, 3600, :second)
      GenServer.stop(pid)
    end
  end

  describe "tick/2" do
    test "queues this hour's sweep on the node's queue" do
      assert :ok = NodeSweep.tick(Oban, "node_a")
      assert [%{queue: "node_a", args: %{}}] = all_enqueued(worker: Sweep)
    end

    # Unique over its incomplete states: the last hour's sweep still waiting
    # or running means this hour's is skipped, and a skip must not be silent.
    test "skips, with a warning naming the outstanding sweep, while the last one is incomplete" do
      {:ok, last} = Oban.insert(Sweep.new(%{}, queue: "node_a"))
      set!(last, state: "executing", attempted_at: DateTime.utc_now())

      log = capture_log(fn -> assert :ok = NodeSweep.tick(Oban, "node_a") end)

      assert [_one] = Repo.all(where(Oban.Job, worker: "Portal.Workers.Sweep"))
      assert log =~ "node_a"
      assert log =~ "#{last.id}"
      assert log =~ "executing"
    end

    # The previous release's leader puts its cron sweep on the shared ingest
    # queue, which no node of this release runs: left there, it would sit
    # available forever.
    test "cancels a sweep left unclaimed on the shared ingest queue" do
      {:ok, stale} = Oban.insert(Sweep.new(%{}, queue: "ingest"))
      set!(stale, scheduled_at: DateTime.add(DateTime.utc_now(), -3, :hour))
      {:ok, fresh} = Oban.insert(Sweep.new(%{"fresh" => true}, queue: "ingest"))

      assert :ok = NodeSweep.tick(Oban, "node_a")

      assert Repo.get!(Oban.Job, stale.id).state == "cancelled"
      # A node still on the previous release runs `ingest`, and claims one in
      # seconds: one that waited less than two hours may still be its.
      assert Repo.get!(Oban.Job, fresh.id).state == "available"
    end
  end
end
