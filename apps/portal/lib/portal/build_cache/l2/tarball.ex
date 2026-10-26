defmodule Portal.BuildCache.L2.Tarball do
  @moduledoc """
  One build cache entry as a gzip tarball, and back.

  `pack/3` is what a home host uploads after a promotion; `unpack/3` is what
  it extracts before a build. Both ends apply the same structural rules as
  `Portal.BuildCache.Promotion` (through `Portal.BuildCache.Tree`): only
  directories, regular files with one link, and Mix's own top-level
  `priv`/`include` links.

  ## Bounds on the way in

  An object from the bucket is hostile input until proven otherwise, and two
  shapes of it would cost the node far more than the object's size:

    * a gzip bomb, a few megabytes that inflate to gigabytes. Before
      `:erl_tar` sees the file, a streaming pre-scan inflates it with `:zlib`
      in bounded pieces, counting the output and discarding it, and refuses
      it (`{:error, :too_large}`) as soon as the count passes
      `max_extracted_bytes/0` (1 GiB). A stream that does not inflate is
      `{:error, {:gzip, reason}}`. The pre-scan reads one gzip member, as
      `:erl_tar` does (`compressed_one`), and refuses a file that is not
      gzip at all, which `:erl_tar` would otherwise read as a plain tar.
    * a header flood, millions of empty members, which `:erl_tar.table/2`
      would turn into a member list of hundreds of megabytes. Everything
      after the pre-scan (table, screen, extraction, manifest, modes, walk)
      runs in `Portal.BuildCache.L2.Bounded`, a separate unlinked process
      with a heap cap and a deadline, so the worst it can do is be killed:
      `{:error, {:unpack, :killed}}` or `{:error, {:unpack, :timeout}}`.

  The pre-scan bounds the tar stream at 1 GiB, which also bounds the header
  count (two million per GiB); the heap cap bounds what those headers cost.

  The tarball carries no symlink member at all. `:erl_tar` refuses a symlink
  whose target leaves the extraction directory, which Mix's own links do, and
  its path safety is what spec section 5.2 relies on, so the links travel as a
  small regular file, `.ncc-links.json` (`{"priv": "<target>"}`), and `unpack/3`
  recreates them after extraction from a validated manifest. On the way in the
  tar table is screened before a single byte is extracted: only regular files
  and directories, safe names, and a bounded total size. `:erl_tar` writes
  device and fifo entries as empty regular files, which the walk afterwards
  could not tell from real ones, and ignores hard-link entries. gzip rather
  than zstd so the portal needs no NIF for a few megabytes per entry (spec,
  section 3.2).
  """

  alias Portal.BuildCache.L2.Bounded
  alias Portal.BuildCache.Tree

  @max_object_bytes 512 * 1024 * 1024
  @max_extracted_bytes 1024 * 1024 * 1024
  @unpack_timeout_ms 120_000
  @prescan_chunk_bytes 1024 * 1024
  @max_depth 64
  @max_manifest_bytes 4096
  @manifest ".ncc-links.json"
  @allowed_types [:regular, :directory]

  @spec max_object_bytes() :: pos_integer()
  def max_object_bytes, do: @max_object_bytes

  @spec max_extracted_bytes() :: pos_integer()
  def max_extracted_bytes, do: @max_extracted_bytes

  # `entry_dir` is a promoted entry under the operator's cache root;
  # `tar_path` its sibling staging name.
  # sobelow_skip ["Traversal.FileModule"]
  @spec pack(Path.t(), Path.t(), String.t() | :any) ::
          {:ok, %{sha256: String.t(), bytes: non_neg_integer()}} | {:error, term()}
  def pack(entry_dir, tar_path, package) do
    with :ok <- Tree.check(entry_dir, package: package),
         {:ok, names} <- top_level(entry_dir),
         {:ok, files, links} <- split_links(entry_dir, names),
         :ok <- create(tar_path, members(entry_dir, files, links)),
         {:ok, %File.Stat{size: bytes}} <- File.stat(tar_path),
         :ok <- bounded(bytes) do
      {:ok, %{sha256: sha256_file(tar_path), bytes: bytes}}
    else
      {:error, _} = error ->
        _ = File.rm(tar_path)
        error
    end
  end

  defp top_level(dir) do
    case :file.list_dir_all(dir) do
      {:ok, []} ->
        {:error, :empty_entry}

      {:ok, raw} ->
        Enum.reduce_while(raw, {:ok, []}, &collect_name/2)

      {:error, reason} ->
        {:error, {:list, reason}}
    end
  end

  defp collect_name(name, {:ok, acc}) do
    case Tree.name_string(name) do
      {:ok, s} -> {:cont, {:ok, [s | acc]}}
      :error -> {:halt, {:error, {:bad_name, name}}}
    end
  end

  # `Tree.check/2` has already proven every top-level link is Mix's own.
  # sobelow_skip ["Traversal.FileModule"]
  defp split_links(dir, names) do
    if @manifest in names,
      do: {:error, {:reserved_name, @manifest}},
      else: split_links_checked(dir, names)
  end

  defp split_links_checked(dir, names) do
    {links, files} =
      Enum.split_with(names, fn name ->
        match?({:ok, %File.Stat{type: :symlink}}, File.lstat(Path.join(dir, name)))
      end)

    with [_ | _] <- files,
         {:ok, targets} <- read_links(dir, links) do
      {:ok, files, targets}
    else
      [] -> {:error, :empty_entry}
      {:error, _} = error -> error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_links(dir, links) do
    Enum.reduce_while(links, {:ok, %{}}, fn name, {:ok, acc} ->
      case File.read_link(Path.join(dir, name)) do
        {:ok, target} -> {:cont, {:ok, Map.put(acc, name, target)}}
        {:error, reason} -> {:halt, {:error, {:list, reason}}}
      end
    end)
  end

  defp members(dir, files, links) do
    members = Enum.map(files, &{String.to_charlist(&1), String.to_charlist(Path.join(dir, &1))})

    if links == %{},
      do: members,
      else: members ++ [{String.to_charlist(@manifest), Jason.encode!(links)}]
  end

  defp create(tar_path, members) do
    case :erl_tar.create(String.to_charlist(tar_path), members, [:compressed]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:tar, reason}}
    end
  end

  defp bounded(bytes) when bytes > @max_object_bytes, do: {:error, :too_large}
  defp bounded(_), do: :ok

  @doc """
  Extracts `tar_path` into `staging_dir`, returning the tar stream's
  decompressed size. Options: `:max_extracted_bytes` bounds the decompressed
  size (default `max_extracted_bytes/0`), `:timeout_ms` (default 120 s) and
  `:max_heap_bytes` (default `Bounded.default_max_heap_bytes/0`) bound the
  process that reads the table and extracts.
  """
  @spec unpack(Path.t(), Path.t(), keyword()) ::
          {:ok, %{extracted_bytes: non_neg_integer()}} | {:error, term()}
  def unpack(tar_path, staging_dir, opts \\ []) do
    max = Keyword.get(opts, :max_extracted_bytes, @max_extracted_bytes)

    with {:ok, bytes} <- prescan(tar_path, max),
         :ok <- bounded_unpack(tar_path, staging_dir, max, opts) do
      {:ok, %{extracted_bytes: bytes}}
    end
  end

  defp bounded_unpack(tar_path, staging_dir, max, opts) do
    bound = [
      timeout_ms: Keyword.get(opts, :timeout_ms, @unpack_timeout_ms),
      max_heap_bytes: Keyword.get(opts, :max_heap_bytes, Bounded.default_max_heap_bytes())
    ]

    case Bounded.run(fn -> extract_checked(tar_path, staging_dir, max) end, bound) do
      {:ok, result} -> result
      {:error, reason} -> {:error, {:unpack, reason}}
    end
  end

  defp extract_checked(tar_path, staging_dir, max) do
    # Modes are stripped before the walk: an archive-applied 0o000 directory
    # could not be listed otherwise. `strip_modes/1` follows no link, and the
    # screened archive held none; the manifest's links come after it.
    with {:ok, table} <- table(tar_path),
         :ok <- screen(table),
         :ok <- extracted_size(table, max),
         :ok <- extract(tar_path, staging_dir),
         :ok <- staging_dir |> Tree.strip_modes() |> refusal(),
         :ok <- restore_links(staging_dir),
         :ok <- refusal(Tree.check(staging_dir, package: :any)) do
      if any_regular_file?(staging_dir), do: :ok, else: {:error, :empty_entry}
    end
  end

  # Inflates the file in bounded pieces, counting and discarding the output,
  # and stops as soon as the count passes `max`. One gzip member, as
  # `:erl_tar` reads it (`compressed_one`); anything after it is ignored by
  # both. `tar_path` is a host-built staging name.
  # sobelow_skip ["Traversal.FileModule"]
  defp prescan(tar_path, max) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 31)

      case File.open(tar_path, [:read, :binary, :raw], &prescan_file(&1, z, max)) do
        {:ok, result} -> result
        {:error, reason} -> {:error, {:gzip, reason}}
      end
    after
      :zlib.close(z)
    end
  end

  defp prescan_file(io, z, max) do
    with {:ok, total} <- prescan_chunks(io, z, 0, max),
         :ok <- inflate_end(z) do
      {:ok, total}
    end
  end

  defp prescan_chunks(io, z, total, max) do
    case IO.binread(io, @prescan_chunk_bytes) do
      :eof ->
        {:ok, total}

      {:error, reason} ->
        {:error, {:gzip, reason}}

      chunk ->
        case inflate_counting(z, :zlib.safeInflate(z, chunk), total, max) do
          {:ok, total} -> prescan_chunks(io, z, total, max)
          error -> error
        end
    end
  catch
    :error, reason -> {:error, {:gzip, reason}}
  end

  defp inflate_counting(z, {:continue, out}, total, max) do
    total = total + IO.iodata_length(out)

    if total > max,
      do: {:error, :too_large},
      else: inflate_counting(z, :zlib.safeInflate(z, []), total, max)
  end

  defp inflate_counting(_z, {:finished, out}, total, max) do
    total = total + IO.iodata_length(out)
    if total > max, do: {:error, :too_large}, else: {:ok, total}
  end

  defp inflate_counting(_z, {:need_dictionary, _, _}, _total, _max),
    do: {:error, {:gzip, :need_dictionary}}

  # Raises `data_error` when the stream did not end: a truncated object.
  defp inflate_end(z) do
    :zlib.inflateEnd(z)
  catch
    :error, reason -> {:error, {:gzip, reason}}
  end

  # The pack side's `:empty_entry` rule: at least one regular file somewhere.
  # Runs after `Tree.check/2`, on a tree of directories, regular files and
  # Mix's two links. `dir` is under the host-built staging dir.
  # sobelow_skip ["Traversal.FileModule"]
  defp any_regular_file?(dir) do
    case :file.list_dir_all(dir) do
      {:ok, names} -> Enum.any?(names, &regular_below?(Path.join(dir, IO.chardata_to_string(&1))))
      {:error, _} -> false
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp regular_below?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> true
      {:ok, %File.Stat{type: :directory}} -> any_regular_file?(path)
      _ -> false
    end
  end

  defp table(tar_path) do
    case :erl_tar.table(String.to_charlist(tar_path), [:compressed, :verbose]) do
      {:ok, []} -> {:error, :empty_archive}
      {:ok, entries} -> {:ok, entries}
      {:error, reason} -> {:error, {:tar, reason}}
    end
  end

  defp screen(entries) do
    Enum.reduce_while(entries, :ok, fn {name, type, _size, _mtime, _mode, _uid, _gid}, :ok ->
      cond do
        type not in @allowed_types -> {:halt, {:error, {:member_type, type, safe_show(name)}}}
        not safe_member_name?(name, type) -> {:halt, {:error, {:member_name, safe_show(name)}}}
        true -> {:cont, :ok}
      end
    end)
  end

  # The name as erl_tar reports it, a charlist; refused unless it is UTF-8,
  # relative, free of empty, `.` and `..` components and NULs, and shallow.
  defp safe_member_name?(raw, type) do
    case to_utf8(raw) do
      {:ok, name} -> member_name_ok?(name, type)
      _ -> false
    end
  end

  defp member_name_ok?(name, type) do
    name = if type == :directory, do: String.trim_trailing(name, "/"), else: name
    parts = String.split(name, "/")

    name != "" and not String.starts_with?(name, "/") and not String.contains?(name, <<0>>) and
      length(parts) <= @max_depth and Enum.all?(parts, &(&1 not in ["", ".", ".."]))
  end

  defp to_utf8(raw) when is_list(raw) do
    case :unicode.characters_to_binary(raw) do
      bin when is_binary(bin) -> if String.valid?(bin), do: {:ok, bin}, else: :error
      _ -> :error
    end
  end

  defp to_utf8(raw) when is_binary(raw), do: if(String.valid?(raw), do: {:ok, raw}, else: :error)

  defp safe_show(raw), do: inspect(raw, printable_limit: 200)

  defp extracted_size(entries, max) do
    total = Enum.reduce(entries, 0, fn {_, _, size, _, _, _, _}, sum -> sum + size end)
    if total > max, do: {:error, :too_large}, else: :ok
  end

  defp extract(tar_path, staging_dir) do
    case :erl_tar.extract(String.to_charlist(tar_path), [
           :compressed,
           {:cwd, String.to_charlist(staging_dir)}
         ]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:tar, reason}}
    end
  end

  # The top-level manifest never survives: read, validated, turned into the
  # links, deleted. `staging_dir` is a host-built staging name.
  # sobelow_skip ["Traversal.FileModule"]
  defp restore_links(staging_dir) do
    path = Path.join(staging_dir, @manifest)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_manifest_bytes ->
        with {:ok, links} <- read_manifest(path),
             :ok <- validate_links(staging_dir, links),
             :ok <- create_links(staging_dir, links) do
          remove_manifest(path)
        end

      {:ok, %File.Stat{type: :regular}} ->
        {:error, {:links, :too_large}}

      {:ok, %File.Stat{}} ->
        {:error, {:links, :not_a_file}}

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:links, reason}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp remove_manifest(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:links, reason}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_manifest(path) do
    with {:ok, json} <- File.read(path),
         {:ok, links} when is_map(links) <- Jason.decode(json) do
      {:ok, links}
    else
      _ -> {:error, {:links, :not_a_map}}
    end
  end

  defp validate_links(staging_dir, links) do
    Enum.reduce_while(links, :ok, fn {name, target}, :ok ->
      case validate_link(staging_dir, name, target) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:links, reason}}}
      end
    end)
  end

  defp validate_link(staging_dir, name, target) when name in ["priv", "include"] do
    if Tree.mix_link?(name, target, :any),
      do: absent(staging_dir, name),
      else: {:error, {:bad_target, Tree.show(target)}}
  end

  defp validate_link(_staging_dir, name, _target), do: {:error, {:bad_name, Tree.show(name)}}

  # The link name must not already exist in what was extracted.
  # sobelow_skip ["Traversal.FileModule"]
  defp absent(staging_dir, name) do
    case File.lstat(Path.join(staging_dir, name)) do
      {:error, :enoent} -> :ok
      _ -> {:error, {:exists, name}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp create_links(staging_dir, links) do
    Enum.reduce_while(links, :ok, fn {name, target}, :ok ->
      case File.ln_s(target, Path.join(staging_dir, name)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:links, reason}}}
      end
    end)
  end

  defp refusal(:ok), do: :ok
  defp refusal({:error, reason}), do: {:error, {:structure, reason}}

  @spec sha256_file(Path.t()) :: String.t()
  # sobelow_skip ["Traversal.FileModule"]
  def sha256_file(path) do
    path
    |> File.stream!(1024 * 1024, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
