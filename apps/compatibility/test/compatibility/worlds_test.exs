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
end
