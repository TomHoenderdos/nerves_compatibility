defmodule Portal.Repo.Migrations.AddModuleIndexCandidates do
  @moduledoc """
  The module index's candidates and their latest releases as the Hex
  registry listed them at a run's start (otp-probe round 6, R5-1):
  `catalog_packages.hex_latest_version` is a nomination column, NULL for
  almost every package, so the index keeps the registry's latest version
  itself. A NULL `version` is a candidate the registry does not list. New
  table only.
  """

  use Ecto.Migration

  def change do
    create table(:catalog_module_index_candidates, primary_key: false) do
      add :package, :text, null: false, primary_key: true
      add :version, :text
      add :generation, :bigint, null: false
    end
  end
end
