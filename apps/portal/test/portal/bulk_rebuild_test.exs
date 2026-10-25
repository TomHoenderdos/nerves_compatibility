defmodule Portal.BulkRebuildTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  alias Portal.BulkRebuild
  alias Portal.Catalog.{Ingestion, RegistryAssessment}

  defp docker_run!(name, opts \\ []) do
    {:ok, _} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => name, "version" => "1.0.0"},
          "finished_at" => Keyword.get(opts, :finished_at, "2026-10-10T10:00:00Z"),
          "systems" => %{
            "host" => %{"status" => "pass"},
            "nerves_system_rpi4" => %{"status" => Keyword.get(opts, :status, "pass")}
          }
        },
        %{
          run_id: "bulk-#{System.unique_integer([:positive])}",
          image_digest: "sha256:x",
          files_dir: System.tmp_dir!()
        }
      )
  end

  defp swept_packages,
    do:
      all_enqueued(worker: Portal.Workers.Backfill)
      |> Enum.map(& &1.args["package"])
      |> Enum.sort()

  test "selects packages with a real build, never registry-only assessments" do
    docker_run!("built")
    {:ok, _} = RegistryAssessment.record("registry_only", "1.0.0", nil)

    {:ok, %{selected: 1, enqueued: 1}} = BulkRebuild.run(limit: 10)
    assert swept_packages() == ["built"]
  end

  test "stalest first, up to the limit" do
    docker_run!("old", finished_at: "2026-01-01T00:00:00Z")
    docker_run!("new", finished_at: "2026-10-01T00:00:00Z")

    {:ok, %{selected: 1}} = BulkRebuild.run(limit: 1, order: :stalest)
    assert swept_packages() == ["old"]
  end

  test "filters on the latest run's status" do
    docker_run!("passing")
    docker_run!("failing", status: "fail")

    {:ok, _} = BulkRebuild.run(limit: 10, status: :fail)
    assert swept_packages() == ["failing"]
  end

  test "a dry run counts and queues nothing" do
    docker_run!("dry")

    assert {:ok, %{selected: 1, enqueued: 0, sweep_id: nil}} =
             BulkRebuild.run(limit: 10, dry_run: true)

    assert all_enqueued(worker: Portal.Workers.Backfill) == []
  end

  test "jobs carry force, the scope and the sweep id" do
    docker_run!("scoped")
    {:ok, %{sweep_id: id}} = BulkRebuild.run(limit: 10, what: {:targets, ["nerves_system_rpi4"]})

    [job] = all_enqueued(worker: Portal.Workers.Backfill)
    assert job.args["force"] == true
    assert job.args["scope"] == "targets"
    assert job.args["systems"] == ["nerves_system_rpi4"]
    assert job.args["sweep_id"] == id
    assert job.meta["sweep_id"] == id
    assert job.args["source"] == "backfill"
  end

  test "status counts the sweep's jobs by stage, and cancel stops what is waiting" do
    docker_run!("c1")
    docker_run!("c2")
    {:ok, %{sweep_id: id}} = BulkRebuild.run(limit: 10)

    assert %{intake: 2} = BulkRebuild.status(id)
    assert {:ok, 2} = BulkRebuild.cancel(id)
    assert %{intake: 0, cancelled: 2} = BulkRebuild.status(id)
    assert [%{id: ^id, cancelled_at: %DateTime{}}] = BulkRebuild.recent()
  end

  test "remaining counts what has not finished, and a discarded intake job is a failure" do
    for name <- ~w(r1 r2 r3), do: docker_run!(name)
    {:ok, %{sweep_id: id}} = BulkRebuild.run(limit: 10)

    [first, second | _] = all_enqueued(worker: Portal.Workers.Backfill)
    Repo.update!(Ecto.Changeset.change(first, state: "discarded"))
    Repo.update!(Ecto.Changeset.change(second, state: "completed"))

    assert %{intake: 1, failed: 1, remaining: 1} = BulkRebuild.status(id)
  end

  test "names override the selection" do
    docker_run!("a")
    docker_run!("b")
    {:ok, %{selected: 1}} = BulkRebuild.run(limit: 10, names: ["b"])
    assert swept_packages() == ["b"]
  end

  test "a package still waiting on an open request is not selected again" do
    docker_run!("waiting")
    docker_run!("free")

    {:ok, _} =
      Portal.ScanRequests.create_once(%{
        package_name: "waiting",
        source: :hex_owner,
        status: :pending
      })

    {:ok, %{selected: 1}} = BulkRebuild.run(limit: 10)
    assert swept_packages() == ["free"]
  end

  test "a name given twice is queued once" do
    docker_run!("a")
    {:ok, %{selected: 1, enqueued: 1}} = BulkRebuild.run(limit: 10, names: ["a", "a"])
    assert swept_packages() == ["a"]
  end

  test "an unknown target is refused before anything is written" do
    docker_run!("t")

    assert {:error, {:unknown_systems, ["nerves_system_nope"]}} =
             BulkRebuild.run(limit: 10, what: {:targets, ["nerves_system_nope"]})

    assert BulkRebuild.recent() == []
    assert all_enqueued(worker: Portal.Workers.Backfill) == []
  end

  describe "a completed RemoteBuild job" do
    defp remote_job!(sweep_id, package, state) do
      request_id = Ecto.UUID.generate()

      job =
        %{package: package, version: "1.0.0", scan_request_id: request_id}
        |> Portal.Workers.RemoteBuild.new(meta: %{sweep_id: sweep_id})
        |> Oban.insert!()

      Repo.update!(Ecto.Changeset.change(job, state: state))
      request_id
    end

    defp lease!(request_id, state) do
      Portal.Builders.Lease
      |> Ash.Changeset.for_create(:create, %{
        package: "p",
        version: "1.0.0",
        image_name: "i",
        image_digest: "sha256:d",
        args: %{},
        scan_request_id: request_id,
        state: state
      })
      |> Ash.create!(domain: Portal.Builders)
    end

    test "counts by its request's newest lease, and as done with none" do
      sweep_id = Ecto.UUID.generate()

      for {package, state} <- [
            q: :queued,
            l: :leased,
            u: :uploading,
            d: :done,
            f: :failed
          ] do
        sweep_id |> remote_job!(to_string(package), "completed") |> lease!(state)
      end

      # An older failed lease is superseded by the newer queued one.
      retried = remote_job!(sweep_id, "retried", "completed")
      lease!(retried, :failed)
      lease!(retried, :queued)

      _deduped = remote_job!(sweep_id, "deduped", "completed")
      _waiting = remote_job!(sweep_id, "waiting", "available")

      assert %{queued: 3, building: 2, done: 2, failed: 1, remaining: 5} =
               BulkRebuild.status(sweep_id)
    end
  end
end
