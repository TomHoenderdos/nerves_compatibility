defmodule Portal.Workers.Ingest do
  @moduledoc """
  Oban worker (queue `:ingest`) that turns one finished build's `result.json`
  into Catalog rows.

  Split out of `Portal.Workers.Build` because the two failure modes have nothing
  to do with each other. A build fails for reasons only another build can fix; an
  ingest fails because the database was busy, a constraint tripped, or the blob
  store hiccuped. While both lived in one job, the second kind of failure
  re-ran the first kind of work: a retry threw away a finished multi-target
  firmware build and spent another ~15 minutes reproducing it byte for byte.

  The run's scratch directory is the handoff. `Build` leaves it in place and
  enqueues this worker; this worker reads it back through
  `Portal.Builder.load_run/1` and only removes it once the rows are committed or
  the last attempt is spent. Retries therefore cost a database round trip, not a
  rebuild.
  """

  use Oban.Worker,
    queue: :ingest,
    max_attempts: 5,
    unique: [keys: [:run_id]]

  require Logger

  alias Portal.Builder
  alias Portal.Catalog.Ingestion
  alias Portal.Workers.Progress

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max_attempts}) do
    run_id = args["run_id"]
    image_digest = args["image_digest"]
    scan_request_id = args["scan_request_id"]

    case builder().load_run(run_id) do
      {:ok, build} ->
        ingest(build, run_id, image_digest, scan_request_id, attempt, max_attempts)

      {:error, reason} ->
        # The scratch dir is gone, so there is nothing a retry could read. Fail
        # the request rather than looping on an empty directory.
        Logger.error("Ingest found no build output for #{run_id}: #{inspect(reason)}")
        message = "build output missing: #{inspect(reason)}"
        Progress.mark(scan_request_id, :error, error_reason: message)
        Progress.broadcast(scan_request_id, :error, %{reason: message})
        {:cancel, message}
    end
  end

  defp ingest(build, run_id, image_digest, scan_request_id, attempt, max_attempts) do
    ingest_opts = %{
      run_id: run_id,
      image_digest: image_digest,
      files_dir: build.files_dir,
      scan_request_id: scan_request_id,
      log: build.log
    }

    case safe_ingest(build.result, ingest_opts) do
      {:ok, run} ->
        Builder.cleanup(run_id)
        Progress.mark(scan_request_id, :built, run_id: run.id)
        Progress.broadcast(scan_request_id, :done, %{run_id: run.id, status: run.overall_status})
        :ok

      {:error, reason} ->
        Logger.error("Ingestion failed for #{run_id}: #{inspect(reason)}")

        # Keep the scratch dir until the attempts are spent; it is the only copy
        # of the build a retry can work from.
        if attempt >= max_attempts do
          Builder.cleanup(run_id)
          message = "ingestion failed: #{inspect(reason)}"
          Progress.mark(scan_request_id, :error, error_reason: message)
          Progress.broadcast(scan_request_id, :error, %{reason: message})
        end

        {:error, reason}
    end
  end

  # `Ingestion.ingest/2` raises on a result.json it cannot map, rather than
  # returning an error. Both failures need the same bookkeeping here, so
  # normalise them: a raised exception would take the job down before the last
  # attempt could free the scratch dir and mark the request.
  defp safe_ingest(result, opts) do
    Ingestion.ingest(result, opts)
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Builder module is injectable for tests via `config :portal, :build_runner`.
  defp builder, do: Application.get_env(:portal, :build_runner, Builder)
end
