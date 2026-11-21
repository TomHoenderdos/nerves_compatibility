defmodule Portal.Workers.ModuleIndexRefreshTest do
  use Portal.DataCase, async: true

  alias Portal.Workers.ModuleIndexRefresh

  test "a run with nothing to read is ok" do
    assert ModuleIndexRefresh.perform(%Oban.Job{args: %{"limit" => 0}}) == :ok
  end

  test "it is on the weekly crontab, after the metadata refresh" do
    plugins = Application.fetch_env!(:portal, Oban)[:plugins]
    {_, cron} = Enum.find(plugins, &match?({Oban.Plugins.Cron, _}, &1))
    assert {"17 6 * * 1", ModuleIndexRefresh} in cron[:crontab]
  end
end
