defmodule NccWorker.StaticPriv do
  @moduledoc """
  Whether a built package's `priv` is static data that is the same on every
  OS and architecture, so a toolchain build may publish it
  (`NccWorker.BuildSelection.portable?/4`).

  Native code is not the same everywhere, and neither is anything the build
  produced: a compile hook can write into `priv`, and a dependency's hook
  into the package's source dir as well as its build. So the reference is the
  package's own Hex tarball, never `deps/<package>`, and a priv file is static
  only when it is (under the build's `priv`, or the package's `deps` priv
  when Mix links it there):

    * a regular file with one link, not executable, here and in the tarball
    * in the tarball's `contents.tar.gz` at `priv/<path>`, byte for byte
    * not native code by name (`.so`, `.dylib`, `.dll`, `.a`, `.o`, `.node`,
      a versioned `.so.N`) or by magic (ELF, Mach-O thin and fat, PE, `ar`)

  and the whole `priv` holds at most 500 files and 10 MiB, which bounds
  what is read here and what a client downloads. Anything that cannot be read
  or judged, the tarball included, is not static. Every reason names what
  failed and differs from the bare "ships priv files" a build without a
  tarball to compare against gets, which the portal builds again.
  """

  import Bitwise

  @max_files 500
  @max_bytes 10 * 1024 * 1024

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

  @doc """
  `:ok` when every file under `priv_dir` (the built package's `priv`) is
  static data its Hex `tarball` carries, `{:skip, reason}` otherwise.
  `source_priv` is `deps/<package>/priv`, the one directory `priv_dir` may be
  a link to. A `nil` tarball is one the worker could not find or trust.
  """
  @spec check(Path.t(), Path.t(), Path.t() | nil) :: :ok | {:skip, String.t()}
  def check(priv_dir, source_priv, tarball) do
    with {:ok, root} <- priv_root(priv_dir, source_priv),
         {:ok, files} <- built_files(root),
         :ok <- within_caps(files),
         :ok <- no_native_names(files),
         {:ok, entries} <- tarball_entries(tarball, files) do
      Enum.find_value(files, :ok, &skip(same_as_tarball(root, &1, entries)))
    end
  end

  defp skip(:ok), do: nil
  defp skip(skip), do: skip

  # The directory the build's `priv` is. Mix links `_build/<env>/lib/<app>/priv`
  # to the dependency's own `priv` rather than copying it, so that one link is
  # followed, and only to `source_priv` as a real directory; everything under
  # it is judged with `lstat`. `nil` for a build without `priv`.
  # sobelow_skip ["Traversal.FileModule"]
  defp priv_root(priv_dir, source_priv) do
    case File.lstat(priv_dir) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, priv_dir}
      {:ok, %File.Stat{type: :symlink}} -> linked_root(priv_dir, source_priv)
      {:error, :enoent} -> {:ok, nil}
      _ -> {:skip, "priv could not be read"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp linked_root(priv_dir, source_priv) do
    with {:ok, target} <- File.read_link(priv_dir),
         root = Path.expand(target, Path.dirname(priv_dir)),
         true <- root == Path.expand(source_priv),
         true <- Enum.all?([Path.dirname(Path.dirname(root)), Path.dirname(root), root], &dir?/1) do
      {:ok, root}
    else
      false -> {:skip, "ships a priv linked outside the package's own priv"}
      _ -> {:skip, "priv could not be read"}
    end
  end

  # A real directory, not a link to one: `deps`, `deps/<package>` and its
  # `priv` all are, so the link resolves where its path says.
  # sobelow_skip ["Traversal.FileModule"]
  defp dir?(path), do: match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))

  # `{relative path, size}` of every file under `root`, read with `lstat` so a
  # link is seen as one.
  defp built_files(nil), do: {:ok, []}
  defp built_files(root), do: walk(root, "", [])

  # sobelow_skip ["Traversal.FileModule"]
  defp walk(root, relative, acc) do
    case File.ls(Path.join(root, relative)) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce_while({:ok, acc}, &walk_entry(root, join(relative, &1), &2))

      {:error, _reason} ->
        {:skip, "priv could not be read"}
    end
  end

  # Stops at the first file over the cap, so a huge priv is not walked whole.
  defp walk_entry(root, relative, {:ok, acc}) do
    case entry(root, relative, acc) do
      {:ok, acc} when length(acc) > @max_files -> {:halt, too_many()}
      {:ok, acc} -> {:cont, {:ok, acc}}
      skip -> {:halt, skip}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp entry(root, relative, acc) do
    case File.lstat(Path.join(root, relative)) do
      {:ok, %File.Stat{type: :directory}} ->
        walk(root, relative, acc)

      {:ok, %File.Stat{type: :regular, links: 1, mode: mode, size: size}} ->
        if executable?(mode),
          do: {:skip, "ships an executable priv file (priv/#{relative})"},
          else: {:ok, [{relative, size} | acc]}

      {:ok, %File.Stat{type: :regular}} ->
        {:skip, "ships a hard-linked priv file (priv/#{relative})"}

      {:ok, %File.Stat{}} ->
        {:skip, "ships a priv file that is not a regular file (priv/#{relative})"}

      {:error, _reason} ->
        {:skip, "priv could not be read"}
    end
  end

  defp join("", name), do: name
  defp join(relative, name), do: relative <> "/" <> name

  defp executable?(mode), do: (mode &&& 0o111) != 0

  defp within_caps(files) do
    cond do
      length(files) > @max_files ->
        too_many()

      files |> Enum.map(&elem(&1, 1)) |> Enum.sum() > @max_bytes ->
        {:skip, "ships more than 10 MiB of priv files"}

      true ->
        :ok
    end
  end

  defp too_many, do: {:skip, "ships more than #{@max_files} priv files"}

  defp no_native_names(files) do
    case Enum.find(files, fn {relative, _size} -> native_name?(relative) end) do
      nil -> :ok
      {relative, _size} -> native(relative)
    end
  end

  defp native_name?(relative) do
    name = Path.basename(relative)
    Path.extname(name) in @native_extensions or Regex.match?(~r/\.so(\.\d+)+\z/, name)
  end

  defp native(relative), do: {:skip, "ships native code in priv (priv/#{relative})"}

  # The tarball's regular `priv/` entries the build has, as
  # `path => {mode, contents}`, where the contents are `:differs` for an entry
  # whose size is not the built file's. Only same-size entries are extracted,
  # so a large tarball costs no more memory than the priv files already
  # capped above.
  defp tarball_entries(_tarball, []), do: {:ok, %{}}
  defp tarball_entries(nil, _files), do: unchecked()

  defp tarball_entries(tarball, files) do
    sizes = Map.new(files, fn {relative, size} -> {"priv/" <> relative, size} end)

    with {:ok, contents} <- contents_tar(tarball),
         {:ok, table} <- :erl_tar.table({:binary, contents}, [:compressed, :verbose]) do
      entries =
        for {name, :regular, size, _mtime, mode, _uid, _gid} <- table,
            path = to_string(name),
            Map.has_key?(sizes, path),
            into: %{},
            do: {path, {name, mode, Map.fetch!(sizes, path) == size}}

      extract(contents, entries)
    else
      _ -> unchecked()
    end
  rescue
    _ -> unchecked()
  end

  # A Hex tarball is an outer tar of `VERSION`, `CHECKSUM`, `metadata.config`
  # and `contents.tar.gz`, the package's files.
  defp contents_tar(tarball) do
    case :erl_tar.extract(String.to_charlist(tarball), [:memory, {:files, [~c"contents.tar.gz"]}]) do
      {:ok, [{_name, contents}]} -> {:ok, contents}
      _ -> :error
    end
  end

  defp extract(contents, entries) do
    names = for {_path, {name, _mode, true}} <- entries, do: name

    with {:ok, extracted} <- extract_names(contents, names) do
      bytes = Map.new(extracted, fn {name, bytes} -> {to_string(name), bytes} end)

      {:ok,
       Map.new(entries, fn {path, {_name, mode, _same_size?}} ->
         {path, {mode, Map.get(bytes, path, :differs)}}
       end)}
    end
  end

  defp extract_names(_contents, []), do: {:ok, []}

  defp extract_names(contents, names) do
    case :erl_tar.extract({:binary, contents}, [:compressed, :memory, {:files, names}]) do
      {:ok, extracted} -> {:ok, extracted}
      _ -> unchecked()
    end
  end

  defp unchecked,
    do: {:skip, "ships priv files that could not be checked against its Hex tarball"}

  # sobelow_skip ["Traversal.FileModule"]
  defp same_as_tarball(root, {relative, _size}, entries) do
    with {:ok, {mode, expected}} <- carried(Map.fetch(entries, "priv/" <> relative), relative),
         :ok <- not_executable_in_tarball(mode, relative),
         {:ok, bytes} <- read(root, relative),
         :ok <- same_bytes(bytes, expected, relative) do
      native_magic(bytes, relative)
    end
  end

  defp carried({:ok, entry}, _relative), do: {:ok, entry}

  defp carried(:error, relative),
    do: {:skip, "ships a priv file its Hex tarball does not carry (priv/#{relative})"}

  defp not_executable_in_tarball(mode, relative) do
    if executable?(mode),
      do: {:skip, "ships an executable priv file (priv/#{relative})"},
      else: :ok
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read(root, relative) do
    case File.read(Path.join(root, relative)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _reason} -> {:skip, "priv could not be read"}
    end
  end

  defp same_bytes(same, same, _relative), do: :ok

  defp same_bytes(_bytes, _expected, relative),
    do: {:skip, "ships a priv file that differs from its Hex tarball's (priv/#{relative})"}

  defp native_magic(bytes, relative) do
    if Enum.any?(@native_magics, &String.starts_with?(bytes, &1)),
      do: native(relative),
      else: :ok
  end
end
