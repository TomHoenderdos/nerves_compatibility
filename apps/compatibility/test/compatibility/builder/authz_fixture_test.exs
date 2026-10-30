defmodule Compatibility.Builder.AuthzFixtureTest do
  use ExUnit.Case, async: true

  alias Compatibility.Builder.Argv

  # The create bodies the authorization policy in front of the builders'
  # docker daemon is tested against, in the builder host's configuration,
  # generated from Argv.build/1 by generate.py beside them. An Argv change that leaves them behind would let
  # the policy pass on a container no builder starts any more, and deny the
  # one it does start only once the policy is deployed.
  @fixture Path.expand("../../fixtures/authz/create_payloads.json", __DIR__)

  # The same input as generate.py: the parity fixture's, on the builders'
  # host layout.
  @run "ncc-11111111-2222-3333-4444-555555555555"
  @scratch "/var/lib/ncc/scratch/" <> @run

  defp spec(mode, name) do
    %{
      container_name: name,
      user: "950:950",
      image: "ncc-worker:local",
      cpus: "2",
      memory: "4g",
      build_concurrency: "2",
      nerves_cache_mode: mode,
      paths: %{
        work: @scratch <> "/work",
        out: @scratch <> "/out",
        files: @scratch <> "/files",
        tmp: @scratch <> "/tmp",
        cache: @scratch <> "/cache",
        nerves_cache: "/var/lib/ncc/nerves-cache",
        hex_cache: "/var/lib/ncc/hex-cache",
        build_cache: "/var/lib/ncc/build-cache/sha256_deadbeef"
      }
    }
  end

  setup_all do
    %{"ncc_authz_fixtures" => fixtures} = @fixture |> File.read!() |> JSON.decode!()
    %{fixtures: fixtures}
  end

  test "the authz fixtures carry the argv Argv builds today", %{fixtures: fixtures} do
    regenerate =
      "regenerate: python3 apps/compatibility/test/fixtures/authz/generate.py, " <>
        "then copy create_payloads.json to the builder host's policy tests"

    assert fixtures["build"]["argv"] == Argv.build(spec(:readonly, @run)), regenerate

    assert fixtures["warm_nerves"]["argv"] ==
             Argv.build(spec(:warm, "ncc-warm_nerves-1730000000000")),
           regenerate
  end

  test "every authz fixture asks docker-ncc for runsc", %{fixtures: fixtures} do
    for name <- ["build", "warm_nerves", "egress_probe", "promotion_copy"] do
      assert get_in(fixtures, [name, "request", "Body", "HostConfig", "Runtime"]) == "runsc",
             name
    end
  end
end
