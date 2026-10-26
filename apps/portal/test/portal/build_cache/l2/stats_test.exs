defmodule Portal.BuildCache.L2.StatsTest do
  use ExUnit.Case, async: false

  alias Portal.BuildCache.L2.Stats

  setup do
    Stats.reset()
    :ok
  end

  test "counts events and bytes and remembers the last success" do
    assert Stats.snapshot().uploads == 0
    Stats.record(:upload_ok, 10)
    Stats.record(:upload_failed)
    Stats.record(:download_ok, 7)
    Stats.record(:refused)
    s = Stats.snapshot()

    assert %{
             uploads: 1,
             upload_failures: 1,
             downloads: 1,
             refused: 1,
             bytes_up: 10,
             bytes_down: 7
           } = s

    assert %DateTime{} = s.last_upload
    assert %DateTime{} = s.last_download
  end

  test "a claim is exclusive until released, and a dead claimant does not hold it" do
    assert Stats.claim("k")
    refute Stats.claim("k")
    Stats.release("k")
    assert Stats.claim("k")
    Stats.release("k")

    {:ok, pid} = Task.start(fn -> Stats.claim("dead") end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert Stats.claim("dead")
  end

  test "a bad key stays bad for a day" do
    refute Stats.bad?("k")
    Stats.mark_bad("k")
    assert Stats.bad?("k")
    refute Stats.bad?("k", System.system_time(:millisecond) + :timer.hours(25))
  end

  test "every call survives the table being absent" do
    # Only the owner may delete a public table's... table; stop the owner.
    :ok = Supervisor.terminate_child(Portal.Supervisor, Stats)

    try do
      assert :ok = Stats.record(:upload_ok, 1)
      refute Stats.claim("k")
      refute Stats.bad?("k")
      assert :ok = Stats.mark_bad("k")
      assert :ok = Stats.release("k")
      assert :ok = Stats.reset()
      assert Stats.snapshot().uploads == 0
    after
      {:ok, _} = Supervisor.restart_child(Portal.Supervisor, Stats)
    end
  end
end
