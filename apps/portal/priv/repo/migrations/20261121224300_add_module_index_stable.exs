defmodule Portal.Repo.Migrations.AddModuleIndexStable do
  @moduledoc """
  The latest stable release of each module index candidate, beside the
  registry's last version (otp-probe final round, R6-1): when the last
  version is a prerelease, Mix resolves the stable one by default, and a
  module only the stable defines must be indexed too. NULL where the
  registry lists no stable release. New nullable columns only.
  """

  use Ecto.Migration

  def change do
    alter table(:catalog_module_index_candidates) do
      add :stable, :text
    end

    alter table(:catalog_module_index_packages) do
      add :stable, :text
    end
  end
end
