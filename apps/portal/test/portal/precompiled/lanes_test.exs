defmodule Portal.Precompiled.LanesTest do
  use ExUnit.Case, async: true
  alias Portal.Precompiled.Lanes

  # Slots of the gauge each test's function writes: lanes in use now, the
  # most at once, heavy ones now, the most heavy ones at once, and whether a
  # light item ever ran beside a heavy one.
  @running 1
  @most 2
  @heavy 3
  @most_heavy 4
  @beside 5

  defp gauge, do: :atomics.new(5, [])

  # Each item is `{kind, n}`; the function sleeps a little so items overlap.
  defp tracked(gauge, ms \\ 15) do
    fn {kind, n} ->
      raise_max(gauge, @most, :atomics.add_get(gauge, @running, 1))
      note_start(gauge, kind)
      Process.sleep(ms)
      if kind == :heavy, do: :atomics.sub(gauge, @heavy, 1)
      :atomics.sub(gauge, @running, 1)
      n * 10
    end
  end

  defp note_start(gauge, :heavy),
    do: raise_max(gauge, @most_heavy, :atomics.add_get(gauge, @heavy, 1))

  defp note_start(gauge, :light),
    do: if(:atomics.get(gauge, @heavy) > 0, do: :atomics.put(gauge, @beside, 1))

  defp raise_max(gauge, slot, value) do
    current = :atomics.get(gauge, slot)

    if value > current and :atomics.compare_exchange(gauge, slot, current, value) != :ok,
      do: raise_max(gauge, slot, value)

    :ok
  end

  defp items(kind, range), do: Enum.map(range, &{kind, &1})

  test "returns every item with its result" do
    heavy = items(:heavy, 1..3)
    light = items(:light, 4..20)

    result = Lanes.map(heavy, light, tracked(gauge(), 1), 4)

    assert Enum.sort(result) == Enum.sort(for {_, n} = item <- heavy ++ light, do: {item, n * 10})
  end

  test "empty lists return nothing" do
    assert Lanes.map([], [], fn _ -> flunk("called") end, 3) == []
  end

  test "runs at most `lanes` items at once, and more than one when it may" do
    g = gauge()
    Lanes.map([], items(:light, 1..24), tracked(g), 3)

    assert :atomics.get(g, @most) == 3
  end

  test "never runs two heavy items at once, and fills the other lanes with light ones" do
    g = gauge()
    Lanes.map(items(:heavy, 1..6), items(:light, 7..30), tracked(g), 4)

    assert :atomics.get(g, @most_heavy) == 1
    assert :atomics.get(g, @beside) == 1
    assert :atomics.get(g, @most) == 4
  end

  test "heavy items alone run one at a time, whatever the lanes" do
    g = gauge()
    Lanes.map(items(:heavy, 1..5), [], tracked(g), 4)

    assert :atomics.get(g, @most) == 1
  end

  test "one lane runs the heavy items first, each list in its order" do
    me = self()
    fun = fn item -> send(me, {:ran, item}) end

    Lanes.map([:h1, :h2], [:l1, :l2, :l3], fun, 1)

    assert collect_ran() == [:h1, :h2, :l1, :l2, :l3]
  end

  @tag :capture_log
  test "an item that raises fails the call" do
    Process.flag(:trap_exit, true)

    fun = fn
      :bad -> raise "render failed"
      item -> item
    end

    caller = spawn_link(fn -> Lanes.map([], [:a, :bad, :c], fun, 2) end)

    assert_receive {:EXIT, ^caller, {%RuntimeError{message: "render failed"}, _stack}}
  end

  @tag :capture_log
  test "a caller that traps exits fails too, instead of waiting for the lane" do
    Process.flag(:trap_exit, true)
    fun = fn _ -> raise "render failed" end

    assert {%RuntimeError{message: "render failed"}, _stack} =
             catch_exit(Lanes.map([], [:a], fun, 2))
  end

  describe "split/3" do
    test "heavy from the size up and of unknown size, each list largest first" do
      sizes = %{a: 10, b: 500, c: 100, d: 2_000, e: nil, f: 99}

      assert Lanes.split([:a, :b, :c, :d, :e, :f, :g], &Map.get(sizes, &1), 100) ==
               {[:d, :b, :c, :e, :g], [:f, :a]}
    end

    test "nothing heavy when every size is known and small" do
      assert Lanes.split([:a, :b], fn _ -> 1 end, 100) == {[], [:a, :b]}
    end
  end

  defp collect_ran(acc \\ []) do
    receive do
      {:ran, item} -> collect_ran([item | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
