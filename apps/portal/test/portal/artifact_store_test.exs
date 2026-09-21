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
end
