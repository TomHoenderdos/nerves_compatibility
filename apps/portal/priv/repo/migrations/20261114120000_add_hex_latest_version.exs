defmodule Portal.Repo.Migrations.AddHexLatestVersion do
  @moduledoc """
  `catalog_packages.hex_latest_version`: the Hex registry's latest version of
  a tracked package whose patch release earned no full run
  (`Portal.Workers.UpdateCheck`), nominated for a toolchain build.
  """

  use Ecto.Migration

  # Add-only and nullable, so the release still running during the deploy
  # window keeps working without the column. A bounded lock wait fails the
  # migration, and the deploy, loudly rather than queueing every writer
  # behind a long read. SET LOCAL lasts for the migration's own transaction
  # only.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_packages) do
      add(:hex_latest_version, :text)
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_packages) do
      remove(:hex_latest_version)
    end
  end
end
