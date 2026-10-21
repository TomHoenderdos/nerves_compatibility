defmodule Portal.Precompiled.BatchesTest do
  use Portal.DataCase, async: false
  @moduletag :tmp_dir
  import Portal.PrecompiledFixtures
  import ExUnit.CaptureLog, only: [with_log: 1]
  alias Portal.Precompiled.{Batches, Envelope, Keys, Manifests}

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
             :day
           ) == 7

    sha = doc["manifests"][name]
    {:ok, bytes} = Manifests.read(sha)
    {:ok, ^bytes} = Manifests.render(name)
    assert Batches.manifests(batch) == %{name => sha}
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

  test "a package whose manifest fails to store is dropped with a warning" do
    result = ingest_with_artifact()
    name = result["package"]["name"]

    old_store = Application.get_env(:portal, :artifact_store)

    locked =
      Path.join(System.tmp_dir!(), "locked-artifact-store-#{System.unique_integer([:positive])}")

    File.mkdir_p!(locked)
    File.chmod!(locked, 0o555)

    on_exit(fn ->
      File.chmod!(locked, 0o755)
      File.rm_rf!(locked)
      Application.put_env(:portal, :artifact_store, old_store)
    end)

    Application.put_env(:portal, :artifact_store, path: locked)

    {result, log} =
      with_log(fn ->
        Batches.build_and_sign()
      end)

    assert {:ok, batch} = result
    assert batch.manifest_count == 0
    assert log =~ name
    assert log =~ "[warning]"
  end
end
