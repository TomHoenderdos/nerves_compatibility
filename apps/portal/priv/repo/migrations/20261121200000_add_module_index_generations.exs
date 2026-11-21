defmodule Portal.Repo.Migrations.AddModuleIndexGenerations do
  @moduledoc """
  The module index's run generations (otp-probe round 5, R3-1): the index
  is usable only when its latest run indexed every candidate, so each run
  is a row with its own completeness, and each package row names the run
  that last confirmed it. Each package's application name (R3-9), and the
  rows a recheck after a complete run withheld, for its undo (R3-5a). New
  tables and new nullable columns only.
  """

  use Ecto.Migration

  def change do
    create table(:catalog_module_index_runs, primary_key: false) do
      add :generation, :bigserial, primary_key: true
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      add :candidates, :integer, null: false
      add :indexed, :integer, null: false, default: 0
      add :unchanged, :integer, null: false, default: 0
      add :failed, :integer, null: false, default: 0
      add :complete, :boolean, null: false, default: false
      add :withheld, :integer
    end

    alter table(:catalog_module_index_packages) do
      add :generation, :bigint
      add :app, :text
    end

    create table(:catalog_module_index_withheld, primary_key: false) do
      add :generation, :bigint, null: false, primary_key: true
      add :kind, :text, null: false, primary_key: true
      add :row_id, :uuid, null: false, primary_key: true
      add :withheld_at, :utc_datetime_usec, null: false
      add :reason, :text, null: false
    end
  end
end
