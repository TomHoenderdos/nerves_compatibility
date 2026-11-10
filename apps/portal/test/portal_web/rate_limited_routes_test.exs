defmodule PortalWeb.RateLimitedRoutesTest do
  # Not async: these turn the limiter on through the application env, which
  # every other test reads too.
  use PortalWeb.ConnCase, async: false

  import Portal.Test.AccountsFixtures, only: [user_fixture: 0]

  alias Portal.{HexSearchCache, RateLimiter}

  @buckets [:auth, :provider_auth, :scan_request, :hex_search, :hex_search_global]

  setup do
    previous = Application.get_env(:portal, RateLimiter)
    RateLimiter.reset()
    HexSearchCache.reset()

    on_exit(fn ->
      Application.put_env(:portal, RateLimiter, previous)
      RateLimiter.reset()
      HexSearchCache.reset()
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
    {:get, "/api/packages/hex?query=ab", :anon_json},
    {:post, "/settings", :user},
    {:post, "/settings/password/set", :user},
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

  describe "an HTML form over its budget" do
    for {path, who, expect} <- [
          {"/login", :anon, "Sign in"},
          {"/register", :anon, "Create an account"},
          {"/login/totp", :anon, "Two-factor"},
          {"/requests/anonymous", :anon, "Request scans for packages"},
          {"/auth/hex/start", :anon, "Request scans for packages"},
          {"/settings", :user, "Settings"},
          {"/settings/password/set", :user, "Settings"},
          {"/settings/security/reauth", :user, "Security"}
        ] do
      test "POST #{path} comes back as its page with a flash and a 429", %{conn: conn} do
        limits(Map.new(@buckets, &{&1, {0, 60_000}}))
        conn = if unquote(who) == :user, do: signed_in(conn), else: conn

        conn = post(conn, unquote(path), %{"username" => "someone"})

        body = html_response(conn, 429)
        assert body =~ "Too many requests. Try again in"
        assert body =~ unquote(expect)
        assert [_] = get_resp_header(conn, "retry-after")
      end
    end
  end

  describe "hex search" do
    @jason [
      %{"name" => "jason", "description" => "JSON", "url" => "https://hex.pm/packages/jason"}
    ]

    test "past the client's budget answers the documented 429", %{conn: conn} do
      limits(%{hex_search: {0, 60_000}})

      conn = get(conn, ~p"/api/packages/hex?query=ab")

      assert %{"packages" => [], "error" => _} = json_response(conn, 429)
      PortalWeb.ApiSpecAssertions.assert_documented_response(conn, "searchHexPackages")
    end

    test "a query too short to search counts against nothing", %{conn: conn} do
      limits(%{hex_search: {0, 60_000}, hex_search_global: {0, 60_000}})

      for query <- ["", "a", " b "] do
        conn = get(conn, ~p"/api/packages/hex?#{[query: query]}")
        assert json_response(conn, 200) == %{"packages" => []}
      end
    end

    test "a cached answer is served without touching the global budget", %{conn: conn} do
      limits(%{hex_search: {100, 60_000}, hex_search_global: {0, 60_000}})
      HexSearchCache.put("jason", @jason)

      for client <- ["203.0.113.1", "203.0.113.2", "203.0.113.3"] do
        conn = conn |> from(client) |> get(~p"/api/packages/hex?query=jason")
        assert json_response(conn, 200) == %{"packages" => @jason}
      end
    end

    test "the client's budget comes first and counts cached answers too", %{conn: conn} do
      limits(%{hex_search: {1, 60_000}, hex_search_global: {100, 60_000}})
      HexSearchCache.put("jason", @jason)

      assert conn
             |> from("203.0.113.1")
             |> get(~p"/api/packages/hex?query=jason")
             |> json_response(200)

      assert conn
             |> from("203.0.113.1")
             |> get(~p"/api/packages/hex?query=jason")
             |> json_response(429)
    end

    test "a miss counts against the budget every client shares", %{conn: conn} do
      limits(%{hex_search: {100, 60_000}, hex_search_global: {1, 60_000}})
      # Another client's miss, already counted.
      assert :ok = RateLimiter.hit(:hex_search_global, :global, 1, 60_000)

      conn = conn |> from("203.0.113.2") |> get(~p"/api/packages/hex?query=uncached")

      assert %{"packages" => []} = json_response(conn, 429)
    end
  end
end
