defmodule Portal.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
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
      # A build node also runs its own ingest queue; see `Portal.Workers.Ingest`.
      {Oban, Portal.Workers.Ingest.with_local_queue(Application.fetch_env!(:portal, Oban))},
      {Phoenix.PubSub, name: Portal.PubSub},
      # Start a worker by calling: Portal.Worker.start_link(arg)
      # {Portal.Worker, arg},
      # Start to serve requests, typically the last entry
      PortalWeb.Endpoint
    ]

    # After the endpoint, so the warm-up never delays serving; the Repo and the
    # Cache it fills are both up by then.
    children =
      if Portal.Catalog.Warmup.enabled?(),
        do: children ++ [Portal.Catalog.Warmup],
        else: children

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Portal.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PortalWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
