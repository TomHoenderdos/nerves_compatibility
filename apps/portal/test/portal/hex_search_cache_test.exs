defmodule Portal.HexSearchCacheTest do
  # Not async: the size and sweep tests see the whole shared table.
  use ExUnit.Case, async: false

  alias Portal.HexSearchCache

  setup do
    HexSearchCache.reset()
    on_exit(&HexSearchCache.reset/0)
  end

  @jason [%{name: "jason", description: "JSON", url: "https://hex.pm/packages/jason"}]

  test "answers a stored query, trimmed and in any case" do
    assert :miss = HexSearchCache.fetch("jason")

    HexSearchCache.put("jason", @jason)

    assert {:ok, @jason} = HexSearchCache.fetch("jason")
    assert {:ok, @jason} = HexSearchCache.fetch("  JaSoN ")
  end

  test "an answer expires after five minutes" do
    now = System.system_time(:millisecond)
    HexSearchCache.put("jason", @jason, now_ms: now)

    assert {:ok, _} = HexSearchCache.fetch("jason", now_ms: now + :timer.minutes(5) - 1)
    assert :miss = HexSearchCache.fetch("jason", now_ms: now + :timer.minutes(5))
  end

  test "a full table serves new answers without storing them" do
    HexSearchCache.put("jason", @jason, max_entries: 1)
    HexSearchCache.put("plug", [], max_entries: 1)

    assert {:ok, _} = HexSearchCache.fetch("jason")
    assert :miss = HexSearchCache.fetch("plug")
  end

  test "the sweep drops expired answers and keeps live ones" do
    now = System.system_time(:millisecond)
    HexSearchCache.put("old", [], now_ms: now - :timer.minutes(5))
    HexSearchCache.put("new", [], now_ms: now)

    HexSearchCache.sweep(now)

    assert :ets.info(:ncc_hex_search_cache, :size) == 1
    assert {:ok, []} = HexSearchCache.fetch("new", now_ms: now)
  end
end
