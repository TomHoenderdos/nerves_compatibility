import Config

# runtime.exs does NOT support import_config, so portal's runtime config
# is inlined here, guarded so the worker Docker image (which copies only
# compatibility + ncc_worker) still builds without apps/portal on disk.
#
# The disk check alone is not enough. In a release this file is evaluated from
# the release's own config dir, where apps/portal does not exist, so the guard
# was false and every variable below was silently ignored: SECRET_KEY_BASE,
# DATABASE_URL, PHX_SERVER, all of it. A release booted on compile-time dev
# config instead. Checking whether the portal code is actually loadable covers
# the release case; the disk check still covers `mix` in the umbrella.
portal_available? =
  File.exists?(Path.expand("../apps/portal", __DIR__)) or
    match?({:module, _}, Code.ensure_loaded(PortalWeb.Endpoint))

if portal_available? do
  if System.get_env("PHX_SERVER") do
    config :portal, PortalWeb.Endpoint, server: true
  end

  config :portal, PortalWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4001"))]

  repo_config = Application.get_env(:portal, Portal.Repo, [])

  repo_pool_size =
    case System.get_env("PORTAL_DATABASE_POOL_SIZE") do
      nil -> Keyword.get(repo_config, :pool_size, 10)
      value -> String.to_integer(value)
    end

  case System.get_env("DATABASE_URL") do
    nil ->
      :ok

    url ->
      maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

      # The build box talks to Postgres across a ~80ms tailnet link while five
      # buildroot compiles fight for its six cores. DBConnection's 15s default
      # kills a connection that is merely slow, which surfaces as
      # `tcp recv: closed` rather than as a timeout.
      repo_timeout =
        case System.get_env("PORTAL_DATABASE_TIMEOUT") do
          nil -> 60_000
          value -> String.to_integer(value)
        end

      # DBConnection decides the pool is unhealthy when a checkout waits longer
      # than queue_target, and then starts dropping queued requests outright. The
      # 50ms default assumes Postgres is on the same box; across the tailnet a
      # single round trip already costs more than that, so the pool looks
      # permanently sick and drops work that was only waiting its turn. That
      # surfaced as `connection not available and request was dropped from queue`
      # once the checkout-hold bug above stopped masking it.
      queue_target =
        case System.get_env("PORTAL_DATABASE_QUEUE_TARGET") do
          nil -> 500
          value -> String.to_integer(value)
        end

      queue_interval =
        case System.get_env("PORTAL_DATABASE_QUEUE_INTERVAL") do
          nil -> 5_000
          value -> String.to_integer(value)
        end

      config :portal, Portal.Repo,
        url: url,
        pool_size: repo_pool_size,
        timeout: repo_timeout,
        queue_target: queue_target,
        queue_interval: queue_interval,
        socket_options: maybe_ipv6
  end

  # Which Oban queues this node runs, e.g. "builds:1,ingest:2". Unset means the
  # full set, so a single-node deploy needs nothing here.
  #
  # This is how the work splits across hosts: the web box runs the light queues,
  # the build box runs `builds` and `ingest`, and Postgres is the only thing they
  # share. `ingest` has to sit on the same host as `builds` because the two hand
  # off through the run's scratch directory on local disk, not through the
  # database.
  parsed_queues =
    case System.get_env("OBAN_QUEUES") do
      nil ->
        [builds: 1, ingest: 2, intake: 5, maintenance: 1]

      queues ->
        queues
        |> String.split(",", trim: true)
        |> Enum.map(fn pair ->
          case String.split(pair, ":", parts: 2) do
            [name, limit] ->
              {String.to_atom(String.trim(name)), String.to_integer(String.trim(limit))}

            _ ->
              raise "OBAN_QUEUES entries must look like `name:limit`, got: #{inspect(pair)}"
          end
        end)
    end

  config :portal, Oban, queues: parsed_queues

  config :portal,
    orchestrator_scan_request_url: System.get_env("ORCHESTRATOR_SCAN_REQUEST_URL"),
    scan_request_shared_secret: System.get_env("SCAN_REQUEST_SHARED_SECRET"),
    github_client_id: System.get_env("GITHUB_CLIENT_ID")

  if store = System.get_env("NCC_ARTIFACT_STORE") do
    config :portal, :artifact_store, path: store
  end

  # Every path here is handed to `docker run --mount source=`, so it is resolved
  # by the *host* daemon, not by this process. They must be host paths.
  #
  # NCC_BUILD_CPUS/NCC_BUILD_MEMORY cap a single build; unset means unbounded.
  builder_env = [
    docker_image: System.get_env("NCC_DOCKER_IMAGE"),
    scratch_root: System.get_env("NCC_SCRATCH_ROOT"),
    nerves_cache: System.get_env("NCC_NERVES_CACHE"),
    hex_cache: System.get_env("NCC_HEX_CACHE"),
    cpus: System.get_env("NCC_BUILD_CPUS"),
    memory: System.get_env("NCC_BUILD_MEMORY"),
    build_concurrency: System.get_env("NCC_BUILD_CONCURRENCY"),
    run_as_user: System.get_env("NCC_BUILD_USER")
  ]

  case Enum.reject(builder_env, fn {_k, v} -> is_nil(v) end) do
    [] -> :ok
    overrides -> config :portal, Portal.Builder, overrides
  end

  if config_env() == :prod do
    secret_key_base =
      System.get_env("SECRET_KEY_BASE") ||
        raise """
        environment variable SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """

    host = System.get_env("PHX_HOST") || "example.com"

    config :portal, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

    # Defaults to every interface. Behind a reverse proxy on the same host,
    # set PHX_BIND_IP=127.0.0.1 so the port is not reachable from outside it.
    bind_ip =
      case System.get_env("PHX_BIND_IP") do
        nil ->
          {0, 0, 0, 0, 0, 0, 0, 0}

        value ->
          case value |> String.to_charlist() |> :inet.parse_address() do
            {:ok, address} -> address
            {:error, _} -> raise "PHX_BIND_IP is not a valid IP address: #{inspect(value)}"
          end
      end

    config :portal, PortalWeb.Endpoint,
      url: [host: host, port: 443, scheme: "https"],
      http: [
        ip: bind_ip
      ],
      secret_key_base: secret_key_base
  end
end
