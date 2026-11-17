defmodule Portal.Repo.Migrations.AddDeterministicMembershipIndexes do
  @moduledoc """
  The two `catalog_artifact_memberships` indexes for deterministic siblings,
  and the validation of the widened `one_owner` check, done without blocking
  the table, as `AddHostNativeMembershipIndexes` did: both indexes are built
  `CONCURRENTLY`, and `VALIDATE CONSTRAINT` scans under SHARE UPDATE
  EXCLUSIVE, which reads and writes pass through.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:catalog_artifact_memberships, [:deterministic_build_id], concurrently: true)
    )

    create_if_not_exists(
      unique_index(:catalog_artifact_memberships, [:deterministic_build_id, :sha256],
        name: "catalog_artifact_memberships_deterministic_build_sha256_index",
        concurrently: true
      )
    )

    execute("ALTER TABLE catalog_artifact_memberships VALIDATE CONSTRAINT one_owner")
  end

  def down do
    drop_if_exists(
      index(:catalog_artifact_memberships, [:deterministic_build_id, :sha256],
        name: "catalog_artifact_memberships_deterministic_build_sha256_index",
        concurrently: true
      )
    )

    drop_if_exists(
      index(:catalog_artifact_memberships, [:deterministic_build_id], concurrently: true)
    )
  end
end
