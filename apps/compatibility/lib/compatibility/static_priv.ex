defmodule Compatibility.StaticPriv do
  @moduledoc """
  Whether a package's priv files are static data its own Hex tarball carries,
  so a toolchain build may publish them to every OS and architecture.

  One rule set with two callers. The worker judges the built `priv` inside
  the build container (`NccWorker.StaticPriv`), and the portal judges the
  build's manifest again on the host at ingest
  (`Portal.Catalog.ToolchainPriv`), against a tarball it fetched itself,
  because a process the build left behind could still change the files after
  the worker looked. Both read the files and the tarball into memory first and
  hand them here; nothing in this module touches the filesystem.

  A priv file is static only when it is:

    * not executable (its own mode)
    * in the tarball's `contents.tar.gz` at `priv/<path>`, exactly once, as a
      regular entry that is not executable
    * byte for byte that entry
    * not native code by name (`.so`, `.dylib`, `.dll`, `.a`, `.o`, `.node`,
      a versioned `.so.N`) or by magic (ELF, Mach-O thin in both widths and
      byte orders, fat in both byte orders, PE, `ar`)

  and the files hold at most 500 files and 10 MiB together, which bounds what
  is read and what a client downloads.

  The tarball is bounded before it is unpacked, since anyone can publish one:
  at most 8 MiB as served, a `contents.tar.gz` that inflates to at most
  64 MiB, counted on the bytes actually inflated (`inflate/2`) and not on what
  the tar headers declare, and at most 20,000 tar entries, counted before
  `:erl_tar` lists them. No Hex package with a publishable priv comes near
  any of these; `hex_core` itself reads tarballs of up to 16 MiB that inflate
  to 128 MiB. Anything that cannot be read or judged is not static.
  """

  import Bitwise

  @max_files 500
  @max_bytes 10 * 1024 * 1024
  @max_tarball_bytes 8 * 1024 * 1024
  @max_contents_bytes 64 * 1024 * 1024
  @max_entries 20_000
  # The most one `:zlib.safeInflate/2` call returns, with room to spare: it
  # stops once it has passed a small threshold (16 KiB on OTP 28).
  @inflate_chunk_bytes 64 * 1024

  @native_extensions ~w(.so .dylib .dll .a .o .node)
  @native_magics [
    <<0x7F, "ELF">>,
    <<0xFE, 0xED, 0xFA, 0xCE>>,
    <<0xCE, 0xFA, 0xED, 0xFE>>,
    <<0xFE, 0xED, 0xFA, 0xCF>>,
    <<0xCF, 0xFA, 0xED, 0xFE>>,
    <<0xCA, 0xFE, 0xBA, 0xBE>>,
    <<0xBE, 0xBA, 0xFE, 0xCA>>,
    "MZ",
    "!<arch>\n"
  ]

  @typedoc "A priv file: its path below `priv`, its mode and its bytes."
  @type file :: %{path: String.t(), mode: non_neg_integer(), bytes: binary()}

  @typedoc """
  Why a build's priv is not static. The reason names what failed and is fit
  for a build's stored reason; the details carry the file's `:path` and, for
  a file that differs from the tarball's, the `:expected` (the tarball's) and
  `:actual` SHA-256, for a log line.
  """
  @type refusal :: {:error, String.t(), keyword()}

  @doc "The most priv files a build may publish."
  @spec max_files() :: pos_integer()
  def max_files, do: @max_files

  @doc "The most priv bytes a build may publish, all files together."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The largest Hex tarball, as served, that is read at all."
  @spec max_tarball_bytes() :: pos_integer()
  def max_tarball_bytes, do: @max_tarball_bytes

  @doc "The most one `inflate/2` step can overrun its cap by."
  @spec inflate_chunk_bytes() :: pos_integer()
  def inflate_chunk_bytes, do: @inflate_chunk_bytes

  @doc """
  `:ok` when every one of `files` is static data the Hex `tarball` (its
  bytes) carries; a `t:refusal/0` otherwise. A `nil` tarball is one the
  caller could not find or trust, and refuses any file. No files need no
  tarball.
  """
  @spec check([file()], binary() | nil) :: :ok | refusal()
  def check(files, tarball) do
    with :ok <- within_caps(Enum.map(files, &{&1.path, byte_size(&1.bytes)})),
         :ok <- no_native_names(Enum.map(files, & &1.path)),
         :ok <- not_executable(files),
         {:ok, entries} <- tarball_entries(tarball, Enum.map(files, & &1.path)) do
      Enum.find_value(files, :ok, &refused(same_as_tarball(&1, entries)))
    end
  end

  defp refused(:ok), do: nil
  defp refused(refusal), do: refusal

  @doc """
  The file-count and size caps on `{path, size}` pairs, for a caller that
  wants to refuse before it reads the files.
  """
  @spec within_caps([{String.t(), non_neg_integer()}]) :: :ok | refusal()
  def within_caps(sizes) do
    cond do
      length(sizes) > @max_files -> too_many()
      sizes |> Enum.map(&elem(&1, 1)) |> Enum.sum() > @max_bytes -> too_large()
      true -> :ok
    end
  end

  @doc "The refusal for more than `max_files/0` priv files."
  @spec too_many() :: refusal()
  def too_many, do: {:error, "ships more than #{@max_files} priv files", []}

  @doc "The refusal for more than `max_bytes/0` of priv files."
  @spec too_large() :: refusal()
  def too_large, do: {:error, "ships more than 10 MiB of priv files", []}

  @doc "Whether a priv path names native code (`.so`, `.dylib`, ...)."
  @spec native_name?(String.t()) :: boolean()
  def native_name?(path) do
    name = Path.basename(path)
    Path.extname(name) in @native_extensions or Regex.match?(~r/\.so(\.\d+)+\z/, name)
  end

  defp no_native_names(paths) do
    case Enum.find(paths, &native_name?/1) do
      nil -> :ok
      path -> native(path)
    end
  end

  defp native(path), do: {:error, "ships native code in priv (priv/#{path})", path: path}

  @doc "Whether a file mode has any execute bit."
  @spec executable?(non_neg_integer()) :: boolean()
  def executable?(mode), do: (mode &&& 0o111) != 0

  defp not_executable(files) do
    case Enum.find(files, &executable?(&1.mode)) do
      nil -> :ok
      %{path: path} -> executable(path)
    end
  end

  defp executable(path), do: {:error, "ships an executable priv file (priv/#{path})", path: path}

  @doc """
  Inflates the gzip stream `gz`, stopping as soon as more than `max_bytes`
  came out: `{:ok, bytes}`, `{:error, {:over_cap, inflated}}` with the bytes
  inflated by then (at most `max_bytes + inflate_chunk_bytes/0`), or
  `{:error, :corrupt}`. Trailing bytes after the stream are ignored.
  """
  @spec inflate(binary(), non_neg_integer()) ::
          {:ok, binary()} | {:error, {:over_cap, non_neg_integer()} | :corrupt}
  def inflate(gz, max_bytes) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 31)
      inflate_loop(z, :zlib.safeInflate(z, gz), [], 0, max_bytes)
    catch
      _kind, _reason -> {:error, :corrupt}
    after
      :zlib.close(z)
    end
  end

  defp inflate_loop(z, {state, out}, acc, size, max_bytes) when state in [:continue, :finished] do
    size = size + IO.iodata_length(out)
    acc = [acc, out]

    cond do
      size > max_bytes -> {:error, {:over_cap, size}}
      state == :finished -> {:ok, IO.iodata_to_binary(acc)}
      true -> inflate_loop(z, :zlib.safeInflate(z, []), acc, size, max_bytes)
    end
  end

  defp inflate_loop(_z, _other, _acc, _size, _max_bytes), do: {:error, :corrupt}

  # The tarball's entries at the files' `priv/` paths, as
  # `path => {type, mode, bytes}` (bytes only for a regular entry), or a
  # refusal for a tarball that is too large, malformed or not there.
  defp tarball_entries(_tarball, []), do: {:ok, %{}}
  defp tarball_entries(nil, _paths), do: unchecked()

  defp tarball_entries(tarball, _paths) when byte_size(tarball) > @max_tarball_bytes,
    do: {:error, "ships priv files whose Hex tarball is over 8 MiB", []}

  defp tarball_entries(tarball, paths) do
    wanted = MapSet.new(paths, &("priv/" <> &1))

    with {:ok, gz} <- contents_tar(tarball),
         {:ok, tar} <- inflate_contents(gz),
         :ok <- count_entries(tar),
         {:ok, table} <- :erl_tar.table({:binary, tar}, [:verbose]) do
      table
      |> Enum.flat_map(&wanted_entry(&1, wanted))
      |> once_each()
      |> with_bytes(tar)
    else
      {:error, _reason, _details} = refusal -> refusal
      _ -> unchecked()
    end
  rescue
    _ -> unchecked()
  end

  # A Hex tarball is an outer tar of `VERSION`, `CHECKSUM`, `metadata.config`
  # and `contents.tar.gz`, the package's files. The outer tar is not
  # compressed, so it is no larger than the tarball.
  defp contents_tar(tarball) do
    case :erl_tar.extract({:binary, tarball}, [:memory, {:files, [~c"contents.tar.gz"]}]) do
      {:ok, [{_name, contents}]} -> {:ok, contents}
      _ -> :error
    end
  end

  defp inflate_contents(gz) do
    case inflate(gz, @max_contents_bytes) do
      {:ok, tar} ->
        {:ok, tar}

      {:error, {:over_cap, _inflated}} ->
        {:error, "ships priv files whose Hex tarball inflates to over 64 MiB", []}

      {:error, :corrupt} ->
        :error
    end
  end

  # Walks the tar's 512-byte headers by the sizes they declare, which is how
  # `:erl_tar` walks them too, and stops counting past the cap. The inflated
  # size is already bounded, so this is at most a few hundred thousand steps.
  defp count_entries(tar), do: count_entries(tar, 0, 0)

  defp count_entries(_tar, _offset, count) when count > @max_entries,
    do: {:error, "ships priv files whose Hex tarball has over #{@max_entries} entries", []}

  defp count_entries(tar, offset, count) when byte_size(tar) - offset >= 512 do
    case binary_part(tar, offset, 512) do
      <<0::4096>> ->
        :ok

      header ->
        case entry_size(binary_part(header, 124, 12)) do
          {:ok, size} -> count_entries(tar, offset + 512 + padded(size), count + 1)
          :error -> :error
        end
    end
  end

  defp count_entries(_tar, _offset, _count), do: :ok

  defp entry_size(field) do
    case field |> String.trim(<<0>>) |> String.trim() |> Integer.parse(8) do
      {size, ""} when size >= 0 -> {:ok, size}
      _ -> :error
    end
  end

  defp padded(size), do: div(size + 511, 512) * 512

  defp wanted_entry({name, type, _size, _mtime, mode, _uid, _gid}, wanted) do
    path = to_string(name)
    if MapSet.member?(wanted, path), do: [{path, {name, type, mode}}], else: []
  end

  defp wanted_entry(_entry, _wanted), do: []

  # A path the tarball holds twice could be read as either; it is neither.
  defp once_each(entries) do
    case entries |> Enum.frequencies_by(&elem(&1, 0)) |> Enum.find(&(elem(&1, 1) > 1)) do
      nil ->
        {:ok, Map.new(entries)}

      {"priv/" <> path, _count} ->
        {:error, "ships a priv file its Hex tarball carries twice (priv/#{path})", path: path}
    end
  end

  defp with_bytes({:ok, entries}, tar) do
    names = for {_path, {name, :regular, _mode}} <- entries, do: name

    with {:ok, extracted} <- extract(tar, names) do
      bytes = Map.new(extracted, fn {name, bytes} -> {to_string(name), bytes} end)

      {:ok,
       Map.new(entries, fn {path, {_name, type, mode}} ->
         {path, {type, mode, Map.get(bytes, path)}}
       end)}
    end
  end

  defp with_bytes(refusal, _tar), do: refusal

  defp extract(_tar, []), do: {:ok, []}

  defp extract(tar, names) do
    case :erl_tar.extract({:binary, tar}, [:memory, {:files, names}]) do
      {:ok, extracted} -> {:ok, extracted}
      _ -> :error
    end
  end

  defp unchecked,
    do: {:error, "ships priv files that could not be checked against its Hex tarball", []}

  defp same_as_tarball(%{path: path, bytes: bytes}, entries) do
    case Map.fetch(entries, "priv/" <> path) do
      :error ->
        {:error, "ships a priv file its Hex tarball does not carry (priv/#{path})", path: path}

      {:ok, {:regular, mode, expected}} when is_binary(expected) ->
        with :ok <- not_executable_in_tarball(mode, path),
             :ok <- same_bytes(bytes, expected, path) do
          native_magic(bytes, path)
        end

      {:ok, {_type, _mode, _bytes}} ->
        {:error, "ships a priv file that is not a regular file in its Hex tarball (priv/#{path})",
         path: path}
    end
  end

  defp not_executable_in_tarball(mode, path) do
    if executable?(mode), do: executable(path), else: :ok
  end

  defp same_bytes(same, same, _path), do: :ok

  defp same_bytes(bytes, expected, path) do
    {:error, "ships a priv file that differs from its Hex tarball's (priv/#{path})",
     path: path, expected: sha256(expected), actual: sha256(bytes)}
  end

  defp native_magic(bytes, path) do
    if Enum.any?(@native_magics, &String.starts_with?(bytes, &1)), do: native(path), else: :ok
  end

  @doc "The lowercase hex SHA-256 of `bytes`."
  @spec sha256(iodata()) :: String.t()
  def sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
