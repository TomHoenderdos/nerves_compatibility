defmodule Portal.NervesCacheTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  alias Portal.NervesCache
  alias Portal.Workers.WarmNerves

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

    # A Hex outage must not turn one build into over a dozen sequential 5+5s
    # lookups, none of which can come back owned, before ingest is enqueued
    # (Portal.Workers.Build.handle_outcome/3 calls this synchronously).
    test "a Hex blackhole stops asking after the first error and drops the rest" do
      pairs =
        for board <- ~w(x86_64 trellis rpi5 rpi4 rpi0 bbb),
            do: p("nerves_system_#{board}", "2.0.0")

      me = self()

      owners = fn name ->
        send(me, {:owners, name})
        {:error, :hex_api_unavailable}
      end

      assert NervesCache.warm_pairs(report(pairs, pairs), owners: owners) == []

      assert_received {:owners, _}
      refute_received {:owners, _}
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

  describe "request_warm/3 and recently_warmed/2" do
    # The memo is one ETS table for the whole node, so each test picks its own
    # image digest the way `Portal.HexPmTest` picks its own package name.
    defp image, do: "sha256:memo-#{System.unique_integer([:positive])}"

    # Plan-mandated (task-6-review.md Important 1): the day-long repeat bound
    # must survive `Oban.Plugins.Pruner` deleting the completed job row at 6 h
    # (apps/portal/config/config.exs), which both the uniqueness check and the
    # old `recently_warmed/1` relied on and which the old doc wrongly claimed
    # it survived.
    test "a warmed pair is still recently_warmed after its job row is gone, for a day" do
      digest = image()
      pair = p("nerves_system_rpi4", "2.0.0")

      assert {:ok, [^pair]} =
               NervesCache.request_warm(report([pair], [pair]), digest,
                 owners: nerves_owns(["nerves_system_rpi4"]),
                 now_ms: 0
               )

      Repo.delete_all(Oban.Job)

      assert MapSet.member?(
               NervesCache.recently_warmed(digest, now_ms: :timer.hours(23)),
               {"nerves_system_rpi4", "2.0.0"}
             )

      refute MapSet.member?(
               NervesCache.recently_warmed(digest, now_ms: :timer.hours(24)),
               {"nerves_system_rpi4", "2.0.0"}
             )
    end

    test "recently_warmed also sees a live job the memo missed" do
      digest = image()
      pair = p("nerves_system_rpi4", "2.0.0")

      assert {:ok, _job} = WarmNerves.enqueue(digest, [pair])

      assert MapSet.member?(NervesCache.recently_warmed(digest), {"nerves_system_rpi4", "2.0.0"})
    end

    test "nothing to warm answers {:ok, []} without touching Oban" do
      assert {:ok, []} =
               NervesCache.request_warm(report([], []), image(), owners: nerves_owns([]))
    end

    # Minor (task-6-review.md Minor 2): a unique conflict must not be reported
    # or logged as a newly queued warm.
    test "a unique conflict is reported as already queued, not queued again" do
      digest = image()
      pair = p("nerves_system_rpi4", "2.0.0")
      owners = nerves_owns(["nerves_system_rpi4"])

      assert {:ok, [^pair]} =
               NervesCache.request_warm(report([pair], [pair]), digest,
                 owners: owners,
                 recently_warmed: MapSet.new(),
                 now_ms: 0
               )

      assert {:ok, :already_queued} =
               NervesCache.request_warm(report([pair], [pair]), digest,
                 owners: owners,
                 recently_warmed: MapSet.new(),
                 now_ms: 0
               )

      assert [_one] = all_enqueued(worker: WarmNerves)
    end
  end

  describe "template file" do
    setup do
      root = Path.join(System.tmp_dir!(), "nerves-template-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)
      %{root: root}
    end

    test "round-trips the entries the template resolves", %{root: root} do
      assert :ok =
               NervesCache.write_template(root, "sha256:x", [
                 "nerves_system_rpi4-2.0.0",
                 "nerves_system_bbb-2.0.0"
               ])

      assert {:ok, entries} = NervesCache.template_entries(root)
      assert entries == MapSet.new(["nerves_system_bbb-2.0.0", "nerves_system_rpi4-2.0.0"])
      refute File.exists?(Path.join(root, "template.json.tmp"))
    end

    test "missing, malformed or not a regular file reads as unknown", %{root: root} do
      assert NervesCache.template_entries(root) == :error

      File.write!(Path.join(root, "template.json"), "{not json")
      assert NervesCache.template_entries(root) == :error

      File.write!(Path.join(root, "template.json"), ~s({"entries": [1, 2]}))
      assert NervesCache.template_entries(root) == :error

      File.rm!(Path.join(root, "template.json"))
      target = Path.join(root, "elsewhere.json")
      File.write!(target, ~s({"entries": ["nerves_system_rpi4-2.0.0"]}))
      File.ln_s!(target, Path.join(root, "template.json"))
      assert NervesCache.template_entries(root) == :error
    end
  end
end
