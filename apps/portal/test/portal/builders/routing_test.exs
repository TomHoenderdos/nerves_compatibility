defmodule Portal.Builders.RoutingTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Builders.{Builder, Images, Routing}
  alias Portal.Workers.{Build, RemoteBuild}

  defmodule StubVersions do
    def latest_version(_package), do: {:ok, "1.0.0"}
  end

  setup do
    path = Path.join(System.tmp_dir!(), "images-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      ~s({"commit":"c","images":{"ncc-worker":{"name":"ghcr.io/x/ncc-worker","tag":"c","digest":"sha256:#{String.duplicate("a", 64)}"}}})
    )

    previous = Application.get_env(:portal, Images, [])
    Application.put_env(:portal, Images, Keyword.put(previous, :path, path))
    Application.put_env(:portal, :package_version_resolver, StubVersions)

    on_exit(fn ->
      Application.put_env(:portal, Images, previous)
      Application.delete_env(:portal, :package_version_resolver)
      File.rm(path)
    end)

    :ok
  end

  defp seen!(name, minutes_ago) do
    Builder
    |> Ash.Changeset.for_create(:enrol, %{
      name: name,
      fingerprint: "fp-#{name}",
      cert_pem: "p",
      cert_expires_at: DateTime.utc_now(),
      enrolled_at: DateTime.utc_now()
    })
    |> Ash.create!(domain: Portal.Builders)
    |> touch!(minutes_ago)
  end

  defp touch!(builder, minutes_ago) do
    builder
    |> Ash.Changeset.for_update(:touch, %{
      last_seen_at: DateTime.add(DateTime.utc_now(), -minutes_ago, :minute)
    })
    |> Ash.update!(domain: Portal.Builders)
  end

  defp backlog!(n),
    do: for(i <- 1..n, do: Oban.insert!(Build.new(%{package: "p#{i}", version: "1.0.0"})))

  test "stays local by default and when forced off" do
    assert Routing.queue_for(%{"package" => "jason"}, []) == :builds
    {:ok, _} = Portal.Settings.save(%{remote_mode: :off})
    seen!("a", 1)
    backlog!(12)
    assert Routing.queue_for(%{"package" => "jason"}, []) == :builds
  end

  test "goes remote only above the backlog threshold when a builder is around" do
    {:ok, _} = Portal.Settings.save(%{remote_backlog_threshold: 2})
    seen!("a", 1)
    assert Routing.queue_for(%{"package" => "jason"}, []) == :builds
    backlog!(3)
    assert Routing.queue_for(%{"package" => "jason"}, []) == :remote
    assert Routing.queue_for(%{package: "jason"}, []) == :remote
    assert Routing.queue_for(%{"package" => "jason"}, meta: %{pin_local: true}) == :builds
    assert Routing.queue_for(%{"package" => "jason"}, meta: %{"pin_local" => true}) == :builds
    assert Routing.queue_for(%{"package" => "jason", "mode" => "toolchain"}, []) == :builds
    assert Routing.queue_for(%{"package" => "jason", "mode" => "warm_nerves"}, []) == :builds
    assert Routing.queue_for(%{package: "jason", mode: "toolchain"}, []) == :builds
  end

  test "forced on routes remote with any backlog; no registry image keeps it local" do
    {:ok, _} = Portal.Settings.save(%{remote_mode: :on})
    assert Routing.remote_enabled?()
    backlog!(1)
    {:ok, _} = Portal.Settings.save(%{remote_backlog_threshold: 0})
    assert Routing.queue_for(%{"package" => "jason"}, []) == :remote
    File.rm!(Images.path())
    assert Routing.queue_for(%{"package" => "jason"}, []) == :builds
  end

  test "auto flips on within 5 minutes and off after 15, holding in between" do
    refute Routing.remote_enabled?()
    seen!("a", 1)
    assert Routing.remote_enabled?()
    assert Portal.Settings.get().remote_auto_on
    Enum.each(Portal.Builders.list_builders(), &touch!(&1, 10))
    assert Routing.remote_enabled?()
    Enum.each(Portal.Builders.list_builders(), &touch!(&1, 16))
    refute Routing.remote_enabled?()
    refute Portal.Settings.get().remote_auto_on
  end

  test "build_job picks the worker, and every enqueuer goes through it" do
    {:ok, _} = Portal.Settings.save(%{remote_mode: :on, remote_backlog_threshold: 0})
    backlog!(1)
    changeset = Routing.build_job(%{package: "jason", version: "1.4.4"}, priority: 2)
    assert changeset.changes.worker == "Portal.Workers.RemoteBuild"
    assert changeset.changes.queue == "remote"
    assert changeset.changes.priority == 2

    {:ok, _} =
      Portal.ScanRequests.create_once(%{
        package_name: "jason",
        version: "1.4.4",
        source: :hex_owner,
        status: :accepted
      })

    assert [_] = all_enqueued(worker: RemoteBuild)
    {:ok, _} = Portal.Settings.save(%{remote_mode: :off})

    {:ok, _} =
      Portal.ScanRequests.create_once(%{
        package_name: "decimal",
        version: "2.0.0",
        source: :hex_owner,
        status: :accepted
      })

    assert [_] = all_enqueued(worker: Build, args: %{package: "decimal"})
  end

  test "a local job and a remote one for the same args dedup against each other" do
    {:ok, _} = Portal.Settings.save(%{remote_mode: :on, remote_backlog_threshold: 0})
    args = %{package: "jason", version: "1.4.4", scan_request_id: Ecto.UUID.generate()}
    assert %Oban.Job{conflict?: false} = Oban.insert!(Build.new(args))

    changeset = Routing.build_job(args, priority: 2)
    assert changeset.changes.worker == "Portal.Workers.RemoteBuild"
    assert {:ok, %Oban.Job{conflict?: true}} = Oban.insert(changeset)
    assert [] = all_enqueued(worker: RemoteBuild)
  end
end
