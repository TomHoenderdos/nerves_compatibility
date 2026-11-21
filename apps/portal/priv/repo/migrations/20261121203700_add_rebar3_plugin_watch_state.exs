defmodule Portal.Repo.Migrations.AddRebar3PluginWatchState do
  @moduledoc """
  `rebar3_plugin_watch_state`: when `Portal.Workers.UpdateCheck` last
  refreshed the rebar3 plugin watch (`key` "refreshed"). One older than
  `Portal.Precompiled.PluginWatch.max_age_hours/0`, or none, withholds every
  build that ran a plugin (review S5 R4).

  A new table only: the release still running during the deploy window
  never reads or writes it.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    create table(:rebar3_plugin_watch_state, primary_key: false) do
      add(:key, :text, null: false, primary_key: true)
      add(:checked_at, :utc_datetime_usec, null: false)
    end
  end

  def down do
    drop(table(:rebar3_plugin_watch_state))
  end
end
