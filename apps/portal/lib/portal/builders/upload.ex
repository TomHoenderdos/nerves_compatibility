defmodule Portal.Builders.Upload do
  @moduledoc """
  Where a remote builder's bytes land before ingest: `<root>/<lease id>/files/`
  (content-addressed, verified on the way in) and `<root>/<lease id>/out/`
  (`result.json`, `logs/`, `runner.log`). `load_run/1` returns exactly what
  `Portal.Builder.load_run/1` returns, so `Portal.Workers.Ingest` runs the same
  ingestion for a remote build as for a local one.
  """
  alias Portal.ArtifactStore
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
      max_logs_bytes: Keyword.get(config, :max_logs_bytes, 67_108_864)
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
  or any entry that is not a plain file, refuses the whole batch. Every byte
  received counts against the lease's total, refused batch or not.
  """
  @spec receive_batch(Lease.t(), (-> term()), keyword()) ::
          {:ok, %{stored: [String.t()], bad: [String.t()], bytes: non_neg_integer()}}
          | {:error, term()}
  def receive_batch(%Lease{} = lease, read_chunk, opts) do
    caps = caps()
    length = Keyword.fetch!(opts, :content_length)

    cond do
      length > caps.max_batch_bytes -> {:error, :batch_too_large}
      lease.bytes_uploaded + length > caps.max_total_bytes -> {:error, :total_exceeded}
      disk_full?() -> {:error, :insufficient_disk}
      true -> stream_batch(lease, read_chunk, length, caps)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp stream_batch(lease, read_chunk, length, caps) do
    dir = files_dir(lease.id)
    File.mkdir_p!(dir)
    state = TarStream.new(callbacks(dir, caps.max_file_bytes))

    case pump(read_chunk, state, 0, length) do
      {:ok, state, bytes} -> conclude(lease, dir, state, bytes)
      {:error, reason, state, bytes} -> refuse(lease, dir, state, bytes, reason)
    end
  end

  defp conclude(lease, dir, state, bytes) do
    with {:ok, results} <- TarStream.finish(state),
         {:ok, _} <- Leases.add_bytes(lease, bytes) do
      stored = for {:stored, sha} <- results, do: sha
      bad = for {kind, sha, _} <- results, kind in [:bad, :skipped], do: sha
      {:ok, %{stored: stored, bad: Enum.uniq(bad), bytes: bytes}}
    else
      {:error, :truncated} -> refuse(lease, dir, state, bytes, :truncated)
      {:error, reason} -> {:error, reason}
    end
  end

  # A refused batch keeps no partial file, and its bytes still count. The
  # open file is the `.incoming-*` path `callbacks/2` built under `dir`.
  # sobelow_skip ["Traversal.FileModule"]
  defp refuse(lease, dir, state, bytes, reason) do
    with {_name, tmp, fd, _hash} <- state && TarStream.pending(state) do
      File.close(fd)
      File.rm(tmp)
    end

    sweep_incoming(dir)
    if bytes > 0, do: Leases.add_bytes(lease, bytes)
    {:error, reason}
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
        {:error, reason, state, bytes}
    end
  end

  # The `start` callback throws for an entry that is not a sha, so the throw
  # crosses `TarStream`; it is caught here, where no entry is open.
  defp feed(state, chunk, bytes, length) do
    bytes = bytes + byte_size(chunk)

    if bytes > length do
      {:error, :batch_too_large, state, bytes}
    else
      try do
        case TarStream.feed(state, chunk) do
          {:ok, state} -> {:ok, state, bytes}
          {:error, reason} -> {:error, reason, state, bytes}
        end
      catch
        {:unsupported_entry, name} -> {:error, {:unsupported_entry, name}, nil, bytes}
      end
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp callbacks(dir, max_file_bytes) do
    %{
      start: fn name, size ->
        cond do
          not Regex.match?(@sha, name) ->
            throw({:unsupported_entry, name})

          size > max_file_bytes ->
            {:skip, :too_large}

          true ->
            rand = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
            tmp = Path.join(dir, ".incoming-#{name}-#{rand}")
            fd = File.open!(tmp, [:write, :binary, :raw, :exclusive])
            {:ok, {name, tmp, fd, :crypto.hash_init(:sha256)}}
        end
      end,
      data: fn {name, tmp, fd, hash}, data ->
        :ok = IO.binwrite(fd, data)
        {name, tmp, fd, :crypto.hash_update(hash, data)}
      end,
      finish: fn {name, tmp, fd, hash} ->
        :ok = File.close(fd)
        actual = hash |> :crypto.hash_final() |> Base.encode16(case: :lower)

        if actual == name do
          File.chmod!(tmp, 0o644)
          File.rename!(tmp, Path.join(dir, name))
          {:stored, name}
        else
          File.rm(tmp)
          {:bad, name, :checksum_mismatch}
        end
      end
    }
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp sweep_incoming(dir),
    do: dir |> Path.join(".incoming-*") |> Path.wildcard(match_dot: true) |> Enum.each(&File.rm/1)

  # Like `Portal.Builder`'s free-space check: an unknown answer does not refuse.
  defp disk_full? do
    case Portal.Builder.free_bytes(root()) do
      nil -> false
      free -> free < Portal.Builder.min_free_bytes()
    end
  end

  @doc "Write `result.json`, the per-system logs and the runner log for ingest."
  @spec write_outputs(String.t(), map()) ::
          :ok
          | {:error, :result_too_large | :result_unparsable | :logs_too_large | :logs_invalid}
  # sobelow_skip ["Traversal.FileModule"]
  def write_outputs(lease_id, %{result: %Plug.Upload{} = result} = parts) do
    caps = caps()
    out = out_dir(lease_id)
    logs_dir = Path.join(out, "logs")
    File.mkdir_p!(logs_dir)
    _ = File.rm(Path.join(out, "result.json"))

    with :ok <- size_ok(result.path, caps.max_result_bytes, :result_too_large),
         {:ok, bytes} <- read_result(result.path),
         {:ok, _} <- decode(bytes),
         :ok <- write_logs(Map.get(parts, :logs), logs_dir, caps.max_logs_bytes),
         :ok <- write_runner_log(Map.get(parts, :runner_log), Path.join(out, "runner.log")) do
      # result.json last: `load_run/1` only sees a run whose parts all landed.
      File.write!(Path.join(out, "result.json"), bytes)
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

  defp write_logs(nil, _dir, _max), do: :ok

  # sobelow_skip ["Traversal.FileModule"]
  defp write_logs(%Plug.Upload{path: path}, dir, max) do
    archive = String.to_charlist(path)

    with :ok <- size_ok(path, max, :logs_too_large),
         {:ok, entries} <- :erl_tar.table(archive, [:compressed]),
         names = Enum.map(entries, &to_string/1),
         true <- Enum.all?(names, &Regex.match?(@log_name, &1)),
         :ok <-
           :erl_tar.extract(archive, [
             :compressed,
             {:cwd, String.to_charlist(dir)},
             {:files, Enum.map(names, &String.to_charlist/1)}
           ]) do
      drop_irregular(dir, names)
    else
      {:error, :logs_too_large} -> {:error, :logs_too_large}
      _ -> {:error, :logs_invalid}
    end
  end

  # Defence in depth: the names were checked, but only regular files stay.
  # sobelow_skip ["Traversal.FileModule"]
  defp drop_irregular(dir, names) do
    for name <- names,
        path = Path.join(dir, name),
        not match?({:ok, %File.Stat{type: :regular}}, File.lstat(path)) do
      File.rm_rf(path)
    end

    :ok
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
