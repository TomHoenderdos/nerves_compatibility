defmodule Portal.Repo.Migrations.AddSystemResultBuildRoot do
  @moduledoc """
  A firmware target's baked build path verdict (`result.json`'s per-system
  `build_root`, `NccWorker.FirmwareBuildRoot`), kept on its row so a newer
  run's refusal can withdraw older runs' builds of the same version and
  target (`Portal.Precompiled.FirmwareRefusal`).
  """

  use Ecto.Migration

  # Add-only and nullable, with no index, so the release still running during
  # the deploy window keeps inserting and copying system results without the
  # column (its rows read as unjudged, never as a refusal). A bounded lock
  # wait fails the migration, and the deploy, loudly rather than queueing
  # every writer behind a long read. SET LOCAL lasts for the migration's own
  # transaction only, so this migration must keep its DDL transaction.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_system_results) do
      add(:build_root, :map)
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_system_results) do
      remove(:build_root)
    end
  end
end
