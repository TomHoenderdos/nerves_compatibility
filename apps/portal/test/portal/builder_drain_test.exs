defmodule Portal.BuilderDrainTest do
  # A builder deploy waits for this node's builder queues to drain. A job
  # whose process hung there (a `docker kill` that never returned) stayed in
  # its producer's running list long after Lifeline had rescued its row and
  # another node had retried it, and the drain waited for it until the
  # deploy timed out. Only a row still executing under this very producer
  # is waited for; the rest are reported, never killed.
  use Portal.DataCase, async: false

  import ExUnit.CaptureIO

  alias Portal.BuilderDrain
  alias Portal.Repo

  @node "portal@builder-a"
  @uuid "11111111-1111-1111-1111-111111111111"

  defp job(state, attempted_by, args \\ %{"package" => "jason", "version" => "1.4.1"}) do
    Repo.insert!(%Oban.Job{
      worker: "Portal.Workers.Build",
      queue: "builds",
      state: state,
      args: args,
      attempt: 1,
      max_attempts: 3,
      attempted_at: DateTime.utc_now(),
      attempted_by: attempted_by
    })
  end

  defp check(running, extra \\ %{}) do
    fn _queue ->
      Map.merge(%{paused: true, running: running, node: @node, uuid: @uuid}, extra)
    end
  end

  test "nothing running is drained" do
    assert %{drained: true, waiting: [], orphans: []} =
             BuilderDrain.status([:builds], check: check([]))
  end

  test "a queue that is not paused is not drained" do
    assert %{drained: false} = BuilderDrain.status([:builds], check: check([], %{paused: false}))
  end

  test "a queue without a producer is not drained" do
    assert %{drained: false} = BuilderDrain.status([:builds], check: fn _ -> nil end)
  end

  test "a job still executing under this producer is waited for" do
    live = job("executing", [@node, @uuid])

    assert %{drained: false, waiting: [id], orphans: []} =
             BuilderDrain.status([:builds], check: check([live.id]))

    assert id == live.id
  end

  test "a job rescued and retried by another node is an orphan, not a wait" do
    elsewhere = job("executing", ["portal@builder-b", "22222222-2222-2222-2222-222222222222"])
    rescued = job("available", [@node, @uuid])
    gone = %{id: 999_999_999}

    assert %{drained: true, waiting: [], orphans: orphans} =
             BuilderDrain.status([:builds], check: check([elsewhere.id, rescued.id, gone.id]))

    assert orphans |> Enum.map(& &1.id) |> Enum.sort() ==
             Enum.sort([elsewhere.id, rescued.id, gone.id])

    assert Enum.find(orphans, &(&1.id == gone.id)).state == "missing"
    assert Enum.find(orphans, &(&1.id == rescued.id)).state == "available"
  end

  # The same node restarted: its producer has a new uuid.
  test "a job executing under an earlier producer of this node is an orphan" do
    old = job("executing", [@node, "33333333-3333-3333-3333-333333333333"])

    assert %{drained: true, orphans: [%{id: id}]} =
             BuilderDrain.status([:builds], check: check([old.id]))

    assert id == old.id
  end

  test "one live job keeps the drain waiting whatever the orphans" do
    live = job("executing", [@node, @uuid])
    orphan = job("retryable", [@node, @uuid])

    assert %{drained: false, waiting: [_], orphans: [_]} =
             BuilderDrain.status([:builds], check: check([live.id, orphan.id]))
  end

  test "report prints the verdict first and one line per orphan naming its container" do
    orphan = job("available", ["portal@builder-b", "x"])

    out =
      capture_io(fn ->
        assert BuilderDrain.report([:builds], check: check([orphan.id])) == :ok
      end)

    assert ["true", line] = String.split(out, "\n", trim: true)
    assert line =~ "orphan queue=builds job=#{orphan.id}"
    assert line =~ "worker=Portal.Workers.Build"
    assert line =~ "state=available"
    assert line =~ "container=ncc-jason-1.4.1-*"
  end

  test "report prints false while a job runs" do
    live = job("executing", [@node, @uuid])

    out =
      capture_io(fn -> BuilderDrain.report([:builds], check: check([live.id])) end)

    assert out == "false\n"
  end
end
