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
      "builder_id" => builder.id
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
