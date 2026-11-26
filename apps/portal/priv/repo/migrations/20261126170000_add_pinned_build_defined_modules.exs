defmodule Portal.Repo.Migrations.AddPinnedBuildDefinedModules do
  @moduledoc """
  S10 fix round 1: `catalog_pinned_builds.defined_modules`, as
  `catalog_toolchain_builds.defined_modules`: a passing pinned host build's
  modules its compile defined outside its ebin, served in format 2 beside
  the ebin, so a dependency matched only by a pinned build has an exact
  module list for client 0.10 too.
  """

  use Ecto.Migration

  # Add-only and nullable, with no index, as the toolchain column.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_pinned_builds) do
      add(:defined_modules, {:array, :text})
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_pinned_builds) do
      remove(:defined_modules)
    end
  end
end
