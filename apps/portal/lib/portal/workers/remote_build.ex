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
  by, not this host's local image.
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

  defp lease_unless_built(job, %{name: name, digest: digest}) do
    %{package: package, version: version, scan_request_id: scan_request_id, force: force} = job

    cond do
      not force and run_exists?(package, version, digest) ->
        Logger.info("RemoteBuild dedup: run already exists for #{package} #{version}")
        Progress.mark(scan_request_id, :built)
        Progress.broadcast(scan_request_id, :done, %{deduped: true})
        :ok

      # This job is done once its lease is written, long before the run
      # exists, so a later job for the same build (a sweep after a
      # request, past the unique window) would otherwise lease it twice.
      # It waits instead: once that lease is ingested the next run
      # dedups on the run above and marks this request built; if the
      # lease failed, the next run leases afresh.
      not force and lease_in_flight?(package, version, digest) ->
        Logger.info("RemoteBuild waiting on an open lease for #{package} #{version}")
        Progress.broadcast(scan_request_id, :queued, %{remote: true, waiting_on_lease: true})
        {:snooze, 120}

      true ->
        lease(package, version, name, digest, job.args, scan_request_id, job.priority, force)
        |> on_enqueue_error(scan_request_id, job.attempt, job.max)
    end
  end

  defp lease(package, version, name, digest, args, scan_request_id, priority, force) do
    scope = Build.scope_args(package, version, args)

    lease_args = %{
      "systems_filter" => scope.systems_filter,
      "mode" => scope.mode,
      # Read when the lease is written, so an admin change applies from the
      # next lease on.
      "argus" => Portal.Settings.worker_argus(Portal.Settings.get()),
      "force" => force
    }

    with {:ok, _lease} <-
           Leases.enqueue(%{
             package: package,
             version: version,
             image_name: name,
             image_digest: digest,
             args: lease_args,
             scan_request_id: scan_request_id,
             # Oban's own default; only a hand-built job struct has none.
             priority: priority || 0
           }) do
      Progress.broadcast(scan_request_id, :queued, %{remote: true})
      :ok
    end
  end

  # As `Portal.Workers.Build.on_retry_or_exhaust/5`: the job retries, and the
  # last attempt marks the request errored instead of leaving it queued.
  defp on_enqueue_error(:ok, _scan_request_id, _attempt, _max), do: :ok

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

  defp lease_in_flight?(package, version, digest) do
    Lease
    |> Ash.Query.filter(
      package == ^package and version == ^version and image_digest == ^digest and
        state in [:queued, :leased, :uploading]
    )
    |> Ash.exists?(domain: Portal.Builders)
  end

  defp run_exists?(package, version, digest) do
    Run
    |> Ash.Query.filter(
      version_tested == ^version and image_digest == ^digest and package.name == ^package
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
