defmodule Portal.Workers.Build do
  @moduledoc """
  Oban worker (queue `:builds`) that builds one package against the Nerves
  systems and hands the result to `Portal.Workers.Ingest`.

  Steps:
    1. Dedupe — skip if a `Run` already exists for (package, version, image_digest).
    2. Run the build via `Portal.Builder.build/2`.
    3. Map the worker/runner exit code to an outcome (see `classify/1`).
    4. On success, enqueue `Portal.Workers.Ingest` and leave the scratch dir in
       place for it to read.
    5. Update the linked `ScanRequest` status (rejected / error; `built` is the
       ingest job's to set).
    6. Broadcast progress to `"request:<scan_request_id>"` over `Portal.PubSub`.

  The Catalog write deliberately does not happen here. A retry of this job costs
  a full multi-target firmware rebuild, and a database-side failure is not a
  reason to pay it.

  Exit-code contract:

      worker   0  -> success → ingest
      worker  11  -> policy (git/path dep) → cancel, request rejected, no retry
      worker  10  -> internal → retry (Oban backoff)
      host    20  -> host/Docker invocation error → retry
      host    21  -> container non-zero → retry; on exhaustion request error
      (pre-check) unknown package → cancel, request rejected
  """

  use Oban.Worker,
    queue: :builds,
    max_attempts: 3,
    unique: [keys: [:package, :version, :image_digest]]

  require Ash.Query
  require Logger

  alias Portal.Builder
  alias Portal.Catalog.Run
  alias Portal.Workers.{Ingest, Progress}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max_attempts}) do
    package = args["package"]
    version = args["version"]
    image_digest = args["image_digest"] || Builder.docker_image() |> Builder.image_digest()
    scan_request_id = args["scan_request_id"]

    run_id = run_id(package, version)
    Progress.broadcast(scan_request_id, :building, %{package: package, version: version})

    cond do
      run_exists?(package, version, image_digest) ->
        Logger.info("Build dedup: run already exists for #{package} #{version}")
        Progress.mark(scan_request_id, :built)
        Progress.broadcast(scan_request_id, :done, %{deduped: true})
        :ok

      true ->
        with_crash_cleanup(scan_request_id, run_id, attempt, max_attempts, fn ->
          do_build(package, version, image_digest, scan_request_id, run_id, attempt, max_attempts)
        end)
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

      _result ->
        # No cleanup: the scratch dir is what the ingest job reads, and it owns
        # removing it once the rows are committed.
        enqueue_ingest(run_id, image_digest, scan_request_id)
    end
  end

  defp handle_outcome({:reject, reason}, _build, ctx) do
    {_package, _version, _digest, scan_request_id, run_id, _attempt, _max} = ctx
    Builder.cleanup(run_id)
    Progress.mark(scan_request_id, :rejected, error_reason: reason)
    Progress.broadcast(scan_request_id, :rejected, %{reason: reason})
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

  defp enqueue_ingest(run_id, image_digest, scan_request_id) do
    args =
      %{"run_id" => run_id, "image_digest" => image_digest}
      |> maybe_put("scan_request_id", scan_request_id)

    case args |> Ingest.new() |> Oban.insert() do
      {:ok, _job} ->
        # Nothing after this point may raise. The ingest job now owns the
        # scratch dir, and `with_crash_cleanup/5` deletes it on the way out of
        # an exception — which is only correct while no ingest job exists yet.
        safely("ingesting broadcast", fn ->
          Progress.broadcast(scan_request_id, :ingesting, %{run_id: run_id})
        end)

        :ok

      {:error, reason} ->
        # Nothing will pick the build up, so fail the job. Costly (the retry
        # rebuilds), but only reachable when the database is unavailable, in
        # which case ingesting was never going to work either.
        Logger.error("Could not enqueue ingest for #{run_id}: #{inspect(reason)}")
        Builder.cleanup(run_id)
        {:error, reason}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
      Progress.mark(scan_request_id, :error, error_reason: reason)
      Progress.broadcast(scan_request_id, :error, %{reason: reason})
    end

    :ok
  end

  # Every cleanup path above is reached by *returning* a value, so an exception
  # skips all of them: the scratch dir is never removed and the linked request
  # is stranded at `queued` forever, because `on_retry_or_exhaust/4` never runs.
  #
  # That is not hypothetical. A full disk made `IO.binwrite/2` raise `:enospc`
  # while streaming docker output, and the leak was self-reinforcing — each
  # crashed build left another multi-gigabyte scratch dir behind, which made the
  # next `:enospc` more likely. It took the build host down for four days.
  #
  # Run the same bookkeeping for a crash, then re-raise, so Oban still sees the
  # real exception and applies its normal retry/discard behaviour.
  defp with_crash_cleanup(scan_request_id, run_id, attempt, max_attempts, fun) do
    fun.()
  rescue
    exception ->
      crash_cleanup(scan_request_id, run_id, attempt, max_attempts, Exception.message(exception))
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      crash_cleanup(scan_request_id, run_id, attempt, max_attempts, "#{kind} #{inspect(reason)}")
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp crash_cleanup(scan_request_id, run_id, attempt, max_attempts, reason) do
    Logger.error("Build crashed for run #{run_id}: #{reason}")

    # Both steps are best-effort: whatever made the build crash (a full disk, a
    # dead database) can just as easily make the cleanup crash, and raising here
    # would replace the real error with a misleading one.
    safely("scratch cleanup", fn -> Builder.cleanup(run_id) end)

    safely("request status", fn ->
      on_retry_or_exhaust(scan_request_id, attempt, max_attempts, "build crashed: #{reason}")
    end)

    :ok
  end

  defp safely(label, fun) do
    fun.()
    :ok
  rescue
    exception -> Logger.error("#{label} failed: #{Exception.message(exception)}")
  catch
    kind, reason -> Logger.error("#{label} failed: #{kind} #{inspect(reason)}")
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

  defp run_id(package, version) do
    ts = System.system_time(:millisecond)
    "#{package}-#{version}-#{ts}"
  end

  # Builder module is injectable for tests via `config :portal, :build_runner`.
  defp builder, do: Application.get_env(:portal, :build_runner, Builder)
end
