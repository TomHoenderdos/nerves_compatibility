defmodule Portal.Repo.Migrations.AddModuleIndex do
  @moduledoc """
  The module index (`Portal.Catalog.ModuleIndex`, otp-probe round 3,
  R2-1): the modules the latest release of each package with 1,000 or more
  recent downloads defines, and which release each package was read at.
  Ingest refuses a build whose recorded declared-absent probe names a module
  another such package defines. New tables only, which the release running
  during the deploy window never reads.
  """

  use Ecto.Migration

  def change do
    create table(:catalog_module_definers, primary_key: false) do
      add :module, :text, null: false, primary_key: true
      add :package, :text, null: false, primary_key: true
    end

    create index(:catalog_module_definers, [:package])

    create table(:catalog_module_index_packages, primary_key: false) do
      add :package, :text, null: false, primary_key: true
      add :version, :text, null: false
      add :modules, :integer, null: false
      add :refreshed_at, :utc_datetime_usec, null: false
    end
  end
end
