defmodule PortalWeb.Plugs.RateLimit do
  @moduledoc """
  Answers 429 with a `retry-after` header once a client has used up its
  budget in a `Portal.RateLimiter` bucket. Controllers plug it for the actions
  that cost something:

      plug PortalWeb.Plugs.RateLimit, [bucket: :auth] when action in [:create_session]

  ## Options

    * `:bucket` -- whose `{hits, window_ms}` applies, read from
      `Portal.RateLimiter.limit/1` on every request so config can change it
      (required)
    * `:by` -- `:ip` (default) counts per client; `:global` counts every
      client together, for a budget that is ours rather than theirs
    * `:json` -- extra fields for a JSON 429 body, next to `error`
    * `:limit`, `:window_ms`, `:enabled`, `:clock` -- override the config
      and the clock; for tests

  ## Client address

  Production sits behind a reverse proxy on the same host, so the TCP peer,
  `conn.remote_ip`, is the proxy's loopback address for every request. A
  limit keyed on it would be one budget for the whole world. So when, and
  only when, the peer is loopback, the client is the *last* entry of
  `X-Forwarded-For`: Apache's `mod_proxy` appends the address it accepted the
  connection from, so that entry is the proxy's own observation, while every
  entry before it is whatever the client chose to send. A peer that is not
  loopback is the client itself and its `X-Forwarded-For` is ignored.

  `conn.remote_ip` itself is left alone: nothing else in the portal reads it
  and the builder endpoint's limits want the real TCP peer.
  """

  @behaviour Plug

  import Plug.Conn

  alias Portal.RateLimiter

  @impl true
  def init(opts) do
    %{
      bucket: Keyword.fetch!(opts, :bucket),
      by: Keyword.get(opts, :by, :ip),
      json: Keyword.get(opts, :json, %{}),
      limit: Keyword.get(opts, :limit),
      window_ms: Keyword.get(opts, :window_ms),
      enabled: Keyword.get(opts, :enabled),
      clock: Keyword.get(opts, :clock)
    }
  end

  @impl true
  def call(conn, opts) do
    if enabled?(opts), do: count(conn, opts), else: conn
  end

  defp count(conn, opts) do
    {limit, window_ms} = limit(opts)
    key = if opts.by == :global, do: :global, else: client_ip(conn)
    clock = if opts.clock, do: [now_ms: opts.clock.()], else: []

    case RateLimiter.hit(opts.bucket, key, limit, window_ms, clock) do
      :ok -> conn
      {:error, retry_after_ms} -> reject(conn, retry_after_ms, opts)
    end
  end

  defp limit(%{limit: limit, window_ms: window_ms})
       when is_integer(limit) and is_integer(window_ms),
       do: {limit, window_ms}

  defp limit(opts) do
    {limit, window_ms} = RateLimiter.limit(opts.bucket)
    {opts.limit || limit, opts.window_ms || window_ms}
  end

  @doc "The client's address as a tuple. See the moduledoc for the proxy rule."
  @spec client_ip(Plug.Conn.t()) :: :inet.ip_address()
  def client_ip(conn) do
    with true <- loopback?(conn.remote_ip),
         [_ | _] = values <- get_req_header(conn, "x-forwarded-for"),
         last when last != "" <- values |> Enum.join(",") |> last_entry(),
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(last)) do
      ip
    else
      _ -> conn.remote_ip
    end
  end

  defp last_entry(header), do: header |> String.split(",") |> List.last() |> String.trim()

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  defp reject(conn, retry_after_ms, opts) do
    seconds = retry_after_ms |> Kernel.+(999) |> div(1000) |> max(1)
    message = "Too many requests. Try again in #{seconds} seconds."

    conn =
      conn
      |> put_resp_header("retry-after", Integer.to_string(seconds))
      |> put_status(:too_many_requests)

    # The format the `:accepts` plug negotiated. `get_format/1` would fall
    # back to reading params, which a plug in a bare pipeline has not fetched.
    conn =
      if conn.private[:phoenix_format] == "json" do
        Phoenix.Controller.json(conn, Map.put(opts.json, :error, message))
      else
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(429, message <> "\n")
      end

    halt(conn)
  end

  defp enabled?(%{enabled: enabled}) when is_boolean(enabled), do: enabled
  defp enabled?(_opts), do: RateLimiter.enabled?()
end
