defmodule PortalWeb.Plugs.RateLimitTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias PortalWeb.Plugs.RateLimit

  # A unique bucket per test keeps async tests off each other's counters in
  # the shared table. `enabled: true` because the test config turns the
  # limiter off.
  defp opts(extra) do
    [bucket: {:test, make_ref()}, limit: 2, window_ms: 60_000, enabled: true]
    |> Keyword.merge(extra)
    |> RateLimit.init()
  end

  defp request(ip, xff \\ nil) do
    conn = %{conn(:post, "/login") | remote_ip: ip}
    if xff, do: put_req_header(conn, "x-forwarded-for", xff), else: conn
  end

  test "lets a client through up to the limit, then answers 429 with retry-after" do
    opts = opts([])

    refute RateLimit.call(request({198, 51, 100, 1}), opts).halted
    refute RateLimit.call(request({198, 51, 100, 1}), opts).halted

    conn = RateLimit.call(request({198, 51, 100, 1}), opts)
    assert conn.halted
    assert conn.status == 429
    assert [retry_after] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) in 1..60
    assert conn.resp_body =~ "Too many requests"
  end

  test "counts each client separately" do
    opts = opts(limit: 1)

    refute RateLimit.call(request({198, 51, 100, 1}), opts).halted
    assert RateLimit.call(request({198, 51, 100, 1}), opts).halted
    refute RateLimit.call(request({198, 51, 100, 2}), opts).halted
  end

  test "behind the proxy, each forwarded client gets its own budget" do
    opts = opts(limit: 1)

    refute RateLimit.call(request({127, 0, 0, 1}, "203.0.113.1"), opts).halted
    assert RateLimit.call(request({127, 0, 0, 1}, "203.0.113.1"), opts).halted
    refute RateLimit.call(request({127, 0, 0, 1}, "203.0.113.2"), opts).halted
  end

  test "a client cannot dodge its budget by prepending addresses to X-Forwarded-For" do
    opts = opts(limit: 1)

    refute RateLimit.call(request({127, 0, 0, 1}, "203.0.113.1"), opts).halted

    conn = RateLimit.call(request({127, 0, 0, 1}, "192.0.2.77, 203.0.113.1"), opts)
    assert conn.status == 429
  end

  test "the budget comes back in the next window" do
    now = System.system_time(:millisecond)
    bucket = {:test, make_ref()}
    at = fn ms -> opts(bucket: bucket, limit: 1, clock: fn -> ms end) end

    refute RateLimit.call(request({198, 51, 100, 1}), at.(now)).halted
    assert RateLimit.call(request({198, 51, 100, 1}), at.(now)).halted
    refute RateLimit.call(request({198, 51, 100, 1}), at.(now + 60_000)).halted
  end

  test ":global counts every client together" do
    opts = opts(limit: 1, by: :global)

    refute RateLimit.call(request({198, 51, 100, 1}), opts).halted
    assert RateLimit.call(request({198, 51, 100, 2}), opts).halted
  end

  test "answers JSON, with any extra fields, to a JSON request" do
    opts = opts(limit: 0, json: %{packages: []})

    conn =
      {198, 51, 100, 1}
      |> request()
      |> Phoenix.Controller.put_format("json")
      |> RateLimit.call(opts)

    assert conn.status == 429
    assert [_] = get_resp_header(conn, "retry-after")
    assert %{"error" => _, "packages" => []} = Jason.decode!(conn.resp_body)
  end

  test "does nothing when disabled" do
    opts = opts(limit: 0, enabled: false)
    refute RateLimit.call(request({198, 51, 100, 1}), opts).halted
  end

  test "follows the :enabled config when the plug does not say" do
    opts = [bucket: {:test, make_ref()}, limit: 0] |> RateLimit.init()

    # config/test.exs turns the limiter off.
    refute RateLimit.call(request({198, 51, 100, 1}), opts).halted
  end

  test "behind a proxy reaching a dual-stack listener, forwarded clients stay apart" do
    opts = opts(limit: 1)
    mapped_loopback = {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}

    refute RateLimit.call(request(mapped_loopback, "203.0.113.1"), opts).halted
    assert RateLimit.call(request(mapped_loopback, "203.0.113.1"), opts).halted
    refute RateLimit.call(request(mapped_loopback, "203.0.113.2"), opts).halted
  end

  test "two IPv6 addresses in one /64 share a budget; another /64 has its own" do
    opts = opts(limit: 1)

    refute RateLimit.call(request({127, 0, 0, 1}, "2001:db8:0:1::a"), opts).halted
    assert RateLimit.call(request({127, 0, 0, 1}, "2001:db8:0:1:ffff::b"), opts).halted
    refute RateLimit.call(request({127, 0, 0, 1}, "2001:db8:0:2::a"), opts).halted
  end

  test "an IPv6 peer that is not the proxy is counted by its /64 too" do
    opts = opts(limit: 1)

    refute RateLimit.call(request({0x2001, 0xDB8, 0, 1, 0, 0, 0, 1}), opts).halted
    assert RateLimit.call(request({0x2001, 0xDB8, 0, 1, 0, 0, 0, 2}), opts).halted
    refute RateLimit.call(request({0x2001, 0xDB8, 0, 2, 0, 0, 0, 1}), opts).halted
  end

  test "check/2 says whether the request went through" do
    opts = opts(limit: 1)

    assert {:ok, %Plug.Conn{halted: false}} = RateLimit.check(request({198, 51, 100, 1}), opts)

    assert {:halted, %Plug.Conn{status: 429}} =
             RateLimit.check(request({198, 51, 100, 1}), opts)
  end

  defmodule Html do
    def render(conn, message), do: send_resp(conn, conn.status, "page: " <> message)
  end

  test "an :html renderer draws the 429 page, keeping status and retry-after" do
    conn = RateLimit.call(request({198, 51, 100, 1}), opts(limit: 0, html: {Html, :render}))

    assert conn.halted
    assert conn.status == 429
    assert [_] = get_resp_header(conn, "retry-after")
    assert conn.resp_body =~ "page: Too many requests"
  end

  describe "client_ip/1" do
    test "reads an IPv4-mapped loopback peer as the proxy" do
      conn = request({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}, "203.0.113.9")
      assert RateLimit.client_ip(conn) == {203, 0, 113, 9}
    end

    test "reads an IPv4-mapped peer or forwarded entry as plain IPv4" do
      assert RateLimit.client_ip(request({0, 0, 0, 0, 0, 0xFFFF, 0xC633, 0x6407})) ==
               {198, 51, 100, 7}

      assert RateLimit.client_ip(request({127, 0, 0, 1}, "::ffff:203.0.113.9")) ==
               {203, 0, 113, 9}
    end

    test "behind the loopback proxy, uses the last X-Forwarded-For entry" do
      conn = request({127, 0, 0, 1}, "192.0.2.66, 203.0.113.9")
      assert RateLimit.client_ip(conn) == {203, 0, 113, 9}
    end

    test "joins repeated X-Forwarded-For headers before taking the last entry" do
      conn =
        {127, 0, 0, 1}
        |> request("192.0.2.66")
        |> Map.update!(:req_headers, &(&1 ++ [{"x-forwarded-for", "203.0.113.9"}]))

      assert RateLimit.client_ip(conn) == {203, 0, 113, 9}
    end

    test "trusts an IPv6 loopback proxy too" do
      conn = request({0, 0, 0, 0, 0, 0, 0, 1}, "203.0.113.9")
      assert RateLimit.client_ip(conn) == {203, 0, 113, 9}
    end

    test "ignores X-Forwarded-For from a peer that is not the proxy" do
      conn = request({198, 51, 100, 7}, "203.0.113.9")
      assert RateLimit.client_ip(conn) == {198, 51, 100, 7}
    end

    test "falls back to the peer on a missing, empty or unparseable header" do
      assert RateLimit.client_ip(request({127, 0, 0, 1})) == {127, 0, 0, 1}
      assert RateLimit.client_ip(request({127, 0, 0, 1}, "")) == {127, 0, 0, 1}
      assert RateLimit.client_ip(request({127, 0, 0, 1}, "203.0.113.9, ")) == {127, 0, 0, 1}
      assert RateLimit.client_ip(request({127, 0, 0, 1}, "garbage")) == {127, 0, 0, 1}
    end

    test "parses an IPv6 client" do
      conn = request({127, 0, 0, 1}, "2001:db8::1")
      assert RateLimit.client_ip(conn) == {8193, 3512, 0, 0, 0, 0, 0, 1}
    end
  end
end
