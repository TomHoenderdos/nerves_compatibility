defmodule Portal.Repo.Migrations.AddSystemResultPublishedVariants do
  @moduledoc """
  The other builds a firmware target publishes beside its own
  (`Portal.Catalog.SystemResult.published_variants`): kept on the target's
  row, so stats, coverage and the latest status, which count rows, never
  see one.
  """

  use Ecto.Migration

  # Add-only and nullable, so the release still running during the deploy
  # window keeps inserting and copying system results without the column
  # (they read as nil: the target publishes its own build alone, as before).
  # A bounded lock wait fails the migration, and the deploy, loudly rather
  # than queueing every writer behind a long read. SET LOCAL lasts for the
  # migration's own transaction only, so this migration must keep its DDL
  # transaction.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_system_results) do
      add(:published_variants, {:array, :map})
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_system_results) do
      remove(:published_variants)
    end
  end
end
