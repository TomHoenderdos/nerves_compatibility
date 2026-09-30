defmodule Portal.Workers.Backfill do
  @moduledoc """
  Turns one upstream package name into a scan request, and through it a build.

  Runs in `intake` rather than `builds` because the work here is a hex.pm
  lookup, not a compile: it belongs on the web host, and keeping it off the
  build box means a multi-thousand package sweep never competes with the builds
  it is queueing.

  `Portal.ScanRequests.create_once/1` is idempotent against an already open
  request, and `Portal.Workers.Build` is unique on package/version/image, so
  re-running a sweep re-checks packages without duplicating work.

  ## The `source` argument

  Every caller funnels through here, but they are not equally urgent, and the
  source they name is what decides the resulting build's Oban priority (see
  `Portal.ScanRequests`). `Portal.Workers.UpdateCheck` passes `update_check`
  because a new release of a package we already show is stale data on the site;
  `Portal.CatalogSeed` passes `catalog_seed` because a package we have never
  tested is merely absent. Omitting it keeps the historical `backfill`, which
  is what `Portal.UpstreamBackfill` still wants.

  Unknown values are rejected rather than defaulted: `create_once/1` would fail
  the resource's `one_of` constraint on the insert, and a typo silently landing
  everything at the default priority is exactly the failure this argument exists
  to prevent.

  ## The queue filter

  With `NCC_QUEUE_FILTER` on, bulk sources (`catalog_seed`, `backfill`) are
  classified from registry data before any build is queued. A package with no
  native code in its dependency closure (`Portal.NativeClosure`) is recorded as
  a `registry_deps` pass (`Portal.Catalog.RegistryAssessment`) and never reaches
  Docker. Everything else takes the ordinary path.

  `update_check` is classified only for a package whose latest run was itself a
  registry assessment. Without that, every minor release of the ~18k packages a
  filtered seed adds would go straight to Docker through `UpdateCheck`. A
  package with a real build history keeps being rebuilt for real.

  Human sources never come through this worker. A registry outage returns an
  error and Oban retries: falling through to a build would turn a CDN hiccup
  during a seed into thousands of Docker runs.
  """

  @sources ~w(backfill update_check catalog_seed)

  use Oban.Worker,
    queue: :intake,
    max_attempts: 5,
    # Long enough that a re-run inside the same sweep is a no-op, short enough
    # that a deliberate re-sweep tomorrow still goes through.
    unique: [keys: [:package], period: 86_400]

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Portal.Catalog.RegistryAssessment
  alias Portal.ScanRequests
  alias Portal.ScanRequests.ScanRequest

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"package" => package} = args}) do
    source = Map.get(args, "source", "backfill")

    if source in @sources do
      build(package, String.to_existing_atom(source))
    else
      {:cancel, {:unknown_source, source}}
    end
  end

  defp build(package, source) do
    if classify?(package, source) do
      classify(package, source)
    else
      request(package, source)
    end
  end

  defp request(package, source) do
    case ScanRequests.create_once(%{package_name: package, source: source}) do
      {:ok, _request} ->
        :ok

      # hex.pm does not have it (renamed, retired, or upstream-only). Retrying
      # will not change that, so stop rather than burn five attempts.
      {:error, reason} when reason in [:unknown_package, :unknown_package_version] ->
        Logger.info("Backfill skipping #{package}: #{inspect(reason)}")
        {:cancel, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # An open request means someone -- often a human -- already has a build on
  # the way. Classifying on top of it would attach a registry run to a queued
  # build, so it is left alone.
  defp classify?(package, source) do
    filter_enabled?() and eligible?(package, source) and
      is_nil(ScanRequests.open_request_for_package(package))
  end

  defp eligible?(_package, source) when source in [:catalog_seed, :backfill], do: true
  defp eligible?(package, :update_check), do: registry_assessed?(package)
  defp eligible?(_package, _source), do: false

  defp classify(package, source) do
    case version_resolver().latest_version(package) do
      {:ok, version} ->
        case native_closure().classify(package, version) do
          :pure ->
            record(package, version, source)

          {:native, reason} ->
            Logger.info("Queue filter: #{package} #{version} is native: #{inspect(reason)}")
            request(package, source)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} when reason in [:unknown_package, :unknown_package_version] ->
        Logger.info("Backfill skipping #{package}: #{inspect(reason)}")
        {:cancel, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The request is created already `built` so `create_once/1` queues nothing,
  # then linked to the run once it exists -- the same end state an ordinary
  # build reaches through `Portal.Workers.Ingest`.
  #
  # `create_once/1` returns whatever open request already exists for the
  # package rather than creating a second one. `classify?/2` checked for that
  # before the hex.pm round trips above, but a human or anonymous request can
  # open in the seconds it takes to resolve the version and classify the
  # closure. If that happened, `create_once/1` hands back that other request
  # here instead of a fresh `:built` one, and recording on top of it would
  # close a queued admin build or skip anonymous review out from under it. So
  # only a request this call itself created (status `:built`, its only
  # possible status straight out of `create_once/1` with that argument) is
  # recorded against; anything else means the race was lost, and this leaves
  # the other request alone.
  defp record(package, version, source) do
    case ScanRequests.create_once(%{
           package_name: package,
           version: version,
           source: source,
           status: :built
         }) do
      {:ok, %ScanRequest{status: :built} = request} ->
        with {:ok, run} <- RegistryAssessment.record(package, version, request.id),
             {:ok, _request} <- ScanRequests.set_status(request, :built, run_id: run.id) do
          :ok
        end

      {:ok, %ScanRequest{} = request} ->
        Logger.info(
          "Queue filter: #{package} gained an open request " <>
            "(#{request.status}) while classifying; leaving it to its own build"
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Two columns from the newest run, not the Ash resource: the run row carries
  # the full runner log, and this only needs to know where the run came from.
  defp registry_assessed?(package) do
    digest =
      Portal.Repo.one(
        from(r in "catalog_runs",
          join: p in "catalog_packages",
          on: p.id == r.package_id,
          where: p.name == ^package,
          order_by: [desc_nulls_last: r.finished_at, desc: r.inserted_at],
          limit: 1,
          select: r.image_digest
        )
      )

    digest == RegistryAssessment.image_digest()
  end

  defp filter_enabled? do
    :portal |> Application.get_env(:queue_filter, []) |> Keyword.get(:enabled, false)
  end

  defp native_closure, do: Application.get_env(:portal, :native_closure, Portal.NativeClosure)

  defp version_resolver,
    do: Application.get_env(:portal, :package_version_resolver, Portal.HexPm)
end
