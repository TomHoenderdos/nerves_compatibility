defmodule Portal.Repo.Migrations.AddToolchainBuildEarlierBuilds do
  @moduledoc """
  The builds of a toolchain build identity that a rebuild with another
  dependency lock replaced (`Portal.Catalog.ToolchainBuild.EarlierBuilds`):
  kept on the row, so a project still locked at the older dependency keeps
  its hit, and every reader that counts rows never sees one.
  """

  use Ecto.Migration

  # Add-only and nullable, so the release still running during the deploy
  # window (and a builder not yet deployed) keeps upserting rows without the
  # column: its upsert never names it, so what is stored there stays. A
  # bounded lock wait fails the migration, and the deploy, loudly rather than
  # queueing every writer behind a long read. SET LOCAL lasts for the
  # migration's own transaction only, so this migration must keep its DDL
  # transaction.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_toolchain_builds) do
      add(:earlier_builds, {:array, :map})
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_toolchain_builds) do
      remove(:earlier_builds)
    end
  end
end
