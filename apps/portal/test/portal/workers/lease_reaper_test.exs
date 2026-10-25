defmodule Portal.Workers.LeaseReaperTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

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
end
