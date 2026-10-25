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

  describe "with remote building forced on and a local backlog" do
    setup do
      path = Path.join(System.tmp_dir!(), "images-#{System.unique_integer([:positive])}.json")
      digest = "sha256:" <> String.duplicate("a", 64)

      File.write!(
        path,
        Jason.encode!(%{
          images: %{"ncc-worker" => %{name: "ghcr.io/x/ncc-worker", tag: "c", digest: digest}}
        })
      )

      previous = Application.get_env(:portal, Portal.Builders.Images, [])
      Application.put_env(:portal, Portal.Builders.Images, Keyword.put(previous, :path, path))

      on_exit(fn ->
        Application.put_env(:portal, Portal.Builders.Images, previous)
        File.rm(path)
      end)

      {:ok, _} = Portal.Settings.save(%{remote_mode: :on, remote_backlog_threshold: 0})
      Oban.insert!(Portal.Workers.Build.new(%{package: "queued_pkg", version: "1.0.0"}))
      :ok
    end

    test "a request routed remote inserts a RemoteBuild job" do
      assert {:ok, _request} =
               Portal.ScanRequests.create_once(%{
                 package_name: "remote_pkg",
                 source: :backfill,
                 status: :accepted
               })

      assert [job] = all_enqueued(worker: Portal.Workers.RemoteBuild)
      assert job.args["package"] == "remote_pkg"
      assert job.queue == "remote"
    end

    test "a pin_local request still inserts a local Build job" do
      assert {:ok, _request} =
               Portal.ScanRequests.create_once(%{
                 package_name: "pinned_pkg",
                 source: :backfill,
                 status: :accepted,
                 pin_local: true
               })

      assert [] = all_enqueued(worker: Portal.Workers.RemoteBuild)
      assert [_] = all_enqueued(worker: Portal.Workers.Build, args: %{package: "pinned_pkg"})
    end
  end
end
