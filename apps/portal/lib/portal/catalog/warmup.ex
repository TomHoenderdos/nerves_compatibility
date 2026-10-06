defmodule Portal.Catalog.Warmup do
  @moduledoc """
  Computes the expensive `Portal.Catalog.Cache` entries once at boot, so the
  first visitor after a deploy does not pay for them.

  `Portal.Catalog.Cache` makes only the first caller after a restart wait, and
  that caller was a person. These computations fold the whole catalog: on a
  local copy shaped like production on 2026-10-06 (22,141 packages, 23,344
  runs, 47,455 system results) `latest_by_pkg_json/0` alone took ~850ms warm,
  and production is slower -- a cold `/api/stats`, built the same way before it
  moved to SQL, took 15.1s there. Running them here moves that wait off the
  request path. After this the entries go stale and refresh in the background
  as usual.

  Runs as a temporary `Task` child: boot does not wait for it, and a failure is
  logged and forgotten rather than restarted.

  Only on a node that serves the site. Both production hosts run the same
  release with the endpoint up (the deploy health-checks `/packages` on each),
  so serving HTTP alone does not say which host is public. What does is the
  Oban queue list each host's env sets: the web host runs `intake`, the build
  host only `builds` and `ingest` -- and the build host reaches Postgres over
  a ~80ms tailnet link, where loading the whole catalog for pages nobody will
  request there is pure cost. A single node with the default queue list runs
  `intake` too, and warms.
  """

  require Logger

  alias Portal.Catalog

  @doc false
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [&warm/0]},
      restart: :temporary
    }
  end

  @doc "Whether this node should warm the cache at boot."
  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    server? = Keyword.get_lazy(opts, :server?, &server?/0)
    queues = Keyword.get_lazy(opts, :queues, &queues/0)
    ttl_ms = Keyword.get_lazy(opts, :ttl_ms, &ttl_ms/0)

    # A zero TTL (the test environment) means nothing would be kept.
    server? and Keyword.has_key?(queues, :intake) and ttl_ms != 0
  end

  @doc """
  Computes each cached key in turn. One at a time, so the warm-up holds a single
  database connection rather than competing with the first real requests for
  the pool.
  """
  def warm do
    for {label, fun} <- keys() do
      {micros, _} = :timer.tc(fn -> warm_one(label, fun) end)
      Logger.info("catalog cache warmed #{label} in #{div(micros, 1000)}ms")
    end

    :ok
  end

  # The keys whose cold computation is the one a visitor would notice, with the
  # arguments their pages pass: `DashboardLive` asks for `dashboard(3, 10)`,
  # `FailureClustersLive` for `failure_clusters(50)`, `StatsLive` for the
  # status counts. `stats_json/0` is not here because it is no longer cached:
  # counted in Postgres it takes milliseconds.
  defp keys do
    [
      {"latest_by_pkg_json", fn -> Catalog.latest_by_pkg_json() end},
      {"dashboard", fn -> Catalog.dashboard(3, 10) end},
      {"package_status_counts", &Catalog.package_status_counts/0},
      {"failure_clusters", fn -> Catalog.failure_clusters(50) end}
    ]
  end

  defp warm_one(label, fun) do
    fun.()
  rescue
    e -> Logger.warning("catalog cache warm-up of #{label} failed: #{Exception.message(e)}")
  end

  defp server?, do: Phoenix.Endpoint.server?(:portal, PortalWeb.Endpoint)

  defp queues, do: :portal |> Application.get_env(Oban, []) |> Keyword.get(:queues, [])

  defp ttl_ms do
    :portal
    |> Application.get_env(Portal.Catalog.Cache, [])
    |> Keyword.get(:ttl_ms, 1)
  end
end
