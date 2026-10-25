defmodule NccAgent.Test.FakePortal do
  @moduledoc """
  A fake of the portal's `/builder/v1/*` API: Bandit over HTTPS with the
  test CA's server certificate, asking for (not requiring) a client
  certificate the way `PortalWeb.BuilderEndpoint` does.

  Every request is reported to the test process as
  `{:portal_request, method, path, body_or_params, peer_fingerprint}`
  (the fingerprint is the lowercase hex sha256 of the client certificate's
  DER, `nil` without one) followed by
  `{:portal_agent_version, method, path, header_value}`.

  The `script` map (kept in an `Agent`) shapes the answers:

    * `:enroll_error` - `{status, body}` returned by `POST /enroll`
    * `:claims` - claim maps answered in turn by `POST /jobs/claim` (then 204)
    * `:claim_error` - `{status, body}` returned by `POST /jobs/claim`
    * `:missing` - the list `POST /jobs/:id/files/missing` answers (default: all)
    * `:upload_bad` - names `PUT /jobs/:id/files` reports as bad (422)
    * `:releases` - `%{name => binary}` served by `GET /releases/:name`
      (agent release tarballs for `NccAgent.Updater`)
  """

  @behaviour Plug

  import Plug.Conn

  alias NccAgent.Test.CA

  @doc "Starts the fake under the calling test; returns its URL and pid."
  def start(ca, test_pid, script) do
    {:ok, agent} = Agent.start_link(fn -> script end)

    pid =
      ExUnit.Callbacks.start_supervised!(
        {Bandit,
         plug: {__MODULE__, %{ca: ca, test_pid: test_pid, script: agent}},
         scheme: :https,
         port: 0,
         ip: {127, 0, 0, 1},
         startup_log: false,
         certfile: Path.join(ca.dir, "server.pem"),
         keyfile: Path.join(ca.dir, "server-key.pem"),
         thousand_island_options: [
           transport_options: [
             cacertfile: Path.join(ca.dir, "ca.pem"),
             verify: :verify_peer,
             fail_if_no_peer_cert: false
           ]
         ]}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    %{url: "https://localhost:#{port}", pid: pid, script: agent}
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    conn =
      Plug.Parsers.call(
        conn,
        Plug.Parsers.init(parsers: [:multipart, :json], pass: ["*/*"], json_decoder: Jason)
      )

    route(conn, conn.method, conn.path_info, opts)
  end

  defp route(conn, "GET", ["builder", "v1", "ca.pem"], opts) do
    record(conn, opts, nil)

    conn
    |> put_resp_content_type("application/x-pem-file")
    |> send_resp(200, File.read!(Path.join(opts.ca.dir, "ca.pem")))
  end

  defp route(conn, "POST", ["builder", "v1", "enroll"], opts) do
    record(conn, opts, conn.body_params)

    case script(opts, :enroll_error) do
      {status, body} ->
        json(conn, status, body)

      nil ->
        pem = CA.issue(opts.ca, conn.body_params["csr_pem"], "box")

        json(conn, 201, %{
          certificate_pem: pem,
          builder_id: "7d1f3c56-2a7e-4a8e-9a1b-0c2d3e4f5a6b",
          name: "box",
          expires_at: expires_at(pem)
        })
    end
  end

  defp route(conn, "POST", ["builder", "v1", "renew"], opts) do
    fingerprint = record(conn, opts, conn.body_params)

    if fingerprint do
      pem = CA.issue(opts.ca, conn.body_params["csr_pem"], "box")
      json(conn, 200, %{certificate_pem: pem, expires_at: expires_at(pem)})
    else
      json(conn, 401, %{error: "certificate_required"})
    end
  end

  defp route(conn, "POST", ["builder", "v1", "status"], opts) do
    record(conn, opts, conn.body_params)
    json(conn, 200, %{ok: true})
  end

  defp route(conn, "POST", ["builder", "v1", "jobs", "claim"], opts) do
    record(conn, opts, conn.body_params)

    case script(opts, :claim_error) do
      {status, body} ->
        json(conn, status, body)

      nil ->
        claim =
          Agent.get_and_update(opts.script, fn script ->
            case Map.get(script, :claims, []) do
              [next | rest] -> {next, Map.put(script, :claims, rest)}
              [] -> {nil, script}
            end
          end)

        if claim, do: json(conn, 200, claim), else: send_resp(conn, 204, "")
    end
  end

  defp route(conn, "POST", ["builder", "v1", "jobs", _id, "heartbeat"], opts) do
    record(conn, opts, conn.body_params)
    json(conn, 200, %{ok: true})
  end

  defp route(conn, "POST", ["builder", "v1", "jobs", _id, "files", "missing"], opts) do
    record(conn, opts, conn.body_params)
    missing = script(opts, :missing) || Map.get(conn.body_params, "shas", [])
    json(conn, 200, %{missing: missing})
  end

  defp route(conn, "PUT", ["builder", "v1", "jobs", _id, "files"], opts) do
    {body, conn} = read_all(conn, [])
    {:ok, entries} = :erl_tar.table({:binary, body})
    names = Enum.map(entries, &to_string/1)
    record(conn, opts, %{"names" => names, "content_type" => content_type(conn)})

    case script(opts, :upload_bad) do
      nil ->
        json(conn, 200, %{stored: names, bad: [], bytes: byte_size(body)})

      bad ->
        json(conn, 422, %{error: "bad_entries", bad: bad, stored: names -- bad, bytes: 0})
    end
  end

  defp route(conn, "POST", ["builder", "v1", "jobs", _id, "complete"], opts) do
    params =
      Map.new(conn.body_params, fn
        {k, %Plug.Upload{} = upload} -> {k, {upload.filename, File.read!(upload.path)}}
        {k, v} -> {k, v}
      end)

    record(conn, opts, params)
    json(conn, 202, %{accepted: true, outcome: "done"})
  end

  defp route(conn, "GET", ["releases", name], opts) do
    record(conn, opts, nil)

    case script(opts, :releases) do
      %{^name => body} ->
        conn |> put_resp_content_type("application/gzip") |> send_resp(200, body)

      _ ->
        json(conn, 404, %{error: "not_found"})
    end
  end

  defp route(conn, _method, _path, opts) do
    record(conn, opts, nil)
    json(conn, 404, %{error: "not_found"})
  end

  defp read_all(conn, acc) do
    case read_body(conn) do
      {:ok, chunk, conn} -> {IO.iodata_to_binary(Enum.reverse([chunk | acc])), conn}
      {:more, chunk, conn} -> read_all(conn, [chunk | acc])
    end
  end

  defp content_type(conn), do: conn |> get_req_header("content-type") |> List.first()

  defp record(conn, opts, params) do
    fingerprint =
      case get_peer_data(conn).ssl_cert do
        nil -> nil
        der -> :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)
      end

    version = conn |> get_req_header("x-ncc-agent-version") |> List.first()
    send(opts.test_pid, {:portal_request, conn.method, conn.request_path, params, fingerprint})
    send(opts.test_pid, {:portal_agent_version, conn.method, conn.request_path, version})
    fingerprint
  end

  defp script(opts, key), do: Agent.get(opts.script, &Map.get(&1, key))

  defp expires_at(pem) do
    {:Validity, _from, until} = pem |> X509.Certificate.from_pem!() |> X509.Certificate.validity()
    until |> X509.DateTime.to_datetime() |> DateTime.to_iso8601()
  end

  defp json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end
end
