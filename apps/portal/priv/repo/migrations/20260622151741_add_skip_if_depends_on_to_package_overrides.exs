defmodule Portal.Repo.Migrations.AddSkipIfDependsOnToPackageOverrides do
  use Ecto.Migration

  def change do
    alter table(:catalog_package_overrides) do
      add(:skip_if_depends_on, {:array, :text}, null: false, default: [])
    end
  end
end
