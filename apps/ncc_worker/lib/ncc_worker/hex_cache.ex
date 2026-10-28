defmodule NccWorker.HexCache do
  @moduledoc """
  Where Hex reads and writes in this container, and what a run tells the host
  about the tarballs it fetched.

  Hex keeps everything under `HEX_HOME` (`Hex.State`'s `cache_home` and
  `config_home` both resolve to it when it is set):

    * `packages/hexpm/<name>-<version>.tar`, the tarball cache. Hex uses a
      cached tarball only when its outer checksum matches the registry's,
      removes one that does not, and downloads a missing one to
      `<tarball>.<16 hex>` before renaming it into place.
    * `cache.bin` (`cache.ets` before Hex 2.6), the registry cache. It is a
      dump of what Hex fetched, behind nothing stronger than a CRC32: Hex
      verifies the signed registry when it downloads it, never when it reads
      this file back, and a cached entry is kept for as long as the server
      answers 304 to its etag.
    * `hex.config`, read at start. It can name a mirror or turn registry
      verification off (`unsafe_registry`).

  The host mounts the shared cache read-only at `/hex-cache`, which is also
  the container's `HEX_HOME`. A build (`prepare/1`, mode `:seeded`) gets its
  own `HEX_HOME` at `/work/hex-home` instead: a real `packages/hexpm/` with
  one symlink per cached tarball and nothing else. Hex then resolves cached
  tarballs through their links, writes its registry cache and every download
  into the run dir, and removes a rejected tarball's link, never the shared
  file. Neither the registry cache nor `hex.config` is seeded, because Hex
  would trust both unchecked; every run fetches the signed registry instead.

  The downloads, the regular files left in that dir, are the run's misses
  (`report/2`). The host promotes them into the shared cache only after
  checking each against Hex.pm itself (`Compatibility.HexCache`); nothing a
  build reports is trusted. `NCC_HEX_CACHE_RW=1`, set by the host for the
  one-release rollback with a read-write mount, keeps `/hex-cache` as
  `HEX_HOME` (`:direct`), as builds did before.

  `NccWorker.HexHome` then gives each build target its own `HEX_HOME` under
  the project, seeded from whatever `HEX_HOME` this module exported.
  """

  alias NccWorker.DepsLock

  @home "hex-home"
  # Hex's own name for a cached tarball: names have no hyphen, versions may.
  @tarball ~r/\A([a-z][a-z0-9_]*)-([0-9][0-9A-Za-z.+\-]*)\.tar\z/

  @type layout :: %{mode: :seeded | :direct, home: Path.t(), work_dir: Path.t()}
  @type miss :: %{String.t() => String.t()}
  @type pair :: %{String.t() => String.t()}

  @doc """
  Lays out the run's `HEX_HOME` and creates it.

  Options: `:cache_root` (default: the container's `HEX_HOME`, `/hex-cache`),
  `:work_dir` (default `"/work"`), `:rw` (default: `NCC_HEX_CACHE_RW` is
  `"1"`).
  """
  @spec prepare(keyword()) :: {:ok, layout()} | {:error, term()}
  def prepare(opts \\ []) do
    root = Keyword.get_lazy(opts, :cache_root, &shared_root/0)
    work_dir = Keyword.get(opts, :work_dir, "/work")

    if Keyword.get_lazy(opts, :rw, &fallback_rw?/0) do
      {:ok, %{mode: :direct, home: root, work_dir: work_dir}}
    else
      layout = %{mode: :seeded, home: Path.join(work_dir, @home), work_dir: work_dir}

      with :ok <- seed(Path.join([root, "packages", "hexpm"]), packages_dir(layout)) do
        {:ok, layout}
      end
    end
  end

  defp shared_root do
    case System.get_env("HEX_HOME") do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> "/hex-cache"
    end
  end

  defp fallback_rw?, do: System.get_env("NCC_HEX_CACHE_RW") == "1"

  defp packages_dir(layout), do: Path.join([layout.home, "packages", "hexpm"])

  # `source` is the read-only mounted cache, `dest` a directory under the
  # run's own /work.
  # sobelow_skip ["Traversal.FileModule"]
  defp seed(source, dest) do
    with :ok <- File.mkdir_p(dest),
         {:ok, names} <- list_tarballs(source) do
      Enum.reduce_while(names, :ok, &link(&1, &2, source, dest))
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp link(name, :ok, source, dest) do
    case File.ln_s(Path.join(source, name), Path.join(dest, name)) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:hex_seed_link_failed, name, reason}}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp list_tarballs(dir) do
    case File.ls(dir) do
      {:ok, names} -> {:ok, names |> Enum.filter(&Regex.match?(@tarball, &1)) |> Enum.sort()}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:hex_cache_unreadable, reason}}
    end
  end

  @doc "The variables that point Hex at `layout`."
  @spec env(layout()) :: [{String.t(), String.t()}]
  def env(layout), do: [{"HEX_HOME", layout.home}]

  @doc """
  Sets `env/1` in this process's environment. Every `mix` the worker runs is
  a child process and inherits it, so call this before the first one.
  """
  @spec export_env(layout()) :: :ok
  def export_env(layout), do: System.put_env(env(layout))

  @doc """
  `result.json`'s `hex_cache` for a seeded run: `misses`, the tarballs Hex
  downloaded (name, version, the SHA-256 of the file, and its path relative
  to the work dir), and `hits`, the locked packages whose cached tarball the
  run used, for the host to mark as recently used. `nil` (the key is left
  out) when both are empty and for the read-write fallback.
  """
  @spec report(layout(), Path.t()) :: %{misses: [miss()], hits: [pair()]} | nil
  def report(%{mode: :seeded} = layout, project_dir) do
    {files, links} = entries(packages_dir(layout))

    case {Enum.map(files, &miss(&1, layout)), hits(links, project_dir)} do
      {[], []} -> nil
      {misses, hits} -> %{misses: misses, hits: hits}
    end
  end

  def report(_layout, _project_dir), do: nil

  @doc "`result` with `:hex_cache` from `report/2`, or unchanged when there is none."
  @spec put_report(map(), layout(), Path.t()) :: map()
  def put_report(result, layout, project_dir) do
    case report(layout, project_dir) do
      nil -> result
      report -> Map.put(result, :hex_cache, report)
    end
  end

  # The tarball names in the run's dir, split into regular files (downloaded
  # in this run) and links (seeded and left alone).
  # sobelow_skip ["Traversal.FileModule"]
  defp entries(dir) do
    case list_tarballs(dir) do
      {:ok, names} ->
        Enum.reduce(Enum.reverse(names), {[], []}, &sort_entry(&1, &2, dir))

      {:error, _reason} ->
        {[], []}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp sort_entry(name, {files, links}, dir) do
    case File.lstat(Path.join(dir, name)) do
      {:ok, %File.Stat{type: :regular}} -> {[name | files], links}
      {:ok, %File.Stat{type: :symlink}} -> {files, [name | links]}
      _ -> {files, links}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp miss(name, layout) do
    [_, package, version] = Regex.run(@tarball, name)
    path = Path.join(packages_dir(layout), name)

    %{
      "name" => package,
      "version" => version,
      "outer_checksum" => checksum(path),
      "path" => Path.relative_to(path, layout.work_dir)
    }
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp checksum(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  rescue
    _ -> nil
  end

  defp hits([], _project_dir), do: []

  defp hits(links, project_dir) do
    linked = MapSet.new(links)

    case DepsLock.versions(project_dir) do
      {:ok, versions} ->
        versions
        |> Enum.filter(fn {name, version} -> MapSet.member?(linked, "#{name}-#{version}.tar") end)
        |> Enum.sort()
        |> Enum.map(fn {name, version} -> %{"name" => name, "version" => version} end)

      :error ->
        []
    end
  end
end
