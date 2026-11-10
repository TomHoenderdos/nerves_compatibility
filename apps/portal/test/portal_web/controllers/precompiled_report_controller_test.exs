defmodule PortalWeb.PrecompiledReportControllerTest do
  # Not async: the rate limit tests turn the limiter on in the application env.
  use PortalWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Portal.Test.ReportFixtures
  import PortalWeb.ApiSpecAssertions, only: [assert_documented_response: 2]

  alias Portal.{RateLimiter, Repo}

  @path "/api/precompiled/reports"

  setup do
    previous = Application.get_env(:portal, RateLimiter)
    RateLimiter.reset()

    on_exit(fn ->
      Application.put_env(:portal, RateLimiter, previous)
      RateLimiter.reset()
    end)

    :ok
  end

  defp send_report(conn, body, client \\ "203.0.113.10") do
    conn
    |> put_req_header("x-forwarded-for", client)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> post(@path, Jason.encode!(body))
  end

  defp rows(table),
    do: Repo.query!("SELECT row_to_json(t)::text FROM #{table} t").rows |> List.flatten()

  test "a report is stored and answered with its id", %{conn: conn} do
    conn = send_report(conn, body())
    assert %{"id" => id} = json_response(conn, 201)
    assert {:ok, _} = Ecto.UUID.cast(id)
    assert_documented_response(conn, "sendPrecompiledReport")
  end

  test "a duplicate is answered 200 without the first report's id", %{conn: conn} do
    %{"id" => id} = conn |> send_report(body()) |> json_response(201)

    again = build_conn() |> send_report(body(), "203.0.113.11")
    assert json_response(again, 200) == %{"duplicate" => true}
    refute again.resp_body =~ id
    assert_documented_response(again, "sendPrecompiledReport")

    assert [1] = Repo.query!("SELECT count(*) FROM precompiled_reports").rows |> List.flatten()
  end

  test "a body over 256 KiB is refused with 413 before it is parsed", %{conn: conn} do
    big = Jason.encode!(%{"pad" => String.duplicate("x", 262_144)})
    assert byte_size(big) > 262_144

    assert_error_sent 413, fn ->
      conn
      |> put_req_header("content-type", "application/json")
      |> post(@path, big)
    end
  end

  test "a body of exactly 256 KiB is parsed (and refused for its content)", %{conn: conn} do
    pad = 262_144 - byte_size(Jason.encode!(%{"pad" => ""}))
    exact = Jason.encode!(%{"pad" => String.duplicate("x", pad)})
    assert byte_size(exact) == 262_144

    conn = conn |> put_req_header("content-type", "application/json") |> post(@path, exact)
    assert json_response(conn, 422)["details"] |> Enum.join() =~ "pad: unknown field"
  end

  test "only application/json is accepted", %{conn: conn} do
    conn = conn |> put_req_header("content-type", "text/plain") |> post(@path, "{}")
    assert conn.status == 415
    assert_documented_response(conn, "sendPrecompiledReport")

    for type <- ["application/jsonx", "application/json-seq", "text/json"] do
      conn = build_conn() |> put_req_header("content-type", type) |> post(@path, "{}")
      assert conn.status == 415, type
    end

    # `Phoenix.ConnTest` will not send a body without a content type, so the
    # body plug is called directly for that case.
    opts = PortalWeb.Plugs.ReportBody.init([])

    conn =
      Plug.Test.conn(:post, @path, Jason.encode!(body()))
      |> PortalWeb.Plugs.ReportBody.call(opts)

    assert conn.halted
    assert conn.status == 415

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json; charset=utf-8")
      |> post(@path, Jason.encode!(body()))

    assert conn.status == 201
  end

  test "invalid reports get 422 with the reasons", %{conn: conn} do
    for bad <- [
          put_in(body(), ["os", "family"], "darwin"),
          put_in(body(), ["os", "kernel"], "x"),
          %{body() | "system" => "Nerves-RPi4"},
          %{body() | "format" => 99}
        ] do
      conn = build_conn() |> send_report(bad)
      response = json_response(conn, 422)
      assert response["error"] == "invalid report"
      assert [_ | _] = response["details"]
      assert_documented_response(conn, "sendPrecompiledReport")
    end

    assert conn |> send_report(["not", "an", "object"]) |> json_response(422)
    assert build_conn() |> send_report("string") |> json_response(422)
  end

  test "null optional fields are accepted", %{conn: conn} do
    body = Map.merge(body(), %{"contact" => nil, "system" => nil, "system_version" => nil})
    assert conn |> send_report(body) |> json_response(201)
  end

  test "a client over 10 an hour gets 429 with retry-after", %{conn: conn} do
    Application.put_env(:portal, RateLimiter,
      enabled: true,
      limits: %{precompiled_report: {1, 3_600_000}}
    )

    assert conn |> send_report(body()) |> json_response(201)
    conn = build_conn() |> send_report(%{body() | "target" => "rpi5"})
    assert conn.status == 429
    assert [_] = get_resp_header(conn, "retry-after")
    assert_documented_response(conn, "sendPrecompiledReport")

    # Another client still gets through.
    assert build_conn()
           |> send_report(%{body() | "target" => "rpi5"}, "203.0.113.99")
           |> json_response(201)
  end

  test "the default limits are 10 per client an hour, 300 an hour and 2000 a day in all" do
    assert RateLimiter.default_limits()[:precompiled_report] == {10, :timer.hours(1)}
    assert RateLimiter.default_limits()[:precompiled_report_global] == {300, :timer.hours(1)}

    assert RateLimiter.default_limits()[:precompiled_report_global_day] ==
             {2000, :timer.hours(24)}
  end

  test "a DELETE counts against the same client budget as a POST", %{conn: conn} do
    Application.put_env(:portal, RateLimiter,
      enabled: true,
      limits: %{precompiled_report: {1, 3_600_000}}
    )

    %{"id" => id} = conn |> send_report(body()) |> json_response(201)

    conn =
      build_conn()
      |> put_req_header("x-forwarded-for", "203.0.113.10")
      |> put_req_header("accept", "application/json")
      |> delete("#{@path}/#{id}")

    assert conn.status == 429
    assert [1] = Repo.query!("SELECT count(*) FROM precompiled_reports").rows |> List.flatten()
  end

  test "the hourly and daily global caps give 429 across clients", %{conn: conn} do
    for bucket <- [:precompiled_report_global, :precompiled_report_global_day] do
      RateLimiter.reset()

      Application.put_env(:portal, RateLimiter,
        enabled: true,
        limits: %{bucket => {1, 3_600_000}}
      )

      assert build_conn()
             |> send_report(%{body() | "target" => "t#{bucket}a"}, "198.51.100.1")
             |> json_response(201)

      assert build_conn()
             |> send_report(%{body() | "target" => "t#{bucket}b"}, "198.51.100.2")
             |> Map.fetch!(:status) == 429
    end

    _ = conn
  end

  test "junk does not use up the global budget; accepted reports do", %{conn: conn} do
    Application.put_env(:portal, RateLimiter,
      enabled: true,
      limits: %{
        precompiled_report_global: {1, 3_600_000},
        precompiled_report_global_day: {1, 3_600_000}
      }
    )

    big = Jason.encode!(%{"pad" => String.duplicate("x", 262_144)})

    junk = [
      fn c -> c |> put_req_header("content-type", "text/plain") |> post(@path, "{}") end,
      fn c -> send_report(c, %{body() | "format" => 99}) end,
      fn c -> c |> put_req_header("content-type", "application/json") |> post(@path, "{") end,
      fn c -> c |> put_req_header("content-type", "application/json") |> post(@path, big) end
    ]

    for {send, n} <- Enum.with_index(junk) do
      c = build_conn() |> put_req_header("x-forwarded-for", "2001:db8:#{n}::1")

      try do
        assert send.(c).status in [400, 413, 415, 422]
      rescue
        e in [Plug.Parsers.ParseError, Plug.Parsers.RequestTooLargeError] -> e
      end
    end

    assert conn |> send_report(body(), "198.51.100.1") |> json_response(201)
    # The new report spent the budget.
    assert build_conn()
           |> send_report(%{body() | "target" => "other"}, "198.51.100.2")
           |> Map.fetch!(:status) == 429
  end

  test "a duplicate does not spend the global budget; only a new report does", %{conn: conn} do
    Application.put_env(:portal, RateLimiter,
      enabled: true,
      limits: %{
        precompiled_report_global: {2, 3_600_000},
        precompiled_report_global_day: {2, 3_600_000}
      }
    )

    assert conn |> send_report(body(), "198.51.100.1") |> json_response(201)

    for client <- ["198.51.100.2", "198.51.100.3", "198.51.100.4"] do
      assert build_conn() |> send_report(body(), client) |> json_response(200)
    end

    assert build_conn()
           |> send_report(%{body() | "target" => "second"}, "198.51.100.5")
           |> json_response(201)

    assert build_conn()
           |> send_report(%{body() | "target" => "third"}, "198.51.100.6")
           |> Map.fetch!(:status) == 429
  end

  test "a spent global cap does not block a DELETE", %{conn: conn} do
    Application.put_env(:portal, RateLimiter,
      enabled: true,
      limits: %{
        precompiled_report_global: {1, 3_600_000},
        precompiled_report_global_day: {1, 3_600_000}
      }
    )

    %{"id" => id} = conn |> send_report(body(), "198.51.100.1") |> json_response(201)

    assert build_conn()
           |> send_report(%{body() | "target" => "other"}, "198.51.100.2")
           |> Map.fetch!(:status) == 429

    deleted =
      build_conn()
      |> put_req_header("x-forwarded-for", "198.51.100.1")
      |> put_req_header("accept", "application/json")
      |> delete("#{@path}/#{id}")

    assert deleted.status == 204
    assert [0] = Repo.query!("SELECT count(*) FROM precompiled_reports").rows |> List.flatten()
  end

  test "malformed JSON is a documented 400", %{conn: conn} do
    assert_error_sent 400, fn ->
      conn |> put_req_header("content-type", "application/json") |> post(@path, "{")
    end

    responses = PortalWeb.ApiSpecAssertions.api_spec().paths[@path].post.responses
    assert Map.has_key?(responses, 400)
    assert Map.has_key?(responses, 413)
  end

  test "a charset other than utf-8 is refused with 415", %{conn: conn} do
    for type <- ["application/json; charset=latin1", "application/json; charset=utf-16"] do
      c = build_conn() |> put_req_header("content-type", type) |> post(@path, "{}")
      assert c.status == 415, type
    end

    c =
      conn
      |> put_req_header("content-type", "application/json; charset=UTF-8")
      |> post(@path, Jason.encode!(body()))

    assert c.status == 201
  end

  test "a percent-encoded report path is not parsed by the endpoint", %{conn: conn} do
    big = Jason.encode!(%{"pad" => String.duplicate("x", 262_144)})

    assert_error_sent 413, fn ->
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/precompiled/%72eports", big)
    end

    opts = PortalWeb.Plugs.BodyParsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason)

    for path <- [
          "/api/precompiled/%72eports",
          "/api/%70recompiled/reports/x",
          "/%61pi/precompiled/reports"
        ] do
      skipped =
        Plug.Test.conn(:post, path, ~s({"a":1}))
        |> put_req_header("content-type", "application/json")
        |> PortalWeb.Plugs.BodyParsers.call(opts)

      assert %Plug.Conn.Unfetched{} = skipped.body_params, path
    end
  end

  test "a body something else already parsed is refused" do
    conn =
      Plug.Test.conn(:post, @path, "")
      |> put_req_header("content-type", "application/json")
      |> Map.put(:body_params, %{"a" => 1})
      |> PortalWeb.Plugs.ReportBody.call(PortalWeb.Plugs.ReportBody.init([]))

    assert conn.halted
    assert conn.status == 413
  end

  test "a request over a limit is refused before its body is read", %{conn: conn} do
    Application.put_env(:portal, RateLimiter,
      enabled: true,
      limits: %{precompiled_report: {0, 3_600_000}}
    )

    big = Jason.encode!(%{"pad" => String.duplicate("x", 262_144)})

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> post(@path, big)

    assert conn.status == 429
  end

  # At the production log level (`:info`, apps/portal/config/prod.exs). Ecto
  # logs query parameters at `:debug`, which production never enables. The
  # suite runs at `:warning`, and a process level can only lower what the
  # primary level lets through, so the primary level is raised for the test.
  test "neither the client address nor the contact is stored or logged", %{conn: conn} do
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: :warning) end)

    log =
      capture_log([level: :info], fn ->
        conn
        |> send_report(Map.put(body(), "contact", "@tester-handle"), "203.0.113.77")
        |> json_response(201)
      end)

    # The capture works: the request line itself is logged.
    assert log =~ "POST /api/precompiled/reports"
    refute log =~ "203.0.113.77"
    refute log =~ "@tester-handle"

    for row <- rows("precompiled_reports") ++ rows("precompiled_report_lines") do
      refute row =~ "203.0.113"
    end
  end

  test "DELETE removes a report and its lines; an unknown id is 404", %{conn: conn} do
    %{"id" => id} = conn |> send_report(body()) |> json_response(201)

    deleted = build_conn() |> delete("#{@path}/#{id}")
    assert response(deleted, 204)
    assert_documented_response(deleted, "retractPrecompiledReport")
    assert rows("precompiled_reports") == []
    assert rows("precompiled_report_lines") == []

    gone = build_conn() |> delete("#{@path}/#{id}")
    assert json_response(gone, 404)
    assert_documented_response(gone, "retractPrecompiledReport")
    assert build_conn() |> delete("#{@path}/not-a-uuid") |> json_response(404)
  end

  test "the endpoint parser skips only the report routes" do
    opts = PortalWeb.Plugs.BodyParsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason)

    parsed =
      Plug.Test.conn(:post, "/api/other", ~s({"a":1}))
      |> put_req_header("content-type", "application/json")
      |> PortalWeb.Plugs.BodyParsers.call(opts)

    assert parsed.body_params == %{"a" => 1}

    for path <- [@path, "#{@path}/x"] do
      skipped =
        Plug.Test.conn(:post, path, ~s({"a":1}))
        |> put_req_header("content-type", "application/json")
        |> PortalWeb.Plugs.BodyParsers.call(opts)

      assert %Plug.Conn.Unfetched{} = skipped.body_params
    end

    # A sibling path is not one of them.
    near =
      Plug.Test.conn(:post, "/api/precompiled/reportsx", ~s({"a":1}))
      |> put_req_header("content-type", "application/json")
      |> PortalWeb.Plugs.BodyParsers.call(opts)

    assert near.body_params == %{"a" => 1}
  end

  test "segments are decoded once, as the router decodes them", %{conn: conn} do
    opts = PortalWeb.Plugs.BodyParsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason)

    # An encoded slash stays inside its segment, a double encoding decodes
    # to "%72eports" and a NUL makes a different name: none is a report
    # route, so the endpoint parser reads them as usual and the router
    # finds no route.
    for path <- [
          "/api/precompiled%2Freports",
          "/api/precompiled/%2572eports",
          "/api/precompiled/reports%00"
        ] do
      parsed =
        Plug.Test.conn(:post, path, ~s({"a":1}))
        |> put_req_header("content-type", "application/json")
        |> PortalWeb.Plugs.BodyParsers.call(opts)

      assert parsed.body_params == %{"a" => 1}, path

      sent =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(path, ~s({"a":1}))

      assert sent.status == 404, path
    end
  end
end
