defmodule Portal.Workers.RemoteBuildTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import ExUnit.CaptureLog

  alias Portal.Builders.{Images, Lease}
  alias Portal.Workers.RemoteBuild

  defmodule StubVersions do
    def latest_version(_package), do: {:ok, "1.4.4"}
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

  test "writes a lease carrying the registry image and the worker input args" do
    {:ok, request} =
      Portal.ScanRequests.create_once(%{
        package_name: "jason",
        version: "1.4.4",
        source: :hex_owner,
        status: :accepted
      })

    assert :ok =
             perform_job(
               RemoteBuild,
               %{"package" => "jason", "version" => "1.4.4", "scan_request_id" => request.id},
               priority: 2
             )

    assert [%Lease{} = lease] = Ash.read!(Lease, domain: Portal.Builders)
    assert lease.package == "jason" and lease.version == "1.4.4" and lease.state == :queued

    assert lease.image_name == "ghcr.io/x/ncc-worker" and
             lease.image_digest == "sha256:" <> String.duplicate("a", 64)

    assert lease.scan_request_id == request.id and lease.priority == 2
    assert Map.has_key?(lease.args, "argus")
  end

  test "dedups on an existing run at the registry digest unless forced" do
    digest = "sha256:" <> String.duplicate("a", 64)

    {:ok, _} =
      Portal.Catalog.Ingestion.ingest(
        %{
          "package" => %{"name" => "jason", "version" => "1.4.4"},
          "finished_at" => "2026-10-10T10:00:00Z",
          "systems" => %{"host" => %{"status" => "pass"}}
        },
        %{run_id: "r", image_digest: digest, files_dir: System.tmp_dir!()}
      )

    assert :ok = perform_job(RemoteBuild, %{"package" => "jason", "version" => "1.4.4"})
    assert [] = Ash.read!(Lease, domain: Portal.Builders)

    assert :ok =
             perform_job(RemoteBuild, %{
               "package" => "jason",
               "version" => "1.4.4",
               "force" => true
             })

    assert [_] = Ash.read!(Lease, domain: Portal.Builders)
  end

  test "dedups on a lease still in flight unless forced" do
    args = %{"package" => "jason", "version" => "1.4.4"}
    assert :ok = perform_job(RemoteBuild, args)
    assert :ok = perform_job(RemoteBuild, args)
    assert [_] = Ash.read!(Lease, domain: Portal.Builders)
    assert :ok = perform_job(RemoteBuild, Map.put(args, "force", true))
    assert [_, _] = Ash.read!(Lease, domain: Portal.Builders)
  end

  test "tooling is recorded as skipped, never leased" do
    assert :ok =
             perform_job(RemoteBuild, %{"package" => "nerves_system_rpi4", "version" => "1.0.0"})

    assert [] = Ash.read!(Lease, domain: Portal.Builders)
    assert [_run] = Ash.read!(Portal.Catalog.Run, domain: Portal.Catalog)
  end

  test "without a registry image the job cancels and the request errors" do
    File.rm!(Images.path())

    {:ok, request} =
      Portal.ScanRequests.create_once(%{
        package_name: "jason",
        version: "1.4.4",
        source: :hex_owner,
        status: :accepted
      })

    args = %{"package" => "jason", "version" => "1.4.4", "scan_request_id" => request.id}

    log =
      capture_log(fn ->
        assert {:cancel, :no_registry_image} = perform_job(RemoteBuild, args)
      end)

    assert log =~ "no registry image"

    {:ok, updated} = Portal.ScanRequests.get_request(request.id)
    assert updated.status == :error
  end
end
