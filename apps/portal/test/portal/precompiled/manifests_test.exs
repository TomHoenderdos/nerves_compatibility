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

  test "store writes by sha256 and is idempotent" do
    {:ok, sha} = Manifests.store("hello")
    assert sha == Base.encode16(:crypto.hash(:sha256, "hello"), case: :lower)
    assert ArtifactStore.present?(sha)
    assert {:ok, ^sha} = Manifests.store("hello")
    assert {:ok, "hello"} = Manifests.read(sha)
    assert Manifests.read(String.duplicate("0", 64)) == :error
  end

  test "packages_with_precompiled_files lists only packages with stored files" do
    result = ingest_with_artifact()
    assert result["package"]["name"] in Catalog.packages_with_precompiled_files()
  end
end
