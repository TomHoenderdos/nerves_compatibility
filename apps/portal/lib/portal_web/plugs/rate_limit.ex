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
    * `:html` -- `{module, function}` called as `function(conn, message)` to
      render an HTML 429, so a form can come back with a flash rather than a
      bare text page. The conn already carries the status and `retry-after`.
      Without it, HTML requests get `text/plain`
    * `:peek` -- `true` checks the budget without spending it
      (`Portal.RateLimiter.peek/5`), for a budget the action spends itself
      with `spend/2` once a request has succeeded
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

  An IPv4-mapped IPv6 address (`::ffff:a.b.c.d`) is read as the IPv4 address
  it carries, on the peer and on the forwarded entry alike: with the listener
  bound to `::`, a proxy connecting to `127.0.0.1` arrives as
  `::ffff:127.0.0.1`.

  Any process on the host that can reach the listener on loopback can set
  `X-Forwarded-For` to whatever it likes. On a single-tenant host that is
  only ourselves, which is acceptable.

  ## Keys

  An IPv4 client is counted by its address, an IPv6 client by its /64: one
  subscriber usually holds a whole /64, and counting each of its 2^64
  addresses apart would make the limit meaningless.

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
      peek: Keyword.get(opts, :peek, false),
      json: Keyword.get(opts, :json, %{}),
      html: Keyword.get(opts, :html),
      limit: Keyword.get(opts, :limit),
      window_ms: Keyword.get(opts, :window_ms),
      enabled: Keyword.get(opts, :enabled),
      clock: Keyword.get(opts, :clock)
    }
  end

  @impl true
  def call(conn, opts) do
    case check(conn, opts) do
      {:ok, conn} -> conn
      {:halted, conn} -> conn
    end
  end

  @doc """
  The plug as a function, for an action that decides mid-way whether a
  request counts: `{:ok, conn}` within the budget, `{:halted, conn}` with the
  429 already sent past it. `opts` is what `init/1` returned.
  """
  @spec check(Plug.Conn.t(), map()) :: {:ok | :halted, Plug.Conn.t()}
  def check(conn, opts) do
    if enabled?(opts), do: count(conn, opts), else: {:ok, conn}
  end

  defp count(conn, opts) do
    {limit, window_ms} = limit(opts)
    key = if opts.by == :global, do: :global, else: client_key(conn)
    clock = if opts.clock, do: [now_ms: opts.clock.()], else: []

    count = if opts.peek, do: &RateLimiter.peek/5, else: &RateLimiter.hit/5

    case count.(opts.bucket, key, limit, window_ms, clock) do
      :ok -> {:ok, conn}
      {:error, retry_after_ms} -> {:halted, reject(conn, retry_after_ms, opts)}
    end
  end

  @doc """
  Spends one hit of a budget the plug only peeked at (`peek: true`). Takes
  the same options as the plug; whether the budget was already over does not
  matter, the request has been answered.
  """
  @spec spend(Plug.Conn.t(), keyword()) :: :ok
  def spend(conn, opts) do
    opts = init(opts)

    if enabled?(opts) do
      {limit, window_ms} = limit(opts)
      key = if opts.by == :global, do: :global, else: client_key(conn)
      clock = if opts.clock, do: [now_ms: opts.clock.()], else: []
      _ = RateLimiter.hit(opts.bucket, key, limit, window_ms, clock)
    end

    :ok
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
    peer = unmap(conn.remote_ip)

    with true <- loopback?(peer),
         [_ | _] = values <- get_req_header(conn, "x-forwarded-for"),
         last when last != "" <- values |> Enum.join(",") |> last_entry(),
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(last)) do
      unmap(ip)
    else
      _ -> peer
    end
  end

  @doc "What a client is counted by: its IPv4 address, or its IPv6 /64."
  @spec client_key(Plug.Conn.t()) :: :inet.ip_address()
  def client_key(conn) do
    case client_ip(conn) do
      {a, b, c, d, _, _, _, _} -> {a, b, c, d, 0, 0, 0, 0}
      ipv4 -> ipv4
    end
  end

  defp last_entry(header), do: header |> String.split(",") |> List.last() |> String.trim()

  defp unmap({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: {Bitwise.bsr(hi, 8), Bitwise.band(hi, 0xFF), Bitwise.bsr(lo, 8), Bitwise.band(lo, 0xFF)}

  defp unmap(ip), do: ip

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
      case {conn.private[:phoenix_format], opts.html} do
        {"json", _} ->
          Phoenix.Controller.json(conn, Map.put(opts.json, :error, message))

        {_, {module, function}} ->
          apply(module, function, [conn, message])

        _ ->
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(429, message <> "\n")
      end

    halt(conn)
  end

  defp enabled?(%{enabled: enabled}) when is_boolean(enabled), do: enabled
  defp enabled?(_opts), do: RateLimiter.enabled?()
end
