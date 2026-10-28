defmodule Portal.BuildCache.L2.Client do
  @moduledoc """
  The few S3 calls the L2 build cache needs, over `Req` with its own SigV4
  step, against a path-style endpoint (`<endpoint>/<bucket>/<object>`,
  which Garage serves). No retries and no redirects: every caller bounds
  its own time and would rather fail fast. Errors come back as terms for
  the caller to log; nothing here logs.
  """

  alias Portal.BuildCache.L2.Config

  @connect_timeout 10_000
  # A send that blocks this long (a store that stopped reading) fails and
  # closes the socket rather than holding the caller.
  @send_timeout 30_000
  @default_timeout_ms 120_000
  @max_pages 50

  @spec head(Config.t(), String.t()) ::
          {:ok, %{size: non_neg_integer() | nil, sha256: String.t() | nil}} | {:error, term()}
  def head(cfg, object) do
    case once_more_if_closed(fn ->
           Req.head(req(cfg, receive_timeout: 30_000), url: object_url(cfg, object))
         end) do
      {:ok, %Req.Response{status: 200} = resp} ->
        {:ok,
         %{size: int_header(resp, "content-length"), sha256: header(resp, "x-amz-meta-sha256")}}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Streams the object into `path`, hashing it; the file is gone on every error."
  @spec get(Config.t(), String.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(cfg, object, path, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case bounded(fn -> do_get(cfg, object, path, Keyword.get(opts, :max_bytes)) end, timeout) do
      {:error, :timeout} = error -> remove(path, error)
      {:error, {:exit, _}} = error -> remove(path, error)
      result -> result
    end
  end

  # The request runs in a task killed at `timeout`: Req's receive timeout
  # measures inactivity, not total time, and nothing at all bounds a send.
  # Whatever the task raises, throws or exits with comes back as an error.
  defp bounded(fun, timeout) do
    task =
      Task.async(fn ->
        try do
          fun.()
        catch
          kind, reason -> {:error, caught(kind, reason)}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> {:error, :timeout}
    end
  end

  @doc false
  # A caught `kind, reason` as an error term: `{:exception, message}` for a
  # raise, `{:exit, reason}` and `{:throw, value}` otherwise.
  @spec caught(:error | :exit | :throw, term()) :: term()
  def caught(:error, reason),
    do: {:exception, Exception.message(Exception.normalize(:error, reason, []))}

  def caught(kind, reason), do: {kind, reason}

  # `path` is a host-built staging name under the slug.
  # sobelow_skip ["Traversal.FileModule"]
  defp do_get(cfg, object, path, max_bytes) do
    with {:ok, io} <- File.open(path, [:write, :binary, :raw]) do
      try do
        # A stale connection fails before any byte reaches the collector,
        # so the file is still empty when the request is sent again.
        result =
          once_more_if_closed(fn ->
            Req.get(req(cfg, receive_timeout: 60_000, into: collector(io, max_bytes)),
              url: object_url(cfg, object)
            )
          end)

        finish_get(result, path)
      catch
        kind, reason -> remove(path, {:error, caught(kind, reason)})
      after
        File.close(io)
      end
    end
  end

  defp collector(io, max_bytes) do
    fn {:data, chunk}, {req, resp} ->
      acc =
        Req.Response.get_private(resp, :l2, %{
          bytes: 0,
          hash: :crypto.hash_init(:sha256),
          too_large: false
        })

      bytes = acc.bytes + byte_size(chunk)

      cond do
        resp.status != 200 ->
          {:cont, {req, resp}}

        max_bytes && bytes > max_bytes ->
          {:halt,
           {req, Req.Response.put_private(resp, :l2, %{acc | bytes: bytes, too_large: true})}}

        true ->
          :ok = IO.binwrite(io, chunk)
          acc = %{acc | bytes: bytes, hash: :crypto.hash_update(acc.hash, chunk)}
          {:cont, {req, Req.Response.put_private(resp, :l2, acc)}}
      end
    end
  end

  defp finish_get({:ok, %Req.Response{status: 200} = resp}, path) do
    case Req.Response.get_private(resp, :l2) do
      %{too_large: true} ->
        remove(path, {:error, :too_large})

      %{bytes: bytes, hash: hash} ->
        {:ok,
         %{
           bytes: bytes,
           sha256_computed: Base.encode16(:crypto.hash_final(hash), case: :lower),
           sha256_header: header(resp, "x-amz-meta-sha256")
         }}

      nil ->
        # An empty 200 body never reached the collector.
        remove(path, {:error, :empty})
    end
  end

  defp finish_get({:ok, %Req.Response{status: 404}}, path), do: remove(path, {:error, :not_found})

  defp finish_get({:ok, %Req.Response{status: status}}, path),
    do: remove(path, {:error, {:status, status}})

  defp finish_get({:error, reason}, path), do: remove(path, {:error, reason})

  # `path` is the staging name `get/4` was given.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove(path, result) do
    # Only a regular file: never a device, directory or symlink the caller named.
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> _ = File.rm(path)
      _ -> :ok
    end

    result
  end

  @doc """
  Uploads `path` with its SHA-256 in `x-amz-meta-sha256`. Bounded in total
  time by `opts[:timeout_ms]` (default 120 s), send phase included:
  `{:error, :timeout}` past it.
  """
  @spec put(Config.t(), String.t(), Path.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def put(cfg, object, path, sha256, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    bounded(fn -> do_put(cfg, object, path, sha256, timeout) end, timeout)
  end

  # `path` is the tarball `Portal.BuildCache.L2.Tarball.pack/3` just wrote.
  # sobelow_skip ["Traversal.FileModule"]
  defp do_put(cfg, object, path, sha256, timeout) do
    with {:ok, body} <- File.read(path) do
      fn -> send_put(cfg, object, body, sha256, timeout) end
      |> once_more_if_closed()
      |> put_result()
    end
  end

  defp send_put(cfg, object, body, sha256, timeout) do
    Req.put(req(cfg, receive_timeout: timeout),
      url: object_url(cfg, object),
      body: body,
      headers: [{"content-type", "application/gzip"}, {"x-amz-meta-sha256", sha256}]
    )
  end

  defp put_result({:ok, %Req.Response{status: status}}) when status in 200..299, do: :ok
  defp put_result({:ok, %Req.Response{status: status}}), do: {:error, {:status, status}}
  defp put_result({:error, reason}), do: {:error, reason}

  @doc """
  Deletes `object`: `:ok` on any 2xx and on a 404 (already gone), `{:error,
  reason}` otherwise. Bounded in total time by `opts[:timeout_ms]` (default
  30 s): `{:error, :timeout}` past it.
  """
  @spec delete(Config.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete(cfg, object, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 30_000)

    bounded(
      fn ->
        fn -> Req.delete(req(cfg, receive_timeout: timeout), url: object_url(cfg, object)) end
        |> once_more_if_closed()
        |> delete_result()
      end,
      timeout
    )
  end

  defp delete_result({:ok, %Req.Response{status: status}}) when status in 200..299, do: :ok
  defp delete_result({:ok, %Req.Response{status: 404}}), do: :ok
  defp delete_result({:ok, %Req.Response{status: status}}), do: {:error, {:status, status}}
  defp delete_result({:error, reason}), do: {:error, reason}

  @doc """
  Lists the objects under `prefix`, `opts[:max_keys]` (1000) per page and at
  most `opts[:max_pages]` (#{@max_pages}) pages; past that the listing ends
  there, short (`list_all/3` says when).
  """
  @spec list(Config.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(cfg, prefix, opts \\ []) do
    with {:ok, objects, _truncated?} <- list_all(cfg, prefix, opts), do: {:ok, objects}
  end

  @doc "As `list/3`, and whether the page cap ended the listing with more to come."
  @spec list_all(Config.t(), String.t(), keyword()) ::
          {:ok, [map()], boolean()} | {:error, term()}
  def list_all(cfg, prefix, opts \\ []) do
    max_pages = Keyword.get(opts, :max_pages, @max_pages)
    list_pages(cfg, prefix, Keyword.get(opts, :max_keys, 1000), nil, [], {0, max_pages})
  end

  # Reached only with a continuation token in hand: the cap cut the listing.
  defp list_pages(_cfg, _prefix, _max, _token, acc, {limit, limit}),
    do: {:ok, Enum.reverse(acc), true}

  defp list_pages(cfg, prefix, max, token, acc, {page, limit}) do
    params =
      [{"list-type", "2"}, {"prefix", prefix}, {"max-keys", Integer.to_string(max)}] ++
        if(token, do: [{"continuation-token", token}], else: [])

    case once_more_if_closed(fn ->
           Req.get(req(cfg, receive_timeout: 30_000, decode_body: false),
             url: "/" <> cfg.bucket,
             params: params
           )
         end) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {objects, next} = parse_listing(body)
        acc = Enum.reverse(objects) ++ acc

        if next,
          do: list_pages(cfg, prefix, max, next, acc, {page + 1, limit}),
          else: {:ok, Enum.reverse(acc), false}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A fixed extraction rather than an XML parser: ListObjectsV2 is flat, the
  # keys are our own hex names, and anything unparseable is dropped.
  defp parse_listing(body) when is_binary(body) do
    objects =
      ~r{<Contents>(.*?)</Contents>}s
      |> Regex.scan(body)
      |> Enum.flat_map(fn [_, block] ->
        with key when is_binary(key) <- text(block, "Key"),
             {size, ""} <- Integer.parse(text(block, "Size") || ""),
             {:ok, dt, _} <- DateTime.from_iso8601(text(block, "LastModified") || "") do
          [%{key: key, size: size, last_modified: dt}]
        else
          _ -> []
        end
      end)

    next = if text(body, "IsTruncated") == "true", do: text(body, "NextContinuationToken")
    {objects, next}
  end

  defp parse_listing(_), do: {[], nil}

  defp text(xml, tag) do
    case Regex.run(~r{<#{tag}>(.*?)</#{tag}>}s, xml) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp req(cfg, opts) do
    Req.new(
      [
        base_url: cfg.endpoint,
        retry: false,
        redirect: false,
        connect_options: [
          timeout: @connect_timeout,
          transport_opts: [send_timeout: @send_timeout, send_timeout_close: true]
        ],
        aws_sigv4: [
          access_key_id: cfg.access_key,
          secret_access_key: cfg.secret_key,
          service: :s3,
          region: cfg.region
        ]
      ] ++ opts
    )
  end

  # One retry, and only on a connection the server had already closed: the
  # pool hands out a kept-alive connection the S3 server timed out, and the
  # request fails before a byte of it is sent. Every request here is
  # idempotent (GET, HEAD, LIST, DELETE, and a PUT of a content-addressed
  # object with the body in memory), so `fun` builds and sends it again from scratch,
  # signed afresh. Not Req's own `retry:`: it re-runs the request steps on the
  # already signed request, and the second SigV4 signature it adds makes the
  # server answer 403.
  defp once_more_if_closed(fun) do
    case fun.() do
      {:error, %Req.TransportError{reason: :closed}} -> fun.()
      other -> other
    end
  end

  defp object_url(cfg, object), do: "/" <> cfg.bucket <> "/" <> object

  defp header(resp, name), do: resp |> Req.Response.get_header(name) |> List.first()

  defp int_header(resp, name) do
    with v when is_binary(v) <- header(resp, name),
         {n, _} <- Integer.parse(v) do
      n
    else
      _ -> nil
    end
  end
end
