defmodule Portal.Catalog.ToolchainBuildTest do
  use Portal.DataCase, async: false
  require Ash.Query
  alias Portal.Catalog.{ArtifactMembership, ToolchainBuild}

  setup do
    {:ok, pkg} =
      Portal.Catalog.Package
      |> Ash.Changeset.for_create(:upsert, %{name: "jason", description: "d"})
      |> Ash.create(domain: Portal.Catalog)

    %{pkg: pkg}
  end

  test "upsert replaces the row for the same identity", %{pkg: pkg} do
    attrs = %{
      package_id: pkg.id,
      version: "1.4.5",
      toolchain: "1.19/28",
      builder_version: 1,
      status: :error,
      reason: "timeout"
    }

    {:ok, a} =
      ToolchainBuild
      |> Ash.Changeset.for_create(:upsert, attrs)
      |> Ash.create(domain: Portal.Catalog)

    {:ok, b} =
      ToolchainBuild
      |> Ash.Changeset.for_create(:upsert, %{attrs | status: :pass, reason: nil})
      |> Ash.create(domain: Portal.Catalog)

    assert a.id == b.id and b.status == :pass and b.reason == nil
  end

  test "a membership needs exactly one owner and re-ingest does not duplicate", %{pkg: pkg} do
    {:ok, tb} =
      ToolchainBuild
      |> Ash.Changeset.for_create(:create, %{
        package_id: pkg.id,
        version: "1.4.5",
        toolchain: "1.19/28",
        builder_version: 1,
        status: :pass
      })
      |> Ash.create(domain: Portal.Catalog)

    row = %{sha256: String.duplicate("a", 64), toolchain_build_id: tb.id}

    # Ingesting the same build twice. Each call is its own statement: Postgres
    # refuses one `ON CONFLICT DO UPDATE` that hits the same row twice, which is
    # why ingestion dedups its entries before the bulk create.
    for _ <- 1..2 do
      assert %Ash.BulkResult{status: :success} =
               Ash.bulk_create([row], ArtifactMembership, :upsert_toolchain,
                 domain: Portal.Catalog,
                 upsert?: true,
                 upsert_identity: :unique_toolchain_build_sha256,
                 upsert_fields: [:sha256],
                 return_errors?: true
               )
    end

    assert 1 ==
             ArtifactMembership
             |> Ash.Query.filter(toolchain_build_id == ^tb.id)
             |> Ash.count!(domain: Portal.Catalog)

    assert {:error, _} =
             ArtifactMembership
             |> Ash.Changeset.for_create(:create, %{sha256: String.duplicate("b", 64)})
             |> Ash.create(domain: Portal.Catalog)
  end

  test "an older release's bare ON CONFLICT on system result and sha still matches an index" do
    # The build host that predates toolchain builds keeps ingesting during a
    # deploy, with no `WHERE` on its conflict target. Postgres resolves the
    # arbiter index when it plans the statement, so inserting zero rows is
    # enough: a partial index here would raise "there is no unique or
    # exclusion constraint matching the ON CONFLICT specification".
    assert %{num_rows: 0} =
             Portal.Repo.query!("""
             INSERT INTO catalog_artifact_memberships (id, sha256, system_result_id)
             SELECT gen_random_uuid(), 'x', NULL WHERE false
             ON CONFLICT (system_result_id, sha256) DO NOTHING
             """)
  end
end
