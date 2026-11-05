defmodule PortalWeb.PrecompiledHTTP do
  @moduledoc """
  Validators and cache policy for `/api/precompiled`, so a CDN in front of it
  stores exactly what is safe to store.

  Content-addressed bytes (files and by-sha manifests) are `:immutable`. The
  signed metadata (root, batches) is `:revalidate`: a minute, then a
  conditional GET answered 304 when the bytes did not change. Per-package-name
  manifests change with every batch and are `:private_short`, which no shared
  cache stores. An absence (404, 503) is `:no_store`, so a CDN never remembers
  that a file was missing after it arrives.

  ETags are strong: the quoted lowercase SHA-256 of the bytes served.
  `If-None-Match` uses the weak comparison (RFC 9110 13.1.2), so `W/"<sha>"`
  from a proxy that compressed the response still matches.
  """
  import Plug.Conn

  @type policy :: :immutable | :revalidate | :private_short | :no_store

  @spec cache_control(policy()) :: String.t()
  def cache_control(:immutable), do: "public, max-age=31536000, immutable"
  def cache_control(:revalidate), do: "public, max-age=60, must-revalidate"
  def cache_control(:private_short), do: "private, max-age=60"
  def cache_control(:no_store), do: "no-store"

  @spec etag(binary()) :: String.t()
  def etag(bytes) when is_binary(bytes),
    do: bytes |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower) |> quote_sha()

  # Every caller already has a validated digest (the route's own 64-hex path
  # match, or `ArtifactStore.valid_sha256?/1`): this guard is a backstop
  # against ever quoting something else as if it were an etag.
  @spec quote_sha(String.t()) :: String.t()
  def quote_sha(sha) when is_binary(sha) do
    if valid_sha256?(sha) do
      ~s("#{sha}")
    else
      raise ArgumentError, "quote_sha/1 expects a lowercase hex sha256, got: #{inspect(sha)}"
    end
  end

  defp valid_sha256?(sha), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, sha)

  @spec put_validators(Plug.Conn.t(), String.t(), policy()) :: Plug.Conn.t()
  def put_validators(conn, etag, policy) do
    conn
    |> put_resp_header("cache-control", cache_control(policy))
    |> put_resp_header("etag", etag)
  end

  @spec not_modified?(Plug.Conn.t(), String.t()) :: boolean()
  def not_modified?(conn, etag) do
    conn |> get_req_header("if-none-match") |> Enum.any?(&names?(&1, etag))
  end

  # RFC 9110 9.3.2 Appendix defines `If-None-Match` as a comma-separated list
  # of entity tags; a bare "," cannot appear inside one because an entity tag
  # is always a quoted string (`"..."`) or, weak, `W/"..."`. Splitting on ","
  # unconditionally is therefore safe here: it can only misparse a quoted etag
  # that itself embeds a comma, and every etag this module issues is a plain
  # hex sha256, which never does.
  defp names?(header, etag) do
    header
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.any?(fn tag -> tag == "*" or strip_weak(tag) == etag end)
  end

  defp strip_weak("W/" <> tag), do: tag
  defp strip_weak(tag), do: tag

  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  # `content_type` is a route-chosen literal (default "application/json") and
  # `bytes` is the precompiled payload already built by the caller, not
  # user-controlled input reflected back unescaped.
  @spec send_bytes(Plug.Conn.t(), binary(), String.t(), policy(), String.t()) :: Plug.Conn.t()
  def send_bytes(conn, bytes, etag, policy, content_type \\ "application/json") do
    conn = put_validators(conn, etag, policy)

    if not_modified?(conn, etag),
      do: send_resp(conn, 304, ""),
      else: conn |> put_resp_content_type(content_type) |> send_resp(200, bytes)
  end

  @spec no_store(Plug.Conn.t()) :: Plug.Conn.t()
  def no_store(conn), do: put_resp_header(conn, "cache-control", cache_control(:no_store))
end
