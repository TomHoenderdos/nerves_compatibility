defmodule Portal.Builders.LeasesTest do
  use Portal.DataCase, async: false

  alias Portal.Builders.{Builder, Lease, Leases}

  defp builder!(name, slots \\ 1) do
    Builder
    |> Ash.Changeset.for_create(:enrol, %{
      name: name,
      fingerprint: "fp-#{name}",
      cert_pem: "p",
      cert_expires_at: DateTime.utc_now(),
      slots: slots,
      enrolled_at: DateTime.utc_now()
    })
    |> Ash.create!(domain: Portal.Builders)
  end

  defp queued!(package \\ "jason", priority \\ 5) do
    {:ok, lease} =
      Leases.enqueue(%{
        package: package,
        version: "1.4.4",
        image_name: "i",
        image_digest: "sha256:d",
        args: %{},
        scan_request_id: nil,
        priority: priority
      })

    lease
  end

  test "enqueue broadcasts and claim takes the highest priority oldest lease" do
    Leases.subscribe()
    low = queued!("a", 9)
    high = queued!("b", 1)
    assert_receive {:lease_queued, _}
    assert_receive {:lease_queued, _}

    b = builder!("one")

    assert {:ok, %Lease{id: id, state: :leased, attempt: 1, run_id: "rb-b-1.4.4-" <> _}} =
             Leases.claim(b)

    assert id == high.id
    assert {:ok, %Lease{id: id2}} = Leases.claim(builder!("two"))
    assert id2 == low.id
    assert :none = Leases.claim(builder!("three"))
  end

  test "a builder holds at most slots leases" do
    queued!("a")
    queued!("b")
    b = builder!("one", 1)
    assert {:ok, _} = Leases.claim(b)
    assert :none = Leases.claim(b)
    assert {:ok, _} = Leases.claim(builder!("two", 1))
  end

  test "claim is atomic across two concurrent claimants" do
    queued!("only")
    b1 = builder!("c1")
    b2 = builder!("c2")
    parent = self()

    tasks =
      for b <- [b1, b2] do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Portal.Repo, parent, self())
          Leases.claim(b)
        end)
      end

    results = Task.await_many(tasks, 10_000)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == :none)) == 1
  end

  test "the long poll wakes on a broadcast" do
    b = builder!("w")
    parent = self()

    task =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Portal.Repo, parent, self())
        Leases.claim_or_wait(b, 5_000)
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Portal.Repo, self(), task.pid)
    _ = :sys.get_state(Portal.PubSub)
    queued!("late")
    assert {:ok, %Lease{package: "late"}} = Task.await(task, 6_000)
    assert :none = Leases.claim_or_wait(builder!("w2"), 50)
  end

  test "heartbeat, held and complete drive the state machine" do
    lease = queued!()
    b = builder!("h")
    other = builder!("o")
    {:ok, leased} = Leases.claim(b)
    assert {:error, :not_held} = Leases.heartbeat(leased.id, other.id, "building", "x")

    assert {:ok, %Lease{phase: "building", log_tail: "tail"}} =
             Leases.heartbeat(leased.id, b.id, "building", "tail")

    assert {:ok, %Lease{state: :uploading}} = Leases.heartbeat(leased.id, b.id, "uploading", "")
    assert {:ok, %Lease{}} = Leases.held(leased.id, b.id)
    assert {:error, :not_held} = Leases.held(leased.id, other.id)

    assert {:ok, :requeued, %Lease{state: :queued, builder_id: nil, attempt: 1}} =
             Leases.complete(Ash.get!(Lease, lease.id, domain: Portal.Builders), 10)

    {:ok, again} = Leases.claim(b)
    assert {:ok, :done, %Lease{state: :done}} = Leases.complete(again, 0)
  end

  test "a policy violation fails the lease without retry and exhausted attempts fail it" do
    lease = queued!()
    {:ok, leased} = Leases.claim(builder!("p"))

    assert {:ok, :rejected, %Lease{state: :failed, error: "non-Hex dep"}} =
             Leases.complete(leased, 11)

    lease2 = queued!("z")
    b = builder!("z")
    {:ok, l} = Leases.claim(b)
    {:ok, :requeued, _} = Leases.complete(l, 21)
    {:ok, l} = Leases.claim(b)
    {:ok, :requeued, _} = Leases.complete(l, 20)
    {:ok, l} = Leases.claim(b)
    assert {:ok, :failed, %Lease{state: :failed, attempt: 3}} = Leases.complete(l, 10)

    assert {:ok, %Lease{state: :queued, attempt: 0}} =
             Leases.requeue(Ash.get!(Lease, lease2.id, domain: Portal.Builders))

    assert lease.id != lease2.id
  end

  test "the reaper requeues silent leases and fails exhausted ones" do
    b = builder!("r", 4)
    queued!("fresh")
    queued!("silent")
    queued!("old_upload")
    queued!("exhausted")
    {:ok, fresh} = Leases.claim(b)
    {:ok, silent} = Leases.claim(b)
    {:ok, old_upload} = Leases.claim(b)
    {:ok, exhausted} = Leases.claim(b)

    now = DateTime.utc_now()

    set = fn lease, attrs ->
      lease |> Ash.Changeset.for_update(:update, attrs) |> Ash.update!(domain: Portal.Builders)
    end

    set.(silent, %{heartbeat_at: DateTime.add(now, -11, :minute)})
    set.(old_upload, %{state: :uploading, heartbeat_at: DateTime.add(now, -61, :minute)})
    set.(exhausted, %{heartbeat_at: DateTime.add(now, -11, :minute), attempt: 3})
    set.(fresh, %{heartbeat_at: DateTime.add(now, -9, :minute)})

    assert %{requeued: 2, failed: 1, failed_ids: [exhausted_id]} = Leases.reap(now)
    assert exhausted_id == exhausted.id
    assert Ash.get!(Lease, fresh.id, domain: Portal.Builders).state == :leased
    assert Ash.get!(Lease, silent.id, domain: Portal.Builders).state == :queued
    assert Ash.get!(Lease, old_upload.id, domain: Portal.Builders).state == :queued

    assert %Lease{state: :failed, error: "builder went silent"} =
             Ash.get!(Lease, exhausted.id, domain: Portal.Builders)
  end

  test "fail_by_id fails a held or done lease, errors its request and drops its uploads" do
    root = Path.join(System.tmp_dir!(), "fail-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:portal, Portal.Builders.Upload, [])
    Application.put_env(:portal, Portal.Builders.Upload, Keyword.put(previous, :root, root))

    on_exit(fn ->
      Application.put_env(:portal, Portal.Builders.Upload, previous)
      File.rm_rf(root)
    end)

    {:ok, request} =
      Portal.ScanRequests.create_once(%{
        package_name: "jason",
        version: "1.4.4",
        source: :hex_owner,
        status: :accepted
      })

    {:ok, _} =
      Leases.enqueue(%{
        package: "jason",
        version: "1.4.4",
        image_name: "i",
        image_digest: "sha256:d",
        args: %{},
        scan_request_id: request.id,
        priority: 5
      })

    {:ok, lease} = Leases.claim(builder!("f"))
    {:ok, :done, lease} = Leases.complete(lease, 0)
    File.mkdir_p!(Portal.Builders.Upload.files_dir(lease.id))

    assert {:ok, %Lease{state: :failed, error: "upload missing"}} =
             Leases.fail_by_id(lease.id, "upload missing")

    refute File.exists?(Portal.Builders.Upload.lease_dir(lease.id))
    {:ok, updated} = Portal.ScanRequests.get_request(request.id)
    assert updated.status == :error

    # Already failed: nothing to transition.
    assert {:error, :stale} = Leases.fail_by_id(lease.id, "again")
    assert {:error, :not_found} = Leases.fail_by_id(Ecto.UUID.generate(), "none")
  end

  test "transitions only apply to the lease as the caller saw it" do
    queued!()
    b = builder!("s")
    {:ok, leased} = Leases.claim(b)
    {:ok, :requeued, _} = Leases.complete(leased, 10)

    # The builder's struct is stale now: it no longer holds the lease.
    assert {:error, :not_held} = Leases.heartbeat(leased.id, b.id, "uploading", "late")
    assert {:error, :not_held} = Leases.complete(leased, 0)

    assert %Lease{state: :queued, builder_id: nil, log_tail: nil} =
             Ash.get!(Lease, leased.id, domain: Portal.Builders)

    {:ok, again} = Leases.claim(b)
    {:ok, :done, done} = Leases.complete(again, 0)
    assert {:error, :not_held} = Leases.complete(done, 10)
    assert %Lease{state: :done} = Ash.get!(Lease, done.id, domain: Portal.Builders)
    assert %{requeued: 0, failed: 0} = Leases.reap(DateTime.add(DateTime.utc_now(), 1, :day))
  end

  test "a claim starts the attempt clean" do
    queued!()
    b = builder!("clean")
    {:ok, leased} = Leases.claim(b)
    {:ok, _} = Leases.heartbeat(leased.id, b.id, "uploading", "old tail")
    {:ok, _} = Leases.add_bytes(Ash.get!(Lease, leased.id, domain: Portal.Builders), 10)
    {:ok, :requeued, _} = Leases.complete(Ash.get!(Lease, leased.id, domain: Portal.Builders), 10)

    assert {:ok, %Lease{bytes_uploaded: 0, log_tail: nil, error: nil, attempt: 2}} =
             Leases.claim(b)
  end
end
