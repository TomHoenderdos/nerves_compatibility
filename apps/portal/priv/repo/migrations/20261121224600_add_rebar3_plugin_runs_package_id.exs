defmodule Portal.Repo.Migrations.AddRebar3PluginRunsPackageId do
  @moduledoc """
  `rebar3_plugin_runs.package_id`: the catalog package whose build the run
  made, so a change to the plugin watch renders again only the packages
  that ran a plugin it touches (review S5 N8;
  `Portal.Precompiled.PluginWatch.fingerprint_sql/0`).

  The table is new in the same release and empty when this runs, and the
  release still running during the deploy window never reads or writes it.

  Versioned after the OTP probe's migrations (main up to 20261121224300),
  which production applied first. `if_not_exists` throughout: a test
  database that applied these tables under their earlier versions
  (20261121190000, 20261121203700, 20261121211500) migrates cleanly.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:rebar3_plugin_runs) do
      add_if_not_exists(:package_id, :uuid, null: false)
    end

    create_if_not_exists(index(:rebar3_plugin_runs, [:package_id]))
  end

  def down do
    drop(index(:rebar3_plugin_runs, [:package_id]))

    alter table(:rebar3_plugin_runs) do
      remove(:package_id)
    end
  end
end
