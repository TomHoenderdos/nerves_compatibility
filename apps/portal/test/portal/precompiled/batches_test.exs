defmodule Portal.Precompiled.BatchesTest do
  use Portal.DataCase, async: false
  @moduletag :tmp_dir
  import Portal.PrecompiledFixtures
  import ExUnit.CaptureLog, only: [with_log: 1]
  alias Portal.ArtifactStore
  alias Portal.Precompiled.{Batches, Envelope, Keys, Manifests}

  # The one file `ingest_with_artifact/1` stores.
  @artifact_sha "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"

  setup %{tmp_dir: dir} do
    old = Application.get_env(:portal, :precompiled_signing)
    on_exit(fn -> Application.put_env(:portal, :precompiled_signing, old) end)
    key = Keys.generate()
    path = Path.join(dir, "signing.key")
    Keys.write!(path, key)
    Application.put_env(:portal, :precompiled_signing, key_path: path)
    %{key: key}
  end

  test "without a key, no batch", %{} do
    Application.put_env(:portal, :precompiled_signing, key_path: nil)
    assert {:error, :no_signing_key} = Batches.build_and_sign()
    assert Batches.latest() == nil
  end

  test "with a configured but unreadable key, the failure is distinct and loud" do
    missing =
      Path.join(System.tmp_dir!(), "missing-signing-key-#{System.unique_integer([:positive])}")

    Application.put_env(:portal, :precompiled_signing, key_path: missing)

    {result, log} =
      with_log(fn ->
        Batches.build_and_sign()
      end)

    assert {:error, :signing_key_unreadable} = result
    assert Batches.latest() == nil
    assert log =~ "[error]"
    assert log =~ missing
  end

  test "signs a batch naming every package's manifest hash", %{key: key} do
    result = ingest_with_artifact()
    name = result["package"]["name"]
    assert {:ok, batch} = Batches.build_and_sign()
    assert batch.sequence == 1
    assert batch.manifest_count == 1

    assert {:ok, payload} =
             Envelope.verify(Batches.envelope(batch), %{key.keyid => key.public}, 1)

    doc = JSON.decode!(payload)
    assert doc["version"] == 1 and doc["sequence"] == 1

    assert DateTime.diff(
             DateTime.from_iso8601(doc["expires"]) |> elem(1),
             DateTime.from_iso8601(doc["issued"]) |> elem(1),
             :hour
           ) == 24

    sha = doc["manifests"][name]
    {:ok, bytes} = Manifests.read(sha)
    {:ok, ^bytes} = Manifests.render(name)
    assert Batches.manifests(batch) == %{name => sha}
  end

  test "the payload keeps version 1 and names format-2 manifests in manifests_v2" do
    run = ingest_with_artifact()
    name = run["package"]["name"]
    tc_only = "tc_batch_#{System.unique_integer([:positive])}"
    ingest_toolchain_build(tc_only, "0.3.0")

    assert {:ok, batch} = Batches.build_and_sign()
    doc = JSON.decode!(batch.payload)

    assert doc["version"] == 1
    assert Map.keys(doc["manifests"]) == [name]
    # The fixture run has no toolchain keys, so only the toolchain build is in format 2.
    assert Map.keys(doc["manifests_v2"]) == [tc_only]

    {:ok, bytes} = Manifests.read(doc["manifests_v2"][tc_only])
    assert {:ok, ^bytes} = Manifests.render_v2(tc_only)
    assert JSON.decode!(bytes)["format"] == 2
    assert Batches.manifests_v2(batch) == doc["manifests_v2"]
  end

  test "sequence increments and latest is the newest" do
    ingest_with_artifact()
    {:ok, b1} = Batches.build_and_sign()
    {:ok, b2} = Batches.build_and_sign()
    assert b2.sequence == b1.sequence + 1
    assert Batches.latest().sequence == b2.sequence
    assert Batches.get(b1.sequence).id == b1.id
  end

  test "sequence is unique" do
    ingest_with_artifact()
    {:ok, b1} = Batches.build_and_sign()

    attrs = %{
      sequence: b1.sequence,
      issued_at: b1.issued_at,
      expires_at: b1.expires_at,
      payload: b1.payload,
      signatures: b1.signatures,
      manifest_count: 0
    }

    assert {:error, %Ash.Error.Invalid{}} =
             Portal.Precompiled.Batch
             |> Ash.Changeset.for_create(:create, attrs)
             |> Ash.create(domain: Portal.Precompiled)
  end

  describe "a package whose inputs did not change since the last batch" do
    test "is not loaded again, and the batch names the same stored bytes" do
      run = ingest_with_artifact()
      name = run["package"]["name"]
      ingest_toolchain_build("tc_memo_a_#{System.unique_integer([:positive])}", "0.1.0")
      ingest_toolchain_build("tc_memo_b_#{System.unique_integer([:positive])}", "0.1.0")

      {first, {:ok, b1}} = count_queries(fn -> Batches.build_and_sign() end)
      {second, {:ok, b2}} = count_queries(fn -> Batches.build_and_sign() end)

      assert Batches.manifests(b2) == Batches.manifests(b1)
      assert Batches.manifests_v2(b2) == Batches.manifests_v2(b1)
      assert map_size(Batches.manifests_v2(b2)) == 2
      assert_stored_bytes_are_fresh_renders(b2)
      assert Map.has_key?(Batches.manifests(b2), name)

      # Three packages took a handful of queries each the first time.
      # The second batch reads the fingerprints (before and after) and the
      # package list, records the named shas in one statement, and signs:
      # a count that does not grow with the catalog.
      assert first > 12
      assert second <= 8, "second batch ran #{second} queries"
    end

    test "a revoked run drops out of the next batch" do
      run = ingest_with_artifact()
      name = run["package"]["name"]
      {:ok, b1} = Batches.build_and_sign()
      assert Map.has_key?(Batches.manifests(b1), name)

      {:ok, _} = Portal.Catalog.revoke_run(run["run_id"])

      {:ok, b2} = Batches.build_and_sign()
      refute Map.has_key?(Batches.manifests(b2), name)
    end

    test "a raw rewrite of a result's file manifest in another transaction is picked up" do
      run = ingest_with_artifact()
      name = run["package"]["name"]
      {:ok, b1} = Batches.build_and_sign()

      # What `Portal.Catalog.ManifestModeRepair` does: plain SQL, so
      # `updated_at` stays as it was.
      {:ok, _} =
        Repo.transaction(fn ->
          Repo.query!(
            """
            UPDATE catalog_system_results s
            SET beam_scan = jsonb_set(s.beam_scan, '{footprint,file_manifest,ebin,0,mode}', '33261')
            FROM catalog_runs r
            WHERE r.id = s.run_id AND r.run_id = $1
              AND s.beam_scan->'footprint'->'file_manifest' IS NOT NULL
            """,
            [run["run_id"]]
          )
        end)

      {:ok, b2} = Batches.build_and_sign()
      assert Batches.manifests(b2)[name] != Batches.manifests(b1)[name]
      assert_stored_bytes_are_fresh_renders(b2)
    end

    test "a file that reaches the store after a batch is published by the next one" do
      run = ingest_with_artifact()
      name = run["package"]["name"]
      blob = ArtifactStore.blob_path(@artifact_sha)
      File.rm!(blob)

      {{:ok, b1}, log} = with_log(fn -> Batches.build_and_sign() end)
      assert log =~ "Dropping #{name}"
      refute Map.has_key?(Batches.manifests(b1), name)

      File.write!(blob, "precompiled-beam")

      {:ok, b2} = Batches.build_and_sign()
      assert Map.has_key?(Batches.manifests(b2), name)
      assert_stored_bytes_are_fresh_renders(b2)
    end

    test "a manifest whose stored bytes went missing or wrong is stored again" do
      run = ingest_with_artifact()
      name = run["package"]["name"]
      {:ok, b1} = Batches.build_and_sign()
      sha = Batches.manifests(b1)[name]
      File.write!(ArtifactStore.blob_path(sha), "wrong bytes")

      {:ok, b2} = Batches.build_and_sign()
      assert Batches.manifests(b2)[name] == sha
      assert_stored_bytes_are_fresh_renders(b2)

      File.rm!(ArtifactStore.blob_path(sha))
      {:ok, b3} = Batches.build_and_sign()
      assert Batches.manifests(b3)[name] == sha
      assert_stored_bytes_are_fresh_renders(b3)
    end
  end

  test "a package whose manifest fails to store is dropped with a warning" do
    result = ingest_with_artifact()
    name = result["package"]["name"]

    # Ingestion already landed the package's own artifact under the real
    # store dir, so render/1 succeeds. Make the store dir unwritable only
    # for the manifest put: present?/read of the existing blob only needs
    # read+execute, but ArtifactStore.put's staging write needs write too,
    # so that's the step that fails -- not render/1 finding nothing.
    store_dir = ArtifactStore.path()

    # The fixture renders the same bytes in every test, and a store that
    # already holds them is not written again, so take them out first.
    {:ok, bytes} = Manifests.render(name)

    _ =
      File.rm(ArtifactStore.blob_path(Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)))

    on_exit(fn -> File.chmod!(store_dir, 0o755) end)
    File.chmod!(store_dir, 0o500)

    {result, log} =
      with_log(fn ->
        Batches.build_and_sign()
      end)

    assert {:ok, batch} = result
    assert batch.manifest_count == 0
    assert log =~ name
    assert log =~ "[warning]"
    assert log =~ "eacces"
  end

  describe "content origins" do
    setup do
      old = Application.get_env(:portal, :precompiled_content_origins)
      on_exit(fn -> Application.put_env(:portal, :precompiled_content_origins, old) end)
    end

    test "unset: the payload has no content field" do
      Application.put_env(:portal, :precompiled_content_origins, nil)
      ingest_with_artifact()
      {:ok, batch} = Batches.build_and_sign()
      refute Map.has_key?(JSON.decode!(batch.payload), "content")
    end

    test "set: content is signed into the payload", %{key: key} do
      Application.put_env(
        :portal,
        :precompiled_content_origins,
        "https://cdn.example,https://mirror.example/p"
      )

      ingest_with_artifact()
      {:ok, batch} = Batches.build_and_sign()
      {:ok, payload} = Envelope.verify(Batches.envelope(batch), %{key.keyid => key.public}, 1)
      doc = JSON.decode!(payload)
      assert doc["content"] == ["https://cdn.example", "https://mirror.example/p"]
      assert doc["version"] == 1
    end

    test "invalid: the batch still signs, without content" do
      Application.put_env(:portal, :precompiled_content_origins, "http://cdn.example")
      ingest_with_artifact()
      {result, _log} = with_log(fn -> Batches.build_and_sign() end)
      assert {:ok, batch} = result
      refute Map.has_key?(JSON.decode!(batch.payload), "content")
    end

    # Origins are a payload field, not a manifest input: changing them must
    # not need the memo busted, and must not be hidden by it.
    test "changing origins changes the next batch, and the memo still reuses manifests" do
      ingest_with_artifact()
      Application.put_env(:portal, :precompiled_content_origins, "https://cdn.example")
      {_, {:ok, b1}} = count_queries(fn -> Batches.build_and_sign() end)
      Application.put_env(:portal, :precompiled_content_origins, "https://mirror.example")
      {second, {:ok, b2}} = count_queries(fn -> Batches.build_and_sign() end)

      assert JSON.decode!(b2.payload)["content"] == ["https://mirror.example"]
      assert Batches.manifests(b2) == Batches.manifests(b1)
      assert second <= 8, "second batch ran #{second} queries"
      assert_stored_bytes_are_fresh_renders(b2)
    end
  end

  # Every manifest the batch names, in both formats, is in the store as exactly
  # the bytes a fresh render of the package gives now.
  defp assert_stored_bytes_are_fresh_renders(batch) do
    for {name, sha} <- Batches.manifests(batch) do
      assert {:ok, bytes} = Manifests.read(sha)
      assert {:ok, ^bytes} = Manifests.render(name)
    end

    for {name, sha} <- Batches.manifests_v2(batch) do
      assert {:ok, bytes} = Manifests.read(sha)
      assert {:ok, ^bytes} = Manifests.render_v2(name)
    end
  end

  # Repo queries this process runs inside `fun`.
  defp count_queries(fun) do
    id = {__MODULE__, make_ref()}
    me = self()

    :ok =
      :telemetry.attach(
        id,
        [:portal, :repo, :query],
        fn _event, _measurements, _meta, pid -> if self() == pid, do: send(pid, {id, :query}) end,
        me
      )

    try do
      result = fun.()
      {drain(id, 0), result}
    after
      :telemetry.detach(id)
    end
  end

  defp drain(id, n) do
    receive do
      {^id, :query} -> drain(id, n + 1)
    after
      0 -> n
    end
  end
end
