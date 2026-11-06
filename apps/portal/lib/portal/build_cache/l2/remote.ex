defmodule Portal.BuildCache.L2.Remote do
  @moduledoc """
  What a remote builder may read of the L2 build cache: for one image slug,
  the objects it lacks, each with a short-lived presigned GET URL, its size
  and its SHA-256. Served by the builder API
  (`POST /builder/v1/jobs/:lease_id/build-cache`), only for a lease the
  calling builder holds and only for that lease's image.

  A builder never holds an S3 key and never writes the bucket. A presigned
  URL authorizes exactly one request: a GET of that one object, until it
  expires (`ttl_seconds/0`, 15 minutes). It carries the access key id, as
  every SigV4 request does, and an HMAC made with the secret key; the secret
  key itself never leaves the portal. The URLs are signed with whatever key
  the portal's own `Portal.BuildCache.L2.Config` holds: on a host whose L2
  config is read-only (`NCC_BUILD_CACHE_S3_READ_ONLY=1`, the operator
  runbook's read-only key) that is the read-only key, otherwise the
  read-write one. Either way the signature binds the method and the path,
  so a URL cannot be turned into a PUT, a DELETE or another object's GET.

  The SHA-256 comes from the object's `x-amz-meta-sha256`, read with a HEAD
  here and handed to the builder over the mTLS builder API. The builder
  compares the body it downloads against that value, not against a header
  in the same response, so a body changed between the bucket and the builder
  is caught even over plain `http`. The URLs point at the configured
  endpoint, which today is reachable on the private network only: a builder
  outside it needs an `https` endpoint it can reach
  (`Portal.BuildCache.L2.Config.insecure_endpoint?/1` warns about plain
  `http` elsewhere).

  The offer is bounded the way `Portal.BuildCache.L2.prefetch/3` is: newest
  first, objects the builder already has (`have`) left out, no object over
  `Compatibility.BuildCache.Tarball.max_object_bytes/0`, at most the per-build
  download budget in total (`Compatibility.BuildCache.prefetch_budget/0`) and
  at most `@max_entries` objects, all within a deadline of its own. Anything
  that goes wrong offers nothing: the cache is an optimisation, and a build
  without it is the same build, slower. Nothing here logs a URL.
  """

  require Logger

  alias Compatibility.BuildCache
  alias Compatibility.BuildCache.Tarball
  alias Portal.BuildCache.L2.{Client, Config, Prefetch}

  @ttl_seconds 900
  @max_entries 256
  @deadline_ms 30_000
  @head_timeout_ms 5_000
  @head_concurrency 8

  @type entry :: %{String.t() => String.t() | non_neg_integer()}
  @type offer :: %{entries: [entry()], expires_at: DateTime.t()}

  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_entries

  @doc """
  The offer for `slug`, leaving out the keys in `have`. Never raises.

  Options: `:config` (default the active one; nil offers nothing), `:now`
  (signing time, default now), `:budget_bytes`, `:max_entries`,
  `:max_object_bytes` and `:deadline_ms` (listing and HEADs together).
  """
  @spec offer(String.t(), [String.t()], keyword()) :: offer()
  def offer(slug, have, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    empty = %{entries: [], expires_at: DateTime.add(now, @ttl_seconds)}

    with %Config{} = cfg <- Keyword.get_lazy(opts, :config, &active_config/0),
         true <- BuildCache.shareable_slug?(slug) do
      %{empty | entries: entries(cfg, slug, MapSet.new(have), now, opts)}
    else
      _ -> empty
    end
  rescue
    e ->
      Logger.warning("Build cache L2 offer for #{show(slug)} raised: #{Exception.message(e)}")
      %{entries: [], expires_at: DateTime.utc_now()}
  end

  defp active_config do
    case Config.config() do
      {:ok, cfg} -> cfg
      _ -> nil
    end
  end

  defp entries(cfg, slug, have, now, opts) do
    prefix = slug <> "/"
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :deadline_ms, @deadline_ms)

    case Prefetch.bounded_list(cfg, prefix, deadline) do
      {:ok, objects} ->
        objects
        |> candidates(prefix, have, opts)
        |> head_all(cfg, deadline)
        |> Enum.map(&entry(cfg, &1, now))

      {:error, reason} ->
        Logger.warning(
          "Build cache L2 listing of #{prefix} for a remote builder failed: " <>
            inspect(reason, printable_limit: 200)
        )

        []
    end
  end

  # Newest first, what the builder lacks, each object within the size cap,
  # then as many as fit the byte budget (one too large is skipped, not the
  # end of the list), at most `max_entries`.
  defp candidates(objects, prefix, have, opts) do
    max_object = Keyword.get(opts, :max_object_bytes, Tarball.max_object_bytes())
    budget = Keyword.get(opts, :budget_bytes, BuildCache.prefetch_budget().bytes)
    max_entries = Keyword.get(opts, :max_entries, @max_entries)

    objects
    |> Enum.flat_map(fn obj ->
      hex = BuildCache.object_hex(obj.key, prefix)

      if hex && obj.size > 0 && obj.size <= max_object && not MapSet.member?(have, hex),
        do: [Map.put(obj, :hex, hex)],
        else: []
    end)
    |> Enum.uniq_by(& &1.hex)
    |> Enum.sort_by(& &1.last_modified, {:desc, DateTime})
    |> Enum.reduce_while({[], 0}, fn obj, {acc, bytes} ->
      cond do
        length(acc) >= max_entries -> {:halt, {acc, bytes}}
        bytes + obj.size > budget -> {:cont, {acc, bytes}}
        true -> {:cont, {[obj | acc], bytes + obj.size}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # The SHA-256 is per-object metadata the listing does not carry. An object
  # whose HEAD fails, has no well-formed SHA-256 or another size than listed
  # (replaced since) is left out. HEADs not started by the deadline are not
  # started at all.
  defp head_all(objects, cfg, deadline) do
    objects
    |> Task.async_stream(&head(cfg, &1, deadline),
      max_concurrency: @head_concurrency,
      timeout: @head_timeout_ms,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.flat_map(fn
      {:ok, {:ok, obj}} -> [obj]
      _ -> []
    end)
  end

  defp head(cfg, obj, deadline) do
    with true <- System.monotonic_time(:millisecond) < deadline,
         {:ok, %{size: size, sha256: sha}} when size == obj.size and is_binary(sha) <-
           Client.head(cfg, obj.key),
         sha = String.downcase(sha),
         true <- BuildCache.sha256?(sha) do
      {:ok, Map.put(obj, :sha256, sha)}
    else
      _ -> :skip
    end
  end

  defp entry(cfg, obj, now) do
    %{
      "key" => obj.hex,
      "size" => obj.size,
      "sha256" => obj.sha256,
      "url" => presign(cfg, obj.key, now)
    }
  end

  @doc false
  # A SigV4 query-string GET for `object`, valid `ttl_seconds/0` from `now`.
  @spec presign(Config.t(), String.t(), DateTime.t()) :: String.t()
  def presign(cfg, object, now) do
    [
      access_key_id: cfg.access_key,
      secret_access_key: cfg.secret_key,
      region: cfg.region,
      service: :s3,
      datetime: now,
      method: :get,
      url: cfg.endpoint <> "/" <> cfg.bucket <> "/" <> object,
      expires: @ttl_seconds
    ]
    |> Req.Utils.aws_sigv4_url()
    |> URI.to_string()
  end

  defp show(term), do: inspect(term, printable_limit: 100)
end
