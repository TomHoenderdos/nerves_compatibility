defmodule Compatibility.WorldsTest do
  use ExUnit.Case, async: true

  alias Compatibility.Worlds

  @phx ~w(
    bandit db_connection decimal dns_cluster ecto ecto_sql esbuild expo finch gettext hpax idna jason
    mime mint nimble_options nimble_pool phoenix phoenix_ecto phoenix_html phoenix_live_dashboard
    phoenix_live_view phoenix_pubsub phoenix_template plug plug_crypto postgrex req swoosh tailwind
    telemetry telemetry_metrics telemetry_poller thousand_island websock websock_adapter
  )

  test "the phx world is the 36 prod packages of a phx.new 1.8.16 app" do
    assert Worlds.names() == ["phx"]
    assert {:ok, members} = Worlds.members("phx")
    assert length(members) == 36
    assert members == Enum.sort(@phx)
    assert Worlds.generator("phx") == {:ok, {"phx_new", "1.8.16"}}
  end

  test "dev and test-only packages of the template are not members" do
    {:ok, members} = Worlds.members("phx")

    for name <- ~w(phoenix_live_reload file_system lazy_html fine cc_precompiler elixir_make),
        do: refute(name in members)
  end

  test "an unknown world has no members" do
    assert Worlds.members("nope") == :error
    assert Worlds.members(nil) == :error
    assert Worlds.generator("nope") == :error
  end

  test "variants are world_<name> atoms, and map back to their world" do
    assert Worlds.variants() == [:world_phx]
    assert Worlds.variant("phx") == {:ok, :world_phx}
    assert Worlds.variant("nope") == :error
    assert Worlds.world(:world_phx) == {:ok, "phx"}
    assert Worlds.world("world_phx") == {:ok, "phx"}
    assert Worlds.world(:with) == :error
    assert Worlds.world("world_nope") == :error
  end

  test "members are valid for the worker and none is a never-added name" do
    {:ok, members} = Worlds.members("phx")
    assert length(members) <= 200
    assert Enum.all?(members, &Regex.match?(~r/^[a-z][a-z0-9_]*$/, &1))
    assert [] == members -- (members -- Compatibility.OptionalDeps.never_added())
  end

  describe "the firmware world" do
    @nerves ~w(
      beam_notify circular_buffer elixir_make interactive_cmd jason logger_backends mdns_lite
      muontrap nerves nerves_discovery nerves_logging nerves_motd nerves_pack nerves_runtime
      nerves_ssh nerves_time nerves_uevent one_dhcpd property_table ring_logger shoehorn
      ssh_subsystem_fwup tablet toolshed uboot_env vintage_net vintage_net_direct
      vintage_net_ethernet vintage_net_wifi
    )

    # The worker's own `nerves.new --no-nerves-pack --prerelease` template,
    # rpi4, less the system, nerves_system_br and the toolchain.
    @template ~w(
      nerves logger_backends ring_logger circular_buffer toolshed nerves_runtime nerves_logging
      nerves_uevent uboot_env property_table elixir_make interactive_cmd nerves_discovery tablet
    )

    test "nerves is the 29 prod packages of a default nerves.new 1.17.4 app, less the system" do
      assert Worlds.firmware_names() == ["nerves"]
      assert {:ok, members} = Worlds.firmware_members("nerves")
      assert length(members) == 29
      assert members == Enum.sort(@nerves)
      assert Worlds.firmware_generator("nerves") == {:ok, {"nerves_bootstrap", "1.17.4"}}
    end

    test "is not a toolchain world" do
      refute "nerves" in Worlds.names()
      refute :world_nerves in Worlds.variants()
      assert Worlds.members("nerves") == :error
      assert Worlds.variant("nerves") == :error
      assert Worlds.world("world_nerves") == :error
    end

    test "its variant is the published variant world_nerves" do
      assert Worlds.firmware_variant("nerves") == {:ok, "world_nerves"}
      assert Worlds.firmware_variant("phx") == :error
      assert Worlds.firmware_variant(nil) == :error
      assert Worlds.firmware_variants() == ["world_nerves"]
      assert Worlds.firmware_members("phx") == :error
    end

    test "holds no system, toolchain or never-added name, and is valid for the worker" do
      {:ok, members} = Worlds.firmware_members("nerves")
      refute Enum.any?(members, &String.starts_with?(&1, ["nerves_system_", "nerves_toolchain_"]))
      assert [] == members -- (members -- Compatibility.OptionalDeps.never_added())
      assert length(members) <= 200
      assert Enum.all?(members, &Regex.match?(~r/^[a-z][a-z0-9_]*$/, &1))
    end

    test "covers every package of the worker's own template, so it only ever adds" do
      {:ok, members} = Worlds.firmware_members("nerves")
      assert @template -- members == []
    end
  end
end
