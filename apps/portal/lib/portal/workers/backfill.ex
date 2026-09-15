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
  """

  @sources ~w(backfill update_check catalog_seed)

  use Oban.Worker,
    queue: :intake,
    max_attempts: 5,
    # Long enough that a re-run inside the same sweep is a no-op, short enough
    # that a deliberate re-sweep tomorrow still goes through.
    unique: [keys: [:package], period: 86_400]

  require Logger

  alias Portal.ScanRequests

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"package" => package} = args}) do
    source = Map.get(args, "source", "backfill")

    if source not in @sources do
      {:cancel, {:unknown_source, source}}
    else
      build(package, String.to_existing_atom(source))
    end
  end

  defp build(package, source) do
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
end
