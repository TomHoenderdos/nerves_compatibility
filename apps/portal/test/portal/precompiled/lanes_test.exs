defmodule Portal.Precompiled.LanesTest do
  use ExUnit.Case, async: true
  alias Portal.Precompiled.Lanes

  # Slots of the gauge each test's function writes: lanes in use now, the
  # most at once, heavy ones now, the most heavy ones at once, whether a light
  # item ever ran beside a heavy one, the heavy weight running now, and the
  # most of it at once.
  @running 1
  @most 2
  @heavy 3
  @most_heavy 4
  @beside 5
  @weight 6
  @most_weight 7

  defp gauge, do: :atomics.new(7, [])

  # Each item is `{:light, n}` or `{:heavy, n, weight}`; the function sleeps a
  # little so items overlap.
  defp tracked(gauge, ms \\ 15) do
    fn item ->
      raise_max(gauge, @most, :atomics.add_get(gauge, @running, 1))
      note_start(gauge, item)
      Process.sleep(ms)
      note_end(gauge, item)
      :atomics.sub(gauge, @running, 1)
      elem(item, 1) * 10
    end
  end

  defp note_start(gauge, {:heavy, _n, weight}) do
    raise_max(gauge, @most_heavy, :atomics.add_get(gauge, @heavy, 1))
    raise_max(gauge, @most_weight, :atomics.add_get(gauge, @weight, weight))
  end

  defp note_start(gauge, {:light, _n}),
    do: if(:atomics.get(gauge, @heavy) > 0, do: :atomics.put(gauge, @beside, 1))

  defp note_end(gauge, {:heavy, _n, weight}) do
    :atomics.sub(gauge, @heavy, 1)
    :atomics.sub(gauge, @weight, weight)
  end

  defp note_end(_gauge, {:light, _n}), do: :ok

  defp raise_max(gauge, slot, value) do
    current = :atomics.get(gauge, slot)

    if value > current and :atomics.compare_exchange(gauge, slot, current, value) != :ok,
      do: raise_max(gauge, slot, value)

    :ok
  end

  defp light(range), do: Enum.map(range, &{:light, &1})

  # `{item, weight}` pairs as `Lanes.map/5` takes them, the item naming its
  # weight for the gauge; a `nil` weight counts as `budget` in the gauge.
  defp heavy(range, weight, budget \\ nil),
    do: Enum.map(range, &{{:heavy, &1, weight || budget}, weight})

  test "returns every item with its result" do
    heavy = heavy(1..3, 5)
    light = light(4..20)

    result = Lanes.map(heavy, light, tracked(gauge(), 1), 4, 10)

    items = Enum.map(heavy, &elem(&1, 0)) ++ light
    assert Enum.sort(result) == Enum.sort(for item <- items, do: {item, elem(item, 1) * 10})
  end

  test "empty lists return nothing" do
    assert Lanes.map([], [], fn _ -> flunk("called") end, 3, 10) == []
  end

  test "runs at most `lanes` items at once, and more than one when it may" do
    g = gauge()
    Lanes.map([], light(1..24), tracked(g), 3, 10)

    assert :atomics.get(g, @most) == 3
  end

  test "runs heavy items beside each other while they weigh no more than the budget" do
    g = gauge()
    Lanes.map(heavy(1..12, 3), light(13..30), tracked(g), 4, 10)

    assert :atomics.get(g, @most_heavy) == 3
    assert :atomics.get(g, @most_weight) == 9
    assert :atomics.get(g, @beside) == 1
    assert :atomics.get(g, @most) == 4
  end

  test "an item heavier than the budget runs as the only heavy one, light ones beside it" do
    g = gauge()
    Lanes.map(heavy(1..3, 25) ++ heavy(4..9, 4), light(10..40), tracked(g), 4, 10)

    assert :atomics.get(g, @most_weight) == 25
    assert :atomics.get(g, @beside) == 1
    assert :atomics.get(g, @most) == 4
  end

  test "an item of unknown weight runs as the only heavy one" do
    g = gauge()
    Lanes.map(heavy(1..4, nil, 10) ++ heavy(5..6, 1), [], tracked(g), 4, 10)

    # Nothing ran beside an unknown one; the light ones then ran together.
    assert :atomics.get(g, @most_weight) == 10
    assert :atomics.get(g, @most_heavy) == 2
  end

  test "heavy items that each fill the budget run one at a time, whatever the lanes" do
    g = gauge()
    Lanes.map(heavy(1..5, 10), [], tracked(g), 4, 10)

    assert :atomics.get(g, @most) == 1
  end

  test "one lane runs the heavy items first, each list in its order" do
    me = self()
    fun = fn item -> send(me, {:ran, item}) end

    Lanes.map([{:h1, 1}, {:h2, 1}], [:l1, :l2, :l3], fun, 1, 10)

    assert collect_ran() == [:h1, :h2, :l1, :l2, :l3]
  end

  @tag :capture_log
  test "an item that raises fails the call" do
    Process.flag(:trap_exit, true)

    fun = fn
      :bad -> raise "render failed"
      item -> item
    end

    caller = spawn_link(fn -> Lanes.map([], [:a, :bad, :c], fun, 2, 10) end)

    assert_receive {:EXIT, ^caller, {%RuntimeError{message: "render failed"}, _stack}}
  end

  @tag :capture_log
  test "a caller that traps exits fails too, instead of waiting for the lane" do
    Process.flag(:trap_exit, true)
    fun = fn _ -> raise "render failed" end

    assert {%RuntimeError{message: "render failed"}, _stack} =
             catch_exit(Lanes.map([], [:a], fun, 2, 10))
  end

  describe "split/3" do
    test "heavy from the size up, weighing their size, and of unknown size, largest first" do
      sizes = %{a: 10, b: 500, c: 100, d: 2_000, e: nil, f: 99}

      assert Lanes.split([:a, :b, :c, :d, :e, :f, :g], &Map.get(sizes, &1), 100) ==
               {[d: 2_000, b: 500, c: 100, e: nil, g: nil], [:f, :a]}
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
