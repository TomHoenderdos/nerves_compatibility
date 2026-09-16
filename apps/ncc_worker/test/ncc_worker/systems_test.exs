defmodule NccWorker.SystemsTest do
  use ExUnit.Case, async: true

  alias NccWorker.Systems

  describe "default/0" do
    # Architecture per default system. Duplicated from
    # Portal.Catalog.Architecture on purpose -- ncc_worker does not depend on
    # portal, and this test is about the worker's own choice of systems rather
    # than about how the portal labels them.
    @arch %{
      "nerves_system_rpi4" => "arm64",
      "nerves_system_mangopi_mq_pro" => "riscv64",
      "nerves_system_x86_64" => "x86_64",
      "nerves_system_trellis" => "arm32"
    }

    test "covers each architecture exactly once" do
      # The point of the default set is ABI spread, not board popularity: a
      # package missing a precompiled NIF for one architecture should show up
      # once, not be masked by three boards that share an ABI. Adding a system
      # that duplicates an architecture fails here, so the cost is deliberate.
      arches = Enum.map(Systems.default(), &Map.fetch!(@arch, &1.name))

      assert Enum.sort(arches) == ["arm32", "arm64", "riscv64", "x86_64"]
      assert length(Enum.uniq(arches)) == length(arches)
    end

    test "includes trellis, the Nerves Starter Kit board" do
      names = Enum.map(Systems.default(), & &1.name)
      assert "nerves_system_trellis" in names
    end

    test "every default is a member of all/0" do
      assert Enum.all?(Systems.default(), &(&1 in Systems.all()))
    end
  end

  describe "select/1" do
    test "nil falls back to the defaults" do
      assert Systems.select(nil) == Systems.default()
    end

    test "filters all/0 by system package name" do
      assert Systems.select(["nerves_system_bbb", "nerves_system_trellis"]) == [
               %{name: "nerves_system_bbb", target: "bbb"},
               %{name: "nerves_system_trellis", target: "trellis"}
             ]
    end

    test "returns all/0 order regardless of how the caller ordered the filter" do
      forward = Systems.select(["nerves_system_bbb", "nerves_system_x86_64"])
      reversed = Systems.select(["nerves_system_x86_64", "nerves_system_bbb"])

      assert forward == reversed
    end

    test "drops names that match no known system" do
      assert Systems.select(["nerves_system_not_a_thing"]) == []
    end

    test "an empty filter selects nothing rather than everything" do
      assert Systems.select([]) == []
    end
  end

  describe "targets/1" do
    test "maps systems to the target names mix nerves.new expects" do
      assert Systems.targets(Systems.select(["nerves_system_trellis"])) == ["trellis"]
    end

    test "every system's target is the name minus the nerves_system_ prefix" do
      # mix nerves.new's own target->package mapping follows this convention.
      # A system that breaks it would generate a mix.exs missing that dep.
      for %{name: name, target: target} <- Systems.all() do
        assert String.replace_prefix(name, "nerves_system_", "") == target
      end
    end
  end
end
