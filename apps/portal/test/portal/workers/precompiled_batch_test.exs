defmodule Portal.Workers.PrecompiledBatchTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo
  @moduletag :tmp_dir
  import Portal.PrecompiledFixtures
  import ExUnit.CaptureLog, only: [with_log: 1]
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

  test "perform with a configured but unreadable key errors loudly instead of cancelling" do
    missing =
      Path.join(System.tmp_dir!(), "missing-signing-key-#{System.unique_integer([:positive])}")

    Application.put_env(:portal, :precompiled_signing, key_path: missing)

    {result, log} =
      with_log(fn ->
        perform_job(PrecompiledBatch, %{})
      end)

    assert {:error, :signing_key_unreadable} = result
    assert Batches.latest() == nil
    assert log =~ "[error]"
    assert log =~ missing
  end
end
