defmodule Portal.BuildCache.L2.BoundedTest do
  use ExUnit.Case, async: true

  alias Portal.BuildCache.L2.Bounded

  test "returns the function's result" do
    assert {:ok, 42} = Bounded.run(fn -> 42 end, timeout_ms: 1_000)
  end

  test "kills a function that outlives its deadline" do
    me = self()

    {micros, result} =
      :timer.tc(fn ->
        Bounded.run(
          fn ->
            send(me, {:running, self()})
            Process.sleep(5_000)
          end,
          timeout_ms: 100
        )
      end)

    assert {:error, :timeout} = result
    assert micros < 1_000_000
    assert_received {:running, pid}
    refute Process.alive?(pid)
    refute_received _
  end

  test "a raise, a throw and an exit come back as errors" do
    assert {:error, {:exception, msg}} = Bounded.run(fn -> raise "boom" end, timeout_ms: 1_000)
    assert msg =~ "boom"
    assert {:error, {:exception, _}} = Bounded.run(fn -> throw(:boom) end, timeout_ms: 1_000)
    assert {:error, {:exception, _}} = Bounded.run(fn -> exit(:boom) end, timeout_ms: 1_000)
  end

  @tag :capture_log
  test "a heap past the cap is killed, and the caller is not" do
    grow = fn -> Enum.to_list(1..10_000_000) |> length() end

    assert {:error, :killed} =
             Bounded.run(grow, timeout_ms: 10_000, max_heap_bytes: 8 * 1024 * 1024)

    assert Process.alive?(self())
    refute_received _
  end
end
