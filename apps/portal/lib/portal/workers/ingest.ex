defmodule Portal.Workers.Ingest do
  @moduledoc """
  Oban worker that turns one finished build's `result.json` into Catalog rows,
  on this node's own queue (`Portal.NodeQueue`) for a local build and on
  `:remote` for a remote one.

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

  A toolchain build (`kind: "toolchain"`, with `toolchain`, `builder_version`,
  the queued `version`, `variant` and `config_variant`) goes to `Portal.Catalog.Ingestion.ingest_toolchain/2`
  instead. It writes no `Run`, so none of a run's follow-up applies: no scan
  request to mark, no progress broadcast, no package metadata refresh.

  ## The job's identity

  Ingest checks the result against the job it was enqueued for. A local build's
  job carries the `package` and `version` its `Portal.Workers.Build` was queued
  with, and a toolchain build's job the `package`, `version`, `toolchain`,
  `variant` and `config_variant` its `Portal.Workers.ToolchainBuild` was
  queued with. Before anything is recorded, `result.json` has to name the
  same package and version, and for a toolchain build have been built on
  that toolchain, for that variant and in that config variant; the rows, and the package metadata refresh after them, are
  then written under the job's identity, not the result's
  (`Portal.Catalog.Ingestion`).

  A toolchain job without a `variant` was queued before variants existed and
  is a `with` build; the default is the job's, never read from the result. A
  `variant` other than `"with"` or `"without"` is no identity at all and is
  refused like a missing one.

  The same holds for a toolchain job's `config_variant`: one without it was
  queued before config variants and is a `"default"` build, and one that is
  not a known variant (`Compatibility.ConfigVariants.known?/1`) is refused
  as unidentified. The job's value is what the row is stored under; the
  result's `toolchain_build.config_variant` echo only has to agree with it.

  A remote build's identity is its lease's `package` and `version`. Its
  upload is checked against them when the builder completes the lease and
  again when it is loaded (`Portal.Builders.Upload.load_run/1`), and they are
  handed to `Portal.Catalog.Ingestion` like a local job's, so its rows are
  written under the lease's identity too.

  The identity is required on every path. A job whose result names something
  else, or that does not carry its identity (one enqueued before jobs did),
  is refused: nothing is recorded, a `security:` line naming both sides is
  logged, the scan request is marked errored and the job is cancelled, since
  a retry would read the same result. A local build's scratch dir is
  removed; a remote build's lease is failed with the refusal as its error,
  which errors its request and removes its upload, as an ingest that runs
  out of attempts does. Resuming a run that is already committed does not
  read `result.json`, so it needs no identity.
  """

  # No `queue:`: `new/2` puts a job on this node's own queue unless the caller
  # names one. The scratch dir is on the disk of the node that built it, so
  # the ingest has to run there (`Portal.NodeQueue`).
  use Oban.Worker,
    max_attempts: 5,
    unique: [keys: [:run_id]]

  require Logger

  alias Portal.Builder
  alias Portal.Builders.{Leases, Upload}
  alias Portal.Catalog.Ingestion
  alias Portal.NodeQueue
  alias Portal.Workers.PackageMeta
  alias Portal.Workers.Progress

  @impl Oban.Worker
  def new(args, opts) when is_map(args) and is_list(opts),
    do: super(args, Keyword.put_new_lazy(opts, :queue, &NodeQueue.name/0))

  @doc """
  The queues a builder deploy pauses and drains on `node` before restarting it
  (`ops/builder-deploy.sh`): the builds, the node's own queue
  (`Portal.NodeQueue`), where a build that finishes while draining puts its
  ingest, the ingest queue the previous release ran for the node (drained for
  one release, `Portal.NodeQueue.legacy_ingest/1`), and the
  node's Nerves cache warm queue (`Portal.Workers.WarmNerves`), the
  `system_abi` queue (`Portal.Workers.SystemAbiRun`) when the node runs
  builds, and the
  `toolchain` and `toolchain_big` queues (`Portal.Workers.ToolchainBuild`)
  each when the node runs it.

  The toolchain queues are conditional because the deploy refuses to go ahead
  when a listed queue has no producer on the node (`Oban.check_queue/1` finds
  none), and a build host only runs it once its `OBAN_QUEUES` names it.
  """
  @spec builder_queues(node(), keyword() | false | nil) :: [String.t()]
  def builder_queues(node \\ node(), queues \\ configured_queues()) do
    [
      "builds",
      NodeQueue.name(node),
      NodeQueue.legacy_ingest(node),
      Portal.Workers.WarmNerves.local_queue(node)
    ] ++
      if(NodeQueue.build_node?(queues), do: ["system_abi"], else: []) ++
      if(runs_queue?(queues, :toolchain), do: ["toolchain"], else: []) ++
      if(runs_queue?(queues, :toolchain_big), do: ["toolchain_big"], else: []) ++
      host_native_queues(queues)
  end

  # A node's own architecture's host-native queue, when it runs it.
  defp host_native_queues(queues) when is_list(queues) do
    with queue when is_binary(queue) <- Portal.HostNative.local_queue(),
         {name, _limit} <- Enum.find(queues, fn {key, _} -> to_string(key) == queue end),
         true <- runs_queue?(queues, name) do
      [queue]
    else
      _ -> []
    end
  end

  defp host_native_queues(_queues), do: []

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

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => "toolchain"} = args} = job) do
    run_id = args["run_id"]

    case builder().load_run(run_id) do
      {:ok, build} ->
        case toolchain_identity(args) do
          nil -> refuse_unidentified(%{kind: :local}, run_id, nil, build.result)
          identity -> ingest_toolchain(build, args, identity, job)
        end

      {:error, reason} ->
        Logger.error("Ingest found no toolchain build output for #{run_id}: #{inspect(reason)}")
        {:cancel, "build output missing: #{inspect(reason)}"}
    end
  end

  def perform(%Oban.Job{args: %{"kind" => "pinned"} = args} = job) do
    run_id = args["run_id"]

    case builder().load_run(run_id) do
      {:ok, build} ->
        ingest_pinned(build, args, job)

      {:error, reason} ->
        Logger.error("Ingest found no pinned build output for #{run_id}: #{inspect(reason)}")
        {:cancel, "build output missing: #{inspect(reason)}"}
    end
  end

  def perform(%Oban.Job{args: %{"kind" => "host_native"} = args} = job) do
    run_id = args["run_id"]

    case builder().load_run(run_id) do
      {:ok, build} ->
        ingest_host_native(build, args, job)

      {:error, reason} ->
        Logger.error("Ingest found no host-native build output for #{run_id}: #{inspect(reason)}")
        {:cancel, "build output missing: #{inspect(reason)}"}
    end
  end

  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max_attempts}) do
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
    do: %{
      kind: :remote,
      lease_id: lease_id,
      builder_id: args["builder_id"],
      arch: args["arch"],
      firmware_world: args["firmware_world"],
      identity: Upload.lease_identity(lease_id)
    }

  # A local ingest runs on the node its build ran on (`Portal.NodeQueue`), so
  # one queued before jobs named the architecture still knows it.
  defp source(args),
    do: %{
      kind: :local,
      arch: args["arch"] || Compatibility.Arch.current(),
      firmware_world: args["firmware_world"],
      identity: run_identity(args)
    }

  # What a local job was queued to build: nil when it does not say.
  defp run_identity(%{"package" => package, "version" => version})
       when is_binary(package) and package != "" and is_binary(version) and version != "",
       do: %{package: package, version: version}

  defp run_identity(_args), do: nil

  defp toolchain_identity(%{"toolchain" => toolchain} = args)
       when is_binary(toolchain) and toolchain != "" do
    with %{} = identity <- run_identity(args),
         variant when variant != nil <- job_variant(args),
         config_variant when config_variant != nil <- job_config_variant(args) do
      Map.merge(identity, %{
        toolchain: toolchain,
        variant: variant,
        config_variant: config_variant
      })
    end
  end

  defp toolchain_identity(_args), do: nil

  # A job queued before variants existed carries none and was a with build:
  # the job's side decides, never the result's. Any other value is not a
  # variant the job could have built.
  defp job_variant(args) do
    case Map.fetch(args, "variant") do
      :error ->
        :with

      {:ok, name} ->
        case Portal.Catalog.ToolchainBuild.parse_variant(name) do
          {:ok, variant} -> variant
          :error -> nil
        end
    end
  end

  # A job queued before config variants carries none and was a default
  # build. Any other value that is not a known variant is no identity.
  defp job_config_variant(args) do
    name = Map.get(args, "config_variant", "default")
    if Compatibility.ConfigVariants.known?(name), do: name
  end

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

      # An upload whose result.json names another build than its lease.
      {:error, {:identity_mismatch, job, reported}} ->
        refuse_mismatch(source, run_id, scan_request_id, job, reported)

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

  # A result is only taken against the identity its job (or lease) carries.
  defp ingest(%{identity: nil} = source, build, run_id, _digest, request, _, _),
    do: refuse_unidentified(source, run_id, request, build.result)

  defp ingest(source, build, run_id, image_digest, scan_request_id, attempt, max_attempts) do
    ingest_opts =
      Map.merge(source.identity, %{
        run_id: run_id,
        image_digest: image_digest,
        files_dir: build.files_dir,
        output_dir: build.output_dir,
        scan_request_id: scan_request_id,
        log: build.log,
        builder_id: Map.get(source, :builder_id),
        arch: source.arch,
        # The firmware world the build job asked for, if any.
        firmware_world: Map.get(source, :firmware_world)
      })

    case safe_ingest(&Ingestion.ingest/2, build.result, ingest_opts) do
      {:ok, run} ->
        complete(source, run, scan_request_id, ingest_opts.package)

      {:error, {:identity_mismatch, job, reported}} ->
        refuse_mismatch(source, run_id, scan_request_id, job, reported)

      {:error, {:identity_missing, _keys}} ->
        refuse_unidentified(source, run_id, scan_request_id, build.result)

      {:error, reason} ->
        Logger.error("Ingestion failed for #{run_id}: #{inspect(reason)}")

        # Keep the output until the attempts are spent; it is the only copy
        # of the build a retry can work from.
        if attempt >= max_attempts,
          do:
            give_up(
              source,
              run_id,
              scan_request_id,
              "ingestion failed: #{inspect(reason)}"
            )

        {:error, reason}
    end
  end

  # Drops the output and errors the request, for a last failed attempt or a
  # refusal. A remote lease is failed rather than left `:done` with nothing
  # behind it; `Leases.fail/2` errors the request and drops the upload
  # itself. A lease that has already moved on gets the local treatment.
  defp give_up(%{kind: :remote, lease_id: lease_id} = source, run_id, request, message) do
    case Leases.fail_by_id(lease_id, message) do
      {:ok, _lease} -> :ok
      {:error, _} -> cleanup_and_error(source, run_id, request, message)
    end
  end

  defp give_up(source, run_id, scan_request_id, message),
    do: cleanup_and_error(source, run_id, scan_request_id, message)

  defp cleanup_and_error(source, run_id, scan_request_id, message) do
    cleanup(source, run_id)
    error_request(scan_request_id, message)
  end

  # Re-ingesting a committed toolchain build is an upsert of the same row, so
  # unlike a run there is no committed-row check before it.
  defp ingest_toolchain(build, args, identity, %Oban.Job{} = job) do
    run_id = args["run_id"]

    opts = %{
      run_id: run_id,
      image_digest: args["image_digest"],
      files_dir: build.files_dir,
      output_dir: build.output_dir,
      package: identity.package,
      version: identity.version,
      toolchain: identity.toolchain,
      variant: identity.variant,
      config_variant: identity.config_variant,
      builder_version: args["builder_version"]
    }

    case safe_ingest(&Ingestion.ingest_toolchain/2, build.result, opts) do
      {:ok, _toolchain_build} ->
        Builder.cleanup(run_id)
        :ok

      {:error, {:identity_mismatch, job_identity, reported}} ->
        refuse_mismatch(%{kind: :local}, run_id, nil, job_identity, reported)

      {:error, {:identity_missing, _keys}} ->
        refuse_unidentified(%{kind: :local}, run_id, nil, build.result)

      {:error, reason} ->
        Logger.error("Toolchain ingestion failed for #{run_id}: #{inspect(reason)}")
        out_of_attempts(job, run_id, reason)
        {:error, reason}
    end
  end

  # The last attempt of a toolchain or pinned ingest: the output goes, and
  # the build gets an `error` row, which is what stops the sweep queueing it
  # again at once (`Portal.Workers.ToolchainBuild.record_ingest_failure/2`).
  defp out_of_attempts(%Oban.Job{attempt: attempt, max_attempts: max} = job, run_id, reason)
       when attempt >= max do
    Builder.cleanup(run_id)

    Portal.Workers.ToolchainBuild.record_ingest_failure(
      job.args,
      "ingest failed: " <> inspect(reason, limit: 5, printable_limit: 200)
    )
  end

  defp out_of_attempts(_job, _run_id, _reason), do: :ok

  # A pinned build (`Ingestion.ingest_pinned/2`), keyed on the job's pinned
  # identity and checked against the job's own set.
  defp ingest_pinned(build, args, %Oban.Job{} = job) do
    run_id = args["run_id"]

    opts =
      args
      |> Portal.Workers.PinnedBuild.identity()
      |> Map.merge(%{
        run_id: run_id,
        image_digest: args["image_digest"],
        files_dir: build.files_dir,
        output_dir: build.output_dir,
        pins: args["pins"],
        sibling_backfill: args["sibling_backfill"] == true
      })

    case safe_ingest(&Ingestion.ingest_pinned/2, build.result, opts) do
      {:ok, _row} ->
        Builder.cleanup(run_id)
        :ok

      {:error, {:identity_mismatch, job_identity, reported}} ->
        refuse_mismatch(%{kind: :local}, run_id, nil, job_identity, reported)

      {:error, {:identity_missing, _keys}} ->
        refuse_unidentified(%{kind: :local}, run_id, nil, build.result)

      {:error, reason} ->
        Logger.error("Pinned ingestion failed for #{run_id}: #{inspect(reason)}")
        out_of_attempts(job, run_id, reason)
        {:error, reason}
    end
  end

  # A host-native build (`Portal.HostNative.Ingest`), keyed on the job's
  # identity as a toolchain build is.
  defp ingest_host_native(build, args, %Oban.Job{} = job) do
    run_id = args["run_id"]

    opts = %{
      run_id: run_id,
      image_digest: args["image_digest"],
      files_dir: build.files_dir,
      package: args["package"],
      version: args["version"],
      toolchain: args["toolchain"],
      triple: args["triple"],
      builder_version: args["builder_version"]
    }

    case safe_ingest(&Portal.HostNative.Ingest.ingest/2, build.result, opts) do
      {:ok, _row} ->
        Builder.cleanup(run_id)
        :ok

      {:error, {:identity_mismatch, job_identity, reported}} ->
        refuse_mismatch(%{kind: :local}, run_id, nil, job_identity, reported)

      {:error, {:identity_missing, _keys}} ->
        refuse_unidentified(%{kind: :local}, run_id, nil, build.result)

      {:error, reason} ->
        Logger.error("Host-native ingestion failed for #{run_id}: #{inspect(reason)}")
        if job.attempt >= job.max_attempts, do: Builder.cleanup(run_id)
        {:error, reason}
    end
  end

  # Refusals. Retrying cannot change what the result or the job says, so the
  # job is cancelled; the output goes with it, as on a last attempt.
  defp refuse_unidentified(source, run_id, scan_request_id, result) do
    reported = describe_identity(reported_identity(result))

    refuse(
      source,
      run_id,
      scan_request_id,
      "the ingest job for #{run_id} does not say what it built (result.json: #{reported})"
    )
  end

  defp refuse_mismatch(source, run_id, scan_request_id, job, reported) do
    refuse(
      source,
      run_id,
      scan_request_id,
      "the ingest job for #{run_id} is for #{describe_identity(job)}, " <>
        "but result.json is for #{describe_identity(reported)}"
    )
  end

  defp refuse(source, run_id, scan_request_id, message) do
    Logger.error("security: #{message}; recording nothing")
    reason = "ingest refused: #{message}"
    give_up(source, run_id, scan_request_id, reason)
    {:cancel, reason}
  end

  defp reported_identity(%{"package" => %{} = package}),
    do: %{package: package["name"], version: package["version"]}

  defp reported_identity(_result), do: %{package: nil, version: nil}

  defp describe_identity(identity) do
    base = "#{inspect(identity[:package])} #{inspect(identity[:version])}"

    base =
      case Map.fetch(identity, :toolchain) do
        {:ok, toolchain} -> "#{base} on #{inspect(toolchain)}"
        :error -> base
      end

    base =
      case Map.fetch(identity, :variant) do
        {:ok, variant} -> "#{base} (variant #{inspect(variant)})"
        :error -> base
      end

    base =
      case Map.fetch(identity, :triple) do
        {:ok, triple} -> "#{base} for #{inspect(triple)}"
        :error -> base
      end

    case Map.fetch(identity, :config_variant) do
      {:ok, config_variant} -> "#{base} (config variant #{inspect(config_variant)})"
      :error -> base
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
