defmodule Portal.PrecompiledFixtures do
  @moduledoc """
  Fixtures for precompiled artifact tests.
  """

  import ExUnit.Callbacks

  alias Portal.ArtifactStore
  alias Portal.Catalog.Ingestion

  @fixture Path.join([__DIR__, "..", "fixtures", "result.json"])

  @doc """
  Ingests a result with a precompiled artifact file.
  """
  def ingest_with_artifact(result \\ result_fixture()) do
    sha = "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"
    _ = File.rm(ArtifactStore.blob_path(sha))
    dir = Path.join(System.tmp_dir!(), "catalog-api-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, sha), "precompiled-beam")
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _run} =
      Ingestion.ingest(result, %{
        run_id: result["run_id"],
        image_digest: "sha256:precompiled",
        files_dir: dir,
        scan_request_id: nil,
        log: "api log"
      })

    result
  end

  defp result_fixture do
    @fixture |> File.read!() |> Jason.decode!()
  end
end
