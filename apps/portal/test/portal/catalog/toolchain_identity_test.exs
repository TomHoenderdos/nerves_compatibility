defmodule Portal.Catalog.ToolchainIdentityTest do
  # Not async: drops an index inside the sandbox transaction.
  use Portal.DataCase, async: false

  import Portal.PrecompiledFixtures

  alias Portal.Catalog.{ToolchainBuild, ToolchainIdentity}
  alias Portal.Repo

  defp row!(package_id, config_variant) do
    ToolchainBuild
    |> Ash.Changeset.for_create(:upsert, %{
      package_id: package_id,
      version: "1.0.0",
      toolchain: "1.19/28",
      builder_version: 1,
      variant: :with,
      config_variant: config_variant,
      status: :pass,
      run_id: "tc-#{config_variant}"
    })
    |> Ash.create!(domain: Portal.Catalog)
  end

  setup do
    build = ingest_toolchain_build("idpkg", "0.1.0")
    %{package_id: build.package_id}
  end

  test "existing and new rows are the default variant", %{package_id: id} do
    assert row!(id, "default").config_variant == "default"
  end

  test "an upsert shaped like the release before config variants still lands on the default row",
       %{package_id: id} do
    row = row!(id, "default")

    # What the pre-variant release sends: ON CONFLICT on the five-column identity.
    Repo.query!(
      """
      INSERT INTO catalog_toolchain_builds (package_id, version, toolchain, builder_version, variant, status)
      VALUES ($1, '1.0.0', '1.19/28', 1, 'with', 'skipped')
      ON CONFLICT (package_id, version, toolchain, builder_version, variant)
      DO UPDATE SET status = EXCLUDED.status
      """,
      [Ecto.UUID.dump!(id)]
    )

    reloaded = Ash.get!(ToolchainBuild, row.id, domain: Portal.Catalog)
    assert reloaded.status == :skipped
    assert reloaded.config_variant == "default"
  end

  test "while the legacy index exists the gate is shut and a named row cannot be stored",
       %{package_id: id} do
    row!(id, "default")
    refute ToolchainIdentity.config_variants_ready?()
    assert_raise Ash.Error.Invalid, fn -> row!(id, "phx_prod") end
  end

  test "once the legacy index is gone the gate opens and both rows coexist", %{package_id: id} do
    drop_legacy_identity_index!()
    assert ToolchainIdentity.config_variants_ready?()
    a = row!(id, "default")
    b = row!(id, "phx_prod")
    assert a.id != b.id
    # The six-column upsert replaces its own row only.
    assert row!(id, "phx_prod").id == b.id
  end

  test "an unknown config variant is refused", %{package_id: id} do
    assert_raise Ash.Error.Invalid, fn -> row!(id, "phx_staging") end
  end
end
