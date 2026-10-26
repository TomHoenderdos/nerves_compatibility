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

  test "cancelling a sweep with nothing waiting leaves it uncancelled" do
    {:ok, %{sweep_id: id}} = BulkRebuild.run(limit: 1, names: ["finished_sweep"])

    for job <- all_enqueued(worker: Portal.Workers.Backfill) do
      Repo.update!(Ecto.Changeset.change(job, state: "completed"))
    end

    assert {:ok, 0} = BulkRebuild.cancel(id)
    assert [%{id: ^id, cancelled_at: nil}] = BulkRebuild.recent()

    query = Ash.Query.filter_input(Portal.Catalog.BulkSweep, %{id: [in: [id]]})
    assert {:ok, %{ok: 0}} = BulkRebuild.bulk_cancel(query, [])
    assert [%{id: ^id, cancelled_at: nil}] = BulkRebuild.recent()
  end

  # The Maintenance page's form, as `opts_from_params/2` turns it into `run/1`
  # options. Moved from the controller unchanged, so these pin what it did.
  describe "opts_from_params/2" do
    test "the defaults, for an empty or forged form" do
      for params <- [
            %{},
            %{"limit" => "0", "what" => "nonsense", "order" => "x", "status" => "x"},
            %{"limit" => "20001"},
            %{"limit" => %{"x" => "1"}, "what" => ["full"], "systems" => %{"a" => "b"}}
          ] do
        assert BulkRebuild.opts_from_params(params, "admin") == [
                 limit: 100,
                 order: :stalest,
                 status: nil,
                 what: :full,
                 dry_run: false,
                 created_by: "admin"
               ]
      end
    end

    test "reads each field the form has" do
      assert BulkRebuild.opts_from_params(
               %{
                 "limit" => "25",
                 "order" => "catalog",
                 "status" => "fail",
                 "what" => "argus_only",
                 "mode" => "dry_run"
               },
               "admin"
             ) == [
               limit: 25,
               order: :catalog,
               status: :fail,
               what: :argus_only,
               dry_run: true,
               created_by: "admin"
             ]
    end

    test "targets keep only known systems, and none ticked is :no_targets" do
      params = %{"what" => "targets", "systems" => ["nerves_system_rpi4", "nerves_system_nope"]}

      assert BulkRebuild.opts_from_params(params, "a")[:what] ==
               {:targets, ["nerves_system_rpi4"]}

      assert BulkRebuild.opts_from_params(%{"what" => "targets"}, "a")[:what] == :no_targets

      assert BulkRebuild.opts_from_params(%{"what" => "targets", "systems" => ["nope"]}, "a")[
               :what
             ] == :no_targets
    end
  end

  describe "bulk_cancel/2" do
    setup do
      :ok = Portal.AdminEvents.subscribe(:sweeps)
      :ok
    end

    test "cancels every sweep the query selects, totals the jobs, and announces once" do
      {:ok, %{sweep_id: a}} = BulkRebuild.run(limit: 1, names: ["bc_a", "bc_a2"])
      {:ok, %{sweep_id: b}} = BulkRebuild.run(limit: 1, names: ["bc_b"])
      {:ok, %{sweep_id: c}} = BulkRebuild.run(limit: 1, names: ["bc_c"])
      flush_sweep_events()

      query = Ash.Query.filter_input(Portal.Catalog.BulkSweep, %{id: [in: [a, b]]})

      assert {:ok, %{ok: 3, failed: []}} = BulkRebuild.bulk_cancel(query, [])
      assert_receive {:admin_changed, :sweeps}
      refute_receive {:admin_changed, :sweeps}

      assert %{cancelled: 2} = BulkRebuild.status(a)
      assert %{cancelled: 1} = BulkRebuild.status(b)
      assert %{cancelled: 0, intake: 1} = BulkRebuild.status(c)
    end

    test "nothing waiting cancels nothing and announces nothing" do
      {:ok, %{sweep_id: a}} = BulkRebuild.run(limit: 1, names: ["bc_done"])
      {:ok, 1} = BulkRebuild.cancel(a)
      flush_sweep_events()

      query = Ash.Query.filter_input(Portal.Catalog.BulkSweep, %{id: [in: [a]]})
      assert {:ok, %{ok: 0, failed: []}} = BulkRebuild.bulk_cancel(query, [])
      refute_receive {:admin_changed, :sweeps}
    end

    defp flush_sweep_events do
      receive do
        {:admin_changed, :sweeps} -> flush_sweep_events()
      after
        0 -> :ok
      end
    end
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

  # The Maintenance page watches `:sweeps` to refresh an in-progress sweep's
  # counts. `run/1` and `cancel/1` are both one-shot writes -- unlike a build
  # or ingest job's own attempt, which the `Portal.AdminEvents.SweepTelemetry`
  # handler announces instead -- so each broadcasts directly.
  describe "sweep change events" do
    setup do
      :ok = Portal.AdminEvents.subscribe(:sweeps)
      :ok
    end

    test "starting and cancelling a sweep is announced" do
      {:ok, %{sweep_id: id}} = BulkRebuild.run(limit: 1, names: ["sweep_evt"], created_by: "t")
      assert_receive {:admin_changed, :sweeps}
      {:ok, _} = BulkRebuild.cancel(id)
      assert_receive {:admin_changed, :sweeps}
    end

    test "a dry run does not announce" do
      docker_run!("dry_evt")
      assert {:ok, %{sweep_id: nil}} = BulkRebuild.run(limit: 10, dry_run: true)
      refute_receive {:admin_changed, :sweeps}
    end

    test "an empty selection does not announce" do
      assert {:ok, %{sweep_id: nil, selected: 0}} = BulkRebuild.run(limit: 10)
      refute_receive {:admin_changed, :sweeps}
    end
  end

  # An Ingest job that a sweep's build hands off to carries the sweep's id
  # under `meta.announce_sweep`, a different key from the `meta.sweep_id` that
  # `sweep_jobs/1` matches by JSONB containment -- see
  # `Portal.Workers.Build.enqueue_ingest/4`. If it carried `sweep_id` instead,
  # `cancel/1` could cancel a pending ingest (losing a finished build's result
  # and leaking its scratch dir) and `status/1` would double-count the
  # package once for its Build job and again for its Ingest job.
  describe "Ingest jobs stay outside a sweep's scope" do
    test "cancel leaves a pending ingest job alone" do
      {:ok, _job} =
        Oban.insert(
          Portal.Workers.Ingest.new(%{"run_id" => "r1"}, meta: %{announce_sweep: "sweep-x"})
        )

      assert {:ok, 0} = BulkRebuild.cancel("sweep-x")

      assert [%{state: "available"}] = all_enqueued(worker: Portal.Workers.Ingest)
    end

    test "status does not count a pending ingest job" do
      {:ok, _job} =
        Oban.insert(
          Portal.Workers.Ingest.new(%{"run_id" => "r2"}, meta: %{announce_sweep: "sweep-y"})
        )

      assert %{intake: 0, queued: 0, building: 0, remaining: 0} = BulkRebuild.status("sweep-y")
    end
  end
end
