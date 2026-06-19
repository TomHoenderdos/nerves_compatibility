defmodule Portal.Workers.Build do
  @moduledoc """
  Oban worker (queue `:builds`) that builds one package against the Nerves
  systems and ingests the result into `Portal.Catalog`.

  Steps:
    1. Dedupe — skip if a `Run` already exists for (package, version, image_digest).
    2. Run the build via `Portal.Builder.build/2`.
    3. Map the worker/runner exit code to an outcome (see `classify/1`).
    4. On success, ingest `result.json` into the Catalog in one transaction.
    5. Update the linked `ScanRequest` status (built / rejected / error).
    6. Broadcast progress to `"request:<scan_request_id>"` over `Portal.PubSub`.

  Exit-code contract (preserved from the runner/orchestrator):

      worker  0   -> success → ingest
      worker  11  -> policy (git/path dep) → cancel, request rejected, no retry
      worker  10  -> internal → retry (Oban backoff)
      runner  20  -> runner error → retry
      runner  21  -> container non-zero → retry; on exhaustion request error
      (pre-check) unknown package → cancel, request rejected
  """

  use Oban.Worker,
    queue: :builds,
    max_attempts: 3,
    unique: [keys: [:package, :version, :image_digest]]

  require Ash.Query
  require Logger

  alias Portal.Builder
  alias Portal.Catalog.{Ingestion, Run}
  alias Portal.ScanRequests

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max_attempts}) do
    package = args["package"]
    version = args["version"]
    image_digest = args["image_digest"] || Builder.docker_image() |> Builder.image_digest()
    scan_request_id = args["scan_request_id"]

    run_id = run_id(package, version)
    broadcast(scan_request_id, :building, %{package: package, version: version})

    cond do
      run_exists?(package, version, image_digest) ->
        Logger.info("Build dedup: run already exists for #{package} #{version}")
        mark_request(scan_request_id, :built)
        broadcast(scan_request_id, :done, %{deduped: true})
        :ok

      true ->
        do_build(package, version, image_digest, scan_request_id, run_id, attempt, max_attempts)
    end
  end

  defp do_build(package, version, image_digest, scan_request_id, run_id, attempt, max_attempts) do
    build_args = %{
      package: package,
      version: version,
      run_id: run_id,
      image_digest: image_digest
    }

    case builder().build(build_args) do
      {:ok, %{exit_code: exit_code} = build} ->
        handle_outcome(
          classify(exit_code),
          build,
          {package, version, image_digest, scan_request_id, run_id, attempt, max_attempts}
        )

      {:error, reason} ->
        # Runner-side failure (docker unavailable, scratch setup). Treat as retryable.
        Logger.error("Builder failed for #{package} #{version}: #{inspect(reason)}")

        on_retry_or_exhaust(
          scan_request_id,
          attempt,
          max_attempts,
          "builder error: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp handle_outcome(:ingest, build, ctx) do
    {_package, _version, image_digest, scan_request_id, run_id, _attempt, _max} = ctx

    case build.result do
      nil ->
        # Exit 0 but no result.json — treat as runner error, retryable.
        Builder.cleanup(run_id)
        {:error, :missing_result_json}

      result ->
        ingest_opts = %{
          run_id: run_id,
          image_digest: image_digest,
          files_dir: build.files_dir,
          scan_request_id: scan_request_id,
          log: build.log
        }

        case Ingestion.ingest(result, ingest_opts) do
          {:ok, run} ->
            Builder.cleanup(run_id)
            mark_request(scan_request_id, :built, run_id: run.id)
            broadcast(scan_request_id, :done, %{run_id: run.id, status: run.overall_status})
            :ok

          {:error, reason} ->
            Logger.error("Ingestion failed for #{run_id}: #{inspect(reason)}")
            Builder.cleanup(run_id)
            {:error, reason}
        end
    end
  end

  defp handle_outcome({:reject, reason}, _build, ctx) do
    {_package, _version, _digest, scan_request_id, run_id, _attempt, _max} = ctx
    Builder.cleanup(run_id)
    mark_request(scan_request_id, :rejected, error_reason: reason)
    broadcast(scan_request_id, :rejected, %{reason: reason})
    {:cancel, reason}
  end

  defp handle_outcome(:retry, build, ctx) do
    {package, version, _digest, scan_request_id, run_id, attempt, max} = ctx
    reason = "worker/runner exit #{build.exit_code}"
    Logger.warning("Build retry for #{package} #{version}: #{reason}")
    Builder.cleanup(run_id)
    on_retry_or_exhaust(scan_request_id, attempt, max, reason)
    {:error, reason}
  end

  @doc """
  Map a worker/runner exit code to an outcome:

    * `:ingest` — success (worker exit 0)
    * `{:reject, reason}` — permanent policy rejection (worker exit 11)
    * `:retry` — transient failure worth retrying (worker 10, runner 20/21, other)
  """
  @spec classify(non_neg_integer()) :: :ingest | {:reject, String.t()} | :retry
  def classify(0), do: :ingest
  def classify(11), do: {:reject, "non-Hex dep"}
  def classify(10), do: :retry
  def classify(20), do: :retry
  def classify(21), do: :retry
  def classify(_other), do: :retry

  # On the final attempt, a retryable failure becomes a permanent `error` on the
  # request; earlier attempts leave it queued so Oban can retry.
  defp on_retry_or_exhaust(scan_request_id, attempt, max_attempts, reason) do
    if attempt >= max_attempts do
      mark_request(scan_request_id, :error, error_reason: reason)
      broadcast(scan_request_id, :error, %{reason: reason})
    end

    :ok
  end

  defp run_exists?(package, version, image_digest) do
    require Ash.Query

    Run
    |> Ash.Query.filter(
      version_tested == ^version and image_digest == ^image_digest and package.name == ^package
    )
    |> Ash.read!(domain: Portal.Catalog)
    |> Enum.any?()
  end

  defp mark_request(id, status), do: mark_request(id, status, [])

  defp mark_request(nil, _status, _opts), do: :ok

  defp mark_request(id, status, opts) when is_binary(id) do
    case ScanRequests.set_status(id, status, opts) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to mark request #{id} #{status}: #{inspect(reason)}")
    end
  end

  defp broadcast(nil, _stage, _payload), do: :ok

  defp broadcast(scan_request_id, stage, payload) when is_binary(scan_request_id) do
    Phoenix.PubSub.broadcast(
      Portal.PubSub,
      "request:#{scan_request_id}",
      {:build_progress, stage, payload}
    )
  end

  defp run_id(package, version) do
    ts = System.system_time(:millisecond)
    "#{package}-#{version}-#{ts}"
  end

  # Builder module is injectable for tests via `config :portal, :build_runner`.
  defp builder, do: Application.get_env(:portal, :build_runner, Builder)
end
