defmodule NccAgent.HexRegistry do
  @moduledoc """
  The outer checksums the signed Hex registry lists, for
  `NccAgent.HexCache.promote/3`: the same source and rules as the portal's
  `Portal.HexDeps.outer_checksum/3`.

  The per-package resource `repo.hex.pm/packages/<name>` is a gzipped,
  signed protobuf; `:hex_core` checks its signature against hex.pm's key
  and decodes it. It is what Hex itself checks a tarball against, it comes
  from the CDN rather than the rate-limited API, and one fetch answers every
  version of a package. Answers are kept for an hour per package in a
  node-wide table (`create_table/0`, from `NccAgent.Application`); errors
  never are. A version the kept answer lacks is asked about once more,
  since it may be newer than the hour.
  """

  require Logger

  @repo_url "https://repo.hex.pm"
  @table __MODULE__
  @ttl_seconds 3600

  @type error :: :unknown_release | :hex_registry_unavailable

  @doc "Creates the cache table. The calling process owns it."
  @spec create_table() :: :ok
  def create_table do
    if :ets.whereis(@table) == :undefined,
      do: :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    :ok
  end

  @doc "Empties the cache. For tests."
  @spec flush() :: :ok
  def flush do
    create_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  `{:ok, checksum}` (lowercase hex) for `name` at `version`;
  `{:error, :unknown_release}` for a package or release the registry does not
  list or lists without an outer checksum; `{:error, :hex_registry_unavailable}`
  for a rate limit, an outage, a transport error or a resource that does not
  verify. `name` must already be a valid Hex name
  (`Compatibility.HexCache.pair/1`). Options `:client` (default `Req`) and
  `:public_key` (default hex.pm's) are for tests.
  """
  @spec outer_checksum(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def outer_checksum(name, version, opts \\ []) do
    with :miss <- cached(name, version),
         {:ok, versions} <- fetch(name, opts) do
      store(name, versions)

      case Map.fetch(versions, version) do
        {:ok, checksum} when is_binary(checksum) -> {:ok, checksum}
        _ -> {:error, :unknown_release}
      end
    else
      {:hit, checksum} when is_binary(checksum) -> {:ok, checksum}
      {:hit, nil} -> {:error, :unknown_release}
      {:error, _} = error -> error
    end
  end

  defp cached(name, version) do
    now = System.system_time(:second)

    case :ets.lookup(@table, name) do
      [{^name, versions, expires_at}] when expires_at > now and is_map_key(versions, version) ->
        {:hit, Map.fetch!(versions, version)}

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp store(name, versions) do
    :ets.insert(@table, {name, versions, System.system_time(:second) + @ttl_seconds})
  rescue
    ArgumentError -> false
  end

  # Fails fast, inside `Compatibility.HexCache.lookup_timeout_ms/0`: the
  # slot stays busy while promotion runs.
  defp fetch(name, opts) do
    client = Keyword.get(opts, :client, Req)
    key = Keyword.get(opts, :public_key, :hex_core.default_config()[:repo_public_key])
    half = div(Compatibility.HexCache.lookup_timeout_ms(), 2)

    # `compressed: false`, `decode_body: false`: `:hex_core` gunzips itself.
    case client.get("#{@repo_url}/packages/#{name}",
           compressed: false,
           decode_body: false,
           retry: false,
           receive_timeout: half,
           connect_options: [timeout: half]
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> unpack(name, body, key)
      {:ok, %{status: status}} when status in [403, 404] -> {:error, :unknown_release}
      {:ok, %{status: status}} -> unavailable(name, "HTTP #{status}")
      {:error, reason} -> unavailable(name, inspect(reason))
    end
  end

  # A bad signature is an error tuple; a body that is not gzip raises.
  defp unpack(name, body, key) do
    case :hex_registry.unpack_package(body, "hexpm", name, key) do
      {:ok, %{releases: releases}} ->
        {:ok, Map.new(releases, &{&1.version, hex(Map.get(&1, :outer_checksum))})}

      {:error, reason} ->
        unavailable(name, inspect(reason))
    end
  rescue
    e -> unavailable(name, Exception.message(e))
  end

  defp hex(<<_::256>> = bytes), do: Base.encode16(bytes, case: :lower)
  defp hex(_other), do: nil

  defp unavailable(name, why) do
    Logger.warning("Hex registry /packages/#{name}: #{why}")
    {:error, :hex_registry_unavailable}
  end
end
