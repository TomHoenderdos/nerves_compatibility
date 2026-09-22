defmodule Portal.AdminTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query, only: [from: 2]

  alias Portal.Admin
  alias Portal.Workers.UpdateCheck

  defmodule StubVersions do
    def latest_version(_package), do: {:ok, "9.9.9"}
  end

  setup do
    Application.put_env(:portal, :package_version_resolver, StubVersions)
    on_exit(fn -> Application.delete_env(:portal, :package_version_resolver) end)

    {:ok, admin} = Portal.Accounts.seed_admin_user("adminops", "correct horse battery staple")
    %{admin: admin}
  end

  defp build_job_for(request_id) do
    from(j in Oban.Job,
      where: j.worker == "Portal.Workers.Build",
      where: fragment("? ->> 'scan_request_id' = ?", j.args, ^request_id),
      order_by: [desc: j.id],
      limit: 1
    )
    |> Portal.Repo.one()
  end

  defp set_priority(job_id, priority) do
    Portal.Repo.update_all(from(j in Oban.Job, where: j.id == ^job_id), set: [priority: priority])
  end

  defp set_state(job_id, state) do
    Portal.Repo.update_all(from(j in Oban.Job, where: j.id == ^job_id), set: [state: state])
  end

  describe "queue_package/3" do
    test "queues a package at the front of the build queue", %{admin: admin} do
      assert {:ok, request} = Admin.queue_package("alpha", admin)

      assert request.source == :admin_manual
      assert request.status == :queued
      assert request.subject == "requested_by:adminops"

      job = build_job_for(request.id)
      assert job.args["package"] == "alpha"
      assert job.args["version"] == "9.9.9"
      # Priority 0 is the point of the admin path: a package an admin typed in
      # must not queue behind a sweep of the whole upstream catalogue.
      assert job.priority == 0
    end

    test "trims whitespace around the name", %{admin: admin} do
      assert {:ok, request} = Admin.queue_package("  alpha  ", admin)
      assert request.package_name == "alpha"
    end

    test "rejects a blank name before asking hex.pm anything", %{admin: admin} do
      assert {:error, :blank_package_name} = Admin.queue_package("   ", admin)
      refute_enqueued(worker: Portal.Workers.Build)
    end

    test "rejects something that is not a package name", %{admin: admin} do
      assert {:error, :invalid_package_name} =
               Admin.queue_package("https://hex.pm/packages/alpha", admin)

      refute_enqueued(worker: Portal.Workers.Build)
    end

    test "reports an already-open request rather than silently doing nothing", %{admin: admin} do
      assert {:ok, first} = Admin.queue_package("alpha", admin)
      assert {:error, {:already_open, open}} = Admin.queue_package("alpha", admin)
      assert open.id == first.id
    end

    test "an ordinary request carries no force key at all", %{admin: admin} do
      assert {:ok, request} = Admin.queue_package("alpha", admin)
      refute Map.has_key?(build_job_for(request.id).args, "force")
    end

    test "forcing past an open request reaches a worker as a distinct job", %{admin: admin} do
      assert {:ok, first} = Admin.queue_package("alpha", admin)
      plain = build_job_for(first.id)

      assert {:ok, again} = Admin.queue_package("alpha", admin, force: true)
      assert again.id == first.id

      forced = build_job_for(again.id)

      # A new row, not the one already queued. Oban compares unique keys by
      # containment, so without `:force` in the key list this insert would be
      # discarded as a duplicate of `plain` and the flag would never arrive.
      assert forced.id != plain.id
      assert forced.args["force"] == true
    end
  end

  describe "reprioritise/2" do
    test "up lowers the number, down raises it", %{admin: admin} do
      {:ok, request} = Admin.queue_package("alpha", admin)
      set_priority(build_job_for(request.id).id, 5)

      assert {:ok, 4} = Admin.reprioritise(request.id, :up)
      assert {:ok, 5} = Admin.reprioritise(request.id, :down)
      assert build_job_for(request.id).priority == 5
    end

    test "refuses to go past either end of Oban's range", %{admin: admin} do
      {:ok, request} = Admin.queue_package("alpha", admin)
      assert {:error, :already_at_limit} = Admin.reprioritise(request.id, :up)

      set_priority(build_job_for(request.id).id, 9)
      assert {:error, :already_at_limit} = Admin.reprioritise(request.id, :down)
    end

    test "refuses a job that is already executing", %{admin: admin} do
      {:ok, request} = Admin.queue_package("alpha", admin)
      set_state(build_job_for(request.id).id, "executing")

      # Oban has handed this job to a worker and will never read its priority
      # again. Reporting success would be a lie to somebody watching the queue
      # fail to move.
      assert {:error, {:not_adjustable, "executing"}} = Admin.reprioritise(request.id, :up)
    end

    test "reports when there is no job to reorder" do
      assert {:error, :no_job} = Admin.reprioritise(Ecto.UUID.generate(), :up)
    end
  end

  describe "queue_positions/1" do
    test "is empty for no requests" do
      assert Admin.queue_positions([]) == %{}
    end

    test "reports priority and adjustability per request", %{admin: admin} do
      {:ok, alpha} = Admin.queue_package("alpha", admin)
      {:ok, beta} = Admin.queue_package("beta", admin)
      set_state(build_job_for(beta.id).id, "executing")

      positions = Admin.queue_positions([alpha.id, beta.id])

      assert positions[alpha.id].priority == 0
      assert positions[alpha.id].adjustable?
      assert positions[beta.id].state == "executing"
      refute positions[beta.id].adjustable?
    end

    test "a forced rebuild supersedes the job it was queued alongside", %{admin: admin} do
      {:ok, request} = Admin.queue_package("alpha", admin)
      {:ok, forced_request} = Admin.queue_package("alpha", admin, force: true)
      assert forced_request.id == request.id

      # Two live jobs for one request. The page must show the newer one -- the
      # rebuild the admin just asked for, not the one it was stacked on.
      assert Admin.queue_positions([request.id])[request.id].priority == 0
      assert build_job_for(request.id).args["force"] == true
    end

    test "omits a request whose job has been pruned", %{admin: admin} do
      {:ok, request} = Admin.queue_package("alpha", admin)
      job_id = build_job_for(request.id).id
      Portal.Repo.delete_all(from(j in Oban.Job, where: j.id == ^job_id))

      assert Admin.queue_positions([request.id]) == %{}
    end
  end

  describe "update_check_status/0" do
    test "reports the configured schedule" do
      status = Admin.update_check_status()
      assert is_boolean(status.enabled?)
    end

    test "a run that recorded nothing is not the last run" do
      # A run that returned early because the check is switched off completes
      # like any other. Counting it would leave the panel showing a row of
      # blanks, indistinguishable from a broken check.
      Oban.insert!(UpdateCheck.new(%{}))
      assert Admin.update_check_status().last_run == nil
    end

    test "picks up the numbers a run recorded" do
      job = Oban.insert!(UpdateCheck.new(%{}))

      Portal.Repo.update_all(
        from(j in Oban.Job, where: j.id == ^job.id),
        set: [meta: %{"seen" => 22_000, "moved" => 217, "enqueued" => 217}]
      )

      assert %{last_run: %Oban.Job{meta: meta}, pending?: true} = Admin.update_check_status()
      assert meta["enqueued"] == 217
    end
  end

  describe "request_update_check/1" do
    test "marks the job manual so it ignores the schedule switch" do
      assert {:ok, _job} = Admin.request_update_check()

      # Read back from the table rather than off the returned struct: Oban
      # hands back the args it was given, atom keys and all, while the worker
      # will be handed the string-keyed row.
      assert_enqueued(worker: UpdateCheck, args: %{"manual" => true})
    end

    test "a dry run is a distinct job, not a deduplicated one" do
      assert {:ok, _} = Admin.request_update_check()
      assert {:ok, _} = Admin.request_update_check(dry_run: true)

      assert_enqueued(worker: UpdateCheck, args: %{"manual" => true, "dry_run" => true})
      assert Portal.Repo.aggregate(Oban.Job, :count) == 2
    end

    test "asking twice reports the queued run instead of stacking another" do
      assert {:ok, _} = Admin.request_update_check()
      assert {:error, :already_queued} = Admin.request_update_check()
    end
  end
end
