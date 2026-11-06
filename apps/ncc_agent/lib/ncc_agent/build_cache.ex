defmodule NccAgent.BuildCache do
  @moduledoc """
  A remote builder's read-only copy of the portal's shared L2 build cache.

  Before a lease's container starts, `prepare/4` asks the portal which L2
  objects of the lease's image it lacks (`NccAgent.Client.build_cache/4`,
  `POST /builder/v1/jobs/:lease_id/build-cache`), downloads them through the
  short-lived presigned GET URLs in that answer, and extracts them into
  `<data>/build-cache/<slug>/<key>`, which `NccAgent.Job` mounts read-only at
  `/build-cache` with `NCC_BUILD_CACHE` set, exactly as `Portal.Builder` does
  on a home host (`Compatibility.Builder.Argv`). The agent holds no S3 key
  and never writes the bucket; the portal never promotes a remote run's
  cache candidates.

  Every object goes through the same code the portal's own prefetch runs
  (`Compatibility.BuildCache.Install`, `Compatibility.BuildCache.Tarball`,
  `Compatibility.BuildCache.Tree`): the downloaded body's SHA-256 must equal
  the one the portal listed over the mTLS builder API, the gzip stream is
  pre-scanned against 1 GiB before extraction, the tar table screened
  (regular files and directories, safe names, bounded size), extraction runs
  in a heap- and time-bounded process, Mix's `priv`/`include` links come
  only from a validated `.ncc-links.json`, and the result is walked with
  Promotion's rules, made the agent's own and readable, never writable, by
  the build user (dirs 0755, files 0644 or 0755), and renamed into
  place. Keys and the slug are validated before they name a path; a URL is
  never logged (its query string is a credential for 15 minutes).

  The budget is the portal's (`Compatibility.BuildCache.prefetch_budget/0`):
  2 GiB downloaded, 4 GiB extracted and 5 minutes in all, the offer request
  included. Free space under `@min_free_bytes` on the data dir's filesystem
  stops it, a transport error or timeout ends it, and so do five failures in
  a row. Two slots never fetch into one slug at once: the second builds with
  what is already there.

  Nothing here fails a lease. `prepare/4` returns the slug dir to mount when
  it holds at least one entry, nil otherwise, and one summary line for
  `runner.log`.

  Each slug stops growing at `NCC_BUILD_CACHE_MAX_GB` (`slug_full?/3`:
  nothing is evicted from a slug another slot may be building from).

  A slug dir no build has used for `@stale_after_days` days (the image it
  names is gone) is removed the next time any build prepares its cache.
  """

  require Logger

  alias Compatibility.BuildCache
  alias Compatibility.BuildCache.{Install, Tarball, Tree}
  alias Compatibility.Builder.Argv
  alias NccAgent.{Client, Config, Fs}

  @object_timeout_ms 120_000
  @offer_timeout_ms 90_000
  @connect_timeout_ms 10_000
  @min_get_ms 1_000
  @max_failures_in_a_row 5
  @min_free_bytes 10 * 1024 * 1024 * 1024
  @stale_after_days 7
  @max_have 20_000
  # A prune renames a slug dir to this prefix before removing it; a crash
  # between the two leaves one behind for the next prune.
  @pruning ".pruning-"

  @type counts :: %{
          offered: non_neg_integer(),
          downloaded: non_neg_integer(),
          discarded: non_neg_integer(),
          failed: non_neg_integer(),
          skipped: non_neg_integer(),
          bytes: non_neg_integer(),
          extracted_bytes: non_neg_integer()
        }

  @doc """
  Fetches what the portal offers for `claim`'s image and returns `{dir |
  nil, line}`: the slug dir to mount at `/build-cache` (nil when it holds no
  entry or the image is not shareable) and a one-line summary. Never raises.

  Options (tests): `:budget_bytes`, `:extracted_budget_bytes`, `:budget_ms`,
  `:min_free_bytes`, `:free_bytes` (a `fn dir -> bytes | nil`).
  """
  @spec prepare(Req.Request.t(), map(), Config.t(), keyword()) :: {Path.t() | nil, String.t()}
  def prepare(req, claim, config, opts \\ []) do
    case slug(claim) do
      {:ok, slug} ->
        root = Config.path(config, :build_cache)
        dir = Path.join(root, slug)
        # In use from here on, whether or not this slot gets the lock: a
        # slot that mounts what another one filled must not see it pruned.
        mark_in_use(dir)
        prune(root, slug)
        line = with_lock(slug, fn -> fill(req, claim["lease_id"], dir, slug, config, opts) end)
        {if(entries(dir) != [], do: dir), line}

      :error ->
        {nil, "build cache: the image digest is not shareable; building without it"}
    end
  rescue
    e ->
      Logger.warning("build cache prepare raised: #{Exception.message(e)}")
      {nil, "build cache: skipped after an error; building without it"}
  catch
    kind, reason ->
      Logger.warning("build cache prepare failed: #{show({kind, reason})}")
      {nil, "build cache: skipped after an error; building without it"}
  end

  # The slug the portal names the image by (`Portal.Builder.cache_slug/1`):
  # the platform digest the claim pinned, made safe for a directory name.
  defp slug(%{"image" => %{"digest" => digest}}) when is_binary(digest) do
    slug = Argv.safe_name(digest)
    if BuildCache.shareable_slug?(slug), do: {:ok, slug}, else: :error
  end

  defp slug(_claim), do: :error

  defp with_lock(slug, fun) do
    case try_lock(slug, fun) do
      {:ok, result} -> result
      :busy -> "build cache: another slot is filling #{slug}; building with what it holds"
    end
  end

  # The per-slug lock, never waited for: `{:ok, fun.()}` or `:busy`. Both
  # the fill and the prune of a slug run under it.
  defp try_lock(slug, fun) do
    lock = {{__MODULE__, slug}, self()}

    if :global.set_lock(lock, [node()], 0) do
      try do
        {:ok, fun.()}
      after
        :global.del_lock(lock, [node()])
      end
    else
      :busy
    end
  end

  # Updates the slug dir's mtime if it exists. `:file.change_time/2` rather
  # than `File.touch/1`, which would create a file where a prune just
  # renamed the dir away.
  # sobelow_skip ["Traversal.FileModule"]
  defp mark_in_use(dir) do
    _ = :file.change_time(String.to_charlist(dir), :calendar.local_time())
    :ok
  end

  # `dir` is `<data>/build-cache/<validated slug>`.
  # sobelow_skip ["Traversal.FileModule"]
  defp fill(req, lease_id, dir, slug, config, opts) do
    File.mkdir_p!(dir)
    # Whatever the umask: the build user must reach the mount's root.
    File.chmod!(Path.dirname(dir), 0o755)
    File.chmod!(dir, 0o755)
    mark_in_use(dir)
    remove_leftovers(dir)
    budget = budget(opts, config, dir)

    have = dir |> entries() |> Enum.take(@max_have)
    timeout = min(@offer_timeout_ms, remaining(budget))

    case Client.build_cache(req, lease_id, have, max(timeout, 1)) do
      {:ok, %{"slug" => ^slug, "entries" => entries}} ->
        candidates = candidates(entries, MapSet.new(have))
        counts = run(candidates, dir, budget)
        summary(slug, counts)

      {:ok, _other} ->
        "build cache: the portal's offer names another image; building without new entries"

      {:error, reason} ->
        Logger.warning("build cache offer for #{lease_id} failed: #{show(reason)}")
        "build cache: no offer from the portal; building with what is local"
    end
  end

  # `slug_used` is what the slug holds already, measured once under the lock;
  # what this fill extracts is added to it as it goes.
  defp budget(opts, config, dir) do
    defaults = BuildCache.prefetch_budget()

    %{
      max_slug: config.build_cache_max_bytes,
      slug_used: disk_usage(dir),
      bytes: Keyword.get(opts, :budget_bytes, defaults.bytes),
      extracted: Keyword.get(opts, :extracted_budget_bytes, defaults.extracted_bytes),
      deadline: System.monotonic_time(:millisecond) + Keyword.get(opts, :budget_ms, defaults.ms),
      min_free: Keyword.get(opts, :min_free_bytes, @min_free_bytes),
      free_bytes: Keyword.get(opts, :free_bytes, &free_bytes/1)
    }
  end

  defp remaining(budget), do: max(budget.deadline - System.monotonic_time(:millisecond), 0)

  @doc """
  The published entries in `dir`: names that are cache keys. Staging names
  and anything else are not entries.
  """
  @spec entries(Path.t()) :: [String.t()]
  # sobelow_skip ["Traversal.FileModule"]
  def entries(dir) do
    case File.ls(dir) do
      {:ok, names} -> names |> Enum.filter(&BuildCache.key?/1) |> Enum.sort()
      {:error, _} -> []
    end
  end

  # Staging dirs and tarballs a crash left behind. Runs under the slug's
  # lock, so no fetch of this agent is using them.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove_leftovers(dir) do
    for name <- File.ls!(dir),
        String.contains?(name, ".tmp."),
        do: File.rm_rf(Path.join(dir, name))
  end

  # The offer, checked entry by entry: a key, a lowercase SHA-256, a size
  # within the object cap and an http(s) URL. Anything else is dropped, as
  # is a key already local or offered twice.
  @doc false
  @spec candidates(term(), MapSet.t()) :: [map()]
  def candidates(entries, have) when is_list(entries) do
    max_object = Tarball.max_object_bytes()

    entries
    |> Enum.flat_map(fn
      %{"key" => key, "sha256" => sha, "size" => size, "url" => url}
      when is_integer(size) and size > 0 ->
        if BuildCache.key?(key) and BuildCache.sha256?(sha) and size <= max_object and
             http_url?(url) and not MapSet.member?(have, key),
           do: [%{key: key, sha256: sha, size: size, url: url}],
           else: []

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1.key)
  end

  def candidates(_entries, _have), do: []

  defp http_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        host != ""

      _ ->
        false
    end
  end

  defp http_url?(_url), do: false

  defp run(candidates, dir, budget) do
    counts = %{
      offered: length(candidates),
      downloaded: 0,
      discarded: 0,
      failed: 0,
      skipped: 0,
      bytes: 0,
      extracted_bytes: 0
    }

    candidates
    |> Enum.reduce({counts, {:go, 0}}, &fetch(&1, &2, dir, budget))
    |> elem(0)
  end

  # `state` is `{:go, failures_in_a_row}` or `:stop`.
  defp fetch(entry, {counts, state}, dir, budget) do
    cond do
      state == :stop or remaining(budget) < @min_get_ms or
        counts.bytes + entry.size > budget.bytes or counts.extracted_bytes >= budget.extracted ->
        {bump(counts, :skipped), state}

      slug_full?(dir, counts, budget) ->
        {bump(counts, :skipped), :stop}

      low_disk?(dir, budget) ->
        {bump(counts, :skipped), :stop}

      true ->
        entry |> download_one(dir, budget) |> tally(entry, counts, state)
    end
  end

  # The per-slug cap (`NCC_BUILD_CACHE_MAX_GB`). Reaching it stops the
  # fetching rather than evicting: another slot's container may be reading
  # any entry of this slug through its read-only mount at this moment, and
  # deleting files under a running build would turn a cache hit into a
  # wrong result. The slug is retired whole once its image is unused for a
  # week (`prune/2`). One object may take the slug past the cap by at most
  # its own extracted size. A slug whose size cannot be measured is full.
  defp slug_full?(dir, counts, budget) do
    full? =
      is_nil(budget.slug_used) or budget.slug_used + counts.extracted_bytes >= budget.max_slug

    if full? and counts.downloaded + counts.discarded + counts.failed + counts.skipped == 0 do
      Logger.info(
        "build cache #{Path.basename(dir)} is at its #{budget.max_slug}-byte cap: fetching nothing more"
      )
    end

    full?
  end

  @doc false
  # Bytes `dir` takes on disk by `du -sk`, nil when it cannot tell.
  @spec disk_usage(Path.t()) :: non_neg_integer() | nil
  # sobelow_skip ["CI.System"]
  def disk_usage(dir) do
    with {out, 0} <- System.cmd("du", ["-sk", dir], stderr_to_stdout: true),
         [kb | _] <- String.split(out, ~r/\s+/, trim: true),
         {kb, ""} <- Integer.parse(kb) do
      kb * 1024
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp low_disk?(dir, budget) do
    case budget.free_bytes.(dir) do
      free when is_integer(free) and free < budget.min_free ->
        Logger.warning(
          "build cache fetch into #{dir} stopped: #{free} bytes free, under #{budget.min_free}"
        )

        true

      _ ->
        false
    end
  end

  defp tally({:ok, bytes, extracted}, _entry, counts, _state),
    do: {add(bump(counts, :downloaded), bytes, extracted), {:go, 0}}

  defp tally({:discarded, bytes, extracted}, _entry, counts, _state),
    do: {add(bump(counts, :discarded), bytes, extracted), {:go, 0}}

  defp tally({:error, reason}, entry, counts, state) do
    Logger.warning("build cache object #{entry.key} not fetched: #{show(reason)}")

    next =
      case {stop?(reason), state} do
        {true, _} -> :stop
        {false, :stop} -> :stop
        {false, {:go, n}} when n + 1 >= @max_failures_in_a_row -> :stop
        {false, {:go, n}} -> {:go, n + 1}
      end

    {bump(counts, :failed), next}
  end

  defp add(counts, bytes, extracted),
    do: %{
      counts
      | bytes: counts.bytes + bytes,
        extracted_bytes: counts.extracted_bytes + extracted
    }

  defp bump(counts, field), do: Map.update!(counts, field, &(&1 + 1))

  # The store is unwell (or the budget gone): do not wait on it once more
  # per object. A wrong object, or a local I/O error, is that object's.
  defp stop?(reason) when reason in [:timeout, :budget_spent], do: true
  defp stop?({:status, status}) when status in [401, 403] or status >= 500, do: true
  defp stop?({tag, _}) when tag in [:exit, :exception], do: true
  defp stop?(%{__exception__: true}), do: true
  defp stop?(_reason), do: false

  # `dir` is the validated slug dir and `entry.key` a validated 64-hex key,
  # so every path here is the agent's own.
  # sobelow_skip ["Traversal.FileModule"]
  defp download_one(entry, dir, budget) do
    dest = Path.join(dir, entry.key)
    staging = dest <> ".tmp." <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    tar = staging <> ".tar.gz"

    try do
      with {:ok, got} <- get(entry, tar, object_timeout(budget)),
           :ok <- Install.verify_sha(got.sha256, entry.sha256) do
        timeout = object_timeout(budget)

        case Install.install(tar, staging, dest,
               timeout_ms: timeout,
               before_publish: &readable_by_build_user/1
             ) do
          {:ok, extracted} ->
            {:ok, got.bytes, extracted}

          {:discarded, extracted} ->
            {:discarded, got.bytes, extracted}

          {:error, {:unpack, :timeout}} when timeout < @object_timeout_ms ->
            {:error, :budget_spent}

          {:error, reason} ->
            {:error, reason}
        end
      end
    after
      _ = File.rm(tar)
      _ = File.rm_rf(staging)
    end
  end

  # The agent owns the tree and the build user only reads it: dirs 0755,
  # files 0644 plus the execute bits the portal's own L2 install keeps
  # (`Tree.strip_modes/1`, then `Tree.readable_modes/1`). On a home host the
  # cache belongs to the uid the container runs as, but the worker never
  # writes it: it restores an entry with `cp -a` into its own build dir,
  # where the copy is the build user's, with these modes, and writable by
  # it. So nothing needs the build user to own the shared copy, and owned
  # by root it stays unwritable to builds even without the read-only mount.
  defp readable_by_build_user(staging) do
    with :ok <- Tree.readable_modes(staging), do: Fs.own_tree(staging)
  end

  defp object_timeout(budget), do: budget |> remaining() |> min(@object_timeout_ms)

  # The GET runs in a task killed at `timeout`: Req's receive timeout
  # measures inactivity, not total time. The body is streamed into `tar`,
  # hashed on the way, and refused past the listed size.
  defp get(entry, tar, timeout) do
    task =
      Task.async(fn ->
        try do
          stream_to(entry, tar)
        catch
          kind, reason -> {:error, {kind_tag(kind), show(reason)}}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:exit, show(reason)}}
      nil -> {:error, :timeout}
    end
  end

  defp kind_tag(:error), do: :exception
  defp kind_tag(kind), do: kind

  # sobelow_skip ["Traversal.FileModule"]
  defp stream_to(entry, tar) do
    File.open!(tar, [:write, :binary, :raw], fn io ->
      Req.get(entry.url,
        retry: false,
        redirect: false,
        decode_body: false,
        compressed: false,
        receive_timeout: 60_000,
        connect_options: [timeout: @connect_timeout_ms],
        into: collector(io, entry.size)
      )
    end)
    |> finish()
  end

  defp collector(io, max_bytes) do
    fn {:data, chunk}, {req, resp} ->
      acc = Req.Response.get_private(resp, :bc, %{bytes: 0, hash: :crypto.hash_init(:sha256)})
      bytes = acc.bytes + byte_size(chunk)

      cond do
        resp.status != 200 ->
          {:cont, {req, resp}}

        bytes > max_bytes ->
          {:halt, {req, Req.Response.put_private(resp, :bc, Map.put(acc, :too_large, true))}}

        true ->
          :ok = IO.binwrite(io, chunk)
          acc = %{acc | bytes: bytes, hash: :crypto.hash_update(acc.hash, chunk)}
          {:cont, {req, Req.Response.put_private(resp, :bc, acc)}}
      end
    end
  end

  defp finish({:ok, %Req.Response{status: 200} = resp}) do
    case Req.Response.get_private(resp, :bc) do
      %{too_large: true} ->
        {:error, :larger_than_listed}

      %{bytes: bytes, hash: hash} ->
        {:ok, %{bytes: bytes, sha256: Base.encode16(:crypto.hash_final(hash), case: :lower)}}

      nil ->
        {:error, :empty}
    end
  end

  defp finish({:ok, %Req.Response{status: status}}), do: {:error, {:status, status}}
  defp finish({:error, reason}), do: {:error, reason}

  defp summary(slug, counts) do
    "build cache #{slug}: #{counts.downloaded} downloaded, #{counts.discarded} discarded, " <>
      "#{counts.failed} failed, #{counts.skipped} skipped of #{counts.offered} offered " <>
      "(#{counts.bytes} bytes)"
  end

  # Slug dirs untouched for `@stale_after_days` days: no build has run that
  # image for a week, and every build touches its own before it starts.
  # Only names that are slugs are considered.
  # sobelow_skip ["Traversal.FileModule"]
  defp prune(root, keep) do
    cutoff = System.os_time(:second) - @stale_after_days * 86_400

    with {:ok, names} <- File.ls(root) do
      for name <- names,
          String.starts_with?(name, @pruning),
          do: File.rm_rf(Path.join(root, name))

      for name <- names,
          name != keep,
          BuildCache.shareable_slug?(name),
          stale?(Path.join(root, name), cutoff),
          do: try_lock(name, fn -> prune_one(root, name, cutoff) end)
    end

    :ok
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp stale?(path, cutoff) do
    match?(
      {:ok, %File.Stat{type: :directory, mtime: mtime}} when mtime < cutoff,
      File.lstat(path, time: :posix)
    )
  end

  # Under the slug's lock, so no slot is filling it, and checked again
  # there: a slot marks its slug in use before it asks for the lock, so a
  # slug whose mtime is still old has no build starting on it. The rename
  # takes it out of every later prepare's sight at once; only then is it
  # removed.
  # sobelow_skip ["Traversal.FileModule"]
  defp prune_one(root, name, cutoff) do
    path = Path.join(root, name)
    doomed = Path.join(root, @pruning <> name)

    if stale?(path, cutoff) and File.rename(path, doomed) == :ok do
      Logger.info("build cache: removing #{name}, unused for #{@stale_after_days} days")
      File.rm_rf(doomed)
    end

    :ok
  end

  @doc false
  # Bytes free on `dir`'s filesystem by `df -Pk`, nil when it cannot tell.
  @spec free_bytes(Path.t()) :: non_neg_integer() | nil
  # sobelow_skip ["CI.System"]
  def free_bytes(dir) do
    with {out, 0} <- System.cmd("df", ["-Pk", dir], stderr_to_stdout: true),
         [_header, line | _] <- String.split(out, "\n", trim: true),
         [_fs, _blocks, _used, avail | _] <- String.split(line, ~r/\s+/, trim: true),
         {kb, ""} <- Integer.parse(avail) do
      kb * 1024
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # A presigned query string is a credential until it expires: should an
  # error ever carry a URL, its query is cut before it reaches a log line.
  @doc false
  @spec show(term()) :: String.t()
  def show(term) do
    term
    |> inspect(printable_limit: 200)
    |> String.replace(~r/\?[^\s"']*/, "?<query removed>")
  end
end
