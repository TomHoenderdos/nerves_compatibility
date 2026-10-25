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
    # The same uniqueness as `Portal.Workers.Build`; see the reasoning there.
    unique: [
      period: 60,
      fields: [:worker, :queue, :args],
      keys: [:package, :version, :image_digest, :force, :scan_request_id, :scope, :systems]
    ]

  require Ash.Query
  require Logger

  alias Portal.Builders.{Images, Leases}
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
      case Images.worker_image() do
        nil ->
          Logger.error("RemoteBuild for #{package} #{version}: no registry image in images.json")

          Progress.mark(scan_request_id, :error,
            error_reason: "no registry image for remote build"
          )

          Progress.broadcast(scan_request_id, :error, %{reason: "no registry image"})
          {:cancel, :no_registry_image}

        %{name: name, digest: digest} ->
          if not force and run_exists?(package, version, digest) do
            Logger.info("RemoteBuild dedup: run already exists for #{package} #{version}")
            Progress.mark(scan_request_id, :built)
            Progress.broadcast(scan_request_id, :done, %{deduped: true})
            :ok
          else
            lease(package, version, name, digest, args, scan_request_id, priority, force)
          end
      end
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

  defp run_exists?(package, version, digest) do
    Run
    |> Ash.Query.filter(
      version_tested == ^version and image_digest == ^digest and package.name == ^package
    )
    |> Ash.read!(domain: Portal.Catalog)
    |> Enum.any?()
  end
end
