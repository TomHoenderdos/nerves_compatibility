defmodule Portal.Workers.ModuleIndexRefreshTest do
  use Portal.DataCase, async: true

  alias Portal.Workers.ModuleIndexRefresh

  test "a run with nothing to read is ok" do
    assert ModuleIndexRefresh.perform(%Oban.Job{args: %{"limit" => 0}}) == :ok
  end

  # R3-7: a deploy that kills the job leaves it executing; inserting it again
  # must not be a silent conflict for the 3 h until Lifeline rescues it.
  test "a job left executing does not block inserting it again" do
    {:ok, job} = Oban.insert(ModuleIndexRefresh.new(%{}))
    Repo.query!("UPDATE oban_jobs SET state = 'executing' WHERE id = $1", [job.id])
    assert {:ok, %Oban.Job{conflict?: false}} = Oban.insert(ModuleIndexRefresh.new(%{}))
    # A second one still waiting is a conflict.
    assert {:ok, %Oban.Job{conflict?: true}} = Oban.insert(ModuleIndexRefresh.new(%{}))
  end

  test "it is on the daily crontab" do
    plugins = Application.fetch_env!(:portal, Oban)[:plugins]
    {_, cron} = Enum.find(plugins, &match?({Oban.Plugins.Cron, _}, &1))
    assert {"17 6 * * *", ModuleIndexRefresh} in cron[:crontab]
  end
end
