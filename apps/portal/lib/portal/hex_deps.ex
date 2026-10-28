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
  kept for an hour -- the resource's own `cache-control` -- reducing repeated
  fetches. Sequential walks and staggered seed jobs make repeats rare; when
  concurrent callers miss the same cache key, each may fetch once, and that is
  accepted because the only cost is an extra CDN request, never a wrong answer.
  Errors are never cached: a CDN hiccup must not be remembered for an hour.

  The table is node-local and owned by this process, like
  `PortalWeb.WebAuthnSession`'s.

  Reads ignore an expired entry, but only the sweep removes it: once per TTL
  the process deletes every row whose expiry has passed. Without it a
  full-registry seed would leave every package it touched -- on the order of
  150-250 MB -- resident for the life of the node.
  """

  use GenServer

  require Logger

  @repo_url "https://repo.hex.pm"
  @repository "hexpm"
  @table __MODULE__
  @ttl_seconds 3600
  # The largest package resource on the registry is a few hundred KiB.
  @max_bytes 8 * 1024 * 1024

  @type dep :: %{
          package: String.t(),
          requirement: String.t(),
          optional: boolean(),
          repository: String.t()
        }
  @type release :: %{
          version: String.t(),
          retired?: boolean(),
          deps: [dep()],
          outer_checksum: String.t() | nil
        }
  @type error :: :hex_registry_unavailable | :hex_registry_undecodable | :not_found

  @doc """
  Every release of `name`, oldest first, with its dependencies.

  Options: `:client` (module exposing `get/2`, default `Req`), `:public_key`
  (default hex.pm's), `:cache` (default `true`). The first two exist for tests,
  as in `Portal.HexRegistry.snapshot/1`. `:receive_timeout` (default 30 s) and
  `:retry` (default Req's) and `:connect_options` pass through to the
  request, for a caller with someone waiting on the answer.
  """
  @spec releases(String.t(), keyword()) :: {:ok, [release()]} | {:error, error()}
  def releases(name, opts \\ []) when is_binary(name) do
    cache? = Keyword.get(opts, :cache, true)

    case cache? && cached(name) do
      {:ok, releases} -> {:ok, releases}
      _ -> fetch_and_store(name, opts, cache?)
    end
  end

  @doc """
  The outer checksum (lowercase hex SHA-256 of the tarball) the signed
  registry lists for `name` at `version`: what Hex itself checks a cached
  or downloaded tarball against, read from the CDN rather than the API, so
  a cold Hex cache costs one cached request per package and no API quota
  (`Portal.HexCache`). A version the cached resource lacks is asked about
  once more, uncached, since it may have been published within the hour.

  `{:error, :unknown_release}` for a package or release the registry does
  not list, or one without an outer checksum (which Hex cannot use either);
  `{:error, :hex_registry_unavailable}` for anything that says "ask later":
  a 429, a 5xx, a transport error or a resource that does not verify.
  Neither is cached. Options as for `releases/2`.
  """
  @spec outer_checksum(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :unknown_release | :hex_registry_unavailable}
  def outer_checksum(name, version, opts \\ []) when is_binary(name) and is_binary(version) do
    with {:ok, releases} <- releases(name, opts),
         :miss <- find_checksum(releases, version),
         {:ok, releases} <- fetch_and_store(name, opts, Keyword.get(opts, :cache, true)),
         :miss <- find_checksum(releases, version) do
      {:error, :unknown_release}
    else
      {:ok, checksum} -> {:ok, checksum}
      :no_checksum -> {:error, :unknown_release}
      {:error, :not_found} -> {:error, :unknown_release}
      {:error, _reason} -> {:error, :hex_registry_unavailable}
    end
  end

  defp find_checksum(releases, version) do
    case Enum.find(releases, &(&1.version == version)) do
      nil -> :miss
      %{outer_checksum: checksum} when is_binary(checksum) -> {:ok, checksum}
      _release -> :no_checksum
    end
  end

  defp fetch_and_store(name, opts, cache?) do
    with {:ok, releases} <- fetch(name, opts) do
      if cache?, do: :ets.insert(@table, {name, releases, now() + @ttl_seconds})
      {:ok, releases}
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
    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  # Rows are `{name, releases, expires_at}`; delete every one that has expired.
  defp sweep do
    now = now()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, :timer.seconds(@ttl_seconds))

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
    # No redirect: the resource is served from repo.hex.pm and nowhere else.
    # The body is capped while it streams in (`capped/1`), and again here for
    # a client that ignores `:into`.
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)

    request_opts =
      Keyword.merge(
        [
          compressed: false,
          decode_body: false,
          receive_timeout: 30_000,
          redirect: false,
          into: capped(max_bytes)
        ],
        Keyword.take(opts, [:receive_timeout, :retry, :connect_options])
      )

    case client.get("#{@repo_url}/packages/#{name}", request_opts) do
      {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) <= max_bytes ->
        unpack(name, body, key)

      {:ok, %{status: 200}} ->
        Logger.warning("Hex registry /packages/#{name} is over #{max_bytes} bytes")
        {:error, :hex_registry_unavailable}

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

  @doc false
  # A Req `:into` that collects the body and stops the download once it is
  # over `max_bytes`, leaving `:too_large` as the body.
  @spec capped(pos_integer()) :: (term(), term() -> term())
  def capped(max_bytes) do
    fn {:data, data}, {req, resp} ->
      body = if is_binary(resp.body), do: resp.body <> data, else: data

      if byte_size(body) > max_bytes,
        do: {:halt, {req, %{resp | body: :too_large}}},
        else: {:cont, {req, %{resp | body: body}}}
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
      outer_checksum: checksum_hex(Map.get(release, :outer_checksum)),
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

  # 32 bytes in the protobuf; anything else is no checksum Hex could match.
  defp checksum_hex(<<_::256>> = bytes), do: Base.encode16(bytes, case: :lower)
  defp checksum_hex(_other), do: nil

  defp public_key, do: :hex_core.default_config()[:repo_public_key]

  defp now, do: System.system_time(:second)
end
