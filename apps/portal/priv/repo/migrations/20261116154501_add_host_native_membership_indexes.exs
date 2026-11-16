defmodule Portal.Repo.Migrations.AddHostNativeMembershipIndexes do
  @moduledoc """
  The two `catalog_artifact_memberships` indexes for host-native builds, and
  the validation of the widened `one_owner` check, done without blocking the
  table: millions of membership rows sit behind every manifest and file the
  portal serves, and the release still running during the deploy window
  keeps reading and writing them.

    * both indexes are built `CONCURRENTLY`, which takes no lock that stops
      reads or writes, and so cannot run inside a transaction;
    * `VALIDATE CONSTRAINT` scans under SHARE UPDATE EXCLUSIVE, which reads
      and writes pass through, for the check
      `AddHostNativeBuilds` added NOT VALID.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:catalog_artifact_memberships, [:host_native_build_id], concurrently: true)
    )

    create_if_not_exists(
      unique_index(:catalog_artifact_memberships, [:host_native_build_id, :sha256],
        name: "catalog_artifact_memberships_host_native_build_sha256_index",
        concurrently: true
      )
    )

    execute("ALTER TABLE catalog_artifact_memberships VALIDATE CONSTRAINT one_owner")
  end

  def down do
    drop_if_exists(
      index(:catalog_artifact_memberships, [:host_native_build_id, :sha256],
        name: "catalog_artifact_memberships_host_native_build_sha256_index",
        concurrently: true
      )
    )

    drop_if_exists(
      index(:catalog_artifact_memberships, [:host_native_build_id], concurrently: true)
    )
  end
end
