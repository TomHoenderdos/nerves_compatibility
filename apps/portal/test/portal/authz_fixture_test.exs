defmodule Portal.AuthzFixtureTest do
  # Changes `Portal.Builder`'s application env.
  use ExUnit.Case, async: false

  alias Portal.BuildCache.Promotion
  alias Portal.EgressCheck

  # The create bodies the authorization policy in front of the builders'
  # docker daemon is tested against. generate.py transcribes the egress probe
  # and the promotion copy by hand, so this builds both from the portal's own
  # code with generate.py's inputs: a change that drops `--memory`,
  # `--read-only` or the runtime from either, and leaves the fixture behind,
  # fails here rather than at the first container the policy denies.
  @fixture Path.expand(
             "../../../compatibility/test/fixtures/authz/create_payloads.json",
             __DIR__
           )

  @regenerate "regenerate: python3 apps/compatibility/test/fixtures/authz/generate.py, " <>
                "then copy create_payloads.json to the builder host's policy tests"

  # generate.py's inputs: the builders' host layout and build user.
  @run "ncc-11111111-2222-3333-4444-555555555555"
  @scratch "/var/lib/ncc/scratch/" <> @run
  @image "ncc-worker:local"

  setup do
    previous = Application.get_env(:portal, Portal.Builder, [])
    on_exit(fn -> Application.put_env(:portal, Portal.Builder, previous) end)

    Application.put_env(
      :portal,
      Portal.Builder,
      Keyword.merge(previous, run_as_user: "950:950", docker_image: @image)
    )

    %{"ncc_authz_fixtures" => fixtures} = @fixture |> File.read!() |> JSON.decode!()
    %{fixtures: fixtures}
  end

  test "the egress probe fixture is the argv EgressCheck.bare_args/1 builds", %{
    fixtures: fixtures
  } do
    argv = EgressCheck.bare_args(%{"address" => "192.0.2.1", "port" => 5432})

    # generate.py stands a placeholder in for the probe's script, which the
    # policy does not look at.
    script = Enum.at(argv, Enum.find_index(argv, &(&1 == "-c")) + 1)
    argv = Enum.map(argv, &if(&1 == script, do: "probe", else: &1))

    assert fixtures["egress_probe"]["argv"] == argv, @regenerate
  end

  test "the promotion copy fixture is the argv Promotion.copy_args/5 builds", %{
    fixtures: fixtures
  } do
    # Portal.BuildCache.Staging.name/1 of the slug's entry: <dest>.tmp.<host>.<hex>.
    staging =
      "/var/lib/ncc/build-cache/sha256_deadbeef/" <>
        String.duplicate("b", 64) <> ".tmp.builder-1.0123456789abcdef"

    argv =
      Promotion.copy_args(
        @scratch <> "/out",
        staging,
        String.duplicate("a", 64),
        @image,
        "ncc-promote-0123456789abcdef"
      )

    assert fixtures["promotion_copy"]["argv"] == argv, @regenerate
  end
end
