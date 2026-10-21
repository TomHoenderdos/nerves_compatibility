defmodule Portal.Workers.PrecompiledBatchTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo
  @moduletag :tmp_dir
  import Portal.PrecompiledFixtures
  alias Portal.Precompiled.{Batches, Keys}
  alias Portal.Workers.PrecompiledBatch

  setup %{tmp_dir: dir} do
    old = Application.get_env(:portal, :precompiled_signing)
    on_exit(fn -> Application.put_env(:portal, :precompiled_signing, old) end)
    path = Path.join(dir, "signing.key")
    Keys.write!(path, Keys.generate())
    Application.put_env(:portal, :precompiled_signing, key_path: path)
    :ok
  end

  test "runs on the maintenance queue" do
    assert PrecompiledBatch.__opts__()[:queue] == :maintenance
  end

  test "perform signs a batch" do
    ingest_with_artifact()
    assert :ok = perform_job(PrecompiledBatch, %{})
    assert Batches.latest().sequence == 1
  end

  test "perform without a key cancels instead of raising" do
    Application.put_env(:portal, :precompiled_signing, key_path: nil)
    assert {:cancel, :no_signing_key} = perform_job(PrecompiledBatch, %{})
    assert Batches.latest() == nil
  end
end
