defmodule Portal.Catalog.PublishingGateTest do
  use Portal.DataCase, async: false

  alias Portal.Builders
  alias Portal.Builders.Builder
  alias Portal.Catalog
  alias Portal.Precompiled.{Batches, Keys, Manifests}

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
        package: result["package"]["name"],
        version: result["package"]["version"],
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

  # The blob endpoint applies the same gate: a file only a non-publishing or
  # revoked builder uploaded is stored, but not served by sha.
  test "the blob endpoint follows the gate too" do
    builder = builder!("gate-blob")
    _remote = ingest!(builder.id, "remote-blob")
    assert Catalog.artifact_by_sha256(@sha)
    refute Catalog.published_sha256?(@sha)

    {:ok, builder} = Builders.set_publishing(builder, true)
    assert Catalog.published_sha256?(@sha)

    {:ok, _} = Builders.revoke(builder)
    refute Catalog.published_sha256?(@sha)

    _local = ingest!(nil, "local-blob")
    assert Catalog.published_sha256?(@sha)
  end

  test "a local run of the same package publishes regardless" do
    builder = builder!("gate2")
    _remote = ingest!(builder.id, "remote-2")
    _local = ingest!(nil, "local-1")
    assert %{versions: %{"1.4.1" => _}} = Catalog.precompiled_manifest("jason")
    assert Catalog.packages_with_precompiled_files() == ["jason"]
  end

  # The flag lives on the builder's row, not the run's, and the package stays
  # in the batch through its local run, so only a fingerprint that carries the
  # builder's state notices that the remote run left the manifest.
  @tag :tmp_dir
  test "the next batch follows a change to the flag", %{tmp_dir: dir} do
    signing_key!(dir)

    builder = builder!("gate-batch")
    {:ok, builder} = Builders.set_publishing(builder, true)
    _local = ingest!(nil, "local-batch")
    _remote = ingest!(builder.id, "remote-batch")

    {:ok, b1} = Batches.build_and_sign()
    {:ok, _} = Builders.set_publishing(builder, false)
    {:ok, b2} = Batches.build_and_sign()

    assert Batches.manifests(b2)["jason"] != Batches.manifests(b1)["jason"]
    assert {:ok, bytes} = Manifests.read(Batches.manifests(b2)["jason"])
    assert {:ok, ^bytes} = Manifests.render("jason")
  end

  # A-B-A: the flag flips right after a batch read its fingerprints, so that
  # batch renders the other state, and flips back before the next batch.
  # Neither the remembered fingerprint nor the reverted flag may let the next
  # batch reuse what was rendered in between.
  for start <- [false, true] do
    @tag :tmp_dir
    @tag start: start
    test "a flag flipped during a batch and back (starting #{start}) is not remembered", %{
      tmp_dir: dir,
      start: start
    } do
      signing_key!(dir)
      builder = builder!("gate-aba-#{start}")
      {:ok, builder} = Builders.set_publishing(builder, start)
      _local = ingest!(nil, "local-aba")
      _remote = ingest!(builder.id, "remote-aba")
      {:ok, start_bytes} = Manifests.render("jason")

      flip_after_first_fingerprint_read(fn -> Builders.set_publishing(builder, not start) end)
      {:ok, _b1} = Batches.build_and_sign()

      {:ok, builder} = Builders.get_builder(builder.id)
      {:ok, _} = Builders.set_publishing(builder, start)
      {:ok, b2} = Batches.build_and_sign()

      assert {:ok, ^start_bytes} = Manifests.read(Batches.manifests(b2)["jason"])
    end
  end

  defp signing_key!(dir) do
    old = Application.get_env(:portal, :precompiled_signing)
    on_exit(fn -> Application.put_env(:portal, :precompiled_signing, old) end)
    key_path = Path.join(dir, "signing.key")
    Keys.write!(key_path, Keys.generate())
    Application.put_env(:portal, :precompiled_signing, key_path: key_path)
  end

  # Runs `flip` once, in this process, right after the first fingerprint query
  # of the batch that follows returns.
  defp flip_after_first_fingerprint_read(flip) do
    me = self()
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        id,
        [:portal, :repo, :query],
        fn _event, _measurements, meta, _ ->
          if self() == me and not Process.get(id, false) and meta.query =~ "WITH runs AS" do
            Process.put(id, true)
            {:ok, _} = flip.()
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end
end
