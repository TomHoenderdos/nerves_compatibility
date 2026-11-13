defmodule Portal.Repo.Migrations.AddCompileInputs do
  @moduledoc """
  A build's compile-time inputs (`Compatibility.CompileInputs`), on toolchain
  builds and system results.
  """

  use Ecto.Migration

  # Add-only and nullable, so the release still running during the deploy
  # window keeps inserting rows without the column (they read as nil). A
  # bounded lock wait fails the migration, and the deploy, loudly rather than
  # queueing every writer behind a long read. SET LOCAL lasts for the
  # migration's own transaction only.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_toolchain_builds) do
      add(:compile_inputs, {:array, :map})
    end

    alter table(:catalog_system_results) do
      add(:compile_inputs, {:array, :map})
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_system_results) do
      remove(:compile_inputs)
    end

    alter table(:catalog_toolchain_builds) do
      remove(:compile_inputs)
    end
  end
end
