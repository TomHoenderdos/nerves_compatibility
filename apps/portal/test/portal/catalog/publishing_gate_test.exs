defmodule Portal.Catalog.PublishingGateTest do
  use Portal.DataCase, async: false

  alias Portal.Builders
  alias Portal.Builders.Builder
  alias Portal.Catalog

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])
  @sha "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"

  defp builder!(name) do
    Builder
    |> Ash.Changeset.for_create(:enrol, %{
      name: name,
      fingerprint: "fp-#{name}",
      cert_pem: "p",
      cert_expires_at: DateTime.utc_now(),
      enrolled_at: DateTime.utc_now()
    })
    |> Ash.create!(domain: Builders)
  end

  defp ingest!(builder_id, run_id) do
    dir = Path.join(System.tmp_dir!(), "gate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    File.write!(Path.join(dir, @sha), "precompiled-beam")
    _ = File.rm(Portal.ArtifactStore.blob_path(@sha))
    result = @fixture |> File.read!() |> Jason.decode!() |> Map.put("run_id", run_id)

    {:ok, run} =
      Catalog.Ingestion.ingest(result, %{
        run_id: run_id,
        image_digest: "sha256:#{run_id}",
        files_dir: dir,
        builder_id: builder_id
      })

    run
  end

  test "publication follows the builder's publishing flag" do
    builder = builder!("gate")
    _remote = ingest!(builder.id, "remote-1")
    assert Catalog.precompiled_manifest("jason") == nil
    assert Catalog.precompiled_manifest_v2("jason") == nil
    assert Catalog.packages_with_precompiled_files() == []

    {:ok, builder} = Builders.set_publishing(builder, true)
    assert %{versions: %{"1.4.1" => _}} = Catalog.precompiled_manifest("jason")
    assert Catalog.packages_with_precompiled_files() == ["jason"]

    {:ok, _} = Builders.revoke(builder)
    assert Catalog.precompiled_manifest("jason") == nil
    assert Catalog.packages_with_precompiled_files() == []
  end

  test "a local run of the same package publishes regardless" do
    builder = builder!("gate2")
    _remote = ingest!(builder.id, "remote-2")
    _local = ingest!(nil, "local-1")
    assert %{versions: %{"1.4.1" => _}} = Catalog.precompiled_manifest("jason")
    assert Catalog.packages_with_precompiled_files() == ["jason"]
  end
end
