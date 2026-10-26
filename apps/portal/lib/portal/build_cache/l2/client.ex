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
    case Req.head(req(cfg, receive_timeout: 30_000), url: object_url(cfg, object)) do
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
        result =
          Req.get(req(cfg, receive_timeout: 60_000, into: collector(io, max_bytes)),
            url: object_url(cfg, object)
          )

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
      case Req.put(req(cfg, receive_timeout: timeout),
             url: object_url(cfg, object),
             body: body,
             headers: [{"content-type", "application/gzip"}, {"x-amz-meta-sha256", sha256}]
           ) do
        {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
        {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec list(Config.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(cfg, prefix, opts \\ []),
    do: list_pages(cfg, prefix, Keyword.get(opts, :max_keys, 1000), nil, [], 0)

  defp list_pages(_cfg, _prefix, _max, _token, acc, @max_pages), do: {:ok, Enum.reverse(acc)}

  defp list_pages(cfg, prefix, max, token, acc, page) do
    params =
      [{"list-type", "2"}, {"prefix", prefix}, {"max-keys", Integer.to_string(max)}] ++
        if(token, do: [{"continuation-token", token}], else: [])

    case Req.get(req(cfg, receive_timeout: 30_000, decode_body: false),
           url: "/" <> cfg.bucket,
           params: params
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {objects, next} = parse_listing(body)
        acc = Enum.reverse(objects) ++ acc

        if next,
          do: list_pages(cfg, prefix, max, next, acc, page + 1),
          else: {:ok, Enum.reverse(acc)}

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
