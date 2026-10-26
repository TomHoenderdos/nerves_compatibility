defmodule Portal.BuildCache.Tree do
  @moduledoc """
  The structural check every build cache entry passes before it becomes
  visible, and the mode stripping that follows it. Moved out of
  `Portal.BuildCache.Promotion` (its moduledoc, steps 7 and 8, explains each
  rule) so the L2 download path (`Portal.BuildCache.L2`) runs exactly the
  same code over what it extracted. `package: :any` is for that path, which
  does not know which package an entry belongs to and so accepts Mix's
  `priv`/`include` link for any package name.
  """

  @doc "Checks the tree under `dir`: directories, regular files with one link, Mix's own links."
  @spec check(Path.t(), package: String.t() | :any) :: :ok | {:error, String.t()}
  def check(dir, opts), do: walk(dir, true, Keyword.fetch!(opts, :package))

  # Paths below the candidate root, named by a raw listing of a directory
  # `lstat` showed is real. Not `File.ls/1`: see `Portal.BuildCache.Promotion`'s
  # moduledoc, step 7.
  # sobelow_skip ["Traversal.FileModule"]
  defp walk(dir, top?, package) do
    case :file.list_dir_all(dir) do
      {:ok, names} ->
        Enum.reduce_while(names, :ok, fn raw, :ok ->
          raw |> check_name(dir, top?, package) |> continue_if_ok()
        end)

      {:error, reason} ->
        {:error, "cannot list #{show(dir)}: #{inspect(reason)}"}
    end
  end

  defp check_name(raw, dir, top?, package) do
    case name_string(raw) do
      {:ok, name} ->
        dir |> Path.join(name) |> check_entry(name, top?, package)

      :error ->
        {:error, "name that is not valid UTF-8 in #{show(dir)}: #{show(raw)}"}
    end
  end

  @doc false
  # A name as `:file.list_dir_all/1` returns it: a charlist when it decodes
  # in the native name encoding, a binary of raw bytes when it does not.
  @spec name_string(binary() | charlist()) :: {:ok, String.t()} | :error
  def name_string(name) when is_list(name) do
    case :unicode.characters_to_binary(name) do
      bin when is_binary(bin) -> name_string(bin)
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  def name_string(name) when is_binary(name) do
    if String.valid?(name) and name not in ["", ".", ".."] and
         not String.contains?(name, ["/", <<0>>]),
       do: {:ok, name},
       else: :error
  end

  def name_string(_name), do: :error

  @doc false
  # Every container-chosen string reaches the log through here: escaped, so
  # a newline cannot forge a line and invalid UTF-8 cannot make the
  # formatter drop it, and bounded.
  def show(term), do: inspect(term, printable_limit: 200, binaries: :as_strings)

  defp continue_if_ok(:ok), do: {:cont, :ok}
  defp continue_if_ok(error), do: {:halt, error}

  defp check_entry(path, name, top?, package) do
    case lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> walk(path, false, package)
      {:ok, %File.Stat{type: :regular, links: 1}} -> :ok
      {:ok, %File.Stat{type: :regular}} -> {:error, "hardlinked file #{show(path)}"}
      {:ok, %File.Stat{type: :symlink}} -> check_link(path, name, top?, package)
      {:ok, %File.Stat{type: type}} -> {:error, "#{type} at #{show(path)}"}
      {:error, reason} -> {:error, "cannot stat #{show(path)}: #{inspect(reason)}"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp check_link(path, name, true, package) when name in ["priv", "include"] do
    with {:ok, target} <- File.read_link(path),
         true <- mix_link?(name, target, package) do
      :ok
    else
      _ -> {:error, "symlink #{show(path)} is not Mix's own #{name} link"}
    end
  end

  defp check_link(path, _name, _top?, _package), do: {:error, "symlink #{show(path)}"}

  @doc false
  # Whether `target` is the link Mix makes for `name` (`priv` or `include`)
  # in a build entry: four levels up into `deps*/<package>/<name>`. One
  # predicate for the walk above and for the L2 link manifest.
  @spec mix_link?(term(), term(), String.t() | :any) :: boolean()
  def mix_link?(name, target, package) when name in ["priv", "include"] and is_binary(target) do
    pkg = if package == :any, do: "[a-z][a-z0-9_]*", else: Regex.escape(package)
    allowed = ~r/\A\.\.\/\.\.\/\.\.\/\.\.\/deps(_[a-z0-9_]+)?\/#{pkg}\/(priv|include)\z/
    match?([_, _deps, ^name], Regex.run(allowed, target))
  end

  def mix_link?(_name, _target, _package), do: false

  # The container (or, on the L2 download path, the archive) chose every
  # mode in the tree. Before it becomes visible, drop setuid, setgid and
  # sticky and group/other write from each directory and regular file, so
  # nothing in the cache is writable by another user or runs with its owner's
  # rights, and give the owner read and write (and search, on a directory),
  # so an applied 0o000 can always be read and removed. Walked with `lstat`
  # and links left alone: `chmod` on a link would change what it points at.
  # That lstat-then-chmod is only safe because it runs on a host-private
  # copy no build can change between the two: Promotion's staging copy
  # (`Portal.BuildCache.Promotion`'s moduledoc, step 6) or the L2 download
  # staging dir `Portal.BuildCache.L2.Tarball.unpack/3` extracts into. The
  # names are rechecked here rather than trusted.
  @keep_mode 0o755
  @dir_floor 0o700
  @file_floor 0o600

  # `path` is a host-built staging path (Promotion's copy or an L2 download).
  # sobelow_skip ["Traversal.FileModule"]
  @spec strip_modes(Path.t()) :: :ok | {:error, term()}
  def strip_modes(path) do
    case lstat(path) do
      {:ok, %File.Stat{type: :directory, mode: mode}} ->
        with :ok <- chmod(path, mode, @dir_floor), do: strip_children(path)

      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        chmod(path, mode, @file_floor)

      {:ok, %File.Stat{}} ->
        :ok

      error ->
        error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp strip_children(dir) do
    case :file.list_dir_all(dir) do
      {:ok, names} ->
        Enum.reduce_while(names, :ok, fn raw, :ok -> strip_child(dir, raw) end)

      error ->
        error
    end
  end

  defp strip_child(dir, raw) do
    case name_string(raw) do
      {:ok, name} -> dir |> Path.join(name) |> strip_modes() |> continue_if_ok()
      :error -> {:halt, {:error, {:name, raw}}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp chmod(path, mode, floor) do
    wanted = mode |> Bitwise.band(@keep_mode) |> Bitwise.bor(floor)

    if Bitwise.band(mode, 0o7777) == wanted, do: :ok, else: File.chmod(path, wanted)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp lstat(path), do: File.lstat(path)
end
