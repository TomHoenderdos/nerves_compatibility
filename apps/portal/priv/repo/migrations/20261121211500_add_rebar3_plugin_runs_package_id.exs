defmodule Portal.Repo.Migrations.AddRebar3PluginRunsPackageId do
  @moduledoc """
  `rebar3_plugin_runs.package_id`: the catalog package whose build the run
  made, so a change to the plugin watch renders again only the packages
  that ran a plugin it touches (review S5 N8;
  `Portal.Precompiled.PluginWatch.fingerprint_sql/0`).

  The table is new in the same release and empty when this runs, and the
  release still running during the deploy window never reads or writes it.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:rebar3_plugin_runs) do
      add(:package_id, :uuid, null: false)
    end

    create(index(:rebar3_plugin_runs, [:package_id]))
  end

  def down do
    drop(index(:rebar3_plugin_runs, [:package_id]))

    alter table(:rebar3_plugin_runs) do
      remove(:package_id)
    end
  end
end
