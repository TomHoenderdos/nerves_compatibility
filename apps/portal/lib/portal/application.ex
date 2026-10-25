defmodule Portal.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Owned by this process, which lives as long as the application: the
    # memo of Hex.pm release checksums `Portal.BuildCache.Promotion` checks.
    :ok = Portal.HexPm.create_release_checksum_table()
    # And the memo of package owners `Portal.NervesCache.warm_pairs/2` checks.
    :ok = Portal.HexPm.create_package_owners_table()
    # And the memo of pairs already warmed `Portal.NervesCache.recently_warmed/2` checks.
    :ok = Portal.NervesCache.create_warmed_table()

    children = [
      PortalWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:portal, :dns_cluster_query) || :ignore},
      Portal.Repo,
      # Must precede the endpoint: it owns the ETS table the catalog reads from.
      Portal.Catalog.Cache,
      # Owns the ETS table of decoded per-package registry resources that
      # `Portal.NativeClosure` walks; see `Portal.HexDeps`.
      Portal.HexDeps,
      # Also precedes the endpoint: it owns the ETS table holding in-flight
      # WebAuthn challenges.
      PortalWeb.WebAuthnSession,
      # A build node also runs its own ingest queue and its own Nerves cache
      # warm queue; see `Portal.Workers.Ingest` and `Portal.Workers.WarmNerves`.
      {Oban,
       :portal
       |> Application.fetch_env!(Oban)
       |> Portal.Workers.Ingest.with_local_queue()
       |> Portal.Workers.WarmNerves.with_local_queue()},
      {Phoenix.PubSub, name: Portal.PubSub},
      # Owns the ETS table of builder rate-limit counters; precedes both
      # endpoints, whose requests count against it.
      Portal.Builders.RateLimit,
      # Start a worker by calling: Portal.Worker.start_link(arg)
      # {Portal.Worker, arg},
      # Start to serve requests, typically the last entry
      PortalWeb.Endpoint
    ]

    # The remote builders' endpoint. It listens (mTLS) only with a CA and
    # `server: true`; `configure/0` installs its certificates first, or turns
    # the listener off, so a CA problem never stops the public site.
    _ = Portal.Builders.Listener.configure()
    children = children ++ [PortalWeb.BuilderEndpoint]

    # After the endpoint, so the warm-up never delays serving; the Repo and the
    # Cache it fills are both up by then.
    children =
      if Portal.Catalog.Warmup.enabled?(),
        do: children ++ [Portal.Catalog.Warmup],
        else: children

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Portal.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      :ok = start_boot_egress_check()
      {:ok, pid}
    end
  end

  # A build node whose egress filter is missing refuses every build
  # (`Portal.Builder.check_egress/0`); say so once at boot rather than only in
  # each refusal. Only where builds run: the web host has no rootless daemon.
  # Off the boot path, since it shells out and, at boot, waits up to a minute
  # for a rootless daemon that starts after the portal
  # (`Portal.Builder.boot_egress_check/1`).
  defp start_boot_egress_check do
    oban = Application.fetch_env!(:portal, Oban)

    if Keyword.get(oban, :testing, :disabled) == :disabled and
         Portal.Workers.Ingest.local_queue_limit(Keyword.get(oban, :queues)) != nil do
      {:ok, _pid} = Task.start(&Portal.Builder.boot_egress_check/0)
    end

    :ok
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PortalWeb.Endpoint.config_change(changed, removed)
    PortalWeb.BuilderEndpoint.config_change(changed, removed)
    :ok
  end
end
