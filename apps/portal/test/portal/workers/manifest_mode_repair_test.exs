defmodule Portal.Workers.ManifestModeRepairTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Workers.ManifestModeRepair

  test "perform runs the repair" do
    assert :ok = perform_job(ManifestModeRepair, %{})
  end

  test "enqueue queues one repair on :maintenance and refuses a second while it waits" do
    assert {:ok, %Oban.Job{queue: "maintenance"}} = ManifestModeRepair.enqueue()
    assert {:error, :already_queued} = ManifestModeRepair.enqueue()
    assert [_job] = all_enqueued(worker: ManifestModeRepair)
  end
end
