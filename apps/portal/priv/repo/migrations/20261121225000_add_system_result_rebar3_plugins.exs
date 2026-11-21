defmodule Portal.Repo.Migrations.AddSystemResultRebar3Plugins do
  @moduledoc """
  The rebar3 plugin releases a firmware target's build ran (`result.json`'s
  per-system `rebar3_plugins`, `NccWorker.FirmwarePlugins`), kept on its row
  so the firmware results that ran a plugin can be found.

  Versioned after main's OTP probe and plugin watch migrations (up to
  20261121224600), which production applied first, and `add_if_not_exists`,
  so a test database that applied it under its earlier version
  (20261121220000) migrates cleanly.
  """

  use Ecto.Migration

  # Add-only and nullable, with no index, so the release still running during
  # the deploy window keeps inserting and copying system results without the
  # column (its rows read as unrecorded). A bounded lock wait fails the
  # migration, and the deploy, loudly rather than queueing every writer behind
  # a long read. SET LOCAL lasts for the migration's own transaction only, so
  # this migration must keep its DDL transaction.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_system_results) do
      add_if_not_exists(:rebar3_plugins, {:array, :map})
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_system_results) do
      remove_if_exists(:rebar3_plugins, {:array, :map})
    end
  end
end
