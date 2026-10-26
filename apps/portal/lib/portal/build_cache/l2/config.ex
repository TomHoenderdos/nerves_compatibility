defmodule Portal.BuildCache.L2.Config do
  @moduledoc """
  The L2 build cache's connection settings, from `config :portal,
  Portal.BuildCache.L2` (which `config/runtime.exs` fills from the
  `NCC_BUILD_CACHE_S3_*` env). No endpoint means off. An endpoint with any
  other required value missing is an error the caller logs once at boot and
  then treats as off: a half-configured cache must not look like a working
  one.
  """

  # The secret never reaches a log line or a crash report through `inspect`.
  @derive {Inspect, except: [:secret_key]}
  @enforce_keys [:endpoint, :bucket, :region, :access_key, :secret_key]
  defstruct [:endpoint, :bucket, :region, :access_key, :secret_key, read_only?: false]

  @type t :: %__MODULE__{
          endpoint: String.t(),
          bucket: String.t(),
          region: String.t(),
          access_key: String.t(),
          secret_key: String.t(),
          read_only?: boolean()
        }

  @spec config(keyword()) :: {:ok, t()} | :off | {:error, String.t()}
  def config(env \\ Application.get_env(:portal, Portal.BuildCache.L2, [])) do
    case present(env[:endpoint]) do
      nil -> :off
      endpoint -> build(endpoint, env)
    end
  end

  defp build(endpoint, env) do
    with {:ok, endpoint} <- parse_endpoint(endpoint),
         {:ok, bucket} <- required(env, :bucket, "NCC_BUILD_CACHE_S3_BUCKET"),
         {:ok, access_key} <- required(env, :access_key, "NCC_BUILD_CACHE_S3_ACCESS_KEY"),
         {:ok, secret_key} <- required(env, :secret_key, "NCC_BUILD_CACHE_S3_SECRET_KEY") do
      {:ok,
       %__MODULE__{
         endpoint: endpoint,
         bucket: bucket,
         region: present(env[:region]) || "garage",
         access_key: access_key,
         secret_key: secret_key,
         read_only?: env[:read_only] == true
       }}
    end
  end

  defp required(env, key, var) do
    case present(env[key]) do
      nil -> {:error, "build cache L2: #{var} is required when the endpoint is set"}
      value -> {:ok, value}
    end
  end

  # No userinfo (credentials belong in the access and secret key, and an
  # endpoint carrying them would be logged at boot) and no fragment. The
  # error never echoes the URL, which may hold exactly those credentials.
  defp parse_endpoint(url) do
    case URI.new(url) do
      {:ok,
       %URI{scheme: scheme, host: host, path: path, query: nil, userinfo: nil, fragment: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             path in [nil, "", "/"] ->
        {:ok, String.trim_trailing(url, "/")}

      _ ->
        {:error,
         "build cache L2: the endpoint (NCC_BUILD_CACHE_S3_ENDPOINT) must be http(s)://host[:port] " <>
           "with no credentials, path, query or fragment"}
    end
  end

  @doc """
  Whether `endpoint` (a URL or a `t()`) is plain `http` outside the private network:
  the host is not loopback (`127.0.0.0/8`, `::1`, `localhost`) and not in
  the private network's CGNAT range `100.64.0.0/10`. A hostname other than
  `localhost` counts as outside, since nothing says where it resolves. The
  object's SHA-256 header detects corruption, not tampering, so such an
  endpoint lets anything on the path change entries in transit.
  """
  @spec insecure_endpoint?(t() | String.t()) :: boolean()
  def insecure_endpoint?(%__MODULE__{endpoint: endpoint}), do: insecure_endpoint?(endpoint)

  def insecure_endpoint?(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: "http", host: host} when is_binary(host) -> not private_host?(host)
      _ -> false
    end
  end

  defp private_host?(host) do
    host = String.downcase(host)

    host == "localhost" or
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, {127, _, _, _}} -> true
        {:ok, {100, b, _, _}} when b in 64..127 -> true
        {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
        _ -> false
      end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil
end
