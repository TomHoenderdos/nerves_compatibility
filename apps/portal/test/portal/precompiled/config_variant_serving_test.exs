defmodule Portal.Precompiled.ConfigVariantServingTest do
  # A named config variant of a toolchain build is served only while it
  # records its own config reads and its default build is served: by the
  # format-2 manifest, the package list and the file route alike.
  use Portal.DataCase, async: false

  import Portal.PrecompiledFixtures

  alias Portal.Catalog
  alias Portal.Precompiled.Withheld

  @lv_lock %{
    "phoenix_live_view" => %{"version" => "1.1.0", "checksum" => "lv"},
    "decimal" => %{"version" => "2.1.1", "checksum" => "abc"}
  }

  setup do
    drop_legacy_identity_index!()
    name = "cvserve_#{System.unique_integer([:positive])}"

    default =
      ingest_toolchain_build(name, "1.0.0",
        deps_lock: @lv_lock,
        compile_env: lv_default_env(),
        compile_env_rule: 1
      )

    variant =
      ingest_toolchain_build(name, "1.0.0",
        config_variant: "phx_prod",
        deps_lock: @lv_lock,
        compile_env: overlay_env("phx_prod"),
        compile_env_rule: 1
      )

    assert default.config_variant == "default" and variant.config_variant == "phx_prod"

    %{
      name: name,
      default: default,
      variant: variant,
      default_sha: ebin_sha(default),
      variant_sha: ebin_sha(variant)
    }
  end

  defp ebin_sha(build), do: hd(build.file_manifest["ebin"])["sha256"]

  defp served_variants(name) do
    case Catalog.precompiled_manifest_v2(name) do
      nil ->
        []

      manifest ->
        manifest["versions"]
        |> Map.values()
        |> Enum.flat_map(& &1["builds"])
        |> Enum.filter(&(&1["target"] == "pure_elixir"))
        |> Enum.map(&(&1["build"]["config_variant"] || "default"))
        |> Enum.sort()
    end
  end

  defp revoke!(build) do
    build
    |> Ash.Changeset.for_update(:revoke, %{})
    |> Ash.update!(domain: Catalog)
  end

  # What an old release's or a rollback's upsert leaves: the mark of a run
  # that is no longer the row's own.
  defp clear_mark!(build) do
    Repo.query!(
      "UPDATE catalog_toolchain_builds SET compile_env_run_id = 'tc-stale' WHERE id = $1",
      [Ecto.UUID.dump!(build.id)]
    )
  end

  defp drop_lock!(build) do
    Repo.query!(
      "UPDATE catalog_toolchain_builds SET deps_lock = NULL WHERE id = $1",
      [Ecto.UUID.dump!(build.id)]
    )
  end

  defp with_withheld(packages, fun) do
    old = Application.get_env(:portal, Withheld)
    Application.put_env(:portal, Withheld, packages: packages)

    try do
      fun.()
    after
      if old,
        do: Application.put_env(:portal, Withheld, old),
        else: Application.delete_env(:portal, Withheld)
    end
  end

  test "both served while the default is a served pass", ctx do
    assert served_variants(ctx.name) == ["default", "phx_prod"]
    assert ctx.name in Catalog.packages_with_precompiled_files()
    assert Catalog.published_sha256?(ctx.default_sha)
    assert Catalog.published_sha256?(ctx.variant_sha)
  end

  test "revoking the default hides the variant everywhere", ctx do
    revoke!(ctx.default)
    assert served_variants(ctx.name) == []
    refute ctx.name in Catalog.packages_with_precompiled_files()
    refute Catalog.published_sha256?(ctx.variant_sha)
  end

  test "a default rebuilt as skipped hides the variant", ctx do
    ingest_toolchain_build(ctx.name, "1.0.0",
      status: "skipped",
      deps_lock: @lv_lock,
      compile_env: lv_default_env(),
      compile_env_rule: 1
    )

    assert served_variants(ctx.name) == []
    refute ctx.name in Catalog.packages_with_precompiled_files()
    refute Catalog.published_sha256?(ctx.variant_sha)
  end

  test "a default that lost its mark is withheld, and so is the variant", ctx do
    clear_mark!(ctx.default)
    assert served_variants(ctx.name) == []
    refute ctx.name in Catalog.packages_with_precompiled_files()
    refute Catalog.published_sha256?(ctx.default_sha)
    refute Catalog.published_sha256?(ctx.variant_sha)
  end

  test "a default without a recorded lock is withheld, and so is the variant", ctx do
    drop_lock!(ctx.default)
    assert served_variants(ctx.name) == []
    refute ctx.name in Catalog.packages_with_precompiled_files()
    refute Catalog.published_sha256?(ctx.variant_sha)
  end

  test "with nothing withheld, an unmarked default is served and so is a marked variant", ctx do
    with_withheld([], fn ->
      clear_mark!(ctx.default)
      assert served_variants(ctx.name) == ["default", "phx_prod"]
      assert Catalog.published_sha256?(ctx.variant_sha)
    end)
  end

  test "a named row whose mark does not vouch for it is not served, whatever the withheld list",
       ctx do
    for packages <- [[], ["phoenix_live_view"]] do
      with_withheld(packages, fn ->
        clear_mark!(ctx.variant)
        assert served_variants(ctx.name) == ["default"]
        assert ctx.name in Catalog.packages_with_precompiled_files()
        assert Catalog.published_sha256?(ctx.default_sha)
        refute Catalog.published_sha256?(ctx.variant_sha)
      end)
    end
  end

  test "a named row without a rule 1 mark is not served", ctx do
    with_withheld([], fn ->
      Repo.query!(
        "UPDATE catalog_toolchain_builds SET compile_env_rule = NULL WHERE id = $1",
        [Ecto.UUID.dump!(ctx.variant.id)]
      )

      assert served_variants(ctx.name) == ["default"]
      refute Catalog.published_sha256?(ctx.variant_sha)
    end)
  end

  test "the default is unaffected by its variants", ctx do
    revoke!(ctx.variant)
    assert served_variants(ctx.name) == ["default"]
    assert Catalog.published_sha256?(ctx.default_sha)
    refute Catalog.published_sha256?(ctx.variant_sha)
  end

  test "a variant is served only beside the default of its own build", ctx do
    # Another builder version's default does not vouch for it.
    with_withheld([], fn ->
      Repo.query!(
        "UPDATE catalog_toolchain_builds SET builder_version = 0 WHERE id = $1",
        [Ecto.UUID.dump!(ctx.default.id)]
      )

      assert served_variants(ctx.name) == ["default"]
      refute Catalog.published_sha256?(ctx.variant_sha)
    end)
  end

  test "the package list counts a package served only through its variant's file", ctx do
    # The default's files are gone, the default is still a served pass:
    # the package is listed for the variant alone.
    Repo.query!(
      "DELETE FROM catalog_artifact_memberships WHERE toolchain_build_id = $1",
      [Ecto.UUID.dump!(ctx.default.id)]
    )

    assert ctx.name in Catalog.packages_with_precompiled_files()
    assert Catalog.published_sha256?(ctx.variant_sha)
  end

  describe "config_variant_served?/2" do
    test "a default build always", ctx do
      assert Withheld.config_variant_served?(ctx.default, [])
    end

    test "a named one beside its served default, marked", ctx do
      assert Withheld.config_variant_served?(ctx.variant, [ctx.default, ctx.variant])
      refute Withheld.config_variant_served?(ctx.variant, [ctx.variant])
      refute Withheld.config_variant_served?(ctx.variant, [%{ctx.default | status: :skipped}])

      refute Withheld.config_variant_served?(ctx.variant, [
               %{ctx.default | revoked_at: DateTime.utc_now()}
             ])

      refute Withheld.config_variant_served?(ctx.variant, [%{ctx.default | variant: :without}])
      refute Withheld.config_variant_served?(ctx.variant, [%{ctx.default | toolchain: "1.20/29"}])
      refute Withheld.config_variant_served?(ctx.variant, [%{ctx.default | version: "1.0.1"}])

      refute Withheld.config_variant_served?(%{ctx.variant | compile_env_run_id: "other"}, [
               ctx.default
             ])
    end
  end
end
