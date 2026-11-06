defmodule Portal.Workers.IngestRemoteTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query
  import Ecto.Query, only: [from: 2]

  alias Portal.Builders.{Builder, Lease, Leases, Upload}
  alias Portal.Catalog.Run
  alias Portal.Workers.Ingest

  @fixture_result Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])
                  |> File.read!()
                  |> Jason.decode!()
  @sha "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"

  setup do
    root = Path.join(System.tmp_dir!(), "uploads-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:portal, Upload, [])
    Application.put_env(:portal, Upload, Keyword.put(previous, :root, root))

    on_exit(fn ->
      Application.put_env(:portal, Upload, previous)
      File.rm_rf(root)
    end)

    builder =
      Builder
      |> Ash.Changeset.for_create(:enrol, %{
        name: "ing",
        fingerprint: "fp-ing",
        cert_pem: "p",
        cert_expires_at: DateTime.utc_now(),
        enrolled_at: DateTime.utc_now()
      })
      |> Ash.create!(domain: Portal.Builders)

    {:ok, request} =
      Portal.ScanRequests.create_once(%{
        package_name: "jason",
        version: "1.4.1",
        source: :hex_owner,
        status: :accepted
      })

    {:ok, _} =
      Leases.enqueue(%{
        package: "jason",
        version: "1.4.1",
        image_name: "i",
        image_digest: "sha256:#{String.duplicate("e", 64)}",
        args: %{},
        scan_request_id: request.id,
        priority: 5
      })

    {:ok, lease} = Leases.claim(builder)
    {:ok, :done, lease} = Leases.complete(lease, 0)
    %{builder: builder, lease: lease, request: request}
  end

  defp seed_outputs!(lease, result) do
    File.mkdir_p!(Upload.files_dir(lease.id))
    File.mkdir_p!(Upload.out_dir(lease.id))
    File.write!(Path.join(Upload.out_dir(lease.id), "result.json"), Jason.encode!(result))
    File.write!(Path.join(Upload.out_dir(lease.id), "runner.log"), "remote runner log")
  end

  defp args(lease, builder),
    do: %{
      "source" => "remote",
      "lease_id" => lease.id,
      "run_id" => lease.run_id,
      "image_digest" => lease.image_digest,
      "scan_request_id" => lease.scan_request_id,
      "builder_id" => builder.id,
      "arch" => "aarch64"
    }

  test "ingests the uploaded run with its builder and cleans the upload dir", %{
    builder: builder,
    lease: lease,
    request: request
  } do
    File.mkdir_p!(Upload.files_dir(lease.id))
    File.write!(Path.join(Upload.files_dir(lease.id), @sha), "precompiled-beam")
    _ = File.rm(Portal.ArtifactStore.blob_path(@sha))
    result = put_in(@fixture_result, ["run_id"], lease.run_id)
    seed_outputs!(lease, result)

    assert :ok = perform_job(Ingest, args(lease, builder))

    run =
      Run
      |> Ash.Query.filter(run_id == ^lease.run_id)
      |> Ash.read_one!(domain: Portal.Catalog)

    assert run.builder_id == builder.id
    assert run.image_digest == lease.image_digest
    assert run.arch == "aarch64"
    # A passing run drops its runner log (`Ingestion.run_log/2`); the failing
    # run below shows the upload's runner log reaches the run.
    assert run.log == nil
    assert Portal.ArtifactStore.present?(@sha)
    {:ok, updated} = Portal.ScanRequests.get_request(request.id)
    assert updated.status == :built
    assert updated.run_id == run.id
    refute File.exists?(Upload.lease_dir(lease.id))
  end

  test "a failing uploaded run keeps the uploaded runner log", %{builder: builder, lease: lease} do
    result =
      @fixture_result
      |> put_in(["run_id"], lease.run_id)
      |> put_in(["systems", "nerves_system_rpi4", "status"], "fail")
      |> put_in(["systems", "nerves_system_rpi4", "beam_scan"], nil)

    seed_outputs!(lease, result)

    assert :ok = perform_job(Ingest, args(lease, builder))

    run =
      Run
      |> Ash.Query.filter(run_id == ^lease.run_id)
      |> Ash.read_one!(domain: Portal.Catalog)

    assert run.overall_status == :fail
    assert run.builder_id == builder.id
    assert run.log == "remote runner log"
    refute File.exists?(Upload.lease_dir(lease.id))
  end

  test "a missing upload fails the lease and the request", %{
    builder: builder,
    lease: lease,
    request: request
  } do
    assert {:cancel, _} = perform_job(Ingest, args(lease, builder))

    assert %Lease{state: :failed, error: "upload missing"} =
             Ash.get!(Lease, lease.id, domain: Portal.Builders)

    {:ok, updated} = Portal.ScanRequests.get_request(request.id)
    assert updated.status == :error
  end

  defp run_for(lease) do
    Run
    |> Ash.Query.filter(run_id == ^lease.run_id)
    |> Ash.read_one!(domain: Portal.Catalog)
  end

  # A remote builder only ever reads the shared build cache. What its worker
  # compiled and reported as cache candidates is never promoted into this
  # host's cache nor uploaded to L2: only `Portal.Workers.Build` runs
  # `Portal.BuildCache.Promotion`, and Ingest ignores the result's `cache`.
  test "a remote run's build cache candidates are never promoted or uploaded", %{
    builder: builder,
    lease: lease
  } do
    {:ok, s3} = Portal.Test.FakeS3.start()
    cache = Path.join(System.tmp_dir!(), "remote-cache-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cache)
    builder_config = Application.get_env(:portal, Portal.Builder, [])
    l2_config = Application.get_env(:portal, Portal.BuildCache.L2)
    Application.put_env(:portal, Portal.Builder, Keyword.put(builder_config, :build_cache, cache))

    Application.put_env(:portal, Portal.BuildCache.L2,
      endpoint: s3.endpoint,
      bucket: s3.bucket,
      region: s3.region,
      access_key: s3.access_key,
      secret_key: s3.secret_key
    )

    on_exit(fn ->
      Application.put_env(:portal, Portal.Builder, builder_config)

      if l2_config,
        do: Application.put_env(:portal, Portal.BuildCache.L2, l2_config),
        else: Application.delete_env(:portal, Portal.BuildCache.L2)

      File.rm_rf(cache)
    end)

    key = String.duplicate("d", 64)

    candidate = %{
      "key" => key,
      "dep" => "jason",
      "dep_lock" => "1.4.1 x y",
      "target" => "host",
      "elixir" => "1.19.0",
      "otp" => "28",
      "closure" => []
    }

    result =
      @fixture_result
      |> put_in(["run_id"], lease.run_id)
      |> Map.put("cache", %{"candidates" => [candidate]})

    seed_outputs!(lease, result)
    planted = Path.join([Upload.out_dir(lease.id), "build-cache", key, "ebin"])
    File.mkdir_p!(planted)
    File.write!(Path.join(planted, "Elixir.Jason.beam"), "planted")

    assert :ok = perform_job(Ingest, args(lease, builder))
    assert run_for(lease)

    assert File.ls!(cache) == []
    assert Portal.Test.FakeS3.requests(s3) == []
  end

  # The request can go while the remote build runs; the run is kept,
  # unlinked, instead of tripping the scan_request_id foreign key on every
  # attempt and losing the upload.
  test "a deleted request does not fail the ingest", %{
    builder: builder,
    lease: lease,
    request: request
  } do
    seed_outputs!(lease, put_in(@fixture_result, ["run_id"], lease.run_id))

    Repo.delete_all(
      from(r in "portal_scan_requests", where: r.id == type(^request.id, Ecto.UUID))
    )

    assert :ok = perform_job(Ingest, args(lease, builder))

    run = run_for(lease)
    assert run.scan_request_id == nil
    assert run.builder_id == builder.id
    refute File.exists?(Upload.lease_dir(lease.id))
  end

  test "the last failed attempt fails the lease and errors the request", %{
    builder: builder,
    lease: lease,
    request: request
  } do
    # A result.json `Ingestion` cannot map.
    seed_outputs!(lease, %{
      "run_id" => lease.run_id,
      "package" => %{"name" => "jason", "version" => "1.4.1"},
      "systems" => "not a map"
    })

    assert {:error, _} = perform_job(Ingest, args(lease, builder), attempt: 1)

    assert %Lease{state: :done} = Ash.get!(Lease, lease.id, domain: Portal.Builders)
    assert File.exists?(Upload.lease_dir(lease.id))

    assert {:error, _} = perform_job(Ingest, args(lease, builder), attempt: 5)

    assert %Lease{state: :failed, error: "ingestion failed: " <> _} =
             Ash.get!(Lease, lease.id, domain: Portal.Builders)

    {:ok, updated} = Portal.ScanRequests.get_request(request.id)
    assert updated.status == :error
    assert "ingestion failed: " <> _ = updated.error_reason
    refute File.exists?(Upload.lease_dir(lease.id))
    assert run_for(lease) == nil
  end

  # The complete endpoint refuses such a result; this is the same check once
  # more, on what is on disk, before it becomes another package's run.
  test "a result.json for another package fails the lease instead of being ingested", %{
    builder: builder,
    lease: lease,
    request: request
  } do
    result =
      @fixture_result
      |> put_in(["run_id"], lease.run_id)
      |> put_in(["package", "name"], "phoenix")

    seed_outputs!(lease, result)

    assert {:cancel, _} = perform_job(Ingest, args(lease, builder))
    assert Ash.get!(Lease, lease.id, domain: Portal.Builders).state == :failed
    assert Portal.Catalog.committed_run(lease.run_id) == {:ok, nil}
    {:ok, updated} = Portal.ScanRequests.get_request(request.id)
    assert updated.status == :error
    refute File.exists?(Upload.lease_dir(lease.id))
  end

  # Ingest checks the result against the job it was enqueued for, which for
  # a remote build is its lease: refused the way a local build's job is, with
  # the lease failed under the refusal's reason.
  test "a result.json for another package than its lease is refused like a local one", %{
    builder: builder,
    lease: lease,
    request: request
  } do
    result =
      @fixture_result
      |> put_in(["run_id"], lease.run_id)
      |> put_in(["package", "name"], "phoenix")

    seed_outputs!(lease, result)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:cancel, "ingest refused: " <> _} = perform_job(Ingest, args(lease, builder))
      end)

    assert log =~ "security:"
    assert log =~ ~s("jason" "1.4.1")
    assert log =~ ~s("phoenix" "1.4.1")

    assert %Lease{state: :failed, error: "ingest refused: " <> _} =
             Ash.get!(Lease, lease.id, domain: Portal.Builders)

    assert Portal.Catalog.committed_run(lease.run_id) == {:ok, nil}

    refute Portal.Catalog.Package
           |> Ash.Query.filter(name == "phoenix")
           |> Ash.exists?(domain: Portal.Catalog)

    {:ok, updated} = Portal.ScanRequests.get_request(request.id)
    assert updated.status == :error
    assert "ingest refused: " <> _ = updated.error_reason
    refute File.exists?(Upload.lease_dir(lease.id))
  end

  test "an upload from a builder revoked since is dropped and fails the lease", %{
    builder: builder,
    lease: lease,
    request: request
  } do
    seed_outputs!(lease, put_in(@fixture_result, ["run_id"], lease.run_id))

    builder
    |> Ash.Changeset.for_update(:revoke, %{})
    |> Ash.update!(domain: Portal.Builders)

    assert {:cancel, "builder revoked"} = perform_job(Ingest, args(lease, builder))

    assert %Lease{state: :failed, error: "builder revoked"} =
             Ash.get!(Lease, lease.id, domain: Portal.Builders)

    {:ok, updated} = Portal.ScanRequests.get_request(request.id)
    assert updated.status == :error
    refute File.exists?(Upload.lease_dir(lease.id))
    assert run_for(lease) == nil
  end
end
