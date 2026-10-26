defmodule Portal.BuildCache.L2.Tarball do
  @moduledoc """
  One build cache entry as a gzip tarball, and back.

  `pack/3` is what a home host uploads after a promotion; `unpack/2` is what
  it extracts before a build. Both ends apply the same structural rules as
  `Portal.BuildCache.Promotion` (through `Portal.BuildCache.Tree`): only
  directories, regular files with one link, and Mix's own top-level
  `priv`/`include` links.

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

  alias Portal.BuildCache.Tree

  @max_object_bytes 512 * 1024 * 1024
  @max_extracted_bytes 2 * 1024 * 1024 * 1024
  @max_depth 64
  @max_manifest_bytes 4096
  @manifest ".ncc-links.json"
  @allowed_types [:regular, :directory]
  @link_target ~r/\A\.\.\/\.\.\/\.\.\/\.\.\/deps(_[a-z0-9_]+)?\/[a-z][a-z0-9_]*\/(priv|include)\z/

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
  Extracts `tar_path` into `staging_dir`. Option `:max_extracted_bytes` bounds
  the sum of the members' sizes (default `max_extracted_bytes/0`).
  """
  @spec unpack(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def unpack(tar_path, staging_dir, opts \\ []) do
    max = Keyword.get(opts, :max_extracted_bytes, @max_extracted_bytes)

    with {:ok, table} <- table(tar_path),
         :ok <- screen(table),
         :ok <- extracted_size(table, max),
         :ok <- extract(tar_path, staging_dir),
         :ok <- restore_links(staging_dir),
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
          File.rm(path)
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
    if link_target?(name, target),
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

  defp link_target?(name, target) when is_binary(target) do
    match?([_, _, ^name], Regex.run(@link_target, target))
  end

  defp link_target?(_name, _target), do: false

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
