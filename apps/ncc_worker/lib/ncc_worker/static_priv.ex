defmodule NccWorker.StaticPriv do
  @moduledoc """
  Whether a built package's `priv` is static data that is the same on every
  OS and architecture, so a toolchain build may publish it
  (`NccWorker.BuildSelection.portable?/4`).

  Native code is not the same everywhere, and neither is anything the build
  produced: a compile hook can write into `priv`, and a dependency's hook
  into the package's source dir as well as its build. So the reference is the
  package's own Hex tarball, never `deps/<package>`. The rules themselves are
  `Compatibility.StaticPriv`, which the portal applies again on the host at
  ingest; what is particular to the container is here: the files are read
  under the build's `priv`, or the package's `deps` priv when Mix links it
  there, and each is a regular file with one link and no execute bit by
  `lstat`, walked no further than the file cap. Only then are the files and
  the tarball read, each once, and judged.

  Anything that cannot be read or judged, the tarball included, is not
  static. Every reason names what failed and differs from the bare "ships
  priv files" a build without a tarball to compare against gets, which the
  portal builds again.
  """

  alias Compatibility.StaticPriv, as: Rules

  @doc """
  `:ok` when every file under `priv_dir` (the built package's `priv`) is
  static data its Hex `tarball` carries, `{:skip, reason}` otherwise.
  `source_priv` is `deps/<package>/priv`, the one directory `priv_dir` may be
  a link to. `tarball` is the tarball's path, or `{:binary, bytes}` for one
  already read (and checked against the lock, `NccWorker.HexCache.package_tarball/4`);
  `nil` is one the worker could not find or trust.
  """
  @spec check(Path.t(), Path.t(), Path.t() | {:binary, binary()} | nil) ::
          :ok | {:skip, String.t()}
  def check(priv_dir, source_priv, tarball) do
    with {:ok, root} <- priv_root(priv_dir, source_priv),
         {:ok, files} <- built_files(root),
         :ok <- rules(Rules.within_caps(Enum.map(files, &{&1.path, &1.size}))),
         {:ok, files} <- read_files(root, files) do
      if files == [], do: :ok, else: rules(Rules.check(files, tarball_bytes(tarball)))
    end
  end

  defp rules(:ok), do: :ok
  defp rules({:error, reason, _details}), do: {:skip, reason}

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

  # `%{path, size, mode}` of every file under `root`, read with `lstat` so a
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
    max_files = Rules.max_files()

    case entry(root, relative, acc) do
      {:ok, acc} when length(acc) > max_files -> {:halt, too_many()}
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
          else: {:ok, [%{path: relative, size: size, mode: mode} | acc]}

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

  defp executable?(mode), do: Rules.executable?(mode)

  defp too_many, do: rules(Rules.too_many())

  # Each file once, no more than its `lstat` size: one that grew since is not
  # the file that was walked.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_files(root, files) do
    Enum.reduce_while(files, {:ok, []}, fn %{path: relative, size: size, mode: mode},
                                           {:ok, acc} ->
      case File.open(Path.join(root, relative), [:read, :raw, :binary], &IO.binread(&1, size + 1)) do
        {:ok, bytes} when is_binary(bytes) and byte_size(bytes) == size ->
          {:cont, {:ok, [%{path: relative, mode: mode, bytes: bytes} | acc]}}

        {:ok, :eof} when size == 0 ->
          {:cont, {:ok, [%{path: relative, mode: mode, bytes: ""} | acc]}}

        _ ->
          {:halt, {:skip, "priv could not be read"}}
      end
    end)
  end

  @doc """
  The bytes of `check/3`'s `tarball` (a path or `{:binary, bytes}`), read
  no further than the largest tarball the rules read at all; `nil` for none
  or one that cannot be read.
  """
  @spec tarball_bytes(Path.t() | {:binary, binary()} | nil) :: binary() | nil
  def tarball_bytes(nil), do: nil
  def tarball_bytes({:binary, bytes}) when is_binary(bytes), do: bytes

  # sobelow_skip ["Traversal.FileModule"]
  def tarball_bytes(path) when is_binary(path) do
    max = Rules.max_tarball_bytes()

    case File.open(path, [:read, :raw, :binary], &IO.binread(&1, max + 1)) do
      {:ok, bytes} when is_binary(bytes) -> bytes
      _ -> nil
    end
  end
end
