defmodule Portal.Repo.Migrations.AddToolchainBuildDefinedModules do
  @moduledoc """
  S10 fix round 1: `catalog_toolchain_builds.defined_modules`, the modules a
  passing build's compile defined outside its ebin
  (`NccWorker.Portability.DefinedModules`), served in format 2 beside the
  ebin as the package's exact module list for client 0.10.
  """

  use Ecto.Migration

  # Add-only and nullable, with no index: the release still running during
  # the deploy window never writes the column. A bounded lock wait fails the
  # migration, and the deploy, loudly. SET LOCAL lasts for the migration's
  # own transaction only, so it must keep its DDL transaction.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_toolchain_builds) do
      add(:defined_modules, {:array, :text})
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_toolchain_builds) do
      remove(:defined_modules)
    end
  end
end
