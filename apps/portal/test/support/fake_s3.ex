defmodule Portal.Test.FakeS3 do
  @moduledoc """
  An in-process S3 stub for the L2 build cache tests: Bandit on an ephemeral
  loopback port plus an Agent holding the objects, the fault and the request
  log. Both are linked to the caller, so ExUnit stops them with the test.

  The stub verifies every request's SigV4 signature with
  `Portal.Test.FakeS3.SigV4`, which shares no code with Req's signer. A client
  that signs wrongly gets a 403, as it would from the real store.

  Faults (`set_fault/2`), one at a time:

    * `{:get, :truncate}` answers a GET with a chunked response carrying the
      first half of the body. Bandit ends a chunked response cleanly when the
      plug returns, so the client sees a *complete* short body, not a broken
      connection. That is what a sha mismatch test needs: a body whose
      `x-amz-meta-sha256` does not match what arrived.
    * `{:get, :status, n}`, `{:put, :status, n}`, `{:list, :status, n}`,
      `{:delete, :status, n}` answer that operation with status `n`.
    * `{:put, :hang}` holds a PUT for 5 s before answering, a store that
      accepted the connection and stopped responding.
    * `{:list, :no_token}` answers the first listing page with one key,
      `IsTruncated` true and no continuation token (a server bug the client
      must not loop on).
  """

  alias Portal.BuildCache.L2.Config

  @bucket "ncc-test"
  @region "garage"
  @access_key "GKTEST"
  @secret_key "secret-test"

  @type s :: %{
          pid: pid(),
          agent: pid(),
          port: :inet.port_number(),
          endpoint: String.t(),
          bucket: String.t(),
          region: String.t(),
          access_key: String.t(),
          secret_key: String.t(),
          config: Config.t()
        }

  @spec start(keyword()) :: {:ok, s()}
  def start(_opts \\ []) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{objects: %{}, fault: nil, on_get: nil, on_list: nil, on_delete: nil, requests: []}
      end)

    plug_opts = %{
      agent: agent,
      bucket: @bucket,
      access_key: @access_key,
      secret_key: @secret_key,
      region: @region
    }

    {:ok, pid} =
      Bandit.start_link(
        plug: {Portal.Test.FakeS3.Plug, plug_opts},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    endpoint = "http://127.0.0.1:#{port}"

    {:ok,
     %{
       pid: pid,
       agent: agent,
       port: port,
       endpoint: endpoint,
       bucket: @bucket,
       region: @region,
       access_key: @access_key,
       secret_key: @secret_key,
       config: %Config{
         endpoint: endpoint,
         bucket: @bucket,
         region: @region,
         access_key: @access_key,
         secret_key: @secret_key,
         read_only?: false
       }
     }}
  end

  @doc """
  Stores an object directly. `meta` maps full `x-amz-meta-*` header names to
  values; `opts[:last_modified]` (a `DateTime`) dates it, default now.
  """
  def put_object(%{agent: agent}, key, body, meta \\ %{}, opts \\ []) do
    object = new_object(body, meta)
    object = %{object | last_modified: Keyword.get(opts, :last_modified, object.last_modified)}
    Agent.update(agent, &put_in(&1, [:objects, key], object))
  end

  @doc false
  def new_object(body, meta),
    do: %{body: body, meta: meta, last_modified: DateTime.utc_now()}

  def get_object(%{agent: agent}, key) do
    case Agent.get(agent, &Map.fetch(&1.objects, key)) do
      {:ok, %{body: body, meta: meta}} -> {:ok, %{body: body, meta: meta}}
      :error -> :error
    end
  end

  def objects(%{agent: agent}), do: agent |> Agent.get(&Map.keys(&1.objects)) |> Enum.sort()

  def delete_object(%{agent: agent}, key),
    do: Agent.update(agent, &update_in(&1.objects, fn o -> Map.delete(o, key) end))

  def set_fault(%{agent: agent}, fault), do: Agent.update(agent, &%{&1 | fault: fault})

  @doc "`fun.(key)` runs before each GET is answered; nil clears it."
  def on_get(%{agent: agent}, fun), do: Agent.update(agent, &%{&1 | on_get: fun})

  @doc "`fun.(prefix)` runs before each listing page is answered; nil clears it."
  def on_list(%{agent: agent}, fun), do: Agent.update(agent, &%{&1 | on_list: fun})

  @doc "`fun.(key)` runs before each DELETE is answered; nil clears it."
  def on_delete(%{agent: agent}, fun), do: Agent.update(agent, &%{&1 | on_delete: fun})

  @doc "Every request the stub saw, oldest first, listing GETs included."
  def requests(%{agent: agent}), do: agent |> Agent.get(& &1.requests) |> Enum.reverse()
end

defmodule Portal.Test.FakeS3.Plug do
  @moduledoc "The request handler behind `Portal.Test.FakeS3`."

  @behaviour Plug

  import Plug.Conn

  alias Portal.Test.FakeS3
  alias Portal.Test.FakeS3.SigV4

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, %{agent: agent} = opts) do
    conn = assign(conn, :body, read_all(conn))

    Agent.update(agent, fn st ->
      %{st | requests: [{conn.method, conn.request_path, conn.query_string} | st.requests]}
    end)

    case SigV4.verify(conn, opts.access_key, opts.secret_key, opts.region) do
      :ok -> route(conn, opts)
      {:error, _} -> error(conn, 403, "SignatureDoesNotMatch")
    end
  end

  # The x-amz-content-sha256 header must match the body, so the whole body is
  # read before verifying.
  defp read_all(conn) do
    {:ok, body, _conn} = read_all(conn, [])
    body
  end

  defp read_all(conn, acc) do
    case read_body(conn, length: 1_000_000_000) do
      {:ok, chunk, conn} -> {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc])), conn}
      {:more, chunk, conn} -> read_all(conn, [chunk | acc])
    end
  end

  defp route(%{path_info: [bucket]} = conn, %{bucket: bucket} = opts) do
    q = conn.query_string |> URI.decode_query()

    if conn.method == "GET" and q["list-type"] == "2",
      do: list(conn, opts, q),
      else: error(conn, 400, "InvalidRequest")
  end

  defp route(%{path_info: [bucket | key_parts]} = conn, %{bucket: bucket} = opts),
    do: object(conn, opts, conn.method, Enum.join(key_parts, "/"))

  defp route(conn, _opts), do: error(conn, 400, "InvalidRequest")

  defp object(conn, %{agent: agent}, "PUT", key) do
    case fault(agent) do
      {:put, :status, n} ->
        error(conn, n, "InternalError")

      {:put, :hang} ->
        Process.sleep(5_000)
        error(conn, 503, "SlowDown")

      _ ->
        body = conn.assigns.body
        meta = for {"x-amz-meta-" <> _ = name, v} <- conn.req_headers, into: %{}, do: {name, v}
        Agent.update(agent, &put_in(&1, [:objects, key], FakeS3.new_object(body, meta)))
        etag = Base.encode16(:crypto.hash(:md5, body), case: :lower)

        conn |> put_resp_header("etag", ~s("#{etag}")) |> send_resp(200, "")
    end
  end

  defp object(conn, %{agent: agent}, "HEAD", key) do
    case Agent.get(agent, &Map.get(&1.objects, key)) do
      nil ->
        send_resp(conn, 404, "")

      %{body: body, meta: meta} ->
        conn
        |> put_meta(meta)
        |> put_resp_header("content-length", Integer.to_string(byte_size(body)))
        |> send_resp(200, "")
    end
  end

  defp object(conn, %{agent: agent}, "GET", key) do
    if fun = Agent.get(agent, & &1.on_get), do: fun.(key)

    case {fault(agent), Agent.get(agent, &Map.get(&1.objects, key))} do
      {{:get, :status, n}, _} ->
        error(conn, n, "InternalError")

      {_, nil} ->
        error(conn, 404, "NoSuchKey")

      {{:get, :truncate}, %{body: body, meta: meta}} ->
        conn = conn |> put_meta(meta) |> send_chunked(200)
        {:ok, conn} = chunk(conn, binary_part(body, 0, div(byte_size(body), 2)))
        conn

      {_, %{body: body, meta: meta}} ->
        conn
        |> put_meta(meta)
        |> put_resp_content_type("application/gzip", nil)
        |> send_resp(200, body)
    end
  end

  # As S3 does, a DELETE of an absent key answers 204 too.
  defp object(conn, %{agent: agent}, "DELETE", key) do
    if fun = Agent.get(agent, & &1.on_delete), do: fun.(key)

    case fault(agent) do
      {:delete, :status, n} ->
        error(conn, n, "InternalError")

      _ ->
        Agent.update(agent, &update_in(&1.objects, fn o -> Map.delete(o, key) end))
        send_resp(conn, 204, "")
    end
  end

  defp object(conn, _opts, _method, _key), do: error(conn, 400, "InvalidRequest")

  defp list(conn, %{agent: agent}, q) do
    if fun = Agent.get(agent, & &1.on_list), do: fun.(q["prefix"])

    case fault(agent) do
      {:list, :status, n} -> error(conn, n, "InternalError")
      fault -> list_page(conn, agent, q, fault)
    end
  end

  defp list_page(conn, agent, q, fault) do
    prefix = q["prefix"] || ""
    after_key = q["continuation-token"]
    no_token? = fault == {:list, :no_token} and after_key == nil
    max = if no_token?, do: 1, else: String.to_integer(q["max-keys"] || "1000")

    entries =
      agent
      |> Agent.get(& &1.objects)
      |> Enum.filter(fn {k, _} ->
        String.starts_with?(k, prefix) and (after_key == nil or k > after_key)
      end)
      |> Enum.sort()

    {page, rest} = Enum.split(entries, max)
    truncated? = rest != []

    token =
      if truncated? and not no_token?,
        do: "<NextContinuationToken>#{elem(List.last(page), 0)}</NextContinuationToken>",
        else: ""

    contents =
      Enum.map_join(page, fn {k, o} ->
        "<Contents><Key>#{k}</Key><LastModified>#{DateTime.to_iso8601(o.last_modified)}</LastModified>" <>
          "<Size>#{byte_size(o.body)}</Size></Contents>"
      end)

    xml =
      ~s(<?xml version="1.0" encoding="UTF-8"?><ListBucketResult>) <>
        "<Name>#{conn.path_info |> hd()}</Name><Prefix>#{prefix}</Prefix>" <>
        "<KeyCount>#{length(page)}</KeyCount><MaxKeys>#{max}</MaxKeys>" <>
        "<IsTruncated>#{truncated?}</IsTruncated>#{contents}#{token}</ListBucketResult>"

    conn |> put_resp_content_type("application/xml") |> send_resp(200, xml)
  end

  defp fault(agent), do: Agent.get(agent, & &1.fault)

  defp put_meta(conn, meta),
    do: Enum.reduce(meta, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)

  defp error(conn, status, code) do
    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(status, "<Error><Code>#{code}</Code></Error>")
    |> halt()
  end
end

defmodule Portal.Test.FakeS3.SigV4 do
  @moduledoc """
  An independent AWS Signature Version 4 verifier for the stub; see the spec,
  section 3.3. It builds the canonical request itself from the incoming
  connection and never calls Req's signing code, so a client that signs
  wrongly cannot be waved through by the same bug on both sides.
  """

  def signature(%{
        method: method,
        path: path,
        query: query,
        headers: headers,
        payload_hash: payload_hash,
        amz_date: amz_date,
        region: region,
        service: service,
        secret_key: secret
      }) do
    headers =
      headers |> Enum.map(fn {k, v} -> {String.downcase(k), String.trim(v)} end) |> Enum.sort()

    signed = Enum.map_join(headers, ";", &elem(&1, 0))
    canonical_headers = Enum.map_join(headers, "", fn {k, v} -> k <> ":" <> v <> "\n" end)

    canonical_query =
      query
      |> Enum.map(fn {k, v} -> {encode(k), encode(v)} end)
      |> Enum.sort()
      |> Enum.map_join("&", fn {k, v} -> k <> "=" <> v end)

    canonical =
      Enum.join(
        [method, path, canonical_query, canonical_headers, signed, payload_hash],
        "\n"
      )

    date = binary_part(amz_date, 0, 8)
    scope = Enum.join([date, region, service, "aws4_request"], "/")

    string_to_sign =
      Enum.join(
        ["AWS4-HMAC-SHA256", amz_date, scope, hex(:crypto.hash(:sha256, canonical))],
        "\n"
      )

    ("AWS4" <> secret)
    |> hmac(date)
    |> hmac(region)
    |> hmac(service)
    |> hmac("aws4_request")
    |> hmac(string_to_sign)
    |> hex()
  end

  @doc "Checks the Authorization header of `conn` against the request it carries."
  def verify(conn, access_key, secret_key, region) do
    with [auth] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, parts} <- parse_auth(auth),
         true <- parts.access_key == access_key || {:error, "unknown access key"},
         [amz_date] <- Plug.Conn.get_req_header(conn, "x-amz-date"),
         [payload_hash] <- Plug.Conn.get_req_header(conn, "x-amz-content-sha256"),
         :ok <- check_payload(conn, payload_hash) do
      headers =
        for name <- parts.signed_headers,
            do: {name, conn |> Plug.Conn.get_req_header(name) |> Enum.join(",")}

      expected =
        signature(%{
          method: conn.method,
          path: conn.request_path,
          query: conn.query_string |> URI.query_decoder() |> Enum.to_list(),
          headers: headers,
          payload_hash: payload_hash,
          amz_date: amz_date,
          region: region,
          service: "s3",
          secret_key: secret_key
        })

      if Plug.Crypto.secure_compare(expected, parts.signature),
        do: :ok,
        else: {:error, "signature mismatch"}
    else
      [] -> {:error, "missing authorization header"}
      {:error, _} = error -> error
      other -> {:error, "bad authorization: #{inspect(other)}"}
    end
  end

  # The body was read into conn.assigns[:body] by the stub's plug before verifying.
  defp check_payload(_conn, "UNSIGNED-PAYLOAD"), do: :ok

  defp check_payload(conn, hash) do
    body = conn.assigns[:body] || ""
    if hex(:crypto.hash(:sha256, body)) == hash, do: :ok, else: {:error, "payload hash mismatch"}
  end

  defp parse_auth("AWS4-HMAC-SHA256 " <> rest) do
    fields =
      rest
      |> String.split(",")
      |> Enum.map(&(&1 |> String.trim() |> String.split("=", parts: 2)))
      |> Map.new(fn
        [k, v] -> {k, v}
        [k] -> {k, nil}
      end)

    with credential when is_binary(credential) <- fields["Credential"],
         [access_key | _] <- String.split(credential, "/"),
         signed when is_binary(signed) <- fields["SignedHeaders"],
         sig when is_binary(sig) <- fields["Signature"] do
      {:ok, %{access_key: access_key, signed_headers: String.split(signed, ";"), signature: sig}}
    else
      _ -> {:error, "unparseable authorization"}
    end
  end

  defp parse_auth(_), do: {:error, "not sigv4"}

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hex(bin), do: Base.encode16(bin, case: :lower)
  defp encode(s), do: URI.encode(s, &URI.char_unreserved?/1)
end
