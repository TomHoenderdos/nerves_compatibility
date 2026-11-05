defmodule Portal.Precompiled.ManifestRefsTest do
  use Portal.DataCase, async: false
  @moduletag :tmp_dir
  import Portal.PrecompiledFixtures
  alias Portal.Precompiled.{Batches, Keys, ManifestRefs}

  @artifact_sha "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"

  setup %{tmp_dir: dir} do
    old = Application.get_env(:portal, :precompiled_signing)
    on_exit(fn -> Application.put_env(:portal, :precompiled_signing, old) end)
    path = Path.join(dir, "signing.key")
    Keys.write!(path, Keys.generate())
    Application.put_env(:portal, :precompiled_signing, key_path: path)
    :ok
  end

  test "a signed batch records each manifest sha under its own format only" do
    name = ingest_with_artifact()["package"]["name"]
    tc = "tc_refs_#{System.unique_integer([:positive])}"
    ingest_toolchain_build(tc, "0.1.0")
    {:ok, batch} = Batches.build_and_sign()

    v1 = Batches.manifests(batch)[name]
    v2 = Batches.manifests_v2(batch)[tc]
    assert ManifestRefs.named?(v1, 1)
    refute ManifestRefs.named?(v1, 2)
    assert ManifestRefs.named?(v2, 2)
    refute ManifestRefs.named?(v2, 1)
  end

  test "a file blob is never a named manifest" do
    ingest_with_artifact()
    {:ok, _} = Batches.build_and_sign()
    refute ManifestRefs.named?(@artifact_sha, 1)
    refute ManifestRefs.named?(@artifact_sha, 2)
  end

  test "a sha stays named after a later batch stops naming it" do
    first = ingest_with_artifact()
    name = first["package"]["name"]
    {:ok, b1} = Batches.build_and_sign()
    old = Batches.manifests(b1)[name]

    ingest_with_artifact(
      first
      |> Map.put("run_id", "run-2")
      |> Map.put("finished_at", "2026-10-21T12:00:00Z")
    )

    {:ok, b2} = Batches.build_and_sign()
    refute Batches.manifests(b2)[name] == old
    assert ManifestRefs.named?(old, 1)
    assert ManifestRefs.named?(Batches.manifests(b2)[name], 1)
  end

  test "a batch whose insert fails leaves no refs behind" do
    ingest_with_artifact()

    # A trigger that rejects the batch row makes the insert fail after the
    # refs statement ran; both must roll back together.
    Portal.Repo.query!("""
    CREATE FUNCTION ncc_test_reject_batch() RETURNS trigger LANGUAGE plpgsql AS
    $$ BEGIN RAISE EXCEPTION 'rejected'; END $$
    """)

    Portal.Repo.query!("""
    CREATE TRIGGER ncc_test_reject_batch BEFORE INSERT ON precompiled_batches
    FOR EACH ROW EXECUTE FUNCTION ncc_test_reject_batch()
    """)

    assert {:error, _} = Batches.build_and_sign()
    assert %{rows: [[0]]} = Portal.Repo.query!("SELECT count(*) FROM precompiled_manifest_refs")
  end

  test "recording is idempotent and keeps the first sequence" do
    sha = String.duplicate("b", 64)
    :ok = ManifestRefs.record(5, %{"x" => sha}, %{"x" => sha})
    :ok = ManifestRefs.record(6, %{"x" => sha, "y" => sha}, %{})

    assert %{rows: [[5], [5]]} =
             Portal.Repo.query!(
               "SELECT first_sequence FROM precompiled_manifest_refs WHERE sha256 = $1 ORDER BY format",
               [sha]
             )
  end

  test "an empty batch records nothing and does not fail" do
    assert :ok = ManifestRefs.record(1, %{}, %{})
  end

  test "malformed input is never named" do
    refute ManifestRefs.named?("not-a-sha", 1)
    refute ManifestRefs.named?(String.duplicate("A", 64), 1)
  end
end
