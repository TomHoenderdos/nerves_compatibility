defmodule Portal.NervesCacheTest do
  use ExUnit.Case, async: true

  alias Portal.NervesCache

  defp p(name, version), do: %{"name" => name, "version" => version}

  defp report(misses, lock), do: %{"nerves_cache" => %{"misses" => misses, "lock" => lock}}

  defp nerves_owns(names) do
    me = self()

    fn name ->
      send(me, {:owners, name})
      {:ok, if(name in names, do: ["nerves"], else: ["mallory"])}
    end
  end

  describe "warm_pairs/2" do
    test "keeps a miss the lock names and the nerves user owns" do
      pair = p("nerves_system_rpi4", "2.0.0")

      assert NervesCache.warm_pairs(report([pair], [pair]),
               owners: nerves_owns(["nerves_system_rpi4"])
             ) == [pair]
    end

    test "drops a miss the lock does not name" do
      result = report([p("nerves_system_rpi4", "2.0.0")], [p("nerves_system_rpi4", "2.0.1")])

      assert NervesCache.warm_pairs(result, owners: nerves_owns(["nerves_system_rpi4"])) == []
      refute_received {:owners, _}
    end

    test "drops a miss not owned by nerves" do
      pair = p("nerves_system_custom_board", "1.0.0")

      assert NervesCache.warm_pairs(report([pair], [pair]), owners: nerves_owns([])) == []
    end

    test "a Hex lookup error drops the pair" do
      pair = p("nerves_system_rpi4", "2.0.0")

      assert NervesCache.warm_pairs(report([pair], [pair]),
               owners: fn _ -> {:error, :hex_api_unavailable} end
             ) == []
    end

    test "keeps at most four, the first in lock order, and asks Hex no further" do
      pairs =
        for board <- ~w(x86_64 trellis rpi5 rpi4 rpi0 bbb),
            do: p("nerves_system_#{board}", "2.0.0")

      names = Enum.map(pairs, & &1["name"])

      assert NervesCache.warm_pairs(report(pairs, pairs), owners: nerves_owns(names)) == [
               p("nerves_system_bbb", "2.0.0"),
               p("nerves_system_rpi0", "2.0.0"),
               p("nerves_system_rpi4", "2.0.0"),
               p("nerves_system_rpi5", "2.0.0")
             ]

      for _ <- 1..4, do: assert_received({:owners, _})
      refute_received {:owners, _}
    end

    test "drops pairs warmed recently" do
      a = p("nerves_system_rpi4", "2.0.0")
      b = p("nerves_system_bbb", "2.0.0")

      assert NervesCache.warm_pairs(report([a, b], [a, b]),
               owners: nerves_owns(["nerves_system_rpi4", "nerves_system_bbb"]),
               recently_warmed: MapSet.new([{"nerves_system_rpi4", "2.0.0"}])
             ) == [b]
    end

    test "malformed reports warm nothing" do
      owners = nerves_owns(["nerves_system_rpi4"])

      for bad <- [
            %{},
            %{"nerves_cache" => nil},
            %{"nerves_cache" => %{"misses" => "nerves_system_rpi4-2.0.0", "lock" => []}},
            report([p("../../etc", "1.0.0")], [p("../../etc", "1.0.0")]),
            report([p("jason", "1.4.4")], [p("jason", "1.4.4")]),
            report([p("nerves_system_rpi4", "2.0.0 || >= 0.0.0")], [
              p("nerves_system_rpi4", "2.0.0 || >= 0.0.0")
            ]),
            report([%{"name" => 1, "version" => "2.0.0"}], [%{"name" => 1, "version" => "2.0.0"}]),
            report(["nerves_system_rpi4-2.0.0"], ["nerves_system_rpi4-2.0.0"])
          ] do
        assert NervesCache.warm_pairs(bad, owners: owners) == [], inspect(bad)
      end

      refute_received {:owners, _}
    end
  end
end
