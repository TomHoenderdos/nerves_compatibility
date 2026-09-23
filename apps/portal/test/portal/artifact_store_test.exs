defmodule Portal.ArtifactStoreTest do
  use ExUnit.Case, async: false

  alias Portal.ArtifactStore

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:portal, :artifact_store)
    Application.put_env(:portal, :artifact_store, path: Path.join(dir, "store"))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:portal, :artifact_store, previous),
        else: Application.delete_env(:portal, :artifact_store)
    end)

    %{dir: dir}
  end

  @moduletag :tmp_dir

  test "stores a regular content-addressed blob", %{dir: dir} do
    source = Path.join(dir, "blob")
    File.write!(source, "blob")
    sha = :crypto.hash(:sha256, "blob") |> Base.encode16(case: :lower)
    assert {:ok, %{disk_path: dest}} = ArtifactStore.put(sha, source)
    assert File.read!(dest) == "blob"
  end

  test "rejects path components before touching either file", %{dir: dir} do
    source = Path.join(dir, "source")
    File.write!(source, "keep")

    for sha <- ["../outside", "/tmp/outside", ".", "..", "", String.duplicate("g", 64)] do
      assert {:error, :invalid_sha256} = ArtifactStore.put(sha, source)
    end

    assert File.read!(source) == "keep"
  end

  test "rejects symlinks in worker output", %{dir: dir} do
    source = Path.join(dir, "source")
    target = Path.join(dir, "target")
    File.write!(target, "keep")
    File.ln_s!(target, source)
    assert {:error, :invalid_source} = ArtifactStore.put(String.duplicate("a", 64), source)
    assert File.read!(target) == "keep"
  end

  test "rejects bytes that do not match their digest without publishing them", %{dir: dir} do
    source = Path.join(dir, "source")
    File.write!(source, "wrong bytes")
    sha = :crypto.hash(:sha256, "expected bytes") |> Base.encode16(case: :lower)

    assert {:error, :checksum_mismatch} = ArtifactStore.put(sha, source)
    refute File.exists?(ArtifactStore.blob_path(sha))
    assert File.read!(source) == "wrong bytes"
    assert File.ls!(ArtifactStore.path()) == []
  end

  test "verifies an existing blob when the source was already moved", %{dir: dir} do
    source = Path.join(dir, "source")
    sha = :crypto.hash(:sha256, "expected bytes") |> Base.encode16(case: :lower)
    File.mkdir_p!(ArtifactStore.path())
    File.write!(ArtifactStore.blob_path(sha), "wrong bytes")

    assert {:error, :checksum_mismatch} = ArtifactStore.put(sha, source)

    File.write!(source, "expected bytes")
    assert {:ok, %{disk_path: dest}} = ArtifactStore.put(sha, source)
    assert File.read!(dest) == "expected bytes"
    refute File.exists?(source)
    assert {:ok, %{disk_path: ^dest}} = ArtifactStore.put(sha, source)
  end

  test "a mismatched upload cannot replace an existing valid blob", %{dir: dir} do
    source = Path.join(dir, "source")
    sha = :crypto.hash(:sha256, "expected bytes") |> Base.encode16(case: :lower)
    File.write!(source, "expected bytes")
    assert {:ok, %{disk_path: dest}} = ArtifactStore.put(sha, source)

    File.write!(source, "wrong bytes")
    assert {:error, :checksum_mismatch} = ArtifactStore.put(sha, source)
    assert File.read!(dest) == "expected bytes"
  end

  test "concurrent publishers produce a complete verified blob", %{dir: dir} do
    bytes = :binary.copy("artifact", 32_768)
    sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    sources =
      for n <- 1..4 do
        source = Path.join(dir, "source-#{n}")
        File.write!(source, bytes)
        source
      end

    results = Task.async_stream(sources, &ArtifactStore.put(sha, &1)) |> Enum.to_list()
    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    assert File.read!(ArtifactStore.blob_path(sha)) == bytes
    assert File.ls!(ArtifactStore.path()) == [sha]
  end
end
