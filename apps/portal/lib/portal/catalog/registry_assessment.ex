defmodule Portal.Catalog.RegistryAssessment do
  @moduledoc """
  Records a `Portal.NativeClosure` `:pure` verdict as an ordinary catalog run.

  The verdict goes through `Portal.Catalog.Ingestion` as a `result.json`-shaped
  map with a single `registry_deps` system, so package pages, badges, the
  schema-v2 API and `Portal.Workers.UpdateCheck` read it without knowing it
  never touched Docker. `native_components.compatibility_basis` is what tells
  them apart, the same way #36 marks its `pure_elixir` assessments.

  A `pass` here claims less than any other `pass` in the catalogue: nothing was
  compiled. That was a deliberate choice (see the design spec, 2026-09-30); a
  human request for the package replaces it with a real build.

  `image_digest` is the fixed string `"registry"` rather than a worker image
  digest, which is how `Portal.Workers.Backfill` recognises a package whose
  latest run came from here.

  A fresh record enqueues `Portal.Workers.PackageMeta` for the package, as
  `Portal.Workers.Ingest` does after a real build: this path bypasses that
  worker, and without it a registry-assessed package would never get hex.pm
  links or owners.
  """

  require Logger

  alias Portal.Catalog
  alias Portal.Catalog.Ingestion
  alias Portal.Workers.PackageMeta

  @image_digest "registry"

  @doc "The `image_digest` every registry-assessed run carries."
  @spec image_digest() :: String.t()
  def image_digest, do: @image_digest

  @spec record(String.t(), String.t(), String.t() | nil) ::
          {:ok, Portal.Catalog.Run.t()} | {:error, term()}
  def record(name, version, scan_request_id) do
    run_id = "registry-#{name}-#{version}"

    # Idempotent on the run id, which is unique: a retried Backfill job whose
    # ingest already committed, or a second seed sweep, returns the run on file
    # instead of tripping the constraint.
    case Catalog.committed_run(run_id) do
      {:ok, %{} = run} -> {:ok, run}
      {:ok, nil} -> ingest(name, version, run_id, scan_request_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ingest(name, version, run_id, scan_request_id) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    result = %{
      "package" => %{
        "name" => name,
        "version" => version,
        "description" => nil,
        "native_components" => %{"compatibility_basis" => "registry_deps"}
      },
      "started_at" => now,
      "finished_at" => now,
      "systems" => %{
        "registry_deps" => %{
          "status" => "pass",
          "duration_sec" => 0.0,
          "log_tail" =>
            "Assumed compatible: no native code in the dependency closure on hex.pm. " <>
              "Nothing was compiled."
        }
      }
    }

    # No blobs and no logs: `files_dir` is never read because the system
    # carries no scans, and `output_dir` is omitted so no log is staged.
    with {:ok, run} <-
           Ingestion.ingest(result, %{
             run_id: run_id,
             image_digest: @image_digest,
             files_dir: System.tmp_dir!(),
             scan_request_id: scan_request_id
           }) do
      enqueue_package_meta(name)
      {:ok, run}
    end
  end

  # After the ingest commits and outside its transaction, as in
  # `Portal.Workers.Ingest`: metadata is decoration, so a failed enqueue is
  # logged and dropped rather than failing the record.
  defp enqueue_package_meta(name) do
    case Oban.insert(PackageMeta.new(%{package: name})) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("PackageMeta enqueue failed for #{name}: #{inspect(reason)}")
    end
  end
end
