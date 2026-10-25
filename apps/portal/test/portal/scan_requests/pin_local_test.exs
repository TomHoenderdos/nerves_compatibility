defmodule Portal.ScanRequests.PinLocalTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  defmodule StubVersions do
    def latest_version(_package), do: {:ok, "9.9.9"}
  end

  setup do
    Application.put_env(:portal, :package_version_resolver, StubVersions)
    on_exit(fn -> Application.delete_env(:portal, :package_version_resolver) end)
    :ok
  end

  test "a pin_local request puts pin_local in the Build job's meta" do
    assert {:ok, _request} =
             Portal.ScanRequests.create_once(%{
               package_name: "pinned_pkg",
               source: :backfill,
               status: :accepted,
               pin_local: true
             })

    assert [job] = all_enqueued(worker: Portal.Workers.Build)
    assert job.meta["pin_local"] == true
  end

  test "an ordinary request carries no pin_local" do
    assert {:ok, _request} =
             Portal.ScanRequests.create_once(%{
               package_name: "unpinned_pkg",
               source: :backfill,
               status: :accepted
             })

    assert [job] = all_enqueued(worker: Portal.Workers.Build)
    refute Map.has_key?(job.meta, "pin_local")
  end
end
