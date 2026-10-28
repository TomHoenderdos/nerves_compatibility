defmodule Portal.BuildCache.L2.EvictTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias Portal.BuildCache.L2.{Evict, Stats}
  alias Portal.Test.FakeS3

  @t0 ~U[2026-01-01 00:00:00Z]

  setup do
    Stats.reset()
    {:ok, s} = FakeS3.start()
    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)
    %{s: s}
  end

  # `n` objects of 100 bytes, the i-th one `i` minutes after @t0, stored in
  # an order unrelated to their age so only the timestamps can sort them.
  defp seed(s, n) do
    for i <- Enum.shuffle(0..(n - 1)) do
      FakeS3.put_object(s, key(i), String.duplicate("x", 100), %{},
        last_modified: DateTime.add(@t0, i * 60, :second)
      )
    end
  end

  defp key(i),
    do: "sha256_#{String.duplicate("ab", 32)}/#{String.pad_leading("#{9 - i}", 3, "0")}.tar.gz"

  defp cfg(s, max_bytes), do: %{s.config | max_bytes: max_bytes}

  defp deletes(s), do: for({"DELETE", path, _} <- FakeS3.requests(s), do: path)

  test "deletes oldest first until the total is at or below the low mark", %{s: s} do
    seed(s, 10)

    log =
      capture_log(fn ->
        assert %{listed: 10, total_bytes: 1000, deleted: 3, freed_bytes: 300, stopped: nil} =
                 Evict.run(cfg(s, 1000))
      end)

    assert FakeS3.objects(s) == Enum.sort(for i <- 3..9, do: key(i))
    assert deletes(s) == for(i <- 0..2, do: "/ncc-test/" <> key(i))
    assert log =~ "Build cache L2 eviction"
    assert log =~ "deleted 3"
    assert %{evictions: 3, evicted_bytes: 300} = Stats.snapshot()
  end

  test "objects of the same age go in key order", %{s: s} do
    for k <- ["s/d", "s/b", "s/a", "s/c"] do
      FakeS3.put_object(s, k, String.duplicate("x", 100), %{}, last_modified: @t0)
    end

    assert %{deleted: 1, stopped: nil} = Evict.run(cfg(s, 420))
    assert FakeS3.objects(s) == ["s/b", "s/c", "s/d"]
  end

  test "does nothing at or under the high mark and logs nothing", %{s: s} do
    seed(s, 9)

    log =
      capture_log(fn ->
        assert %{listed: 9, total_bytes: 900, deleted: 0, freed_bytes: 0, stopped: nil} =
                 Evict.run(cfg(s, 1000))
      end)

    assert deletes(s) == []
    assert length(FakeS3.objects(s)) == 9
    refute log =~ "eviction"
  end

  test "stops at the first delete error", %{s: s} do
    seed(s, 10)
    second = key(1)

    FakeS3.on_delete(s, fn
      ^second -> FakeS3.set_fault(s, {:delete, :status, 500})
      _ -> :ok
    end)

    log =
      capture_log(fn ->
        assert %{deleted: 1, freed_bytes: 100, stopped: {:delete_failed, {:status, 500}}} =
                 Evict.run(cfg(s, 1000))
      end)

    assert length(deletes(s)) == 2
    assert log =~ "stopped"
  end

  test "deletes at most max_deletes objects in one run", %{s: s} do
    seed(s, 10)

    assert %{deleted: 2, stopped: :max_deletes} = Evict.run(cfg(s, 1000), max_deletes: 2)
    assert length(FakeS3.objects(s)) == 8
  end

  test "the default delete cap and budget" do
    assert Evict.default_max_deletes() == 5_000
    assert Evict.default_budget_ms() == 120_000
  end

  test "stops once its time budget is spent", %{s: s} do
    seed(s, 10)
    ticks = :counters.new(1, [])

    # Each read of the clock is 100 ms after the last: the run starts at 0,
    # and the deletes are asked at 100, 200 and 300.
    clock = fn ->
      :counters.add(ticks, 1, 1)
      (:counters.get(ticks, 1) - 1) * 100
    end

    assert %{deleted: 2, stopped: :budget} = Evict.run(cfg(s, 1000), budget_ms: 250, clock: clock)
  end

  test "a listing failure is a warning and a summary, not a raise", %{s: s} do
    seed(s, 10)
    FakeS3.set_fault(s, {:list, :status, 500})

    log =
      capture_log(fn ->
        assert %{listed: 0, deleted: 0, stopped: {:list_failed, {:status, 500}}} =
                 Evict.run(cfg(s, 1000))
      end)

    assert log =~ "[warning]"
    assert log =~ "listing"
    assert length(FakeS3.objects(s)) == 10
  end

  test "an unreachable store is a summary, not a raise", %{s: s} do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)

    capture_log(fn ->
      assert %{deleted: 0, stopped: {:list_failed, _}} =
               Evict.run(%{cfg(s, 1000) | endpoint: "http://127.0.0.1:#{port}"})
    end)
  end

  test "a read-only config or one with no max never lists or deletes", %{s: s} do
    seed(s, 10)

    assert %{listed: 0, deleted: 0, stopped: nil} = Evict.run(%{cfg(s, 100) | read_only?: true})
    assert %{listed: 0, deleted: 0, stopped: nil} = Evict.run(cfg(s, nil))
    assert FakeS3.requests(s) == []
  end
end
