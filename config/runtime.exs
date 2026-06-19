import Config

# runtime.exs does NOT support import_config, so portal's runtime config
# is inlined here, guarded so the worker Docker image (which copies only
# compatibility + ncc_worker) still builds without apps/portal on disk.
if File.exists?(Path.expand("../apps/portal", __DIR__)) do
  if System.get_env("PHX_SERVER") do
    config :portal, PortalWeb.Endpoint, server: true
  end

  config :portal, PortalWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4001"))]

  repo_config = Application.get_env(:portal, Portal.Repo, [])

  repo_pool_size =
    case System.get_env("PORTAL_DATABASE_POOL_SIZE") do
      nil -> Keyword.get(repo_config, :pool_size, 5)
      value -> String.to_integer(value)
    end

  config :portal, Portal.Repo,
    database:
      System.get_env("PORTAL_DATABASE_PATH") ||
        Keyword.get(repo_config, :database) ||
        "var/portal.sqlite3",
    pool_size: repo_pool_size

  config :portal,
    orchestrator_scan_request_url: System.get_env("ORCHESTRATOR_SCAN_REQUEST_URL"),
    scan_request_shared_secret: System.get_env("SCAN_REQUEST_SHARED_SECRET"),
    github_client_id: System.get_env("GITHUB_CLIENT_ID")

  if config_env() == :prod do
    secret_key_base =
      System.get_env("SECRET_KEY_BASE") ||
        raise """
        environment variable SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """

    host = System.get_env("PHX_HOST") || "example.com"

    config :portal, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

    config :portal, PortalWeb.Endpoint,
      url: [host: host, port: 443, scheme: "https"],
      http: [
        ip: {0, 0, 0, 0, 0, 0, 0, 0}
      ],
      secret_key_base: secret_key_base
  end
end
