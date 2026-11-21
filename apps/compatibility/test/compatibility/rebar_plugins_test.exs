defmodule Compatibility.RebarPluginsTest do
  use ExUnit.Case, async: true

  alias Compatibility.RebarPlugins

  test "every pin is a version and a lowercase sha256, and none is also left out" do
    for {name, releases} <- RebarPlugins.pins(), {version, sha} <- releases do
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, sha), "#{name} #{version}"
      assert {:ok, _} = Version.parse(version)
      refute version in Map.get(RebarPlugins.left_out(), name, []), "#{name} #{version}"
    end

    for {name, versions} <- RebarPlugins.left_out(),
        do: assert(Map.has_key?(RebarPlugins.pins(), name), name)
  end

  test "the reviewed plugins and what builds resolved on 2026-11-21 are pinned" do
    pins = RebarPlugins.pins()

    for name <- ~w(rebar3_hex rebar3_ex_doc rebar3_lint rebar3_proper coveralls covertool),
        do: assert(map_size(pins[name]) > 0, name)

    for {name, version} <- [
          {"rebar3_hex", "7.5.0"},
          {"hex_core", "0.21.1"},
          {"verl", "1.1.1"},
          {"rebar3_ex_doc", "0.3.0"},
          {"rebar3_lint", "5.0.4"},
          {"elvis_core", "5.0.4"},
          {"katana_code", "2.4.3"}
        ],
        do: assert(is_binary(pins[name][version]), "#{name} #{version}")
  end

  test "a release is reviewed when pinned or left out, and only then" do
    assert RebarPlugins.reviewed?("rebar3_hex", "7.5.0")
    assert RebarPlugins.reviewed?("rebar3_hex", "0.7.0")
    refute RebarPlugins.reviewed?("rebar3_hex", "7.6.0")
    refute RebarPlugins.reviewed?("rebar3_hex", "8.0.0-rc.1")
    refute RebarPlugins.reviewed?("pc", "1.0.0")
    assert "rebar3_hex" in RebarPlugins.packages()
  end
end
