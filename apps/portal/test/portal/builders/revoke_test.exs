defmodule Portal.Builders.RevokeTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Builders
  alias Portal.Builders.{CA, Lease}
  alias Portal.Catalog.Run

  setup do
    dir = Path.join(System.tmp_dir!(), "ncc-ca-#{System.unique_integer([:positive])}")
    key_path = Path.join(dir, "ca-key.pem")
    previous = Application.get_env(:portal, CA, [])
    Application.put_env(:portal, CA, Keyword.put(previous, :key_path, key_path))
    {:ok, _} = CA.init(key_path)

    on_exit(fn ->
      Application.put_env(:portal, CA, previous)
      File.rm_rf(dir)
    end)

    {:ok, %{token: token}} = Builders.create_token("box-r", "admin")
    csr = X509.CSR.new(X509.PrivateKey.new_ec(:secp256r1), "/CN=x") |> X509.CSR.to_pem()
    {:ok, %{builder: builder}} = Builders.enrol(token, csr, %{})
    %{builder: builder}
  end

  defp ingest!(name, version, builder_id) do
    {:ok, run} =
      Portal.Catalog.Ingestion.ingest(
        %{
          "package" => %{"name" => name, "version" => version},
          "finished_at" => "2026-10-10T10:00:00Z",
          "systems" => %{"host" => %{"status" => "pass"}}
        },
        %{
          run_id: "r-#{name}-#{System.unique_integer([:positive])}",
          image_digest: "sha256:x",
          files_dir: System.tmp_dir!(),
          builder_id: builder_id
        }
      )

    run
  end

  test "revoking a builder revokes its runs, requeues its leases and pins the rebuilds locally",
       %{builder: builder} do
    mine = ingest!("jason", "1.4.4", builder.id)
    other = ingest!("decimal", "2.1.1", nil)

    lease =
      Lease
      |> Ash.Changeset.for_create(:create, %{
        package: "plug",
        version: "1.0.0",
        image_name: "i",
        image_digest: "sha256:d",
        args: %{},
        state: :leased,
        builder_id: builder.id,
        attempt: 1
      })
      |> Ash.create!(domain: Builders)

    assert %{runs: 1, packages: ["jason"]} = Builders.revoke_preview(builder)

    assert {:ok, %{runs_revoked: 1, packages: ["jason"], sweep_id: sweep_id}} =
             Builders.revoke(builder)

    assert is_binary(sweep_id)

    assert %Run{revoked_at: %DateTime{}} = Ash.get!(Run, mine.id, domain: Portal.Catalog)
    assert %Run{revoked_at: nil} = Ash.get!(Run, other.id, domain: Portal.Catalog)

    assert %Lease{state: :queued, builder_id: nil, attempt: 1} =
             Ash.get!(Lease, lease.id, domain: Builders)

    assert [job] = all_enqueued(worker: Portal.Workers.Backfill)

    assert job.args["package"] == "jason" and job.args["pin_local"] == true and
             job.args["force"] == true

    assert job.meta["sweep_id"] == sweep_id
  end

  test "a revoke retried after only the status was written still revokes and rebuilds", %{
    builder: builder
  } do
    mine = ingest!("jason", "1.4.4", builder.id)

    revoked =
      builder |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update!(domain: Builders)

    assert {:ok, %{runs_revoked: 1, packages: ["jason"], sweep_id: sweep_id, builder: again}} =
             Builders.revoke(revoked)

    assert is_binary(sweep_id)
    assert again.revoked_at == revoked.revoked_at
    assert %Run{revoked_at: %DateTime{}} = Ash.get!(Run, mine.id, domain: Portal.Catalog)
    assert [job] = all_enqueued(worker: Portal.Workers.Backfill)
    assert job.args["pin_local"] == true
  end
end
