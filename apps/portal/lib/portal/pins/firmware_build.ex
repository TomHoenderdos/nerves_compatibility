defmodule Portal.Pins.FirmwareBuild do
  @moduledoc """
  The firmware path of a pinned build (`Portal.Workers.PinnedBuild`, lock-driven
  builds spec, phase 2): a native pin set built as a firmware build of one
  target at its exact system release, on this node's worker image
  (`Portal.Builder.docker_image/0`), queue `:builds`.

  The worker gets no `mode`, `systems_filter: [target]`, `systems_override:
  %{target => "== <system_version>"}`, `optional_deps: "pinned"` and the set
  as `pins` (`NccWorker.Pins`), and nothing else a firmware run may carry:
  no argus, no firmware world. It runs outside `Portal.Workers.Build`: no
  Run, no scan request, no tooling skip, no build-cache promotion, and a
  timeout is no Run either. A package's latest version is never touched.

  Exit-code contract, as `Portal.Workers.ToolchainBuild`'s:

      worker   0  -> a written result → a Nerves cache warm for its misses
                     and the Hex tarballs it downloaded (both best effort,
                     as a firmware build does), then
                     `Portal.Workers.Ingest` `kind: "pinned"` with the
                     target and release, on this node's queue
      worker  11  -> lock policy violation → `fail` row, cancel
      worker  10  -> no result → retry; the last attempt an `error` row
      host 20/21  -> runner error → retry, the same
      wall clock  -> a `fail` row ("build timed out after Ns"), cancel

  A host that refuses builds (disk, scratch, egress filter, memory limit,
  no image digest) defers the job and takes this node off the queue
  (`Portal.Builder.AutoPause`), as every build job does.
  """

  require Logger

  alias Portal.Builder
  alias Portal.Builder.AutoPause
  alias Portal.Catalog.LogSanitizer
  alias Portal.{HexCache, NervesCache, NodeQueue}
  alias Portal.Workers.{Ingest, PinnedBuild}

  @zero_digest "sha256:" <> String.duplicate("0", 64)

  @doc "Builds the job's set (see the moduledoc); `PinnedBuild.perform/1` checked its args."
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{} = job) do
    image = Builder.docker_image()

    case builder().image_digest(image) do
      @zero_digest ->
        Logger.warning(
          "Pinned build #{describe(job)} waiting: image #{inspect(image)} has no digest"
        )

        AutoPause.defer_image(job.queue)

      digest ->
        build_on(job, image, digest)
    end
  end

  defp build_on(%Oban.Job{args: args} = job, image, digest) do
    run_id = run_id(args["package"], args["version"])

    with_crash_cleanup(job, run_id, fn ->
      args
      |> build_args(run_id, image, digest)
      |> builder().build()
      |> handle(job, run_id, digest)
    end)
  end

  @doc false
  # The `Portal.Builder.build/2` args of a firmware pinned job. Public for
  # tests.
  @spec build_args(map(), String.t(), String.t(), String.t()) :: map()
  def build_args(args, run_id, image, digest) do
    target = args["target"]

    %{
      package: args["package"],
      version: args["version"],
      run_id: run_id,
      image: image,
      image_digest: digest,
      systems_filter: [target],
      systems_override: %{target => "== " <> args["system_version"]},
      optional_deps: "pinned",
      pins: args["pins"]
    }
  end

  defp handle({:ok, %{exit_code: 0, result: result}}, job, run_id, digest)
       when is_map(result) do
    warm_and_promote(result, run_id, digest, job)
    # No cleanup: the ingest reads the scratch dir and removes it.
    enqueue_ingest(job, run_id, digest)
  end

  defp handle({:ok, %{exit_code: 0} = build}, job, run_id, digest),
    do: retry(job, run_id, digest, "missing result.json", excerpt_from(build.log))

  defp handle({:ok, %{exit_code: 11}}, job, run_id, digest) do
    builder().cleanup(run_id)
    reason = "lock policy violation"
    PinnedBuild.write_row(job.args, :fail, reason, run_id, digest)
    {:cancel, reason}
  end

  defp handle({:ok, %{exit_code: exit_code} = build}, job, run_id, digest),
    do: retry(job, run_id, digest, "worker/runner exit #{exit_code}", excerpt_from(build.log))

  # A build that ran past the wall clock never finishes on a rebuild either;
  # it is a verdict, recorded once.
  defp handle({:error, {:build_timeout, seconds, _container}}, job, run_id, digest) do
    Logger.warning("Pinned build #{describe(job)} exceeded the #{seconds}s wall clock")
    builder().cleanup(run_id)
    reason = "build timed out after #{seconds}s"
    PinnedBuild.write_row(job.args, :fail, reason, run_id, digest)
    {:cancel, reason}
  end

  defp handle({:error, reason}, job, run_id, digest) do
    case AutoPause.check_for(reason, nil) do
      nil ->
        # Read before cleanup removes it.
        log = excerpt_from_file(Builder.runner_log_path(run_id))
        retry(job, run_id, digest, "builder error: #{inspect(reason)}", log, reason)

      check ->
        Logger.error("Pinned build #{describe(job)} deferred: #{AutoPause.describe(check)}")
        builder().cleanup(run_id)
        AutoPause.defer(job.queue, check)
    end
  end

  defp retry(job, run_id, digest, message, log, error \\ nil) do
    Logger.warning("Pinned build retry for #{describe(job)}: #{message}")
    builder().cleanup(run_id)

    if job.attempt >= job.max_attempts,
      do: PinnedBuild.write_row(job.args, :error, reason(message, log), run_id, digest)

    {:error, error || message}
  end

  # Before ingest, which consumes the scratch dir. Neither may cost the
  # build its result.
  defp warm_and_promote(result, run_id, digest, job) do
    safely(fn ->
      case NervesCache.request_warm(result, digest) do
        {:ok, [_ | _] = pairs} ->
          Logger.info(
            "Queued a Nerves cache warm of " <>
              Enum.map_join(pairs, ", ", &"#{&1["name"]} #{&1["version"]}") <>
              " after pinned build #{describe(job)}"
          )

        _other ->
          :ok
      end
    end)

    safely(fn -> HexCache.promote(result, run_id) end)
  end

  defp enqueue_ingest(%Oban.Job{args: args}, run_id, digest) do
    ingest_args =
      args
      |> Map.take(
        ~w(package version toolchain builder_version pins pin_hash target system_version)
      )
      |> Map.merge(%{
        "kind" => "pinned",
        "run_id" => run_id,
        "image_digest" => digest,
        "config_variant" => "default"
      })

    # This node's own queue: the scratch dir the ingest reads is on this disk.
    case ingest_args |> Ingest.new(queue: NodeQueue.name()) |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Could not enqueue pinned ingest for #{run_id}: #{inspect(reason)}")
        builder().cleanup(run_id)
        {:error, reason}
    end
  end

  # Every terminal path above cleans up by returning; an exception would
  # skip them and leave the scratch dir and no row behind.
  defp with_crash_cleanup(job, run_id, fun) do
    fun.()
  rescue
    exception ->
      message = Exception.message(exception)
      Logger.error("Pinned build crashed for run #{run_id}: #{message}")
      safely(fn -> builder().cleanup(run_id) end)

      if job.attempt >= job.max_attempts do
        safely(fn ->
          PinnedBuild.write_row(job.args, :error, "build crashed: #{message}", run_id, nil)
        end)
      end

      reraise exception, __STACKTRACE__
  end

  defp safely(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    _kind, _reason -> nil
  end

  defp reason(message, nil), do: message
  defp reason(message, log), do: message <> "\n\n" <> log

  defp excerpt_from(raw) when is_binary(raw) and raw != "", do: LogSanitizer.runner_excerpt(raw)
  defp excerpt_from(_raw), do: nil

  defp excerpt_from_file(path) do
    case LogSanitizer.runner_excerpt_file(path) do
      {:ok, ""} -> nil
      {:ok, excerpt} -> excerpt
      {:error, _reason} -> nil
    end
  end

  defp describe(%Oban.Job{args: args}), do: PinnedBuild.describe(args)

  # Names the run's scratch dir and container on this node.
  defp run_id(package, version),
    do:
      "pin-#{package}-#{version}-#{System.system_time(:millisecond)}-" <>
        "#{System.unique_integer([:positive])}"

  # Injectable for tests via `config :portal, :build_runner`, as in `Build`.
  defp builder, do: Application.get_env(:portal, :build_runner, Builder)
end
