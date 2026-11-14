defmodule Portal.Catalog.WorldConfigVariantsTest do
  # A world build's config variants: a served `world_phx` default whose
  # compile read LiveView's config wants its `phx_*` variants like any
  # default, and a named world row is served beside its default, in
  # `builds_closure`. Not async: swaps the `Portal.Toolchains` application
  # env and drops the legacy identity index inside the sandbox.
  use Portal.DataCase, async: false

  import Portal.PrecompiledFixtures

  alias Portal.Catalog

  @world_lock %{
    "jason" => %{"version" => "1.4.4", "checksum" => "j"},
    "decimal" => %{"version" => "2.3.0", "checksum" => "d"}
  }

  setup do
    previous = Application.fetch_env!(:portal, Portal.Toolchains)

    Application.put_env(
      :portal,
      Portal.Toolchains,
      previous
      |> Keyword.merge(
        builder_version: 1,
        images: [%{toolchain: "1.19/28", image: "ncc-worker:elixir-1.19-otp-28"}]
      )
      |> Keyword.drop([:config_variants, :worlds, :world_top_packages])
    )

    on_exit(fn -> Application.put_env(:portal, Portal.Toolchains, previous) end)
    drop_legacy_identity_index!()
    :ok
  end

  defp name, do: "lvworld_#{System.unique_integer([:positive])}"

  defp world_default!(name) do
    ingest_toolchain_build(name, "1.0.0",
      variant: :world_phx,
      deps_lock: @world_lock,
      compile_env: lv_default_env(),
      compile_env_rule: 1
    )
  end

  defp named(name) do
    for %{package: ^name, config_variant: cv, variant: variant} <-
          Catalog.toolchain_backlog("1.19/28", 1, 50, backfill: []),
        cv != "default",
        do: {variant, cv}
  end

  test "a served world_phx default wants its config variants, phx_dev among them" do
    {:ok, _} = Portal.Settings.save(%{world_variants_enabled: true})
    name = name()
    assert %{status: :pass} = world_default!(name)

    assert Enum.sort(named(name)) == [
             {:world_phx, "phx_dev"},
             {:world_phx, "phx_prod"},
             {:world_phx, "phx_test"}
           ]
  end

  test "while world builds are off, a world default wants no config variant" do
    name = name()
    world_default!(name)
    assert named(name) == []
  end

  test "a named world row is served beside its default, in builds_closure only" do
    name = name()
    world_default!(name)

    named =
      ingest_toolchain_build(name, "1.0.0",
        variant: :world_phx,
        deps_lock: @world_lock,
        config_variant: "phx_dev",
        compile_env: overlay_env("phx_dev"),
        compile_env_rule: 1
      )

    assert %{status: :pass, variant: :world_phx, config_variant: "phx_dev"} = named

    version = Catalog.precompiled_manifest_v2(name)["versions"]["1.0.0"]

    assert version["builds"] == []

    assert version["builds_closure"]
           |> Enum.map(&{&1["build"]["variant"], &1["build"]["config_variant"]})
           |> Enum.sort() == [{"world_phx", nil}, {"world_phx", "phx_dev"}]
  end

  test "a named world row whose world default is not served is not served" do
    name = name()

    ingest_toolchain_build(name, "1.0.0",
      variant: :world_phx,
      deps_lock: @world_lock,
      config_variant: "phx_dev",
      compile_env: overlay_env("phx_dev"),
      compile_env_rule: 1
    )

    # A with default of the same version does not stand in for it.
    ingest_toolchain_build(name, "1.0.0", compile_env: lv_default_env(), compile_env_rule: 1)

    version = Catalog.precompiled_manifest_v2(name)["versions"]["1.0.0"]
    refute Map.has_key?(version, "builds_closure")
  end
end
