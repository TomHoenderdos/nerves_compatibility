defmodule Portal.Repo.Migrations.AddRebar3PluginWatch do
  @moduledoc """
  `rebar3_plugin_runs`: the rebar3 plugin releases each run ran (its build's
  `compile_observations.rebar3_plugins`), by run id, so an earlier build kept
  on a row (its own run id) is found as well as the row's own build.
  `rebar3_plugin_watch`: the reviewed plugin packages Hex now has a release
  of outside the review (`Compatibility.RebarPlugins`), which
  `Portal.Workers.UpdateCheck` writes. A build whose run ran one of them is
  withheld (`Portal.Precompiled.PluginWatch`).

  New tables only: the release still running during the deploy window never
  reads or writes them.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    create table(:rebar3_plugin_runs, primary_key: false) do
      add(:run_id, :text, null: false)
      add(:package, :text, null: false)
      add(:version, :text, null: false)
      add(:sha256, :text)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(unique_index(:rebar3_plugin_runs, [:run_id, :package, :version]))
    create(index(:rebar3_plugin_runs, [:package]))

    create table(:rebar3_plugin_watch, primary_key: false) do
      add(:package, :text, null: false, primary_key: true)
      add(:unreviewed, {:array, :text}, null: false)
      add(:checked_at, :utc_datetime_usec, null: false)
    end
  end

  def down do
    drop(table(:rebar3_plugin_watch))
    drop(table(:rebar3_plugin_runs))
  end
end
