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

  # The scratch dir is on the disk of the node that built it, so the ingest has
  # to run there. With several build hosts sharing the `:ingest` queue, any of
  # them could take it, find no `result.json` and give up: 19 of 42 builds on
  # 2026-10-10 lost their result that way. `Portal.Workers.Build` enqueues on
  # `local_queue/0` instead, and each build node runs that queue for itself
  # only (`Portal.Application`). The shared `:ingest` queue still drains jobs
  # enqueued before this, and keeps the cron jobs that live on it.
  @default_local_limit 2

  @doc "This node's own ingest queue."
  @spec local_queue(node()) :: String.t()
  def local_queue(node \\ node()) do
    slug = node |> Atom.to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")
    "ingest_" <> slug
  end

  @doc """
  How wide this node's `local_queue/0` runs, given its Oban `queues`; nil when
  the node runs no builds and so never has a scratch dir to ingest.
  """
  @spec local_queue_limit(keyword() | false | nil) :: pos_integer() | nil
  def local_queue_limit(queues) when is_list(queues) do
    if Keyword.get(queues, :builds, 0) > 0,
      do: Keyword.get(queues, :ingest, @default_local_limit),
      else: nil
  end

  def local_queue_limit(_queues), do: nil

  @doc """
  `oban_config` with `node`'s own ingest queue added when the node runs
  builds. Oban wants queue names as keyword keys, so this makes one atom per
  node, from the node's own name.
  """
  @spec with_local_queue(keyword(), node()) :: keyword()
  # The atom comes from the node name the release was started with, not from
  # any request: one per build host, created once at boot.
  # sobelow_skip ["DOS.StringToAtom"]
  def with_local_queue(oban_config, node \\ node()) do
    queues = Keyword.get(oban_config, :queues)

    case local_queue_limit(queues) do
      nil ->
        oban_config

      limit ->
        warn_if_unnamed(node)
        name = node |> local_queue() |> String.to_atom()

        queues =
          if Keyword.has_key?(queues, name), do: queues, else: queues ++ [{name, limit}]

        Keyword.put(oban_config, :queues, queues)
    end
  end

  # A single unnamed node (dev, one-host installs) is fine. Several build hosts
  # without names would all be `nonode@nohost` and share one "local" queue --
  # the cross-host ingest this exists to prevent -- so say so at boot.
  defp warn_if_unnamed(:nonode@nohost) do
    Logger.warning(
      "this node runs builds without a node name; its ingest queue " <>
        "#{local_queue(:nonode@nohost)} is only node-local while it is the only build host"
    )
  end

  defp warn_if_unnamed(_node), do: :ok

  @doc """
  The queues a builder deploy pauses and drains on `node` before restarting it
  (`ops/builder-deploy.sh`): the builds, the shared ingest queue and the node's
  own, where a build that finishes while draining puts its ingest.
  """
  @spec builder_queues(node()) :: [String.t()]
  def builder_queues(node \\ node()), do: ["builds", "ingest", local_queue(node)]

  alias Portal.Builder
  alias Portal.Catalog.Ingestion
  alias Portal.Workers.PackageMeta
  alias Portal.Workers.Progress

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max_attempts}) do
    run_id = args["run_id"]
    image_digest = args["image_digest"]
    scan_request_id = args["scan_request_id"]

    with {:ok, run} <- Portal.Catalog.committed_run(run_id) do
      case run do
        nil -> load_and_ingest(run_id, image_digest, scan_request_id, attempt, max_attempts)
        run -> complete(run, scan_request_id, run.package.name)
      end
    end
  end

  defp load_and_ingest(run_id, image_digest, scan_request_id, attempt, max_attempts) do
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
      output_dir: build.output_dir,
      scan_request_id: scan_request_id,
      log: build.log
    }

    case safe_ingest(build.result, ingest_opts) do
      {:ok, run} ->
        complete(run, scan_request_id, get_in(build.result, ["package", "name"]))

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

  # Once the transaction commits, the run is the durable source of truth. A
  # retry must finish these steps even after scratch cleanup. Unlike the
  # best-effort Progress.mark/3, a failed request update must retry this job.
  defp complete(run, scan_request_id, package) do
    with :ok <- mark_built(scan_request_id, run.id) do
      enqueue_package_meta(package)
      Builder.cleanup(run.run_id)
      Progress.broadcast(scan_request_id, :done, %{run_id: run.id, status: run.overall_status})
      :ok
    end
  end

  defp mark_built(nil, _run_id), do: :ok

  defp mark_built(scan_request_id, run_id) do
    case Portal.ScanRequests.set_status(scan_request_id, :built, run_id: run_id) do
      {:ok, _request} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Every package that enters the catalog passes through here, which makes this
  # the one place that keeps hex.pm metadata in step with the catalog without a
  # scheduled sweep. The job is unique per package for a day, so a package
  # rebuilt against six systems still costs one hex.pm request.
  #
  # Deliberately after the ingest commits and outside its transaction: metadata
  # is decoration, and a hex.pm outage must not roll back a build result. A
  # failed enqueue is logged and dropped for the same reason.
  defp enqueue_package_meta(package) do
    case package do
      name when is_binary(name) and name != "" ->
        case Oban.insert(PackageMeta.new(%{package: name})) do
          {:ok, _job} ->
            :ok

          {:error, reason} ->
            Logger.warning("PackageMeta enqueue failed for #{name}: #{inspect(reason)}")
        end

      _ ->
        :ok
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
