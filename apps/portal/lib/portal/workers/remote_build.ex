defmodule Portal.Workers.RemoteBuild do
  @moduledoc """
  Oban worker (queue `:remote`, web host) that turns a build job into a
  `builder_leases` row for a remote builder to claim. It never runs Docker:
  the lease table is the remote queue, and `Portal.Workers.Ingest` with
  `source: "remote"` finishes the job once the builder has uploaded.

  It mirrors `Portal.Workers.Build` up to the build itself: tooling is
  recorded as skipped, an existing run at the same image digest dedups
  unless `force`, and `Build.scope_args/3` decides the scope. The digest is
  the registry one from `Portal.Builders.Images`, which every builder pulls
  by, not this host's local image. The lease carries one platform digest per
  architecture (`args["image_platforms"]`) and the claim pins it to the
  claiming builder's; a run at any of them dedups.
  """
  use Oban.Worker,
    queue: :remote,
    max_attempts: 3,
    # The same uniqueness as `Portal.Workers.Build`, which it dedups against;
    # see the reasoning there.
    unique: [
      period: 60,
      fields: [:args],
      keys: [:package, :version, :image_digest, :force, :scan_request_id, :scope, :systems]
    ]

  require Ash.Query
  require Logger

  alias Portal.Builders.{Images, Lease, Leases}
  alias Portal.Catalog.{Run, ToolingSkip}
  alias Portal.Workers.{Build, Progress}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, priority: priority, attempt: attempt, max_attempts: max}) do
    package = args["package"]
    version = args["version"]
    scan_request_id = args["scan_request_id"]
    force = args["force"] == true

    if ToolingSkip.tooling?(package) do
      record_tooling_skip(package, version, scan_request_id, attempt, max)
    else
      job = %{
        package: package,
        version: version,
        scan_request_id: scan_request_id,
        force: force,
        args: args,
        priority: priority,
        attempt: attempt,
        max: max
      }

      case Images.worker_image() do
        nil -> no_registry_image(job)
        %{name: _, digest: _} = image -> lease_unless_built(job, image)
      end
    end
  end

  defp no_registry_image(%{package: package, version: version, scan_request_id: id}) do
    Logger.error("RemoteBuild for #{package} #{version}: no registry image in images.json")
    Progress.mark(id, :error, error_reason: "no registry image for remote build")
    Progress.broadcast(id, :error, %{reason: "no registry image"})
    {:cancel, :no_registry_image}
  end

  # The dedup checks and the lease insert run under one advisory lock on the
  # build: the `:remote` queue runs more than one job, and two of them for
  # different requests of the same package/version would otherwise both pass
  # `lease_in_flight?/3` and lease it twice.
  defp lease_unless_built(job, %{digest: digest} = image) do
    key = "lease:#{job.package}@#{job.version}@#{digest}"

    {:ok, outcome} =
      Portal.Repo.transaction(fn ->
        Portal.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1::text))", [key])
        decide(job, image)
      end)

    # The wake-up goes out once the lease is committed: a claim woken inside
    # the transaction would find nothing and sleep its whole poll.
    case outcome do
      {:ok, %Lease{} = lease} ->
        Leases.notify_queued(lease)
        :ok

      {:error, _reason} = error ->
        on_enqueue_error(error, job.scan_request_id, job.attempt, job.max)

      other ->
        other
    end
  end

  # A run or lease at any platform digest of the image counts: the version
  # is checked for this image whichever architecture built it, and a claim
  # moves a lease's `image_digest` to the claiming architecture's.
  defp decide(job, %{name: name, digest: digest, platforms: platforms}) do
    %{package: package, version: version, scan_request_id: scan_request_id, force: force} = job
    digests = Map.values(platforms)

    cond do
      not force and run_exists?(package, version, digests) ->
        Logger.info("RemoteBuild dedup: run already exists for #{package} #{version}")
        Progress.mark(scan_request_id, :built)
        Progress.broadcast(scan_request_id, :done, %{deduped: true})
        :ok

      # This job is done once its lease is written, long before the run
      # exists, so a later job for the same build (a sweep after a
      # request, past the unique window) would otherwise lease it twice.
      # It waits instead: once that lease is ingested the next run
      # dedups on the run above and marks this request built; if the
      # lease failed, the next run leases afresh. A `done` lease is in
      # flight too, until its ingest commits the run or fails it.
      not force and lease_in_flight?(package, version, digests) ->
        Logger.info("RemoteBuild waiting on an open lease for #{package} #{version}")
        Progress.broadcast(scan_request_id, :queued, %{remote: true, waiting_on_lease: true})
        {:snooze, 120}

      true ->
        image = %{name: name, digest: digest, platforms: platforms}
        lease(package, version, image, job.args, scan_request_id, job.priority, force)
    end
  end

  defp lease(package, version, image, args, scan_request_id, priority, force) do
    %{name: name, digest: digest, platforms: platforms} = image
    scope = Build.scope_args(package, version, args)

    lease_args = %{
      "systems_filter" => scope.systems_filter,
      "mode" => scope.mode,
      # Read when the lease is written, so an admin change applies from the
      # next lease on.
      "argus" => Portal.Settings.worker_argus(Portal.Settings.get()),
      "force" => force,
      # One platform digest per architecture: the claim pins the lease to
      # the claiming builder's (`Portal.Builders.Leases.claim/2`). Until
      # then `image_digest` names the x86_64 one.
      "image_platforms" => platforms
    }

    with {:ok, lease} <-
           Leases.enqueue(
             %{
               package: package,
               version: version,
               image_name: name,
               image_digest: digest,
               args: lease_args,
               scan_request_id: scan_request_id,
               # Oban's own default; only a hand-built job struct has none.
               priority: priority || 0
             },
             notify: false
           ) do
      Progress.broadcast(scan_request_id, :queued, %{remote: true})
      {:ok, lease}
    end
  end

  # As `Portal.Workers.Build.on_retry_or_exhaust/5`: the job retries, and the
  # last attempt marks the request errored instead of leaving it queued.
  defp on_enqueue_error({:error, reason} = error, scan_request_id, attempt, max) do
    message = "remote lease enqueue failed: #{inspect(reason)}"
    Logger.error(message)

    if attempt >= max do
      Progress.mark(scan_request_id, :error, error_reason: message)
      Progress.broadcast(scan_request_id, :error, %{reason: message})
    end

    error
  end

  # As `Portal.Workers.Build`: never built, regardless of `force`; an error
  # retries, and the last attempt marks the request errored.
  defp record_tooling_skip(package, version, scan_request_id, attempt, max) do
    case ToolingSkip.record(package, version, scan_request_id) do
      {:ok, run} ->
        Progress.mark(scan_request_id, :built, run_id: run.id)
        Progress.broadcast(scan_request_id, :done, %{run_id: run.id, status: run.overall_status})
        :ok

      {:error, reason} ->
        if attempt >= max do
          message = "tooling skip failed: #{inspect(reason)}"
          Progress.mark(scan_request_id, :error, error_reason: message)
          Progress.broadcast(scan_request_id, :error, %{reason: message})
        end

        {:error, reason}
    end
  end

  defp lease_in_flight?(package, version, digests) do
    Lease
    |> Ash.Query.filter(
      package == ^package and version == ^version and image_digest in ^digests and
        state in [:queued, :leased, :uploading, :done]
    )
    |> Ash.exists?(domain: Portal.Builders)
  end

  defp run_exists?(package, version, digests) do
    Run
    |> Ash.Query.filter(
      version_tested == ^version and image_digest in ^digests and package.name == ^package
    )
    |> Ash.read!(domain: Portal.Catalog)
    |> Enum.any?()
  end

  # As `Portal.Workers.Build`: `{:snooze, _}` bumps `attempt`, and Oban's
  # default backoff is quartic in it, so a job waiting on a long lease would
  # otherwise come back days later. Cap it at an hour.
  @impl Oban.Worker
  def backoff(%Oban.Job{} = job) do
    job |> Oban.Worker.backoff() |> min(3600)
  end
end
