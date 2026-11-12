defmodule Portal.Repo.Migrations.AddSystemAbiBackfill do
  @moduledoc """
  What the system ABI backfill and observer need to stay bounded:

    * `catalog_system_results.elf_checked_at`: set when the backfill read a
      result's priv files, so one whose blob is missing is not read again;
    * `catalog_system_abi_attempts`: one row per system release a
      `system_abi` run was queued for, with when and, once it ran, the
      error it reported. A release is asked at most once a day, and never
      again after an error no retry can fix.
  """

  use Ecto.Migration

  def up do
    alter table(:catalog_system_results) do
      add(:elf_checked_at, :utc_datetime_usec)
    end

    create table(:catalog_system_abi_attempts, primary_key: false) do
      add(:system_pkg, :text, null: false, primary_key: true)
      add(:version, :text, null: false, primary_key: true)
      add(:attempted_at, :utc_datetime_usec, null: false)
      add(:error, :text)
      add(:permanent, :boolean, null: false, default: false)
    end
  end

  def down do
    drop(table(:catalog_system_abi_attempts))

    alter table(:catalog_system_results) do
      remove(:elf_checked_at)
    end
  end
end
