defmodule Portal.Builders.Listener do
  @moduledoc """
  Decides whether the mTLS listener starts and assembles its Bandit options:
  the CA-signed server certificate, the CA as the only trusted root, and
  `fail_if_no_peer_cert: false` so `/builder/v1/enroll` and `/ca.pem` are
  reachable without a certificate while `PortalWeb.Plugs.BuilderCert` demands
  one everywhere else.
  """
  require Logger
  alias Portal.Builders.CA

  @default_port 8443

  @doc "True when the builder endpoint is configured to serve and the CA loads."
  @spec enabled?() :: boolean()
  def enabled? do
    Keyword.get(endpoint_config(), :server, false) == true and match?({:ok, _}, CA.load())
  end

  @spec port() :: :inet.port_number()
  def port, do: endpoint_config() |> Keyword.get(:https, []) |> Keyword.get(:port, @default_port)

  @doc "The Bandit `https:` options for `host`; issues the server certificate when needed."
  @spec https_options(String.t()) :: keyword()
  def https_options(host) do
    case build_https_options(host) do
      {:ok, opts} ->
        opts

      {:error, reason} ->
        raise ArgumentError,
              "builder listener server certificate for #{inspect(host)}: #{inspect(reason)}"
    end
  end

  defp build_https_options(host) do
    with {:ok, %{certfile: certfile, keyfile: keyfile}} <- CA.ensure_server_cert(host) do
      {:ok,
       [
         port: port(),
         ip: {0, 0, 0, 0, 0, 0, 0, 0},
         certfile: certfile,
         keyfile: keyfile,
         cacertfile: CA.cert_path(),
         verify: :verify_peer,
         fail_if_no_peer_cert: false,
         cipher_suite: :strong,
         http_2_options: [enabled: false]
       ]}
    end
  end

  @doc """
  Settle the endpoint config before `PortalWeb.BuilderEndpoint` starts
  (Phoenix reads it at boot). When `enabled?/0`, install the https options
  and return `:ok`: the endpoint listens. Otherwise, or when the server
  certificate cannot be issued (a host the CA will not name, an unwritable CA
  dir), force `server: false` so the endpoint runs without a listener -- the
  public site keeps serving and `Phoenix.ConnTest` can still dispatch to it.
  """
  @spec configure() :: :ok | {:error, term()}
  def configure do
    if enabled?() do
      host =
        :portal
        |> Application.get_env(PortalWeb.Endpoint, [])
        |> Keyword.get(:url, [])
        |> Keyword.get(:host, "localhost")

      case build_https_options(host) do
        {:ok, https} ->
          put_endpoint_config(:https, https)
          Logger.info("builder listener on #{port()} with CA #{CA.cert_path()}")
          :ok

        {:error, reason} = error ->
          put_endpoint_config(:server, false)
          Logger.error("builder listener not started: #{inspect(reason)} (host #{inspect(host)})")
          error
      end
    else
      put_endpoint_config(:server, false)
      {:error, :disabled}
    end
  end

  defp put_endpoint_config(key, value),
    do:
      Application.put_env(
        :portal,
        PortalWeb.BuilderEndpoint,
        Keyword.put(endpoint_config(), key, value)
      )

  defp endpoint_config, do: Application.get_env(:portal, PortalWeb.BuilderEndpoint, [])
end
