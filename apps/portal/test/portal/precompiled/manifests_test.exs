defmodule Portal.Precompiled.ManifestsTest do
  use Portal.DataCase, async: false
  alias Portal.{ArtifactStore, Catalog}
  alias Portal.Precompiled.Manifests

  import Portal.PrecompiledFixtures

  test "render gives the same bytes JSON.decode gives the live manifest" do
    result = ingest_with_artifact()
    name = result["package"]["name"]
    assert {:ok, bytes} = Manifests.render(name)
    assert JSON.decode!(bytes) == JSON.decode!(JSON.encode!(Catalog.precompiled_manifest(name)))
    assert Manifests.render("no_such_package") == :none
  end

  test "render_v2 gives the bytes of the live format-2 manifest" do
    name = "tc_render_#{System.unique_integer([:positive])}"
    ingest_toolchain_build(name, "0.3.0")

    assert {:ok, bytes} = Manifests.render_v2(name)

    assert JSON.decode!(bytes) ==
             JSON.decode!(JSON.encode!(Catalog.precompiled_manifest_v2(name)))

    assert Manifests.render_v2("no_such_package") == :none
  end

  test "store writes by sha256 and is idempotent" do
    {:ok, sha} = Manifests.store("hello")
    assert sha == Base.encode16(:crypto.hash(:sha256, "hello"), case: :lower)
    assert ArtifactStore.present?(sha)
    assert {:ok, ^sha} = Manifests.store("hello")
    assert {:ok, "hello"} = Manifests.read(sha)
    assert Manifests.read(String.duplicate("0", 64)) == :error
  end

  test "store repairs a blob that was already present with the wrong bytes" do
    sha = Base.encode16(:crypto.hash(:sha256, "hello"), case: :lower)
    File.mkdir_p!(ArtifactStore.path())
    File.write!(ArtifactStore.blob_path(sha), "wrong bytes")

    assert {:ok, ^sha} = Manifests.store("hello")
    assert {:ok, "hello"} = Manifests.read(sha)
  end

  test "packages_with_precompiled_files lists only packages with stored files" do
    result = ingest_with_artifact()
    assert result["package"]["name"] in Catalog.packages_with_precompiled_files()
  end

  test "store cleans up temp file on ArtifactStore.put failure" do
    leak_bytes = "leak"
    leak_sha = Base.encode16(:crypto.hash(:sha256, leak_bytes), case: :lower)

    # Clean up any leftover files from previous test runs
    glob_pattern = Path.join(System.tmp_dir!(), "manifest-#{leak_sha}-*")

    Path.wildcard(glob_pattern)
    |> Enum.each(&File.rm/1)

    # Force ArtifactStore.put to fail by making the store path non-existent.
    old_config = Application.get_env(:portal, :artifact_store)
    Application.put_env(:portal, :artifact_store, path: "/nonexistent/dir")
    on_exit(fn -> Application.put_env(:portal, :artifact_store, old_config) end)

    # Store will fail with an exception (File.mkdir_p! in ArtifactStore.put_blob).
    # Catch the exception and verify temp cleanup happened.
    try do
      Manifests.store(leak_bytes)
      assert false, "store should have raised an exception"
    catch
      _kind, _reason ->
        # Exception was raised as expected. Now verify temp file was cleaned up.
        assert Path.wildcard(glob_pattern) == [],
               "Temp file was not cleaned up: #{inspect(Path.wildcard(glob_pattern))}"
    end
  end
end
