defmodule Portal.Workers.ReleaseIndexRefreshTest do
  # S10 round 5: the module index per release, run daily (failed releases
  # tried again) and hourly when the update check sees a new release.
  use Portal.DataCase, async: true

  import Ecto.Query, only: [from: 2]

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

  # Re-review R5-1: the hourly check inserted a second run beside an
  # executing one, which started where the first one was and read the same
  # releases again. Now a run that starts beside another does not read.
  test "a refresh that starts while another executes does not read" do
    {:ok, running} = Oban.insert(ReleaseIndexRefresh.new(%{"incremental" => true}))
    executing = fn at -> [state: "executing", attempted_at: at] end

    Repo.update_all(from(j in Oban.Job, where: j.id == ^running.id),
      set: executing.(DateTime.utc_now())
    )

    # The hourly insert beside it, and the daily one.
    {:ok, hourly} = Oban.insert(ReleaseIndexRefresh.new(%{"incremental" => true}))
    refute hourly.conflict?
    assert ReleaseIndexRefresh.perform(hourly) == {:cancel, :another_refresh_running}

    {:ok, daily} = Oban.insert(ReleaseIndexRefresh.new(%{}))
    assert ReleaseIndexRefresh.perform(daily) == {:snooze, 900}

    # One that started longer ago than the job timeout (a deploy killed
    # it, and Lifeline has not rescued it yet) runs no more.
    Repo.update_all(from(j in Oban.Job, where: j.id == ^running.id),
      set: executing.(DateTime.add(DateTime.utc_now(), -151, :minute))
    )

    assert ReleaseIndexRefresh.perform(%{hourly | args: %{"incremental" => true, "limit" => 0}}) ==
             :ok
  end

  test "it is on the daily crontab" do
    plugins = Application.fetch_env!(:portal, Oban)[:plugins]
    {_, cron} = Enum.find(plugins, &match?({Oban.Plugins.Cron, _}, &1))
    assert {"37 6 * * *", ReleaseIndexRefresh} in cron[:crontab]
  end
end
