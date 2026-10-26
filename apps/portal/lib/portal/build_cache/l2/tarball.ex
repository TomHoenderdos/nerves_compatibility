defmodule Portal.BuildCache.L2.Tarball do
  @moduledoc """
  One build cache entry as a gzip tarball, and back.

  `pack/3` is what a home host uploads after a promotion; `unpack/2` is what
  it extracts before a build. Both ends apply the same structural rules as
  `Portal.BuildCache.Promotion` (through `Portal.BuildCache.Tree`): only
  directories, regular files with one link, and Mix's own top-level
  `priv`/`include` links. On the way in the tar table is screened before a
  single byte is extracted: `:erl_tar` refuses escaping paths and symlinks
  itself (`safe_relative_path`) and ignores hard-link entries, but writes
  device and fifo entries as empty regular files, which the walk afterwards
  could not tell from real ones. gzip rather than zstd so the portal needs
  no NIF for a few megabytes per entry (spec, section 3.2).
  """

  alias Portal.BuildCache.Tree

  @max_object_bytes 512 * 1024 * 1024
  @max_depth 64
  @allowed_types [:regular, :directory, :symlink]

  @spec max_object_bytes() :: pos_integer()
  def max_object_bytes, do: @max_object_bytes

  # `entry_dir` is a promoted entry under the operator's cache root;
  # `tar_path` its sibling staging name.
  # sobelow_skip ["Traversal.FileModule"]
  @spec pack(Path.t(), Path.t(), String.t() | :any) ::
          {:ok, %{sha256: String.t(), bytes: non_neg_integer()}} | {:error, term()}
  def pack(entry_dir, tar_path, package) do
    with :ok <- Tree.check(entry_dir, package: package),
         {:ok, names} <- top_level(entry_dir),
         :ok <-
           create(
             tar_path,
             Enum.map(
               names,
               &{String.to_charlist(&1), String.to_charlist(Path.join(entry_dir, &1))}
             )
           ),
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

  defp create(tar_path, members) do
    case :erl_tar.create(String.to_charlist(tar_path), members, [:compressed]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:tar, reason}}
    end
  end

  defp bounded(bytes) when bytes > @max_object_bytes, do: {:error, :too_large}
  defp bounded(_), do: :ok

  # `:erl_tar` refuses every symlink whose target leaves the extraction
  # directory (`unsafe_symlink`), and Mix's own `priv` link does exactly that,
  # so links are not extracted by `:erl_tar`: everything else is, and the links
  # are created from the archive's own headers afterwards, each checked by
  # `Tree.check/2` against Mix's link shape like any other entry.
  @spec unpack(Path.t(), Path.t()) :: :ok | {:error, term()}
  def unpack(tar_path, staging_dir) do
    with {:ok, table} <- table(tar_path),
         :ok <- screen(table),
         {:ok, links} <- links(tar_path, table),
         :ok <-
           extract(
             tar_path,
             staging_dir,
             for({name, type, _, _, _, _, _} <- table, type != :symlink, do: name)
           ),
         :ok <- link(staging_dir, links),
         :ok <- refusal(Tree.check(staging_dir, package: :any)) do
      Tree.strip_modes(staging_dir)
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

  defp extract(tar_path, staging_dir, names) do
    opts = [:compressed, {:cwd, String.to_charlist(staging_dir)}, {:files, names}]

    case :erl_tar.extract(String.to_charlist(tar_path), opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:tar, reason}}
    end
  end

  # The symlink members as `{name, target}`, read from the ustar headers
  # because the table does not carry targets. The names must be exactly the
  # table's symlinks, so a header this reader and `:erl_tar` disagree on
  # (pax or GNU extensions) is refused rather than guessed at.
  defp links(tar_path, table) do
    wanted = for {name, :symlink, _, _, _, _, _} <- table, do: name

    if wanted == [] do
      {:ok, []}
    else
      links = tar_path |> gunzip() |> header_links([])

      if Enum.sort(Enum.map(links, &elem(&1, 0))) == Enum.sort(wanted),
        do: {:ok, links},
        else: {:error, {:member_name, "symlink headers"}}
    end
  end

  # `tar_path` is a host-built staging name.
  # sobelow_skip ["Traversal.FileModule"]
  defp gunzip(tar_path), do: tar_path |> File.read!() |> :zlib.gunzip()

  defp header_links(<<header::binary-size(512), rest::binary>>, acc) do
    <<name::binary-size(100), _::binary-size(24), size::binary-size(12), _::binary-size(20), type,
      linkname::binary-size(100), _::binary-size(88), prefix::binary-size(155), _::binary>> =
      header

    case octal(size) do
      nil ->
        acc

      bytes ->
        skip = min(div(bytes + 511, 512) * 512, byte_size(rest))
        <<_::binary-size(^skip), rest::binary>> = rest

        acc =
          if type == ?2, do: [{join(trim(prefix), trim(name)), trim(linkname)} | acc], else: acc

        header_links(rest, acc)
    end
  end

  defp header_links(_end, acc), do: acc

  defp octal(field) do
    case field |> trim() |> String.trim() |> Integer.parse(8) do
      {n, ""} -> n
      _ -> if String.trim(trim(field)) == "", do: 0
    end
  end

  defp trim(field), do: field |> :binary.split(<<0>>) |> hd()
  defp join("", name), do: String.to_charlist(name)
  defp join(prefix, name), do: String.to_charlist(prefix <> "/" <> name)

  # The target is only a string here; `Tree.check/2` decides whether it is
  # Mix's link. `staging_dir` and the names are host-built or screened.
  # sobelow_skip ["Traversal.FileModule"]
  defp link(staging_dir, links) do
    Enum.reduce_while(links, :ok, fn {name, target}, :ok ->
      path = Path.join(staging_dir, List.to_string(name))

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.ln_s(target, path) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:tar, reason}}}
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
