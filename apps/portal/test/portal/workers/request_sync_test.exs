defmodule Portal.Workers.RequestSyncTest do
  use Portal.DataCase, async: false

  import Ecto.Query

  alias Portal.Repo
  alias Portal.ScanRequests.ScanRequest
  alias Portal.Workers.RequestSync

  # Requests are inserted directly: `create_once/1` resolves a version against
  # hex.pm and enqueues a build, and these tests are about what happens to a
  # request whose job is already gone.
  defp request(source, status, opts \\ []) do
    request =
      Ash.create!(
        ScanRequest,
        %{
          package_name: "pkg#{System.unique_integer([:positive])}",
          source: source,
          status: status
        },
        action: :create,
        domain: Portal.ScanRequests
      )

    age = Keyword.get(opts, :age_minutes, 60)
    at = NaiveDateTime.add(NaiveDateTime.utc_now(), -age * 60)

    Repo.update_all(
      from(r in "portal_scan_requests", where: r.id == type(^request.id, Ecto.UUID)),
      set: [inserted_at: at, updated_at: at]
    )

    request
  end

  defp job(worker, request, state) do
    Repo.insert!(%Oban.Job{
      worker: worker,
      queue: "builds",
      state: state,
      args: %{"scan_request_id" => request.id, "package" => request.package_name}
    })
  end

  defp lease(request, state) do
    Ash.create!(
      Portal.Builders.Lease,
      %{
        package: request.package_name,
        version: "1.0.0",
        image_name: "i",
        image_digest: "sha256:" <> String.duplicate("a", 64),
        scan_request_id: request.id,
        state: state
      },
      action: :create,
      domain: Portal.Builders
    )
  end

  defp exists?(request), do: match?({:ok, _}, Portal.ScanRequests.get_request(request.id))

  defp status(request) do
    {:ok, request} = Portal.ScanRequests.get_request(request.id)
    request.status
  end

  defp sync, do: RequestSync.perform(%Oban.Job{args: %{}})

  describe "open requests whose job is gone" do
    # Cancelling a build in Oban Web touches oban_jobs only; the request stayed
    # `queued` and filled the admin queue with 3,417 dead rows.
    test "one of ours is deleted" do
      orphan = request(:backfill, :queued)
      job("Portal.Workers.Build", orphan, "cancelled")

      sync()

      refute exists?(orphan)
    end

    test "a user's is closed as an error, not deleted" do
      orphan = request(:admin_manual, :queued)
      job("Portal.Workers.Build", orphan, "discarded")

      sync()

      assert status(orphan) == :error
    end

    test "one with a live build is left alone" do
      live = request(:backfill, :queued)
      job("Portal.Workers.Build", live, "available")

      sync()

      assert status(live) == :queued
    end

    test "closing an orphan announces the admin queue" do
      :ok = Portal.AdminEvents.subscribe(:queue)
      orphan = request(:admin_manual, :queued)
      job("Portal.Workers.Build", orphan, "discarded")

      sync()

      assert_receive {:admin_changed, :queue}
    end

    # A sync that touches no rows (every open request still has a live job)
    # has nothing to tell the admin queue.
    test "a sync with nothing to close announces nothing" do
      :ok = Portal.AdminEvents.subscribe(:queue)
      live = request(:backfill, :queued)
      job("Portal.Workers.Build", live, "available")

      sync()

      refute_receive {:admin_changed, :queue}
    end

    # The build finished and handed over to ingest; the request only turns
    # `built` when ingest completes.
    test "one with a live ingest is left alone" do
      ingesting = request(:update_check, :queued)
      job("Portal.Workers.Build", ingesting, "completed")
      job("Portal.Workers.Ingest", ingesting, "executing")

      sync()

      assert status(ingesting) == :queued
    end

    # `RemoteBuild` completes once it has written the lease; the remote build
    # runs for as long as it takes with no live job behind the request.
    test "a request with an open lease is left alone" do
      for state <- [:queued, :leased, :uploading] do
        remote = request(:backfill, :queued)
        user = request(:admin_manual, :queued)
        job("Portal.Workers.RemoteBuild", remote, "completed")
        lease(remote, state)
        lease(user, state)

        sync()

        assert status(remote) == :queued
        assert status(user) == :queued
      end
    end

    # `done` is terminal: once its Ingest job is gone (cancelled, out of
    # attempts) nothing will ever mark the request.
    test "a request whose lease is done and whose ingest is gone is closed" do
      remote = request(:backfill, :queued)
      user = request(:admin_manual, :queued)

      for r <- [remote, user] do
        job("Portal.Workers.RemoteBuild", r, "completed")
        job("Portal.Workers.Ingest", r, "cancelled")
        lease(r, :done)
      end

      sync()

      refute exists?(remote)
      assert status(user) == :error
    end

    test "a done lease with a live ingest is left alone" do
      ingesting = request(:backfill, :queued)
      job("Portal.Workers.Ingest", ingesting, "available")
      lease(ingesting, :done)

      sync()

      assert status(ingesting) == :queued
    end

    test "a request whose lease failed is closed" do
      orphan = request(:admin_manual, :queued)
      job("Portal.Workers.RemoteBuild", orphan, "completed")
      lease(orphan, :failed)

      sync()

      assert status(orphan) == :error
    end

    # `create_once/1` inserts the request before its build job; a sync landing
    # between the two must not take it for an orphan.
    test "a fresh one gets a grace period" do
      fresh = request(:catalog_seed, :queued, age_minutes: 2)

      sync()

      assert status(fresh) == :queued
    end

    test "a pending anonymous request is not open work and is left alone" do
      pending = request(:anonymous_manual, :pending)

      sync()

      assert status(pending) == :pending
    end
  end

  describe "finished requests" do
    test "ours are deleted a day after they finish" do
      old = request(:backfill, :built, age_minutes: 25 * 60)
      recent = request(:update_check, :error, age_minutes: 60)

      sync()

      refute exists?(old)
      assert exists?(recent)
    end

    test "a user's are kept" do
      kept = request(:hex_owner, :built, age_minutes: 25 * 60)

      sync()

      assert exists?(kept)
    end

    test "deleting finished requests announces the admin queue" do
      :ok = Portal.AdminEvents.subscribe(:queue)
      request(:backfill, :built, age_minutes: 25 * 60)

      sync()

      assert_receive {:admin_changed, :queue}
    end

    test "a run that pointed at a deleted request keeps its row" do
      old = request(:catalog_seed, :built, age_minutes: 25 * 60)

      {:ok, run} =
        Portal.Catalog.Ingestion.ingest(
          %{
            "package" => %{"name" => old.package_name, "version" => "1.0.0"},
            "finished_at" => "2026-10-11T10:00:00Z",
            "systems" => %{"nerves_system_rpi4" => %{"status" => "pass"}}
          },
          %{
            run_id: "rs-#{System.unique_integer([:positive])}",
            image_digest: "sha256:x",
            files_dir: System.tmp_dir!(),
            scan_request_id: old.id
          }
        )

      sync()

      refute exists?(old)

      assert Repo.one(
               from(r in "catalog_runs",
                 where: r.id == type(^run.id, Ecto.UUID),
                 select: is_nil(r.scan_request_id)
               )
             )
    end
  end
end
