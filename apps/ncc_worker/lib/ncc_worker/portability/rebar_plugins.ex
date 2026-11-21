defmodule NccWorker.Portability.RebarPlugins do
  @moduledoc """
  The rebar3 plugins a rebar3 app's build installed, each pinned to a
  reviewed Hex release (precompiled judge, stream S5 item 8).

  rebar3 installs a dependency's `plugins` inside `rebar3 bare compile`,
  with their own dependencies, from Hex at whatever release its registry
  cache resolves; no lock names them. A plugin's `init/1` runs in the traced
  child VM, but what it does to rebar3's state (a compiler it adds, the
  `erl_opts` it sets) no event shows. So `NccWorker.Portability.Rebar` lets
  only reviewed plugins through by name, and this module holds every
  release a build installed to the exact releases that were reviewed, by
  version and Hex outer checksum (`pins/0`): the plugins' own releases and
  those of every dependency they pull. A release not in the table refuses,
  naming the plugin and its version.

  rebar3 extracts each one into `<app>/_build/default/plugins/<name>` (the
  `prod` profile links to it) and keeps its tarball in its cache,
  `<cache>/hex/hexpm/packages/<name>-<version>.tar`, where `<cache>` is
  `REBAR_CACHE_DIR` or `$HOME/.cache/rebar3` of the compile. A release is the
  reviewed one only when all of these hold:

    * its `hex_metadata.config` names it and its version, and the table pins
      that version;
    * its cached tarball hashes to the pinned checksum;
    * its dir holds exactly the tarball's files, byte for byte, plus
      `hex_metadata.config` (the tarball's `metadata.config`), the `.erl`
      rebar3's leex or yecc compiler wrote next to a `.xrl` or `.yrl` the
      release ships in `src`, and an `ebin` of `<name>.app` and one beam
      per module of its own sources (or the tarball's own `ebin` files): no
      file planted, changed or left out.

  Every entry of every `_build/<profile>/plugins` dir is judged (a link must
  name a plugin dir of the same name under `_build`), and every reviewed
  plugin the app's config names must be installed. A dir that cannot be
  read, a missing tarball or an unknown cache dir cannot be judged.

  A new release of a plugin or of one of its dependencies refuses until it
  is reviewed and added to `pins/0`; see the S5 design note for how.
  """

  alias NccWorker.Portability.{HexFiles, Rebar}

  @max_tarball_bytes 32 * 1024 * 1024
  @max_files 2_000
  @max_bytes 64 * 1024 * 1024
  @version ~r/\A[0-9A-Za-z][0-9A-Za-z.+-]{0,63}\z/
  @name ~r/\A[a-z][a-z0-9_]{0,63}\z/

  @doc "The reviewed releases (`Compatibility.RebarPlugins.pins/0`)."
  @spec pins() :: %{String.t() => %{String.t() => String.t()}}
  def pins, do: Compatibility.RebarPlugins.pins()

  @doc """
  `:ok` when every plugin installed for the rebar3 app in `dest` is a
  reviewed release and every name in `named` is installed; `{:refuse,
  reason}` or `{:unjudged, why}` otherwise. `cache` is rebar3's cache dir of
  the compile (`nil` when unknown), `pins` the table (`pins/0`).
  """
  @spec check(String.t(), String.t() | nil, [String.t()], map()) ::
          :ok | {:refuse, String.t()} | {:unjudged, String.t()}
  def check(dest, cache, named, pins \\ pins()) do
    with {:ok, installed} <- installed(dest),
         :ok <- all_named(named, installed) do
      installed
      |> Enum.sort()
      |> Enum.find_value(:ok, fn {name, dir} -> failed(release(name, dir, cache, pins)) end)
    end
  end

  defp failed(:ok), do: nil
  defp failed(other), do: other

  defp all_named(named, installed) do
    case Enum.find(named, &(not Map.has_key?(installed, &1))) do
      nil -> :ok
      name -> {:unjudged, "rebar3 plugin #{name} is named but not installed"}
    end
  end

  # `%{name => real dir}` of every plugin under `dest/_build/*/plugins`.
  # sobelow_skip ["Traversal.FileModule"]
  defp installed(dest) do
    build = Path.join(dest, "_build")

    case File.lstat(build) do
      {:error, :enoent} -> {:ok, %{}}
      {:ok, %File.Stat{type: :directory}} -> profiles(build)
      _ -> {:unjudged, "rebar3 build dir cannot be read"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp profiles(build) do
    case File.ls(build) do
      {:ok, names} ->
        names |> Enum.sort() |> Enum.reduce_while({:ok, %{}}, &profile(build, &1, &2))

      _ ->
        {:unjudged, "rebar3 build dir cannot be read"}
    end
  end

  defp profile(build, profile, {:ok, acc}) do
    case plugins_dir(build, Path.join([build, profile, "plugins"])) do
      {:ok, found} -> {:cont, merge(acc, found)}
      other -> {:halt, other}
    end
  end

  defp merge(acc, found) do
    Enum.reduce_while(found, {:ok, acc}, fn {name, dir}, {:ok, acc} ->
      case Map.fetch(acc, name) do
        :error -> {:cont, {:ok, Map.put(acc, name, dir)}}
        {:ok, ^dir} -> {:cont, {:ok, acc}}
        {:ok, _other} -> {:halt, odd(name)}
      end
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp plugins_dir(build, dir) do
    case File.lstat(dir) do
      {:error, :enoent} ->
        {:ok, %{}}

      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(dir) do
          {:ok, names} -> entries(build, dir, Enum.reject(names, &String.starts_with?(&1, ".")))
          _ -> {:unjudged, "rebar3 plugin dir cannot be read"}
        end

      {:ok, _other} ->
        {:refuse, "rebar3 build has a plugins dir that is not a directory"}

      _ ->
        {:unjudged, "rebar3 plugin dir cannot be read"}
    end
  end

  defp entries(build, dir, names) do
    Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, acc} ->
      case entry(build, Path.join(dir, name), name) do
        {:ok, real} -> {:cont, {:ok, Map.put(acc, name, real)}}
        other -> {:halt, other}
      end
    end)
  end

  # A plugin's own dir, or rebar3's link from another profile to a plugin
  # dir of the same name under `_build`.
  # sobelow_skip ["Traversal.FileModule"]
  defp entry(build, path, name) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, path}

      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(path),
             real = Path.expand(target, Path.dirname(path)),
             true <- Path.basename(real) == name,
             true <- Path.basename(Path.dirname(real)) == "plugins",
             true <- Path.dirname(Path.dirname(Path.dirname(real))) == Path.expand(build),
             {:ok, %File.Stat{type: :directory}} <- File.lstat(real) do
          {:ok, real}
        else
          _ -> odd(name)
        end

      _ ->
        odd(name)
    end
  end

  defp odd(name),
    do: {:refuse, "rebar3 build runs a plugin from a dir it cannot judge (#{name})"}

  defp release(name, dir, cache, pins) do
    with {:ok, version} <- metadata_version(name, dir),
         {:ok, sha} <- pinned(pins, name, version),
         {:ok, tarball} <- cached(cache, name, version),
         :ok <- same_sha(tarball, sha, name, version) do
      same_tree(tarball, dir, name, version)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp metadata_version(name, dir) do
    with true <- Regex.match?(@name, name),
         {:ok, text} <- small(Path.join(dir, "hex_metadata.config"), 1024 * 1024),
         {:ok, terms} <- HexFiles.parse(text),
         [^name] <- for({"name", n} <- terms, do: n),
         [version] when is_binary(version) <- for({"version", v} <- terms, do: v),
         true <- Regex.match?(@version, version) do
      {:ok, version}
    else
      _ -> {:unjudged, "rebar3 plugin #{name}: its release cannot be read"}
    end
  end

  defp pinned(pins, name, version) do
    case get_in(pins, [name, version]) do
      sha when is_binary(sha) -> {:ok, sha}
      _ -> {:refuse, "rebar3 build runs plugin #{name} #{version}, a release not reviewed"}
    end
  end

  defp cached(nil, name, version),
    do: {:unjudged, "rebar3 plugin #{name} #{version}: rebar3's cache dir is unknown"}

  defp cached(cache, name, version) do
    path = Path.join([cache, "hex", "hexpm", "packages", "#{name}-#{version}.tar"])

    case small(path, @max_tarball_bytes) do
      {:ok, bytes} -> {:ok, bytes}
      _ -> {:unjudged, "rebar3 plugin #{name} #{version}: no cached Hex tarball"}
    end
  end

  defp same_sha(tarball, sha, name, version) do
    if :sha256 |> :crypto.hash(tarball) |> Base.encode16(case: :lower) == sha,
      do: :ok,
      else:
        {:refuse,
         "rebar3 build runs plugin #{name} #{version} from a Hex tarball " <>
           "that is not the reviewed release"}
  end

  defp same_tree(tarball, dir, name, version) do
    differs =
      {:refuse,
       "rebar3 build runs plugin #{name} #{version} from files that are not " <>
         "its reviewed release's"}

    with {:ok, files, metadata} <- tarball_files(tarball),
         {:ok, disk} <- walk(dir) do
      {ebin, rest} = Enum.split_with(disk, fn {path, _} -> String.starts_with?(path, "ebin/") end)
      {generated, rest} = Enum.split_with(rest, &generated?(&1, files))
      expected = files |> Map.reject(fn {p, _} -> String.starts_with?(p, "ebin/") end)
      expected = Map.put(expected, "hex_metadata.config", metadata)

      if Map.new(rest) == expected and ebin_ok?(ebin, files, name, generated),
        do: :ok,
        else: differs
    else
      {:unjudged, _} = unjudged -> unjudged
      _ -> differs
    end
  end

  # rebar3's leex and yecc compilers write the module they generate from a
  # `.xrl` or `.yrl` the release ships next to it in `src` (hex_core's
  # `safe_erl_term`): such an `.erl` is the release's, when the release
  # ships no file at that path.
  defp generated?({"src/" <> _ = path, _bytes}, files) do
    Path.extname(path) == ".erl" and not Map.has_key?(files, path) and
      Enum.any?([".xrl", ".yrl"], &Map.has_key?(files, Path.rootname(path) <> &1))
  end

  defp generated?(_file, _files), do: false

  # `ebin`: the app file and one beam per module of its own sources, or a
  # file the tarball itself ships there, byte for byte.
  defp ebin_ok?(ebin, files, name, generated) do
    sources = Map.keys(files) ++ Enum.map(generated, &elem(&1, 0))

    modules =
      for path <- sources,
          String.starts_with?(path, "src/"),
          Path.extname(path) in [".erl", ".xrl", ".yrl"],
          into: MapSet.new(),
          do: Path.basename(path, Path.extname(path))

    Enum.all?(ebin, fn {"ebin/" <> file = path, bytes} ->
      cond do
        Map.get(files, path) == bytes -> true
        String.contains?(file, "/") -> false
        file == name <> ".app" -> true
        Path.extname(file) == ".beam" -> MapSet.member?(modules, Path.basename(file, ".beam"))
        true -> false
      end
    end)
  end

  defp tarball_files(tarball) do
    with {:ok, [{_, metadata}]} <-
           :erl_tar.extract({:binary, tarball}, [:memory, {:files, [~c"metadata.config"]}]),
         {:ok, tar} <- Rebar.contents_tar(tarball),
         {:ok, files} <- :erl_tar.extract({:binary, tar}, [:memory]) do
      {:ok, Map.new(files, fn {path, bytes} -> {List.to_string(path), bytes} end), metadata}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # Every regular file under `dir`, relative, with its bytes; anything else
  # (a link, a device) is not a release's file.
  defp walk(dir), do: walk(dir, "", {:ok, [], 0, 0})

  # sobelow_skip ["Traversal.FileModule"]
  defp walk(root, relative, acc) do
    case File.ls(Path.join(root, relative)) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce_while(acc, &walk_step(root, join(relative, &1), &2))
        |> walked(relative)

      _ ->
        {:unjudged, "rebar3 plugin dir cannot be read"}
    end
  end

  defp walk_step(root, relative, acc) do
    case walk_entry(root, relative, acc) do
      {:ok, _, _, _} = acc -> {:cont, acc}
      other -> {:halt, other}
    end
  end

  defp walked({:ok, files, _count, _bytes}, ""), do: {:ok, files}
  defp walked(other, _relative), do: other

  # sobelow_skip ["Traversal.FileModule"]
  defp walk_entry(root, relative, {:ok, files, count, bytes}) do
    path = Path.join(root, relative)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        walk(root, relative, {:ok, files, count, bytes})

      {:ok, %File.Stat{type: :regular, size: size}}
      when count < @max_files and bytes + size <= @max_bytes ->
        case File.read(path) do
          {:ok, data} -> {:ok, [{relative, data} | files], count + 1, bytes + size}
          _ -> {:unjudged, "rebar3 plugin dir cannot be read"}
        end

      _ ->
        :error
    end
  end

  defp join("", name), do: name
  defp join(relative, name), do: relative <> "/" <> name

  # sobelow_skip ["Traversal.FileModule"]
  defp small(path, max) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= max <- File.lstat(path),
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes}
    else
      _ -> :error
    end
  end
end
