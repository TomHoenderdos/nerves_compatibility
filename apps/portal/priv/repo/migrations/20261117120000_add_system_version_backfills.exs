defmodule Portal.Repo.Migrations.AddSystemVersionBackfills do
  @moduledoc """
  The audit trail of `Portal.Catalog.SystemVersionBackfill`: one row per
  system result it gave a `system_version`, with the value, the evidence and
  the call's `filled_at`, which `undo/1` takes. Rows are only ever inserted
  and marked `undone_at`.
  """

  use Ecto.Migration

  # A new table: nothing the running release reads or writes changes.
  def up do
    create table(:catalog_system_version_backfills, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:system_result_id, :uuid, null: false)
      add(:system_pkg, :text, null: false)
      add(:system_version, :text, null: false)
      add(:evidence, :map)
      add(:filled_at, :naive_datetime_usec, null: false)
      add(:undone_at, :naive_datetime_usec)
    end

    create(index(:catalog_system_version_backfills, [:filled_at]))
    create(index(:catalog_system_version_backfills, [:system_result_id]))
  end

  def down do
    drop(table(:catalog_system_version_backfills))
  end
end
