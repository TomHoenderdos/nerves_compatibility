defmodule Portal.Workers.ReleaseIndexRefreshTest do
  # S10 round 5: the module index per release, run daily (failed releases
  # tried again) and hourly when the update check sees a new release.
  use Portal.DataCase, async: true

  alias Portal.Workers.ReleaseIndexRefresh

  test "a run with nothing to read is ok" do
    assert ReleaseIndexRefresh.perform(%Oban.Job{args: %{"limit" => 0}}) == :ok

    assert ReleaseIndexRefresh.perform(%Oban.Job{args: %{"incremental" => true, "limit" => 0}}) ==
             :ok
  end

  test "one daily and one incremental job may wait, not two of either" do
    assert {:ok, %Oban.Job{conflict?: false}} = Oban.insert(ReleaseIndexRefresh.new(%{}))
    assert {:ok, %Oban.Job{conflict?: true}} = Oban.insert(ReleaseIndexRefresh.new(%{}))

    assert {:ok, %Oban.Job{conflict?: false}} =
             Oban.insert(ReleaseIndexRefresh.new(%{"incremental" => true}))

    assert {:ok, %Oban.Job{conflict?: true}} =
             Oban.insert(ReleaseIndexRefresh.new(%{"incremental" => true}))
  end

  test "it is on the daily crontab" do
    plugins = Application.fetch_env!(:portal, Oban)[:plugins]
    {_, cron} = Enum.find(plugins, &match?({Oban.Plugins.Cron, _}, &1))
    assert {"37 6 * * *", ReleaseIndexRefresh} in cron[:crontab]
  end
end
