defmodule PortalWeb.RateLimitedRoutesTest do
  # Not async: these turn the limiter on through the application env, which
  # every other test reads too.
  use PortalWeb.ConnCase, async: false

  import Portal.Test.AccountsFixtures, only: [user_fixture: 0]

  alias Portal.RateLimiter

  @buckets [:auth, :provider_auth, :scan_request, :hex_search, :hex_search_global]

  setup do
    previous = Application.get_env(:portal, RateLimiter)
    RateLimiter.reset()

    on_exit(fn ->
      Application.put_env(:portal, RateLimiter, previous)
      RateLimiter.reset()
    end)

    :ok
  end

  defp limits(limits),
    do: Application.put_env(:portal, RateLimiter, enabled: true, limits: limits)

  defp from(conn, client), do: put_req_header(conn, "x-forwarded-for", client)

  defp signed_in(conn) do
    conn
    |> init_test_session(%{})
    |> put_session(:user_id, user_fixture().id)
  end

  # With every budget at zero, the first request to a limited route answers
  # 429 before its action runs, so none of them needs a working flow behind it.
  @limited [
    {:post, "/login", :anon},
    {:post, "/register", :anon},
    {:post, "/login/totp", :anon},
    {:post, "/auth/passkey/challenge", :anon_json},
    {:post, "/auth/passkey/verify", :anon_json},
    {:post, "/auth/hex/start", :anon},
    {:post, "/auth/hex/complete", :anon},
    {:post, "/auth/github/start", :anon},
    {:post, "/auth/github/complete", :anon},
    {:post, "/auth/hex/login", :anon},
    {:post, "/auth/github/login/complete", :anon},
    {:post, "/auth/choose-username", :anon},
    {:post, "/requests/anonymous", :anon},
    {:get, "/api/packages/hex", :anon_json},
    {:post, "/settings/security/reauth", :user},
    {:post, "/settings/security/reauth/passkey", :user_json},
    {:post, "/settings/providers/hex/link", :user},
    {:post, "/settings/providers/github/link/complete", :user},
    {:post, "/settings/providers/hex/confirm", :user},
    {:post, "/settings/providers/github/confirm/complete", :user}
  ]

  for {method, path, who} <- @limited do
    test "#{method} #{path} is rate limited", %{conn: conn} do
      limits(Map.new(@buckets, &{&1, {0, 60_000}}))

      conn =
        case unquote(who) do
          :anon -> conn
          :anon_json -> put_req_header(conn, "accept", "application/json")
          :user -> signed_in(conn)
          :user_json -> conn |> signed_in() |> put_req_header("accept", "application/json")
        end

      conn = dispatch(conn, @endpoint, unquote(method), unquote(path), %{})

      assert conn.status == 429
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) in 1..60
    end
  end

  test "pages that cost nothing are not limited", %{conn: conn} do
    limits(Map.new(@buckets, &{&1, {0, 60_000}}))

    for path <- ["/login", "/register", "/request-scan", "/api/packages"] do
      assert dispatch(conn, @endpoint, :get, path, %{}).status == 200
    end
  end

  describe "behind the proxy" do
    test "each forwarded client gets its own budget", %{conn: conn} do
      limits(%{auth: {2, 60_000}})
      params = %{"username" => "nobody", "password" => "wrong password"}

      # `Phoenix.ConnTest` requests come from 127.0.0.1, as Apache's do.
      for _ <- 1..2 do
        assert conn |> from("203.0.113.1") |> post(~p"/login", params) |> Map.fetch!(:status) ==
                 200
      end

      limited = conn |> from("203.0.113.1") |> post(~p"/login", params)
      assert limited.status == 429
      assert [_] = get_resp_header(limited, "retry-after")

      assert conn |> from("203.0.113.2") |> post(~p"/login", params) |> Map.fetch!(:status) ==
               200
    end

    test "a budget is the client's, not one address shared by everyone", %{conn: conn} do
      limits(%{auth: {1, 60_000}})
      params = %{"username" => "nobody", "password" => "wrong password"}

      for client <- ["203.0.113.1", "203.0.113.2", "203.0.113.3"] do
        assert conn |> from(client) |> post(~p"/login", params) |> Map.fetch!(:status) == 200
      end
    end
  end

  test "a limited hex search answers the documented 429", %{conn: conn} do
    limits(%{hex_search: {0, 60_000}, hex_search_global: {100, 60_000}})

    conn = get(conn, ~p"/api/packages/hex?query=a")

    assert %{"packages" => [], "error" => _} = json_response(conn, 429)
    PortalWeb.ApiSpecAssertions.assert_documented_response(conn, "searchHexPackages")
  end

  test "the global hex search budget is shared by every client", %{conn: conn} do
    limits(%{hex_search: {100, 60_000}, hex_search_global: {1, 60_000}})

    assert conn |> from("203.0.113.1") |> get(~p"/api/packages/hex") |> Map.fetch!(:status) ==
             200

    assert conn |> from("203.0.113.2") |> get(~p"/api/packages/hex") |> Map.fetch!(:status) ==
             429
  end
end
