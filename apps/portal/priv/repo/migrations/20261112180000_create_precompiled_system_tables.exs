defmodule Portal.Repo.Migrations.CreatePrecompiledSystemTables do
  @moduledoc """
  The systems tables signed batches named (`Portal.Precompiled.SystemAbi`),
  by the SHA-256 of their bytes. Rows are only ever inserted.
  """

  use Ecto.Migration

  def up do
    create table(:precompiled_system_tables, primary_key: false) do
      add(:sha256, :text, null: false, primary_key: true)
      add(:body, :text, null: false)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end
  end

  def down do
    drop(table(:precompiled_system_tables))
  end
end
