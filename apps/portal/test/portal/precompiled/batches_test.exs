defmodule Portal.Precompiled.BatchesTest do
  use Portal.DataCase, async: false
  @moduletag :tmp_dir
  import Portal.PrecompiledFixtures
  import ExUnit.CaptureLog, only: [with_log: 1]
  alias Portal.ArtifactStore
  alias Portal.Precompiled.{Batches, Envelope, Keys, Manifests}

  # The one file `ingest_with_artifact/1` stores.
  @artifact_sha "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"

  @lv_lock %{"phoenix_live_view" => %{"version" => "1.1.0", "checksum" => "lv"}}

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
      # The second batch reads the fingerprints (before and after), the
      # package list and the systems table, records the named shas in one
      # statement, and signs: a count that does not grow with the catalog.
      assert first > 12
      assert second <= 9, "second batch ran #{second} queries"
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

  describe "a package with config variants" do
    setup do
      drop_legacy_identity_index!()
      name = "cvb_#{System.unique_integer([:positive])}"

      # A LiveView closure: each build is served only on its own mark.
      default =
        ingest_toolchain_build(name, "1.0.0",
          deps_lock: @lv_lock,
          compile_env: lv_default_env(),
          compile_env_rule: 1
        )

      %{name: name, default: default}
    end

    defp v2_builds(batch, name) do
      case Batches.manifests_v2(batch)[name] do
        nil ->
          []

        sha ->
          {:ok, bytes} = Manifests.read(sha)
          JSON.decode!(bytes)["versions"]["1.0.0"]["builds"]
      end
    end

    defp variant!(name, config_variant) do
      ingest_toolchain_build(name, "1.0.0",
        config_variant: config_variant,
        deps_lock: @lv_lock,
        compile_env: overlay_env(config_variant),
        compile_env_rule: 1
      )
    end

    test "the batch signs the bytes the format-2 route serves", %{name: name} do
      variant!(name, "phx_dev")

      assert {:ok, batch} = Batches.build_and_sign()
      sha = JSON.decode!(batch.payload)["manifests_v2"][name]
      {:ok, bytes} = Manifests.read(sha)
      assert length(JSON.decode!(bytes)["versions"]["1.0.0"]["builds"]) == 2
      assert {:ok, ^bytes} = Manifests.render_v2(name)
      assert_stored_bytes_are_fresh_renders(batch)
    end

    test "adding a variant renders the package again", %{name: name} do
      {:ok, b1} = Batches.build_and_sign()
      assert length(v2_builds(b1, name)) == 1

      variant!(name, "phx_prod")

      {:ok, b2} = Batches.build_and_sign()
      assert Batches.manifests_v2(b2)[name] != Batches.manifests_v2(b1)[name]
      assert length(v2_builds(b2, name)) == 2
      assert_stored_bytes_are_fresh_renders(b2)
    end

    test "revoking the default withdraws its variants in the same batch", ctx do
      variant!(ctx.name, "phx_prod")
      {:ok, b1} = Batches.build_and_sign()
      assert length(v2_builds(b1, ctx.name)) == 2

      ctx.default |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update!(domain: Portal.Catalog)

      {:ok, b2} = Batches.build_and_sign()
      assert v2_builds(b2, ctx.name) == []
      refute Map.has_key?(Batches.manifests_v2(b2), ctx.name)
    end

    test "a default whose mark is lost in another transaction withdraws its variants", ctx do
      variant!(ctx.name, "phx_prod")
      {:ok, b1} = Batches.build_and_sign()
      assert length(v2_builds(b1, ctx.name)) == 2

      # A raw upsert's leftover mark: `updated_at` stays as it was.
      {:ok, _} =
        Repo.transaction(fn ->
          Repo.query!(
            "UPDATE catalog_toolchain_builds SET compile_env_run_id = 'tc-stale' WHERE id = $1",
            [Ecto.UUID.dump!(ctx.default.id)]
          )
        end)

      {:ok, b2} = Batches.build_and_sign()
      assert v2_builds(b2, ctx.name) == []
      refute Map.has_key?(Batches.manifests_v2(b2), ctx.name)
    end

    test "a variant whose own mark is lost is withdrawn alone", ctx do
      variant = variant!(ctx.name, "phx_prod")
      {:ok, b1} = Batches.build_and_sign()
      assert length(v2_builds(b1, ctx.name)) == 2

      {:ok, _} =
        Repo.transaction(fn ->
          Repo.query!(
            "UPDATE catalog_toolchain_builds SET compile_env_run_id = 'tc-stale' WHERE id = $1",
            [Ecto.UUID.dump!(variant.id)]
          )
        end)

      {:ok, b2} = Batches.build_and_sign()
      assert [build] = v2_builds(b2, ctx.name)
      refute Map.has_key?(build["build"], "config_variant")
      assert_stored_bytes_are_fresh_renders(b2)
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
      assert second <= 9, "second batch ran #{second} queries"
      assert_stored_bytes_are_fresh_renders(b2)
    end
  end

  describe "the systems table" do
    defp abi_row!(system, version) do
      {:ok, _row} =
        Portal.Catalog.SystemAbi.observe(%{
          system_pkg: system,
          version: version,
          source: "lock",
          toolchain_pkg: "nerves_toolchain_aarch64_nerves_linux_gnu",
          toolchain_version: "15.3.1",
          otp: "28.1.2",
          libs: %{"libc.so.6" => ["GLIBC_2.17"]}
        })

      :ok
    end

    test "a batch names the table by the SHA-256 of the bytes stored for it" do
      ingest_toolchain_build("tc_sys_#{System.unique_integer([:positive])}", "0.1.0")
      abi_row!("nerves_system_rpi4", "2.2.2")

      assert {:ok, batch} = Batches.build_and_sign()
      doc = JSON.decode!(batch.payload)

      assert doc["version"] == 1
      assert doc["systems"] =~ ~r/\A[0-9a-f]{64}\z/
      assert {:ok, body} = Portal.Precompiled.SystemAbi.stored(doc["systems"])
      assert Base.encode16(:crypto.hash(:sha256, body), case: :lower) == doc["systems"]
      assert {doc["systems"], body} == Portal.Precompiled.SystemAbi.render()
    end

    test "without rows the payload has no systems key" do
      ingest_toolchain_build("tc_nosys_#{System.unique_integer([:positive])}", "0.1.0")
      assert {:ok, batch} = Batches.build_and_sign()
      refute Map.has_key?(JSON.decode!(batch.payload), "systems")
    end

    test "a new release changes the table and no manifest" do
      ingest_with_artifact()
      ingest_toolchain_build("tc_stable_#{System.unique_integer([:positive])}", "0.1.0")
      abi_row!("nerves_system_rpi4", "2.2.2")
      {:ok, b1} = Batches.build_and_sign()

      abi_row!("nerves_system_rpi4", "2.3.0")
      {:ok, b2} = Batches.build_and_sign()

      systems = &JSON.decode!(&1.payload)["systems"]
      assert systems.(b2) != systems.(b1)
      assert {:ok, _} = Portal.Precompiled.SystemAbi.stored(systems.(b1))
      assert {:ok, _} = Portal.Precompiled.SystemAbi.stored(systems.(b2))
      assert map_size(Batches.manifests_v2(b2)) > 0
      assert Batches.manifests_v2(b2) == Batches.manifests_v2(b1)
      assert Batches.manifests(b2) == Batches.manifests(b1)
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
