defmodule Compatibility.NifOrigin do
  @moduledoc """
  Where a host-native build's native files came from, for a package that
  downloads its NIF at compile time (rustler_precompiled, elixir_make's
  precompilers): such a package ships checksum files (`checksum-<module>.exs`,
  `checksum.exs`) in its own Hex tarball, mapping each upstream archive's
  name to its SHA-256, and a build may publish a native file only when it
  is, byte for byte, a member of an archive whose bytes have exactly the sum
  the package's own checksum file lists for that name (`verify/3`). That is
  the archive a user's own compile would have downloaded and checked.

  One rule set with three callers: the worker (`NccWorker.HostNative`)
  against the archives in its run's cache dir, the portal at ingest against
  a tarball it fetched itself and the archive blob the worker archived, and
  a client against the checksum file in its own `deps/<package>`.

  A checksum file is read as data (`parse/1`): a literal map of archive
  names to `"sha256:<64 lowercase hex>"` strings, at most 1 MiB and 4096
  entries, quoted with `Code.string_to_quoted/2` and never evaluated.
  Anything else is `:error`, so a downloader whose checksum file cannot be
  read publishes no native file.
  """

  alias Compatibility.StaticPriv

  @max_checksum_bytes 1024 * 1024
  @max_checksum_entries 4096
  @max_archive_bytes 128 * 1024 * 1024
  @max_archive_inflated 256 * 1024 * 1024
  @checksum_file ~r/\Achecksum(-[A-Za-z0-9_.]+)?\.exs\z/
  @sum ~r/\Asha256:([0-9a-f]{64})\z/
  @refusal "native file not verified against the package's checksum file: "
  @compiled "native file compiled in the run, not a checksum-pinned download: "

  @typedoc "A verified native file: its priv path and the archive it came from."
  @type origin :: %{String.t() => String.t()}

  @doc "Whether `name` is a checksum file's name (a bare basename)."
  @spec checksum_file?(term()) :: boolean()
  def checksum_file?(name) when is_binary(name), do: Regex.match?(@checksum_file, name)
  def checksum_file?(_name), do: false

  @doc """
  The refusal for the native files of a package with no checksum file,
  which it compiled in the run: `path` is the first of them. Such a file is
  not served. Nothing checks what its build assumed of the builder's CPU
  (`-march=native`, `-mavx2` or `-mcpu=native` in a Makefile runs fine on
  the builder and dies with SIGILL on an older CPU), its run paths, or what
  its build downloaded without a checksum; an upstream file its checksum
  file pins is the one a user's own compile would load.
  """
  @spec compiled_refusal(term()) :: String.t()
  def compiled_refusal(path), do: @compiled <> to_string(path)

  @doc "The largest archive `members/1` reads."
  @spec max_archive_bytes() :: pos_integer()
  def max_archive_bytes, do: @max_archive_bytes

  @doc "A checksum file's entries, archive name => lowercase hex SHA-256."
  @spec parse(term()) :: {:ok, %{String.t() => String.t()}} | :error
  def parse(source) when is_binary(source) and byte_size(source) <= @max_checksum_bytes do
    with true <- String.valid?(source),
         {:ok, {:%{}, _meta, pairs}} when is_list(pairs) <-
           Code.string_to_quoted(source, existing_atoms_only: true),
         true <- length(pairs) <= @max_checksum_entries do
      entries(pairs, %{})
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def parse(_source), do: :error

  defp entries([], acc), do: {:ok, acc}

  defp entries([{name, sum} | rest], acc) when is_binary(name) and is_binary(sum) do
    with true <- archive_name?(name),
         false <- Map.has_key?(acc, name),
         [_, hex] <- Regex.run(@sum, sum) do
      entries(rest, Map.put(acc, name, hex))
    else
      _ -> :error
    end
  end

  defp entries(_pairs, _acc), do: :error

  defp archive_name?(name) do
    name != "" and byte_size(name) <= 255 and Path.basename(name) == name and
      name not in [".", ".."] and String.printable?(name)
  end

  @doc """
  The checksum files at the root of a Hex `tarball`'s contents, each
  `parse/1`d: `{:ok, %{file => entries}}` (`%{}` for a package with none),
  or `:error` when the tarball or any checksum file in it cannot be read.
  """
  @spec checksum_files(term()) :: {:ok, %{String.t() => %{String.t() => String.t()}}} | :error
  def checksum_files(tarball) do
    with {:ok, tar} <- StaticPriv.contents(tarball),
         {:ok, table} <- :erl_tar.table({:binary, tar}, [:verbose]),
         names = checksum_entries(table),
         {:ok, extracted} <- extract(tar, names) do
      parse_all(extracted, %{})
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp checksum_entries(table) do
    for {name, :regular, _size, _mtime, _mode, _uid, _gid} <- table,
        checksum_file?(to_string(name)),
        do: name
  end

  defp extract(_tar, []), do: {:ok, []}
  defp extract(tar, names), do: :erl_tar.extract({:binary, tar}, [:memory, {:files, names}])

  defp parse_all([], acc), do: {:ok, acc}

  defp parse_all([{name, bytes} | rest], acc) do
    file = to_string(name)

    case parse(bytes) do
      {:ok, entries} when not is_map_key(acc, file) ->
        parse_all(rest, Map.put(acc, file, entries))

      _ ->
        :error
    end
  end

  @doc """
  The regular members of a gzip tar `archive`, path => SHA-256, read in
  memory with at most 128 MiB compressed and 256 MiB inflated.
  """
  @spec members(term()) :: {:ok, %{String.t() => String.t()}} | :error
  def members(archive) when is_binary(archive) and byte_size(archive) <= @max_archive_bytes do
    with {:ok, tar} <- StaticPriv.inflate(archive, @max_archive_inflated),
         {:ok, files} <- :erl_tar.extract({:binary, tar}, [:memory]) do
      {:ok, Map.new(files, fn {name, bytes} -> {to_string(name), sha256(bytes)} end)}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def members(_archive), do: :error

  @doc """
  The origin of every native file in `files` (`%{"path", "sha256"}`), from
  the `checksums` (`checksum_files/1`) and the candidate `archives` (name =>
  bytes): `{:ok, origins}` when each file is a member of an archive whose
  bytes have the sum a checksum file lists for its name, else
  `{:error, reason}` naming the first file that is not.
  """
  @spec verify([map()], map(), %{String.t() => binary()}) ::
          {:ok, [origin()]} | {:error, String.t()}
  def verify(files, checksums, archives) do
    verified = verified_archives(checksums, archives)

    files
    |> Enum.sort_by(& &1["path"])
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
      case origin(file, verified) do
        nil -> {:halt, {:error, @refusal <> to_string(file["path"])}}
        origin -> {:cont, {:ok, [origin | acc]}}
      end
    end)
    |> then(fn
      {:ok, origins} -> {:ok, Enum.reverse(origins)}
      error -> error
    end)
  end

  defp origin(file, verified) do
    case Enum.find(verified, fn {_name, _file, _sum, members} -> file["sha256"] in members end) do
      {name, checksum_file, sum, _members} ->
        %{
          "path" => file["path"],
          "checksum_file" => checksum_file,
          "archive" => name,
          "archive_sha256" => sum
        }

      nil ->
        nil
    end
  end

  # `{name, checksum_file, sum, member_sums}` for every candidate archive a
  # checksum file lists with exactly its bytes' sum, by name.
  defp verified_archives(checksums, archives) do
    for {name, bytes} <- Enum.sort(archives),
        is_binary(bytes),
        sum = sha256(bytes),
        checksum_file = listing(checksums, name, sum),
        checksum_file != nil,
        {:ok, members} <- [members(bytes)],
        do: {name, checksum_file, sum, Map.values(members)}
  end

  defp listing(checksums, name, sum) do
    checksums
    |> Enum.sort()
    |> Enum.find_value(fn {file, entries} -> if entries[name] == sum, do: file end)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
