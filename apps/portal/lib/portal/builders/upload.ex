defmodule Portal.Builders.Upload do
  @moduledoc """
  Where a remote builder's bytes land before ingest: `<root>/<lease id>/files/`
  (content-addressed, verified on the way in) and `<root>/<lease id>/out/`
  (`result.json`, `logs/`, `runner.log`). `load_run/1` returns exactly what
  `Portal.Builder.load_run/1` returns, so `Portal.Workers.Ingest` runs the same
  ingestion for a remote build as for a local one.
  """
  require Logger

  alias Portal.{ArtifactStore, Repo}
  alias Portal.Builders.{Lease, Leases, TarStream}

  @sha ~r/\A[0-9a-f]{64}\z/
  @log_name ~r/\A[A-Za-z0-9_.\-]+\.log\z/
  @log_tail_bytes 1024 * 1024

  @spec root() :: Path.t()
  def root,
    do:
      :portal
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:root, Path.expand("~/.ncc-uploads"))

  @doc "`Leases.upload_caps/0` plus the size limits of the `complete` parts."
  @spec caps() :: map()
  def caps do
    config = Application.get_env(:portal, __MODULE__, [])

    Map.merge(Leases.upload_caps(), %{
      max_result_bytes: Keyword.get(config, :max_result_bytes, 8_388_608),
      max_logs_bytes: Keyword.get(config, :max_logs_bytes, 67_108_864),
      max_log_bytes: Keyword.get(config, :max_log_bytes, 16_777_216),
      max_logs_total_bytes: Keyword.get(config, :max_logs_total_bytes, 268_435_456)
    })
  end

  @spec lease_dir(String.t()) :: Path.t()
  def lease_dir(lease_id), do: Path.join(root(), lease_name(lease_id))
  @spec files_dir(String.t()) :: Path.t()
  def files_dir(lease_id), do: Path.join(lease_dir(lease_id), "files")
  @spec out_dir(String.t()) :: Path.t()
  def out_dir(lease_id), do: Path.join(lease_dir(lease_id), "out")

  # A lease id is a uuid; anything else never becomes a path component.
  defp lease_name(lease_id) do
    {:ok, uuid} = Ecto.UUID.cast(lease_id)
    uuid
  end

  @doc "The shas of `shas` neither the store nor this lease's uploads already hold."
  @spec missing(String.t(), term()) :: {:ok, [String.t()]} | {:error, :too_many | :invalid_sha}
  def missing(lease_id, shas) when is_list(shas) do
    cond do
      length(shas) > caps().max_files ->
        {:error, :too_many}

      not Enum.all?(shas, &(is_binary(&1) and Regex.match?(@sha, &1))) ->
        {:error, :invalid_sha}

      true ->
        {:ok,
         shas
         |> Enum.uniq()
         |> Enum.reject(&(ArtifactStore.present?(&1) or local_file?(lease_id, &1)))}
    end
  end

  def missing(_lease_id, _shas), do: {:error, :invalid_sha}

  # Paths are the configured root, a uuid and a validated sha.
  # sobelow_skip ["Traversal.FileModule"]
  defp local_file?(lease_id, sha),
    do: match?({:ok, %File.Stat{type: :regular}}, File.lstat(Path.join(files_dir(lease_id), sha)))

  @doc """
  Receive one tar batch through `read_chunk` (`-> {:ok, bin} | {:more, bin} |
  :done | {:error, reason}`), verifying each entry's sha as it is written.
  An entry whose bytes do not hash to its name, or that is over
  `max_file_bytes`, is listed under `bad`; an entry whose name is not a sha,
  or any entry that is not a plain file, refuses the whole batch.

  The declared `content_length` is reserved against the lease's total in one
  guarded `UPDATE` before the body is read, so concurrent batches on one
  lease cannot overrun `max_total_bytes` together; once read, the
  reservation is corrected to the bytes actually received, refused batch or
  not, and also when the read raises or exits. A batch first sweeps the
  `.incoming-*` files a killed batch left behind.
  """
  @spec receive_batch(Lease.t(), (-> term()), keyword()) ::
          {:ok, %{stored: [String.t()], bad: [String.t()], bytes: non_neg_integer()}}
          | {:error, term()}
  def receive_batch(%Lease{} = lease, read_chunk, opts) do
    caps = caps()
    length = Keyword.fetch!(opts, :content_length)

    cond do
      length > caps.max_batch_bytes ->
        {:error, :batch_too_large}

      disk_full?() ->
        {:error, :insufficient_disk}

      true ->
        with :ok <- reserve(lease, length, caps.max_total_bytes),
             do: reserved_batch(lease, read_chunk, length, caps)
    end
  end

  # The reservation is settled in `after`, from a count the reader keeps as
  # it goes: a body read that raises or exits (a dropped connection) still
  # hands back the bytes it never read, instead of holding them against the
  # lease's total for good.
  defp reserved_batch(lease, read_chunk, length, caps) do
    key = {__MODULE__, :received, make_ref()}
    Process.put(key, 0)

    counted = fn ->
      case read_chunk.() do
        {tag, chunk} = read when tag in [:ok, :more] and is_binary(chunk) ->
          Process.put(key, Process.get(key, 0) + byte_size(chunk))
          read

        other ->
          other
      end
    end

    try do
      {result, bytes} = stream_batch(lease, counted, length, caps)

      case result do
        {:ok, summary} -> {:ok, %{summary | bytes: bytes}}
        error -> error
      end
    after
      settle(lease, (Process.delete(key) || 0) - length)
    end
  end

  # These two statements guard on the attempt the way `Leases.add_bytes/2`
  # does; they could move into `Portal.Builders.Leases`.
  @reserve_sql """
  UPDATE builder_leases
  SET bytes_uploaded = bytes_uploaded + $3::bigint, updated_at = now()
  WHERE id = $1 AND builder_id = $2 AND run_id = $4
    AND state IN ('leased', 'uploading')
    AND bytes_uploaded + $3::bigint <= $5::bigint
  RETURNING bytes_uploaded
  """

  @settle_sql """
  UPDATE builder_leases
  SET bytes_uploaded = bytes_uploaded + $2::bigint, updated_at = now()
  WHERE id = $1 AND run_id = $3
  """

  defp reserve(%Lease{builder_id: builder_id, run_id: run_id}, _length, _max)
       when is_nil(builder_id) or is_nil(run_id),
       do: {:error, :not_held}

  defp reserve(%Lease{} = lease, length, max) do
    params = [
      Ecto.UUID.dump!(lease.id),
      Ecto.UUID.dump!(lease.builder_id),
      length,
      lease.run_id,
      max
    ]

    case Repo.query(@reserve_sql, params) do
      {:ok, %{num_rows: 1}} ->
        :ok

      {:ok, %{num_rows: 0}} ->
        if held?(lease), do: {:error, :total_exceeded}, else: {:error, :not_held}

      {:error, reason} ->
        db_failed(lease, reason)
    end
  end

  defp held?(%Lease{id: id, builder_id: builder_id, run_id: run_id}),
    do: match?({:ok, %Lease{run_id: ^run_id}}, Leases.held(id, builder_id))

  defp settle(lease, delta) do
    if delta != 0 do
      case Repo.query(@settle_sql, [Ecto.UUID.dump!(lease.id), delta, lease.run_id]) do
        {:ok, _} -> :ok
        {:error, reason} -> db_failed(lease, reason)
      end
    end

    Portal.AdminEvents.broadcast(:builders)
  end

  defp db_failed(lease, reason) do
    Logger.error("upload could not update lease #{lease.id}: #{inspect(reason)}")
    {:error, :update_failed}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp stream_batch(lease, read_chunk, length, caps) do
    dir = files_dir(lease.id)

    case File.mkdir_p(dir) do
      :ok ->
        sweep_stale_incoming(dir)
        state = TarStream.new(callbacks(dir, caps.max_file_bytes))

        case pump(read_chunk, state, 0, length) do
          {:ok, state, bytes} -> {conclude(dir, state), bytes}
          {:error, reason, state, open, bytes} -> {refuse(dir, state, open, reason), bytes}
        end

      {:error, reason} ->
        {{:error, io_error(reason)}, 0}
    end
  end

  defp conclude(dir, state) do
    case TarStream.finish(state) do
      {:ok, results} ->
        stored = for {:stored, sha} <- results, do: sha
        bad = for {kind, sha, _} <- results, kind in [:bad, :skipped], do: sha
        {:ok, %{stored: stored, bad: Enum.uniq(bad), bytes: nil}}

      {:error, reason} ->
        refuse(dir, state, nil, reason)
    end
  end

  # A refused batch keeps no partial file: the entry the reader had open
  # (`TarStream.pending/1`), the one a failed write names, and any other
  # `.incoming-*` are removed.
  defp refuse(dir, state, open, reason) do
    case TarStream.pending(state) do
      {_name, tmp, fd, _hash} -> close_open({fd, tmp})
      nil -> :ok
    end

    close_open(open)
    sweep_incoming(dir)
    {:error, reason}
  end

  defp close_open(nil), do: :ok

  # `tmp` is an `.incoming-*` path `open_incoming/1` built.
  # sobelow_skip ["Traversal.FileModule"]
  defp close_open({fd, tmp}) do
    if fd, do: File.close(fd)
    File.rm(tmp)
    :ok
  end

  defp pump(read_chunk, state, bytes, length) do
    case read_chunk.() do
      {:more, chunk} ->
        with {:ok, state, bytes} <- feed(state, chunk, bytes, length),
             do: pump(read_chunk, state, bytes, length)

      {:ok, chunk} ->
        feed(state, chunk, bytes, length)

      :done ->
        {:ok, state, bytes}

      {:error, reason} ->
        {:error, reason, state, nil, bytes}
    end
  end

  # The callbacks `throw` to refuse the batch from inside `TarStream` (an
  # entry that is not a sha, a failed write); caught here with whatever file
  # the failure left open.
  defp feed(state, chunk, bytes, length) do
    bytes = bytes + byte_size(chunk)

    if bytes > length do
      {:error, :batch_too_large, state, nil, bytes}
    else
      try do
        case TarStream.feed(state, chunk) do
          {:ok, state} -> {:ok, state, bytes}
          {:error, reason} -> {:error, reason, state, nil, bytes}
        end
      catch
        {:upload_abort, reason, open} -> {:error, reason, state, open, bytes}
      end
    end
  end

  defp abort(reason, open), do: throw({:upload_abort, reason, open})

  defp io_error(:enospc), do: :insufficient_disk
  defp io_error(reason), do: {:io, reason}

  # sobelow_skip ["Traversal.FileModule"]
  defp open_incoming(dir) do
    rand = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    tmp = Path.join(dir, ".incoming-#{rand}")

    case File.open(tmp, [:write, :binary, :raw, :exclusive]) do
      {:ok, fd} -> {fd, tmp}
      {:error, reason} -> abort(io_error(reason), nil)
    end
  end

  defp write_chunk(fd, tmp, data) do
    case :file.write(fd, data) do
      :ok -> :ok
      {:error, reason} -> abort(io_error(reason), {fd, tmp})
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp publish(fd, tmp, dest) do
    with :ok <- File.close(fd),
         :ok <- File.chmod(tmp, 0o644),
         :ok <- File.rename(tmp, dest) do
      :ok
    else
      {:error, reason} -> abort(io_error(reason), {nil, tmp})
    end
  end

  defp callbacks(dir, max_file_bytes) do
    %{
      start: fn name, size ->
        cond do
          not Regex.match?(@sha, name) ->
            abort({:unsupported_entry, name}, nil)

          size > max_file_bytes ->
            {:skip, :too_large}

          true ->
            {fd, tmp} = open_incoming(dir)
            {:ok, {name, tmp, fd, :crypto.hash_init(:sha256)}}
        end
      end,
      data: fn {name, tmp, fd, hash}, data ->
        write_chunk(fd, tmp, data)
        {name, tmp, fd, :crypto.hash_update(hash, data)}
      end,
      finish: fn {name, tmp, fd, hash} ->
        actual = hash |> :crypto.hash_final() |> Base.encode16(case: :lower)

        if actual == name do
          publish(fd, tmp, Path.join(dir, name))
          {:stored, name}
        else
          close_open({fd, tmp})
          {:bad, name, :checksum_mismatch}
        end
      end
    }
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp sweep_incoming(dir),
    do: dir |> Path.join(".incoming-*") |> Path.wildcard(match_dot: true) |> Enum.each(&File.rm/1)

  # A batch killed mid-entry (the request process gone with its connection)
  # leaves its `.incoming-*` behind, which no refusal swept. Each batch
  # starts by removing those not written to for a minute: a concurrent
  # batch on the same lease writes its open entry as its bytes arrive, so
  # only a dead one goes that long untouched.
  @stale_incoming_seconds 60

  # sobelow_skip ["Traversal.FileModule"]
  defp sweep_stale_incoming(dir) do
    cutoff = System.os_time(:second) - @stale_incoming_seconds

    dir
    |> Path.join(".incoming-*")
    |> Path.wildcard(match_dot: true)
    |> Enum.each(fn path ->
      case File.lstat(path, time: :posix) do
        {:ok, %File.Stat{type: :regular, mtime: mtime}} when mtime < cutoff -> File.rm(path)
        _ -> :ok
      end
    end)
  end

  # Like `Portal.Builder`'s free-space check: an unknown answer does not refuse.
  defp disk_full? do
    case Portal.Builder.free_bytes(root()) do
      nil -> false
      free -> free < Portal.Builder.min_free_bytes()
    end
  end

  @doc """
  Write `result.json`, the per-system logs and the runner log for ingest.
  The logs directory starts empty on every call, so an attempt never
  inherits a previous attempt's logs.
  """
  @spec write_outputs(String.t(), map()) ::
          :ok
          | {:error,
             :result_too_large
             | :result_unparsable
             | :logs_too_large
             | :logs_invalid
             | :insufficient_disk
             | {:io, term()}}
  # sobelow_skip ["Traversal.FileModule"]
  def write_outputs(lease_id, %{result: %Plug.Upload{} = result} = parts) do
    caps = caps()
    out = out_dir(lease_id)
    logs_dir = Path.join(out, "logs")
    _ = File.rm(Path.join(out, "result.json"))
    _ = File.rm_rf(logs_dir)

    with :ok <- mkdir(logs_dir),
         :ok <- size_ok(result.path, caps.max_result_bytes, :result_too_large),
         {:ok, bytes} <- read_result(result.path),
         {:ok, _} <- decode(bytes),
         :ok <- write_logs(Map.get(parts, :logs), logs_dir, caps),
         :ok <- write_runner_log(Map.get(parts, :runner_log), Path.join(out, "runner.log")) do
      # result.json last: `load_run/1` only sees a run whose parts all landed.
      case File.write(Path.join(out, "result.json"), bytes) do
        :ok -> :ok
        {:error, reason} -> {:error, io_error(reason)}
      end
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, io_error(reason)}
    end
  end

  # `path` is the Plug.Upload temp file Plug.Parsers wrote.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_result(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _} -> {:error, :result_unparsable}
    end
  end

  defp decode(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, :result_unparsable}
    end
  end

  defp size_ok(path, max, error) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= max -> :ok
      {:ok, _} -> {:error, error}
      {:error, _} -> {:error, :result_unparsable}
    end
  end

  defp write_logs(nil, _dir, _caps), do: :ok

  # `logs.tar.gz` is never handed to `:erl_tar`: it is inflated chunk by
  # chunk into `TarStream`, which takes plain file entries only, and each
  # entry is written to a fresh `.incoming-*` file and renamed to its
  # (validated, not yet present) name. Sizes are capped on the inflated
  # bytes, per entry and in total, so a small archive cannot inflate past
  # them. Any refusal removes everything written.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_logs(%Plug.Upload{path: path}, dir, caps) do
    with :ok <- size_ok(path, caps.max_logs_bytes, :logs_too_large) do
      case inflate_logs(path, dir, caps) do
        :ok ->
          :ok

        {:error, reason} ->
          _ = File.rm_rf(dir)
          {:error, reason}
      end
    end
  end

  # `path` is the Plug.Upload temp file Plug.Parsers wrote.
  # sobelow_skip ["Traversal.FileModule"]
  defp inflate_logs(path, dir, caps) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 31)
      state = TarStream.new(log_callbacks(dir, caps.max_log_bytes))
      max = caps.max_logs_total_bytes

      path
      |> File.stream!(65_536)
      |> Enum.reduce_while({:ok, state, 0}, fn chunk, {:ok, state, n} ->
        case inflate(z, chunk, state, n, max) do
          {:ok, state, n} -> {if(TarStream.done?(state), do: :halt, else: :cont), {:ok, state, n}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, state, _n} -> finish_logs(state)
        {:error, reason} -> {:error, reason}
      end
    catch
      {:upload_abort, reason, open} ->
        close_open(open)
        {:error, log_error(reason)}

      :error, _ ->
        {:error, :logs_invalid}
    after
      :zlib.close(z)
    end
  end

  defp inflate(z, input, state, n, max) do
    case :zlib.safeInflate(z, input) do
      {status, out} when status in [:continue, :finished] ->
        bin = IO.iodata_to_binary(out)
        feed_logs(z, status, bin, state, n + byte_size(bin), max)

      _ ->
        {:error, :logs_invalid}
    end
  end

  defp feed_logs(_z, _status, _bin, state, n, max) when n > max,
    do: abandon(state, :logs_too_large)

  defp feed_logs(z, status, bin, state, n, max) do
    case TarStream.feed(state, bin) do
      {:ok, state} ->
        if status == :continue and bin != "" and not TarStream.done?(state),
          do: inflate(z, [], state, n, max),
          else: {:ok, state, n}

      {:error, _} ->
        abandon(state, :logs_invalid)
    end
  end

  defp finish_logs(state) do
    case TarStream.finish(state) do
      {:ok, _names} -> :ok
      {:error, _} -> abandon(state, :logs_invalid)
    end
  end

  defp abandon(state, reason) do
    case TarStream.pending(state) do
      {_name, tmp, fd} -> close_open({fd, tmp})
      nil -> :ok
    end

    {:error, reason}
  end

  defp log_error({:unsupported_entry, _}), do: :logs_invalid
  defp log_error(reason), do: reason

  # sobelow_skip ["Traversal.FileModule"]
  defp log_callbacks(dir, max_log_bytes) do
    %{
      start: fn name, size ->
        cond do
          not Regex.match?(@log_name, name) -> abort(:logs_invalid, nil)
          size > max_log_bytes -> abort(:logs_too_large, nil)
          File.lstat(Path.join(dir, name)) != {:error, :enoent} -> abort(:logs_invalid, nil)
          true -> open_log(dir, name)
        end
      end,
      data: fn {name, tmp, fd}, data ->
        write_chunk(fd, tmp, data)
        {name, tmp, fd}
      end,
      finish: fn {name, tmp, fd} ->
        publish(fd, tmp, Path.join(dir, name))
        name
      end
    }
  end

  defp open_log(dir, name) do
    {fd, tmp} = open_incoming(dir)
    {:ok, {name, tmp, fd}}
  end

  defp write_runner_log(nil, _path), do: :ok

  # sobelow_skip ["Traversal.FileModule"]
  defp write_runner_log(%Plug.Upload{path: src}, dest) do
    case File.cp(src, dest) do
      :ok -> :ok
      {:error, _} -> {:error, :logs_invalid}
    end
  end

  @doc "The uploaded run in `Portal.Builder.load_run/1`'s shape."
  @spec load_run(String.t()) ::
          {:ok, Portal.Builder.build_result()} | {:error, :missing_result_json}
  # sobelow_skip ["Traversal.FileModule"]
  def load_run(lease_id) do
    out = out_dir(lease_id)
    path = Path.join(out, "result.json")

    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, result} <- decode(bytes) do
      {:ok,
       %{
         exit_code: 0,
         result: result,
         files_dir: files_dir(lease_id),
         output_dir: out,
         log: read_tail(Path.join(out, "runner.log"))
       }}
    else
      _ -> {:error, :missing_result_json}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_tail(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
         {:ok, fd} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        case :file.pread(fd, max(size - @log_tail_bytes, 0), min(size, @log_tail_bytes)) do
          {:ok, content} -> content
          _ -> ""
        end
      after
        :file.close(fd)
      end
    else
      _ -> ""
    end
  end

  @doc "Remove everything the lease uploaded."
  @spec cleanup(String.t()) :: :ok
  # sobelow_skip ["Traversal.FileModule"]
  def cleanup(lease_id) do
    _ = File.rm_rf(lease_dir(lease_id))
    :ok
  end
end
