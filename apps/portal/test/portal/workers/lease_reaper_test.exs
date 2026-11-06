defmodule Portal.Workers.LeaseReaperTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo
  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias Portal.Builders.{Builder, Lease, Leases, Upload}
  alias Portal.Workers.LeaseReaper

  setup do
    root = Path.join(System.tmp_dir!(), "reaper-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:portal, Upload, [])
    Application.put_env(:portal, Upload, Keyword.put(previous, :root, root))

    on_exit(fn ->
      Application.put_env(:portal, Upload, previous)
      File.rm_rf(root)
    end)

    builder =
      Builder
      |> Ash.Changeset.for_create(:enrol, %{
        name: "reaper",
        fingerprint: "fp-reaper",
        cert_pem: "p",
        cert_expires_at: DateTime.utc_now(),
        slots: 2,
        enrolled_at: DateTime.utc_now()
      })
      |> Ash.create!(domain: Portal.Builders)

    %{builder: builder}
  end

  defp queued!(package) do
    {:ok, lease} =
      Leases.enqueue(%{
        package: package,
        version: "1.0.0",
        image_name: "i",
        image_digest: "sha256:d",
        args: %{},
        scan_request_id: nil,
        priority: 5
      })

    lease
  end

  defp silence!(lease, attrs) do
    attrs = Map.put(attrs, :heartbeat_at, DateTime.add(DateTime.utc_now(), -11, :minute))
    lease |> Ash.Changeset.for_update(:update, attrs) |> Ash.update!(domain: Portal.Builders)
  end

  test "runs on the maintenance queue" do
    assert LeaseReaper.__opts__()[:queue] == :maintenance
  end

  test "requeues a silent lease and keeps its upload dir", %{builder: builder} do
    queued!("silent")
    {:ok, lease} = Leases.claim(builder)
    silence!(lease, %{})
    File.mkdir_p!(Upload.files_dir(lease.id))

    assert :ok = perform_job(LeaseReaper, %{})
    assert %Lease{state: :queued} = Ash.get!(Lease, lease.id, domain: Portal.Builders)
    assert File.dir?(Upload.files_dir(lease.id))
  end

  test "fails an exhausted silent lease and removes its upload dir", %{builder: builder} do
    queued!("exhausted")
    {:ok, lease} = Leases.claim(builder)
    silence!(lease, %{attempt: 3})
    File.mkdir_p!(Upload.files_dir(lease.id))

    assert :ok = perform_job(LeaseReaper, %{})
    assert %Lease{state: :failed} = Ash.get!(Lease, lease.id, domain: Portal.Builders)
    refute File.exists?(Upload.lease_dir(lease.id))
  end

  describe "a queued lease no builder can claim" do
    defp queued_for!(package, minutes_ago, args \\ %{}) do
      {:ok, lease} =
        Leases.enqueue(%{
          package: package,
          version: "1.0.0",
          image_name: "i",
          image_digest: "sha256:d",
          args: args,
          scan_request_id: nil,
          priority: 4
        })

      at = DateTime.add(DateTime.utc_now(), -minutes_ago, :minute)

      Portal.Repo.update_all(
        from(l in "builder_leases", where: l.id == type(^lease.id, Ecto.UUID)),
        set: [updated_at: at, inserted_at: at]
      )

      lease
    end

    defp ready!(builder, arch) do
      {:ok, builder} = Portal.Builders.set_egress(builder, "ok")
      {:ok, builder} = Portal.Builders.set_arch(builder, arch)

      builder
      |> Ash.Changeset.for_update(:touch, %{last_seen_at: DateTime.utc_now()})
      |> Ash.update!(domain: Portal.Builders)
    end

    test "goes back to a local build once it has waited 30 minutes" do
      lease = queued_for!("orphan", 31)
      File.mkdir_p!(Upload.files_dir(lease.id))

      assert :ok = perform_job(LeaseReaper, %{})

      assert %Lease{state: :failed, error: "requeued locally"} =
               Ash.get!(Lease, lease.id, domain: Portal.Builders)

      assert [job] = all_enqueued(worker: Portal.Workers.Build)
      assert job.queue == "builds"
      assert job.args["package"] == "orphan"
      assert job.args["version"] == "1.0.0"
      assert job.meta["pin_local"] == true
      assert job.priority == 4
      refute File.exists?(Upload.lease_dir(lease.id))
    end

    test "a fresh one waits, however unready the builders", %{builder: builder} do
      {:ok, _} = Portal.Builders.set_egress(builder, "host_unready")
      lease = queued_for!("fresh", 5)

      assert :ok = perform_job(LeaseReaper, %{})
      assert %Lease{state: :queued} = Ash.get!(Lease, lease.id, domain: Portal.Builders)
      assert [] = all_enqueued(worker: Portal.Workers.Build)
    end

    test "an old one stays while a builder able to claim it is around", %{builder: builder} do
      ready!(builder, "x86_64")
      lease = queued_for!("backlogged", 90)

      assert :ok = perform_job(LeaseReaper, %{})
      assert %Lease{state: :queued} = Ash.get!(Lease, lease.id, domain: Portal.Builders)
      assert [] = all_enqueued(worker: Portal.Workers.Build)
    end

    test "a builder of another architecture does not hold it", %{builder: builder} do
      ready!(builder, "aarch64")
      lease = queued_for!("amd-only", 31, %{"image_platforms" => %{"x86_64" => "sha256:d"}})

      assert :ok = perform_job(LeaseReaper, %{})

      assert %Lease{state: :failed, error: "requeued locally"} =
               Ash.get!(Lease, lease.id, domain: Portal.Builders)

      assert [_] = all_enqueued(worker: Portal.Workers.Build)
    end

    test "an unready builder does not hold it", %{builder: builder} do
      builder |> ready!("x86_64") |> Portal.Builders.set_egress("host_unready")
      lease = queued_for!("unready", 31)

      assert :ok = perform_job(LeaseReaper, %{})
      assert %Lease{state: :failed} = Ash.get!(Lease, lease.id, domain: Portal.Builders)
    end

    # The local build does what the lease would have: an argus-only sweep
    # must not come back as a forced full firmware build of every system.
    test "an argus-only lease comes back as an argus-only build" do
      queued_for!("argus", 31, %{"mode" => "argus_only", "systems_filter" => nil, "force" => true})

      assert :ok = perform_job(LeaseReaper, %{})

      assert [job] = all_enqueued(worker: Portal.Workers.Build)
      assert job.args["scope"] == "argus_only"
      assert job.args["force"] == true
      refute Map.has_key?(job.args, "systems")
      # The local build runs this host's image, not the remote platform digest.
      refute Map.has_key?(job.args, "image_digest")
    end

    test "a targets lease comes back with its systems" do
      queued_for!("targets", 31, %{"mode" => nil, "systems_filter" => ["rpi4", "bbb"]})
      assert :ok = perform_job(LeaseReaper, %{})

      assert [job] = all_enqueued(worker: Portal.Workers.Build)
      assert job.args["scope"] == "targets"
      assert job.args["systems"] == ["rpi4", "bbb"]
      assert job.args["force"] == false
    end

    test "a full lease comes back as a full build" do
      queued_for!("full", 31, %{"mode" => nil, "systems_filter" => nil})
      assert :ok = perform_job(LeaseReaper, %{})

      assert [job] = all_enqueued(worker: Portal.Workers.Build)
      refute Map.has_key?(job.args, "scope")
      refute Map.has_key?(job.args, "systems")
    end

    test "one tick hands back a bounded number" do
      previous = Application.get_env(:portal, LeaseReaper, [])
      Application.put_env(:portal, LeaseReaper, stale_queued_limit: 2)
      on_exit(fn -> Application.put_env(:portal, LeaseReaper, previous) end)

      for p <- ["b1", "b2", "b3"], do: queued_for!(p, 40)
      assert :ok = perform_job(LeaseReaper, %{})
      assert length(all_enqueued(worker: Portal.Workers.Build)) == 2

      assert [%Lease{state: :queued}] =
               Lease
               |> Ash.Query.filter(state == :queued)
               |> Ash.read!(domain: Portal.Builders)
    end

    test "the wait is configurable" do
      previous = Application.get_env(:portal, LeaseReaper, [])
      Application.put_env(:portal, LeaseReaper, stale_queued_minutes: 120)
      on_exit(fn -> Application.put_env(:portal, LeaseReaper, previous) end)

      lease = queued_for!("patient", 60)
      assert :ok = perform_job(LeaseReaper, %{})
      assert %Lease{state: :queued} = Ash.get!(Lease, lease.id, domain: Portal.Builders)
    end
  end
end
