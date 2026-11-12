defmodule Portal.Repo.Migrations.AddSystemAbi do
  @moduledoc """
  Each target build's toolchain, OTP and ELF facts on its system result, and
  one row per Nerves system release with the toolchain, OTP and library
  table that release was observed to have.

  The unique index on `(system_pkg, version)` is a full one on purpose: a
  partial unique index cannot back an `ON CONFLICT` on those columns, and a
  release still running the old code during the deploy would fail its
  upserts against one.
  """

  use Ecto.Migration

  def up do
    alter table(:catalog_system_results) do
      add(:native, :boolean)
      add(:portable, :boolean)
      add(:elf_needs, :map)
      add(:toolchain_pkg, :text)
      add(:toolchain_version, :text)
      add(:otp_full, :text)
    end

    create table(:catalog_system_abi, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:system_pkg, :text, null: false)
      add(:version, :text, null: false)
      add(:toolchain_pkg, :text)
      add(:toolchain_version, :text)
      add(:series, :text)
      add(:source, :text, null: false)
      add(:otp, :text)
      add(:libs, :map)
      add(:observed_at, :utc_datetime_usec)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(:catalog_system_abi, [:system_pkg, :version],
        name: "catalog_system_abi_unique_release_index"
      )
    )
  end

  def down do
    drop_if_exists(
      unique_index(:catalog_system_abi, [:system_pkg, :version],
        name: "catalog_system_abi_unique_release_index"
      )
    )

    drop(table(:catalog_system_abi))

    alter table(:catalog_system_results) do
      remove(:otp_full)
      remove(:toolchain_version)
      remove(:toolchain_pkg)
      remove(:elf_needs)
      remove(:portable)
      remove(:native)
    end
  end
end
