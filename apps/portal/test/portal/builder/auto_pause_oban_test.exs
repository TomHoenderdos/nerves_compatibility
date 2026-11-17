defmodule Portal.Builder.AutoPauseObanTest do
  # The Oban calls themselves, against a running instance: the signal this
  # module sends must pause and resume a real producer, and the pauses
  # Oban's own API sends must reach it as someone else's.
  use Portal.DataCase, async: false

  import ExUnit.CaptureLog

  alias Portal.Builder.AutoPause

  @oban Module.concat(__MODULE__, Oban)

  setup do
    # Oban.Met would start beside a non-testing instance and outlive the
    # sandbox; nothing here needs it.
    previous = Application.get_env(:oban_met, :auto_start)
    Application.put_env(:oban_met, :auto_start, false)
    on_exit(fn -> Application.put_env(:oban_met, :auto_start, previous) end)

    start_supervised!(
      {Oban,
       name: @oban,
       repo: Portal.Repo,
       testing: :disabled,
       node: "portal@builder-a",
       queues: [toolchain: 1, builds: 1],
       plugins: false,
       peer: false,
       stage_interval: :infinity,
       notifier: {Oban.Notifiers.PG, namespace: @oban}}
    )

    {:ok, probes} = Agent.start_link(fn -> %{} end)
    probe = fn check -> Agent.get(probes, &Map.get(&1, check, {:error, :failing})) end

    server =
      start_supervised!(
        {AutoPause,
         name: Module.concat(__MODULE__, AutoPause),
         enabled: true,
         oban: @oban,
         interval_ms: :timer.hours(1),
         probe: probe}
      )

    %{server: server, probes: probes}
  end

  defp paused?(queue), do: Oban.check_queue(@oban, queue: queue).paused

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  defp tick(server) do
    send(server, :tick)
    :sys.get_state(server)
  end

  test "pauses and resumes the producer on this node, and only its own pause", ctx do
    capture_log(fn ->
      assert {:snooze, 60} = AutoPause.defer("toolchain", :egress, ctx.server)
    end)

    assert eventually(fn -> paused?("toolchain") end)
    refute paused?("builds")

    # Its own signal comes back and changes nothing.
    :sys.get_state(ctx.server)
    assert AutoPause.held_queues(ctx.server) == ["toolchain"]

    Agent.update(ctx.probes, &Map.put(&1, :egress, :ok))
    capture_log(fn -> tick(ctx.server) end)

    assert eventually(fn -> not paused?("toolchain") end)

    # Paused again, then by an operator: theirs from then on.
    Agent.update(ctx.probes, &Map.delete(&1, :egress))
    capture_log(fn -> AutoPause.defer("toolchain", :egress, ctx.server) end)
    assert eventually(fn -> paused?("toolchain") end)

    capture_log(fn ->
      :ok = Oban.pause_queue(@oban, queue: :toolchain, local_only: true)
      assert eventually(fn -> AutoPause.held_queues(ctx.server) == [] end)
    end)

    Agent.update(ctx.probes, &Map.put(&1, :egress, :ok))
    tick(ctx.server)
    Process.sleep(50)

    assert paused?("toolchain")
  end
end
