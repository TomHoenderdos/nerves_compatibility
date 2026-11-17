defmodule Portal.Builder.AutoPauseTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Portal.Builder.AutoPause

  @node "portal@builder-a"
  @tag_value "own-tag"

  # Stands in for Oban: the queues' paused flags live in an Agent, and
  # every signal and announcement is sent to the test process. A signal of
  # its own comes back to the server, as through Oban's notifier, unless
  # the test holds the echoes back.
  setup do
    {:ok, queues} = Agent.start_link(fn -> %{"toolchain" => false, "builds" => false} end)
    {:ok, probes} = Agent.start_link(fn -> %{} end)
    test = self()

    ops = %{
      check_queue: fn queue ->
        Agent.get(queues, fn flags ->
          case Map.fetch(flags, queue) do
            {:ok, paused} -> %{paused: paused}
            :error -> nil
          end
        end)
      end,
      # Runs in the server process.
      signal: fn action, queue, id ->
        send(test, {:signal, action, queue})

        case Agent.get(queues, &Map.get(&1, :signal_answer, :ok)) do
          :ok ->
            Agent.update(queues, &Map.put(&1, queue, action == :pause))

            if not Agent.get(queues, &Map.get(&1, :hold_echoes, false)) do
              send(self(), {:notification, :signal, own(action, queue, id)})
            end

            :ok

          error ->
            error
        end
      end,
      listen: fn -> :ok end,
      gossip: fn payload ->
        send(test, {:gossip, payload})
        :ok
      end
    }

    probe = fn check ->
      case Agent.get(probes, &Map.get(&1, check, {:error, :still_failing})) do
        :raise -> raise "probe blew up"
        answer -> answer
      end
    end

    server = start(ops: ops, probe: probe)
    %{server: server, queues: queues, probes: probes, ops: ops, probe: probe}
  end

  defp own(action, queue, id) do
    %{
      "action" => Atom.to_string(action),
      "queue" => queue,
      "auto_pause" => @tag_value,
      "auto_pause_id" => id
    }
  end

  defp start(opts) do
    name = :"auto_pause_#{System.unique_integer([:positive])}"

    start_supervised!(
      {AutoPause,
       [name: name, enabled: true, node: @node, tag: @tag_value, interval_ms: :timer.hours(1)] ++
         opts},
      id: name
    )

    name
  end

  defp passes(%{probes: probes}, check), do: Agent.update(probes, &Map.put(&1, check, :ok))
  defp paused?(%{queues: queues}, queue), do: Agent.get(queues, &Map.fetch!(&1, queue))
  defp hold_echoes(%{queues: queues}), do: Agent.update(queues, &Map.put(&1, :hold_echoes, true))

  # A tick, and the re-check it starts, finished.
  defp tick(server) do
    send(server, :tick)
    await_probe(server, 200)
  end

  defp await_probe(server, tries) do
    case :sys.get_state(server) do
      %{probing: nil} = state -> state
      _ when tries > 0 -> Process.sleep(5) && await_probe(server, tries - 1)
    end
  end

  defp signal(server, payload) do
    send(server, {:notification, :signal, payload})
    :sys.get_state(server)
  end

  describe "defer/3" do
    test "pauses the job's queue on this node and snoozes the job briefly", ctx do
      log =
        capture_log(fn ->
          assert {:snooze, 60} = AutoPause.defer("toolchain", {:disk, "toolchain"}, ctx.server)
        end)

      assert_received {:signal, :pause, "toolchain"}
      assert paused?(ctx, "toolchain")
      refute paused?(ctx, "builds")
      assert AutoPause.held_queues(ctx.server) == ["toolchain"]
      assert log =~ "[warning]"
      assert log =~ "Pausing queue toolchain on this node"
      assert log =~ "free on the scratch disk"
    end

    test "a second refusal on a queue it holds pauses nothing more", ctx do
      capture_log(fn ->
        assert {:snooze, 60} = AutoPause.defer("toolchain", :egress, ctx.server)
        assert {:snooze, 60} = AutoPause.defer("toolchain", :egress, ctx.server)
      end)

      assert_received {:signal, :pause, "toolchain"}
      refute_received {:signal, _, _}
    end

    test "a queue someone else paused stays theirs, and the job still snoozes briefly", ctx do
      Agent.update(ctx.queues, &Map.put(&1, "toolchain", true))

      assert {:snooze, 60} = AutoPause.defer("toolchain", :egress, ctx.server)

      refute_received {:signal, _, _}
      assert AutoPause.held_queues(ctx.server) == []
    end

    test "a queue with no producer on this node is not paused", ctx do
      assert {:snooze, 900} = AutoPause.defer("warm_nerves_x", :egress, ctx.server)
      refute_received {:signal, _, _}
    end

    test "a pause that fails leaves the long snooze", ctx do
      Agent.update(ctx.queues, &Map.put(&1, :signal_answer, {:error, :notifier_down}))

      capture_log(fn ->
        assert {:snooze, 900} = AutoPause.defer("toolchain", :egress, ctx.server)
      end)

      assert AutoPause.held_queues(ctx.server) == []
    end

    test "without a running server the job snoozes as long as before" do
      assert {:snooze, 900} = AutoPause.defer("toolchain", :egress, :no_such_auto_pause)
      assert {:snooze, 900} = AutoPause.defer(nil, :egress, :no_such_auto_pause)
      assert AutoPause.held_queues(:no_such_auto_pause) == []
      assert AutoPause.cluster(:no_such_auto_pause) == []
      assert :ok = AutoPause.let_go(["toolchain"], :no_such_auto_pause)
    end
  end

  describe "the re-check" do
    test "resumes the queue once its precondition holds again, and says so", ctx do
      capture_log(fn -> AutoPause.defer("toolchain", {:disk, "toolchain"}, ctx.server) end)
      assert_received {:signal, :pause, "toolchain"}

      tick(ctx.server)
      refute_received {:signal, :resume, _}
      assert AutoPause.held_queues(ctx.server) == ["toolchain"]

      passes(ctx, {:disk, "toolchain"})
      log = capture_log(fn -> tick(ctx.server) end)

      assert_received {:signal, :resume, "toolchain"}
      refute paused?(ctx, "toolchain")
      assert AutoPause.held_queues(ctx.server) == []
      assert log =~ "[warning]"
      assert log =~ "Resuming queue toolchain on this node"
    end

    test "probes each check once and resumes only the queues whose check holds", ctx do
      capture_log(fn ->
        AutoPause.defer("toolchain", {:disk, "toolchain"}, ctx.server)
        AutoPause.defer("builds", :egress, ctx.server)
      end)

      passes(ctx, :egress)
      capture_log(fn -> tick(ctx.server) end)

      assert paused?(ctx, "toolchain")
      refute paused?(ctx, "builds")
      assert AutoPause.held_queues(ctx.server) == ["toolchain"]
    end

    test "a probe that raises counts as still failing", ctx do
      capture_log(fn -> AutoPause.defer("toolchain", :egress, ctx.server) end)
      Agent.update(ctx.probes, &Map.put(&1, :egress, :raise))

      capture_log(fn -> tick(ctx.server) end)

      assert AutoPause.held_queues(ctx.server) == ["toolchain"]
      assert paused?(ctx, "toolchain")
    end

    test "probes off the server, which keeps answering meanwhile", ctx do
      test = self()

      slow = fn _check ->
        send(test, {:probing, self()})

        receive do
          :go -> :ok
        end
      end

      server = start(ops: ctx.ops, probe: slow)
      capture_log(fn -> AutoPause.defer("toolchain", :egress, server) end)
      send(server, :tick)
      assert_receive {:probing, prober}

      # A deploy asks while the probe hangs, and lets go before it ends.
      assert AutoPause.held_queues(server) == ["toolchain"]
      capture_log(fn -> assert :ok = AutoPause.let_go(["toolchain"], server) end)

      send(prober, :go)
      await_probe(server, 200)

      refute_received {:signal, :resume, _}
      assert paused?(ctx, "toolchain")
    end
  end

  describe "only its own pause" do
    test "never resumes a queue someone else paused after it did", ctx do
      capture_log(fn -> AutoPause.defer("toolchain", :egress, ctx.server) end)

      log =
        capture_log(fn ->
          signal(ctx.server, %{
            "action" => "pause",
            "queue" => "toolchain",
            "ident" => "Oban.#{@node}"
          })
        end)

      assert log =~ "[warning]"
      assert log =~ "no longer auto-paused"

      passes(ctx, :egress)
      tick(ctx.server)

      refute_received {:signal, :resume, _}
      assert paused?(ctx, "toolchain")
      assert AutoPause.held_queues(ctx.server) == []
    end

    test "nor one someone paused just before its own pause landed", ctx do
      hold_echoes(ctx)
      capture_log(fn -> AutoPause.defer("toolchain", :egress, ctx.server) end)

      capture_log(fn -> signal(ctx.server, %{"action" => "pause", "queue" => "toolchain"}) end)

      assert AutoPause.held_queues(ctx.server) == []
    end

    test "a pause of every queue ends every hold", ctx do
      capture_log(fn ->
        AutoPause.defer("toolchain", :egress, ctx.server)
        AutoPause.defer("builds", :egress, ctx.server)
      end)

      capture_log(fn -> signal(ctx.server, %{"action" => "pause", "queue" => "*"}) end)

      assert AutoPause.held_queues(ctx.server) == []
    end

    test "someone else's resume after its pause ends the hold", ctx do
      capture_log(fn -> AutoPause.defer("toolchain", :egress, ctx.server) end)
      capture_log(fn -> signal(ctx.server, %{"action" => "resume", "queue" => "toolchain"}) end)

      assert AutoPause.held_queues(ctx.server) == []
    end

    test "a resume that landed before its own pause leaves the hold", ctx do
      hold_echoes(ctx)
      capture_log(fn -> AutoPause.defer("toolchain", :egress, ctx.server) end)

      signal(ctx.server, %{"action" => "resume", "queue" => "toolchain"})

      # The producer applied that resume first, then this pause: still its own.
      assert AutoPause.held_queues(ctx.server) == ["toolchain"]
    end

    test "a pause that landed just before its own resume is said again", ctx do
      capture_log(fn -> AutoPause.defer("toolchain", :egress, ctx.server) end)
      assert_received {:signal, :pause, "toolchain"}
      passes(ctx, :egress)
      hold_echoes(ctx)
      capture_log(fn -> tick(ctx.server) end)
      assert_received {:signal, :resume, "toolchain"}

      # A deploy's pause, applied before that resume: the queue would run.
      log =
        capture_log(fn -> signal(ctx.server, %{"action" => "pause", "queue" => "toolchain"}) end)

      assert_received {:signal, :pause, "toolchain"}
      assert paused?(ctx, "toolchain")
      assert AutoPause.held_queues(ctx.server) == []
      assert log =~ "repeating theirs"
    end

    test "its own signals coming back do not end its hold", ctx do
      hold_echoes(ctx)
      capture_log(fn -> AutoPause.defer("toolchain", :egress, ctx.server) end)

      signal(ctx.server, own(:pause, "toolchain", 1))

      assert %{pending: pending} = :sys.get_state(ctx.server)
      assert pending == %{}
      assert AutoPause.held_queues(ctx.server) == ["toolchain"]
    end

    test "signals about other queues or other actions change nothing", ctx do
      capture_log(fn -> AutoPause.defer("toolchain", :egress, ctx.server) end)

      signal(ctx.server, %{"action" => "pause", "queue" => "builds"})
      signal(ctx.server, %{"action" => "scale", "queue" => "toolchain", "limit" => 2})

      assert AutoPause.held_queues(ctx.server) == ["toolchain"]
    end

    test "let_go/2 hands its pauses to a deploy, which it then never resumes", ctx do
      capture_log(fn -> AutoPause.defer("toolchain", :egress, ctx.server) end)

      log =
        capture_log(fn -> assert :ok = AutoPause.let_go(["toolchain", :builds], ctx.server) end)

      assert log =~ "[warning]"
      assert AutoPause.held_queues(ctx.server) == []

      passes(ctx, :egress)
      tick(ctx.server)

      refute_received {:signal, :resume, _}
      assert paused?(ctx, "toolchain")
    end

    test "a crash gives back the queues it still holds, a shutdown does not", ctx do
      capture_log(fn -> AutoPause.defer("toolchain", :egress, ctx.server) end)
      assert_received {:signal, :pause, "toolchain"}

      capture_log(fn -> GenServer.stop(ctx.server, :boom) end)

      assert_received {:signal, :resume, "toolchain"}

      other = start(ops: ctx.ops, probe: ctx.probe)
      capture_log(fn -> AutoPause.defer("builds", :egress, other) end)
      assert_received {:signal, :pause, "builds"}

      GenServer.stop(other, :shutdown)

      refute_received {:signal, :resume, _}
    end
  end

  describe "the admin view" do
    test "announces what it holds whenever that changes", ctx do
      capture_log(fn -> AutoPause.defer("toolchain", :egress, ctx.server) end)

      assert_received {:gossip, %{node: @node, held: [%{queue: "toolchain", reason: reason}]}}
      assert reason =~ "egress filter"

      passes(ctx, :egress)
      capture_log(fn -> tick(ctx.server) end)

      assert_received {:gossip, %{node: @node, held: []}}
    end

    test "lists its own holds and every peer heard from lately", ctx do
      capture_log(fn -> AutoPause.defer("toolchain", :memory_limit, ctx.server) end)

      send(
        ctx.server,
        {:notification, :ncc_auto_pause,
         %{
           "node" => "portal@builder-b",
           "held" => [
             %{
               "queue" => "builds",
               "reason" => "the build egress filter is missing",
               "since" => "2026-11-17T10:00:00Z"
             }
           ]
         }}
      )

      assert [
               %{node: @node, queue: "toolchain", reason: own, since: %DateTime{}},
               %{
                 node: "portal@builder-b",
                 queue: "builds",
                 reason: "the build egress filter is missing",
                 since: ~U[2026-11-17 10:00:00Z]
               }
             ] = AutoPause.cluster(ctx.server)

      assert own =~ "memory limit"

      # A peer that lets go announces an empty list.
      send(
        ctx.server,
        {:notification, :ncc_auto_pause, %{"node" => "portal@builder-b", "held" => []}}
      )

      assert [%{node: @node}] = AutoPause.cluster(ctx.server)
    end

    test "forgets a peer it has not heard from within the time to live", ctx do
      server = start(ops: ctx.ops, probe: ctx.probe, peer_ttl_ms: 0)

      send(
        server,
        {:notification, :ncc_auto_pause,
         %{
           "node" => "portal@builder-b",
           "held" => [%{"queue" => "builds", "reason" => "x", "since" => "garbage"}]
         }}
      )

      assert [%{node: "portal@builder-b", since: nil}] = AutoPause.cluster(server)

      tick(server)

      assert AutoPause.cluster(server) == []
    end

    test "ignores its own announcement and malformed ones", ctx do
      send(ctx.server, {:notification, :ncc_auto_pause, %{"node" => @node, "held" => [%{}]}})
      send(ctx.server, {:notification, :ncc_auto_pause, %{"nonsense" => true}})

      assert AutoPause.cluster(ctx.server) == []
    end
  end

  describe "defer_image/2" do
    test "pauses for docker while it does not answer, and only then", ctx do
      previous = Application.get_env(:portal, AutoPause)
      on_exit(fn -> if previous, do: Application.put_env(:portal, AutoPause, previous) end)

      Application.put_env(:portal, AutoPause, docker_check: fn -> {:error, "down"} end)
      capture_log(fn -> assert {:snooze, 60} = AutoPause.defer_image("toolchain", ctx.server) end)
      assert_received {:signal, :pause, "toolchain"}
      assert %{held: %{"toolchain" => %{check: :docker}}} = :sys.get_state(ctx.server)

      Application.put_env(:portal, AutoPause, docker_check: fn -> {:ok, "27.0"} end)
      assert {:snooze, 900} = AutoPause.defer_image("builds", ctx.server)
      refute_received {:signal, _, "builds"}
      assert AutoPause.probe(:docker) == :ok

      Application.delete_env(:portal, AutoPause)
    end
  end

  describe "check_for/2" do
    test "names the node-local check of a builder refusal" do
      assert AutoPause.check_for({:insufficient_disk, 1, 2}, "toolchain") == {:disk, "toolchain"}
      assert AutoPause.check_for(:scratch_noexec, nil) == :scratch_exec
      assert AutoPause.check_for(:egress_filter_missing, nil) == :egress
      assert AutoPause.check_for(:build_memory_limit_missing, nil) == :memory_limit
      assert AutoPause.check_for(:docker_unavailable, nil) == nil
    end
  end

  describe "start_link/1" do
    test "stays out of the way while Oban runs in testing mode" do
      assert :ignore = AutoPause.start_link(name: :auto_pause_ignored)
    end
  end
end
