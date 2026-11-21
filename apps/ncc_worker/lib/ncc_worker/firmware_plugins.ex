defmodule NccWorker.FirmwarePlugins do
  @moduledoc """
  The rebar3 plugin releases each passing firmware target's `mix firmware`
  ran, recorded as the target's `rebar3_plugins` so the portal can find the
  firmware results that ran one, as the toolchain judge's record lets it
  find the toolchain builds (stream S5's `compile_observations.rebar3_plugins`,
  whose entry shape this keeps). A record only: nothing here judges a
  plugin, and statuses, firmware images and files never change.

  rebar3 installs a dependency's `plugins` inside the `rebar3 bare compile`
  Mix runs in the dependency's own dir, here the target's deps dir
  (`MIX_DEPS_PATH`, `deps_<target>`), at
  `<app>/_build/<profile>/plugins/<name>` (another profile links to the
  default profile's dir), and keeps the release's tarball in its cache,
  `<cache>/hex/hexpm/packages/<name>-<version>.tar`, where `<cache>` is the
  build env's `REBAR_CACHE_DIR`, else `$HOME/.cache/rebar3`.

  Each entry is a release, `%{"name", "version", "sha256", "owners"}`: its
  name and version as its `hex_metadata.config` gives them, the sha256 of
  its cached tarball (the Hex outer checksum), and the apps it was installed
  for, sorted; entries sorted by name and version. A release whose files
  cannot be read, or a link that leaves its app's `_build`, is recorded with
  a `nil` version, and one with no cached tarball with a `nil` sha256: a
  plugin that ran is never left out. Nothing is cut either.
  """

  alias NccWorker.Portability.HexFiles

  @max_metadata_bytes 1024 * 1024
  @max_tarball_bytes 32 * 1024 * 1024
  @name ~r/\A[A-Za-z0-9_.+-]{1,255}\z/
  @version ~r/\A[0-9A-Za-z][0-9A-Za-z.+-]{0,63}\z/

  @type release :: %{String.t() => String.t() | nil | [String.t()]}

  @doc """
  Puts `rebar3_plugins` on every passing target of `systems` that has a
  build env in `ctx.targets` (`%{name => {target, env}}`) naming its deps
  dir (`MIX_DEPS_PATH`). `ctx.project_dir` is the Nerves project.
  """
  @spec put(%{String.t() => map()}, %{project_dir: String.t(), targets: map()}) ::
          %{String.t() => map()}
  def put(systems, %{project_dir: project_dir, targets: targets}) do
    Map.new(systems, fn {name, result} ->
      with true <- result[:status] in [:pass, "pass"],
           {:ok, {_target, env}} <- Map.fetch(targets, name),
           deps when is_binary(deps) <- env_value(env, "MIX_DEPS_PATH") do
        deps = Path.expand(deps, project_dir)
        {name, Map.put(result, :rebar3_plugins, record(deps, rebar_cache(env)))}
      else
        _ -> {name, result}
      end
    end)
  end

  @doc """
  The record of the plugins installed for every app in the deps dir `deps`,
  with rebar3's cache dir `cache` (`nil` when unknown).
  """
  @spec record(String.t(), String.t() | nil) :: [release()]
  def record(deps, cache) do
    deps
    |> apps()
    |> Enum.flat_map(fn app ->
      Enum.map(installed(Path.join(deps, app)), &{release(&1, cache), app})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {release, owners} ->
      Map.put(release, "owners", owners |> Enum.uniq() |> Enum.sort())
    end)
    |> Enum.sort_by(&{&1["name"], &1["version"] || "", &1["sha256"] || ""})
  end

  @doc """
  rebar3's cache dir of a compile with `env` (`rebar_dir:global_cache_dir/1`):
  `REBAR_CACHE_DIR`, else `$HOME/.cache/rebar3`, each the last value `env`
  gives it, else this VM's, which the compile inherits.
  """
  @spec rebar_cache([{String.t(), String.t() | nil}]) :: String.t() | nil
  def rebar_cache(env) do
    get = fn name ->
      case env |> Enum.reverse() |> List.keyfind(name, 0) do
        {^name, value} -> value
        nil -> System.get_env(name)
      end
    end

    case {get.("REBAR_CACHE_DIR"), get.("HOME")} do
      {dir, _home} when is_binary(dir) and dir != "" -> dir
      {_dir, home} when is_binary(home) and home != "" -> Path.join([home, ".cache", "rebar3"])
      _ -> nil
    end
  end

  # The run's own deps dir.
  # sobelow_skip ["Traversal.FileModule"]
  defp apps(deps) do
    case File.ls(deps) do
      {:ok, names} -> names |> Enum.reject(&String.starts_with?(&1, ".")) |> Enum.sort()
      _ -> []
    end
  end

  # `{name, real dir | :odd}` of every plugin under `app/_build/*/plugins`,
  # one per name: a profile's link to the default profile's dir is that dir.
  # sobelow_skip ["Traversal.FileModule"]
  defp installed(app) do
    build = Path.join(app, "_build")

    case File.ls(build) do
      {:ok, profiles} ->
        profiles
        |> Enum.sort()
        |> Enum.flat_map(&plugins(build, Path.join([build, &1, "plugins"])))
        |> Enum.uniq()
        |> Enum.group_by(&elem(&1, 0))
        |> Enum.map(fn
          {name, [{name, dir}]} -> {name, dir}
          {name, _differ} -> {name, :odd}
        end)

      _ ->
        []
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp plugins(build, dir) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(dir),
         {:ok, names} <- File.ls(dir) do
      for name <- Enum.sort(names),
          not String.starts_with?(name, "."),
          do: {name, entry(build, Path.join(dir, name), name)}
    else
      _ -> []
    end
  end

  # A plugin's own dir, or a link to a plugin dir of the same name under
  # the same `_build`; anything else is odd.
  # sobelow_skip ["Traversal.FileModule"]
  defp entry(build, path, name) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        Path.expand(path)

      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(path),
             real = Path.expand(target, Path.dirname(path)),
             true <- Path.basename(real) == name,
             true <- Path.basename(Path.dirname(real)) == "plugins",
             true <- Path.dirname(Path.dirname(Path.dirname(real))) == Path.expand(build),
             {:ok, %File.Stat{type: :directory}} <- File.lstat(real) do
          real
        else
          _ -> :odd
        end

      _ ->
        :odd
    end
  end

  defp release({name, :odd}, _cache), do: unread(name)

  defp release({name, dir}, cache) do
    case metadata_version(name, dir) do
      {:ok, version} ->
        %{"name" => name, "version" => version, "sha256" => cached_sha(cache, name, version)}

      :error ->
        unread(name)
    end
  end

  defp unread(name),
    do: %{"name" => printable(name), "version" => nil, "sha256" => nil}

  defp printable(name) do
    if String.valid?(name) and Regex.match?(@name, name),
      do: name,
      else: "unreadable:" <> Base.encode16(:crypto.hash(:sha256, name), case: :lower)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp metadata_version(name, dir) do
    with true <- Regex.match?(@name, name),
         {:ok, text} <- small(Path.join(dir, "hex_metadata.config"), @max_metadata_bytes),
         {:ok, terms} <- HexFiles.parse(text),
         [^name] <- for({"name", n} <- terms, do: n),
         [version] when is_binary(version) <- for({"version", v} <- terms, do: v),
         true <- Regex.match?(@version, version) do
      {:ok, version}
    else
      _ -> :error
    end
  end

  defp cached_sha(nil, _name, _version), do: nil

  defp cached_sha(cache, name, version) do
    case small(
           Path.join([cache, "hex", "hexpm", "packages", "#{name}-#{version}.tar"]),
           @max_tarball_bytes
         ) do
      {:ok, bytes} -> :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
      :error -> nil
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp small(path, max) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= max <- File.lstat(path),
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  defp env_value(env, name) do
    case List.keyfind(env, name, 0) do
      {_, value} when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
