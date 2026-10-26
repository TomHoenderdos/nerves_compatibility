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

  A remote build (`source: "remote"`, with `lease_id` and `builder_id`) is
  enqueued on `:remote` by the builder's `complete` call. Its output is the
  lease's upload dir on the web host (`Portal.Builders.Upload`), the run
  records its `builder_id`, and an upload with no `result.json` fails the
  lease (`Portal.Builders.Leases.fail_by_id/2`), as do a revoked builder and
  a last attempt that still cannot ingest. A request deleted while the build
  ran leaves the run unlinked instead of failing it.

  A toolchain build (`kind: "toolchain"`, with `toolchain`, `builder_version`
  and the queued `version`) goes to `Portal.Catalog.Ingestion.ingest_toolchain/2`
  instead. It writes no `Run`, so none of a run's follow-up applies: no scan
  request to mark, no progress broadcast, no package metadata refresh.
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
  own, where a build that finishes while draining puts its ingest, and the
  node's Nerves cache warm queue (`Portal.Workers.WarmNerves`), and the
  `toolchain` queue (`Portal.Workers.ToolchainBuild`) when the node runs it.

  The toolchain queue is conditional because the deploy refuses to go ahead
  when a listed queue has no producer on the node (`Oban.check_queue/1` finds
  none), and a build host only runs it once its `OBAN_QUEUES` names it.
  """
  @spec builder_queues(node(), keyword() | false | nil) :: [String.t()]
  def builder_queues(node \\ node(), queues \\ configured_queues()) do
    ["builds", "ingest", local_queue(node), Portal.Workers.WarmNerves.local_queue(node)] ++
      if runs_queue?(queues, :toolchain), do: ["toolchain"], else: []
  end

  defp configured_queues, do: :portal |> Application.get_env(Oban, []) |> Keyword.get(:queues)

  defp runs_queue?(queues, name) when is_list(queues) do
    case Keyword.get(queues, name, 0) do
      limit when is_integer(limit) -> limit > 0
      # Oban also takes a keyword of queue options, e.g. `[limit: 1]`.
      opts when is_list(opts) -> Keyword.get(opts, :limit, 0) > 0
      _ -> false
    end
  end

  defp runs_queue?(_queues, _name), do: false

  alias Portal.AdminEvents
  alias Portal.Builder
  alias Portal.Builders.{Leases, Upload}
  alias Portal.Catalog.Ingestion
  alias Portal.Workers.PackageMeta
  alias Portal.Workers.Progress

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => "toolchain"} = args} = job) do
    run_id = args["run_id"]

    case builder().load_run(run_id) do
      {:ok, build} ->
        ingest_toolchain(build, args, job)

      {:error, reason} ->
        Logger.error("Ingest found no toolchain build output for #{run_id}: #{inspect(reason)}")
        {:cancel, "build output missing: #{inspect(reason)}"}
    end
  end

  def perform(%Oban.Job{meta: meta, args: args, attempt: attempt, max_attempts: max_attempts}) do
    do_perform(args, attempt, max_attempts)
  after
    # Same reasoning as `Portal.Workers.Build`: a sweep's Maintenance page
    # (Task 7) counts jobs by Oban state, so every attempt here -- whether it
    # commits the run, retries, or gets discarded -- has to announce. `after`
    # runs once the ingest's own transaction (inside `Ingestion.ingest/2`) has
    # already committed or rolled back, and a non-sweep job stays silent.
    if meta["sweep_id"], do: AdminEvents.broadcast(:sweeps)
  end

  defp do_perform(args, attempt, max_attempts) do
    run_id = args["run_id"]
    image_digest = args["image_digest"]
    source = source(args)
    scan_request_id = live_request_id(source, args["scan_request_id"])

    with {:ok, run} <- Portal.Catalog.committed_run(run_id) do
      case run do
        nil ->
          ingest_unless_revoked(
            source,
            run_id,
            image_digest,
            scan_request_id,
            attempt,
            max_attempts
          )

        run ->
          complete(source, run, scan_request_id, run.package.name)
      end
    end
  end

  # Where the run's output lives and how to drop it: a local build's scratch
  # dir on this node, or a remote builder's upload dir on the web host
  # (`Portal.Builders.Upload`, enqueued by the builder's `complete` call).
  defp source(%{"source" => "remote", "lease_id" => lease_id} = args),
    do: %{kind: :remote, lease_id: lease_id, builder_id: args["builder_id"]}

  defp source(_args), do: %{kind: :local}

  # A remote build outlives its request's jobs by as long as it takes, so the
  # request may be gone by the time its upload is ingested (deleted by hand,
  # or by `Portal.Workers.RequestSync` before it knew about leases). The run
  # is still worth keeping: ingest it unlinked rather than trip
  # `catalog_runs_scan_request_id_fkey` on every attempt and lose the upload.
  defp live_request_id(%{kind: :remote}, id) when is_binary(id) do
    case Portal.ScanRequests.get_request(id) do
      {:error, :not_found} ->
        Logger.warning("Ingest: request #{id} is gone, ingesting the run unlinked")
        nil

      _found_or_unknown ->
        id
    end
  end

  defp live_request_id(_source, id), do: id

  defp ingest_unless_revoked(source, run_id, image_digest, scan_request_id, attempt, max) do
    if builder_revoked?(source),
      do: revoked(source, run_id),
      else: load_and_ingest(source, run_id, image_digest, scan_request_id, attempt, max)
  end

  # A builder revoked after it uploaded is no longer trusted, so neither is
  # what it uploaded: handled like a missing upload, with no run.
  defp builder_revoked?(%{kind: :remote, builder_id: builder_id}) when is_binary(builder_id) do
    match?(
      {:ok, %Portal.Builders.Builder{status: :revoked}},
      Ash.get(Portal.Builders.Builder, builder_id, domain: Portal.Builders)
    )
  end

  defp builder_revoked?(_source), do: false

  defp revoked(%{lease_id: lease_id} = source, run_id) do
    Logger.error("Ingest dropped #{run_id}: its builder was revoked")

    case Leases.fail_by_id(lease_id, "builder revoked") do
      {:ok, _lease} -> :ok
      {:error, _} -> cleanup(source, run_id)
    end

    {:cancel, "builder revoked"}
  end

  defp load(%{kind: :remote, lease_id: lease_id}, _run_id), do: Upload.load_run(lease_id)
  defp load(%{kind: :local}, run_id), do: builder().load_run(run_id)

  defp cleanup(%{kind: :remote, lease_id: lease_id}, _run_id), do: Upload.cleanup(lease_id)
  defp cleanup(%{kind: :local}, run_id), do: Builder.cleanup(run_id)

  defp load_and_ingest(source, run_id, image_digest, scan_request_id, attempt, max_attempts) do
    case load(source, run_id) do
      {:ok, build} ->
        ingest(source, build, run_id, image_digest, scan_request_id, attempt, max_attempts)

      {:error, reason} ->
        # The output is gone, so there is nothing a retry could read. Fail
        # the request rather than looping on an empty directory.
        Logger.error("Ingest found no build output for #{run_id}: #{inspect(reason)}")
        message = "build output missing: #{inspect(reason)}"
        output_missing(source, scan_request_id, message)
        {:cancel, message}
    end
  end

  # A remote lease is `:done` by now; failing it marks and broadcasts the
  # request's error and drops whatever did land in its upload dir. A lease
  # that has already moved on still gets its request errored here.
  defp output_missing(%{kind: :remote, lease_id: lease_id}, scan_request_id, message) do
    case Leases.fail_by_id(lease_id, "upload missing") do
      {:ok, _lease} -> :ok
      {:error, _} -> error_request(scan_request_id, message)
    end
  end

  defp output_missing(%{kind: :local}, scan_request_id, message),
    do: error_request(scan_request_id, message)

  defp error_request(scan_request_id, message) do
    Progress.mark(scan_request_id, :error, error_reason: message)
    Progress.broadcast(scan_request_id, :error, %{reason: message})
  end

  defp ingest(source, build, run_id, image_digest, scan_request_id, attempt, max_attempts) do
    ingest_opts = %{
      run_id: run_id,
      image_digest: image_digest,
      files_dir: build.files_dir,
      output_dir: build.output_dir,
      scan_request_id: scan_request_id,
      log: build.log,
      builder_id: Map.get(source, :builder_id)
    }

    case safe_ingest(&Ingestion.ingest/2, build.result, ingest_opts) do
      {:ok, run} ->
        complete(source, run, scan_request_id, get_in(build.result, ["package", "name"]))

      {:error, reason} ->
        Logger.error("Ingestion failed for #{run_id}: #{inspect(reason)}")

        # Keep the output until the attempts are spent; it is the only copy
        # of the build a retry can work from.
        if attempt >= max_attempts,
          do:
            ingest_exhausted(
              source,
              run_id,
              scan_request_id,
              "ingestion failed: #{inspect(reason)}"
            )

        {:error, reason}
    end
  end

  # A remote lease is failed rather than left `:done` with nothing behind
  # it; `Leases.fail/2` errors the request and drops the upload itself. A
  # lease that has already moved on gets the local treatment.
  defp ingest_exhausted(%{kind: :remote, lease_id: lease_id} = source, run_id, request, message) do
    case Leases.fail_by_id(lease_id, message) do
      {:ok, _lease} -> :ok
      {:error, _} -> cleanup_and_error(source, run_id, request, message)
    end
  end

  defp ingest_exhausted(source, run_id, scan_request_id, message),
    do: cleanup_and_error(source, run_id, scan_request_id, message)

  defp cleanup_and_error(source, run_id, scan_request_id, message) do
    cleanup(source, run_id)
    error_request(scan_request_id, message)
  end

  # Re-ingesting a committed toolchain build is an upsert of the same row, so
  # unlike a run there is no committed-row check before it.
  defp ingest_toolchain(build, args, %Oban.Job{attempt: attempt, max_attempts: max_attempts}) do
    run_id = args["run_id"]

    opts = %{
      run_id: run_id,
      image_digest: args["image_digest"],
      files_dir: build.files_dir,
      output_dir: build.output_dir,
      version: args["version"],
      toolchain: args["toolchain"],
      builder_version: args["builder_version"]
    }

    case safe_ingest(&Ingestion.ingest_toolchain/2, build.result, opts) do
      {:ok, _toolchain_build} ->
        Builder.cleanup(run_id)
        :ok

      {:error, reason} ->
        Logger.error("Toolchain ingestion failed for #{run_id}: #{inspect(reason)}")
        if attempt >= max_attempts, do: Builder.cleanup(run_id)
        {:error, reason}
    end
  end

  # Once the transaction commits, the run is the durable source of truth. A
  # retry must finish these steps even after scratch cleanup. Unlike the
  # best-effort Progress.mark/3, a failed request update must retry this job.
  defp complete(source, run, scan_request_id, package) do
    with :ok <- mark_built(scan_request_id, run.id) do
      enqueue_package_meta(package)
      cleanup(source, run.run_id)
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

  # `Ingestion.ingest/2` and `ingest_toolchain/2` raise on a result.json they
  # cannot map, rather than returning an error. Both failures need the same
  # bookkeeping here, so normalise them: a raised exception would take the job
  # down before the last attempt could free the scratch dir and mark the
  # request.
  defp safe_ingest(fun, result, opts) do
    fun.(result, opts)
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Builder module is injectable for tests via `config :portal, :build_runner`.
  defp builder, do: Application.get_env(:portal, :build_runner, Builder)
end
