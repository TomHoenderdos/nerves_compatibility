defmodule Portal.HexDeps do
  @moduledoc """
  Reads one package's releases and their dependency lists from `repo.hex.pm`.

  This is the per-package resource of [registry v2][spec], the same signed,
  gzipped protobuf protocol `Portal.HexRegistry` reads for `/names` and
  `/versions`, and it is served from the CDN for the same reason: Hex's team
  asked the project to poll the repository, not the API. `:hex_core` verifies
  the signature and decodes; nothing here parses protobuf.

  [spec]: https://github.com/hexpm/specifications/blob/main/registry-v2.md

  ## Why a cache

  `Portal.NativeClosure` walks a dependency closure per package. Across a sweep
  of thousands of packages the same few hundred dependencies (`jason`,
  `telemetry`, `plug`, ...) recur in almost every closure. Decoded answers are
  kept for an hour -- the resource's own `cache-control` -- so a sweep costs one
  request per distinct package, not one per edge. Errors are never cached: a
  CDN hiccup must not be remembered for an hour.

  The table is node-local and owned by this process, like
  `PortalWeb.WebAuthnSession`'s.
  """

  use GenServer

  require Logger

  @repo_url "https://repo.hex.pm"
  @repository "hexpm"
  @table __MODULE__
  @ttl_seconds 3600

  @type dep :: %{
          package: String.t(),
          requirement: String.t(),
          optional: boolean(),
          repository: String.t()
        }
  @type release :: %{version: String.t(), retired?: boolean(), deps: [dep()]}
  @type error :: :hex_registry_unavailable | :hex_registry_undecodable | :not_found

  @doc """
  Every release of `name`, oldest first, with its dependencies.

  Options: `:client` (module exposing `get/2`, default `Req`), `:public_key`
  (default hex.pm's), `:cache` (default `true`). The first two exist for tests,
  as in `Portal.HexRegistry.snapshot/1`.
  """
  @spec releases(String.t(), keyword()) :: {:ok, [release()]} | {:error, error()}
  def releases(name, opts \\ []) when is_binary(name) do
    cache? = Keyword.get(opts, :cache, true)

    case cache? && cached(name) do
      {:ok, releases} ->
        {:ok, releases}

      _ ->
        with {:ok, releases} <- fetch(name, opts) do
          if cache?, do: :ets.insert(@table, {name, releases, now() + @ttl_seconds})
          {:ok, releases}
        end
    end
  end

  @doc "Drop every cached entry. Exposed for tests and `bin/portal rpc`."
  @spec flush() :: :ok
  def flush do
    :ets.delete_all_objects(@table)
    :ok
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  defp cached(name) do
    now = now()

    case :ets.lookup(@table, name) do
      [{^name, releases, expires_at}] when expires_at > now -> {:ok, releases}
      _ -> :miss
    end
  end

  defp fetch(name, opts) do
    client = Keyword.get(opts, :client, Req)
    key = Keyword.get(opts, :public_key, public_key())

    # `compressed: false` and `decode_body: false` for the reason documented in
    # `Portal.HexRegistry`: `:hex_core` gunzips the body itself.
    case client.get("#{@repo_url}/packages/#{name}",
           compressed: false,
           decode_body: false,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        unpack(name, body, key)

      # The CDN answers 403/404 for a package that does not exist. That is a
      # fact about the package, not an outage, so it must not trigger a retry.
      {:ok, %{status: status}} when status in [403, 404] ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        Logger.warning("Hex registry /packages/#{name} failed: HTTP #{status}")
        {:error, :hex_registry_unavailable}

      {:error, reason} ->
        Logger.warning("Hex registry /packages/#{name} failed: #{inspect(reason)}")
        {:error, :hex_registry_unavailable}
    end
  end

  # try/rescue for the same reason as `Portal.HexRegistry.unpack/3`: a bad
  # signature is an error tuple, but a body that is not gzip raises in `:zlib`.
  defp unpack(name, body, key) do
    case :hex_registry.unpack_package(body, @repository, name, key) do
      {:ok, %{releases: releases}} ->
        {:ok, Enum.map(releases, &normalise/1)}

      {:error, reason} ->
        Logger.warning("Hex registry /packages/#{name} did not decode: #{inspect(reason)}")
        {:error, :hex_registry_undecodable}
    end
  rescue
    error ->
      Logger.warning("Hex registry /packages/#{name} did not decode: #{inspect(error)}")
      {:error, :hex_registry_undecodable}
  end

  # Optional protobuf fields are simply absent from the decoded map. An absent
  # `repository` means the dependency lives in the same repository as the
  # package -- hexpm -- and an absent `optional` means required.
  defp normalise(release) do
    %{
      version: release.version,
      retired?: Map.has_key?(release, :retired),
      deps:
        release
        |> Map.get(:dependencies, [])
        |> Enum.map(fn dep ->
          %{
            package: dep.package,
            requirement: dep.requirement,
            optional: Map.get(dep, :optional, false) in [true, 1],
            repository: Map.get(dep, :repository, @repository)
          }
        end)
    }
  end

  defp public_key, do: :hex_core.default_config()[:repo_public_key]

  defp now, do: System.system_time(:second)
end
