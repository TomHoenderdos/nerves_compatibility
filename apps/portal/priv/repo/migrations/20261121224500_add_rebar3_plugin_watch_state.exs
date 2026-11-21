defmodule Portal.Repo.Migrations.AddRebar3PluginWatchState do
  @moduledoc """
  `rebar3_plugin_watch_state`: when `Portal.Workers.UpdateCheck` last
  refreshed the rebar3 plugin watch (`key` "refreshed"). One older than
  `Portal.Precompiled.PluginWatch.max_age_hours/0`, or none, withholds every
  build that ran a plugin (review S5 R4).

  A new table only: the release still running during the deploy window
  never reads or writes it.

  Versioned after the OTP probe's migrations (main up to 20261121224300),
  which production applied first. `if_not_exists` throughout: a test
  database that applied these tables under their earlier versions
  (20261121190000, 20261121203700, 20261121211500) migrates cleanly.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    create_if_not_exists table(:rebar3_plugin_watch_state, primary_key: false) do
      add(:key, :text, null: false, primary_key: true)
      add(:checked_at, :utc_datetime_usec, null: false)
    end
  end

  def down do
    drop(table(:rebar3_plugin_watch_state))
  end
end
