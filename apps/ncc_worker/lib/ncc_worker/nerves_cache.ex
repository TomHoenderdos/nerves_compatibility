defmodule NccWorker.NervesCache do
  @moduledoc """
  Where Nerves reads and writes its artifacts in this container, and what a
  run tells the host about them (isolation spec, section 1).

  Nerves 2.0.0-pre.3 resolves both directories from the environment
  (`Nerves.Paths`: `NERVES_ARTIFACTS_DIR`, `NERVES_DL_DIR`), and an artifact
  lives at `<artifacts dir>/<app>-<version>`. It is valid when its
  `.fingerprint` matches; otherwise Nerves removes the entry with
  `File.rm_rf!/1`, extracts a fresh one and writes `.fingerprint` last.

  The host mounts the shared cache at `/nerves-cache`:

    * A build mounts it read-only and gets a per-run symlink farm
      (`:farm`): `/work/nerves/artifacts/` holds one link per entry of
      `/nerves-cache/artifacts/`, and `/work/nerves/dl/` starts empty. A cached
      artifact resolves through its link. One the cache lacks, or whose
      fingerprint does not match, Nerves extracts into the run dir instead
      (`rm_rf!` on a link removes the link, never its target), and the build
      passes either way. Those real directories are the run's misses
      (`report/2`); the host decides, without trusting the report, which to
      warm.
    * A warm run (`mode: "warm_nerves"`, `NccWorker.WarmNerves`) mounts it
      read-write and farms `/nerves-cache/staging/<run_id>/artifacts` the same
      way (`:staging`), so only what is missing or mismatched is downloaded.
      `install_staged/1` then renames what Nerves extracted into
      `artifacts/`. Nothing else ever writes the cache.
    * `NCC_NERVES_CACHE_RW=1`, set by `Portal.Builder` for the one-release
      rollback, points both variables straight at the mounted cache
      (`:direct`), as builds did before the farm.

  Every mode also points `XDG_DATA_HOME` at `/work/nerves/data`.
  nerves_bootstrap's `UpdateChecker` creates `<XDG_DATA_HOME>/nerves` (else
  `~/.nerves`) when its application starts. The container root is read-only,
  so without a writable dir the app fails to start, its compile hook never
  runs `Nerves.export_env/0`, and `mix firmware` builds for the host and
  raises "No Nerves package is supplying an Erlang runtime". `prepare/2`
  marks the check done there, so bootstrap does not ask hex.pm either.

  Nothing refers to `/home/nerves/.nerves`.
  """

  alias NccWorker.DepsLock

  @cache_root "/nerves-cache"
  @artifact_prefixes ["nerves_system_", "nerves_toolchain_"]
  # `<app>-<version>`: app names have no hyphen, versions may.
  @entry ~r/\A[a-z][a-z0-9_]*-[0-9][0-9A-Za-z.+\-]*\z/
  @stale ".stale."

  @type mode :: :farm | :direct | :staging
  @type layout :: %{
          mode: mode(),
          cache_root: Path.t(),
          artifacts_dir: Path.t(),
          dl_dir: Path.t(),
          data_dir: Path.t(),
          run_id: String.t() | nil
        }
  @type pair :: %{String.t() => String.t()}
  @type install :: %{
          installed: [String.t()],
          kept: [String.t()],
          replaced: [String.t()],
          incomplete: [String.t()]
        }

  @doc """
  Lays out the Nerves directories for a run of `kind` and creates them.

  Options: `:cache_root` (default `"/nerves-cache"`), `:work_dir` (default
  `"/work"`), `:run_id` (required for `:warm`), `:rw` (default:
  `NCC_NERVES_CACHE_RW` is `"1"`; a warm run ignores it).
  """
  @spec prepare(:build | :warm, keyword()) :: {:ok, layout()} | {:error, term()}
  def prepare(kind, opts \\ []) do
    data_dir = Path.join([Keyword.get(opts, :work_dir, "/work"), "nerves", "data"])

    layout =
      kind
      |> layout(Keyword.get(opts, :cache_root, @cache_root), opts)
      |> Map.put(:data_dir, data_dir)

    with :ok <- materialize_data_dir(data_dir),
         :ok <- materialize(layout) do
      {:ok, layout}
    end
  end

  # nerves_bootstrap's check file (`NervesBootstrap.UpdateChecker`), touched
  # so it counts as checked and nothing writes or fetches at app start.
  # data_dir is under the container's own /work mount, from prepare/2.
  # sobelow_skip ["Traversal.FileModule"]
  defp materialize_data_dir(data_dir) do
    dir = Path.join(data_dir, "nerves")

    with :ok <- File.mkdir_p(dir),
         do: File.touch(Path.join(dir, "nerves_bootstrap_update_check"))
  end

  defp layout(:warm, root, opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    staging = Path.join([root, "staging", staging_name(run_id)])

    %{
      mode: :staging,
      cache_root: root,
      run_id: run_id,
      artifacts_dir: Path.join(staging, "artifacts"),
      dl_dir: Path.join(staging, "dl")
    }
  end

  defp layout(:build, root, opts) do
    if Keyword.get_lazy(opts, :rw, &fallback_rw?/0) do
      %{
        mode: :direct,
        cache_root: root,
        run_id: nil,
        artifacts_dir: Path.join(root, "artifacts"),
        dl_dir: Path.join(root, "dl")
      }
    else
      run_dir = Path.join(Keyword.get(opts, :work_dir, "/work"), "nerves")

      %{
        mode: :farm,
        cache_root: root,
        run_id: nil,
        artifacts_dir: Path.join(run_dir, "artifacts"),
        dl_dir: Path.join(run_dir, "dl")
      }
    end
  end

  defp fallback_rw?, do: System.get_env("NCC_NERVES_CACHE_RW") == "1"

  # One path component under staging/, whatever the run id says.
  defp staging_name(run_id) when run_id in ["", ".", ".."],
    do: raise(ArgumentError, "invalid run id for a Nerves staging dir: #{inspect(run_id)}")

  defp staging_name(run_id) when is_binary(run_id),
    do: String.replace(run_id, ~r/[^A-Za-z0-9_.\-]/, "_")

  # Paths are the container's own mounts (/work, /nerves-cache) from prepare/2.
  # sobelow_skip ["Traversal.FileModule"]
  defp materialize(%{mode: :direct} = layout) do
    with :ok <- File.mkdir_p(layout.artifacts_dir), do: File.mkdir_p(layout.dl_dir)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp materialize(layout) do
    with :ok <- File.mkdir_p(layout.dl_dir) do
      build_farm(Path.join(layout.cache_root, "artifacts"), layout.artifacts_dir)
    end
  end

  @doc """
  Fills `farm` with one symlink per artifact entry of `source`. A missing
  `source`, a host whose cache was never warmed, leaves the farm empty.
  """
  @spec build_farm(Path.t(), Path.t()) :: :ok | {:error, term()}
  # source is the mounted cache, farm a directory under the run's /work or staging.
  # sobelow_skip ["Traversal.FileModule"]
  def build_farm(source, farm) do
    with :ok <- File.mkdir_p(farm),
         {:ok, names} <- list_entries(source) do
      Enum.reduce_while(names, :ok, &link_entry(&1, &2, source, farm))
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp link_entry(name, :ok, source, farm) do
    case File.ln_s(Path.join(source, name), Path.join(farm, name)) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:nerves_farm_link_failed, name, reason}}}
    end
  end

  @doc false
  @spec entry?(String.t()) :: boolean()
  def entry?(name), do: Regex.match?(@entry, name) and not String.contains?(name, @stale)

  # sobelow_skip ["Traversal.FileModule"]
  defp list_entries(dir) do
    case File.ls(dir) do
      {:ok, names} -> {:ok, names |> Enum.filter(&entry?/1) |> Enum.sort()}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:nerves_cache_unreadable, reason}}
    end
  end

  @doc """
  The variables that point Nerves at `layout`: its two artifact dirs, and
  `XDG_DATA_HOME` for nerves_bootstrap's data dir.
  """
  @spec env(layout()) :: [{String.t(), String.t()}]
  def env(layout),
    do: [
      {"NERVES_ARTIFACTS_DIR", layout.artifacts_dir},
      {"NERVES_DL_DIR", layout.dl_dir},
      {"XDG_DATA_HOME", layout.data_dir}
    ]

  @doc """
  Sets `env/1` in this process's environment. Every `mix` the worker runs is
  a child process and inherits it, so call this before the first one.
  """
  @spec export_env(layout()) :: :ok
  def export_env(layout), do: System.put_env(env(layout))

  @doc """
  The farm entries that are real directories: artifacts Nerves extracted in
  this run because the cache lacked them or their fingerprint did not match.
  `[]` for the read-write fallback, which has no farm.
  """
  @spec misses(layout()) :: [pair()]
  def misses(%{mode: mode} = layout) when mode in [:farm, :staging],
    do: layout.artifacts_dir |> real_entries() |> Enum.map(&pair/1)

  def misses(_layout), do: []

  # sobelow_skip ["Traversal.FileModule"]
  defp real_entries(dir) do
    case list_entries(dir) do
      {:ok, names} ->
        Enum.filter(
          names,
          &match?({:ok, %File.Stat{type: :directory}}, File.lstat(Path.join(dir, &1)))
        )

      {:error, _reason} ->
        []
    end
  end

  @doc "`\"nerves_system_rpi4-2.0.0\"` as `%{\"name\" => ..., \"version\" => ...}`."
  @spec pair(String.t()) :: pair()
  def pair(entry) do
    [name, version] = String.split(entry, "-", parts: 2)
    %{"name" => name, "version" => version}
  end

  @doc "The artifact directory name of a pair."
  @spec entry_name(pair()) :: String.t()
  def entry_name(%{"name" => name, "version" => version}), do: "#{name}-#{version}"

  @doc """
  The project's locked packages whose name starts with `nerves_system_` or
  `nerves_toolchain_`, sorted by name (the order Mix writes `mix.lock` in).
  `[]` when the lock cannot be read.
  """
  @spec lock_entries(Path.t()) :: [pair()]
  def lock_entries(project_dir) do
    case DepsLock.versions(project_dir) do
      {:ok, versions} ->
        versions
        |> Enum.filter(fn {name, _version} -> String.starts_with?(name, @artifact_prefixes) end)
        |> Enum.sort()
        |> Enum.map(fn {name, version} -> %{"name" => name, "version" => version} end)

      :error ->
        []
    end
  end

  @doc """
  `result.json`'s `nerves_cache` for a build: its misses and its locked Nerves
  packages. `nil` (the key is left out) when both are empty and for anything
  but a farm build.
  """
  @spec report(layout(), Path.t()) :: %{misses: [pair()], lock: [pair()]} | nil
  def report(%{mode: :farm} = layout, project_dir) do
    case {misses(layout), lock_entries(project_dir)} do
      {[], []} -> nil
      {misses, lock} -> %{misses: misses, lock: lock}
    end
  end

  def report(_layout, _project_dir), do: nil

  @doc "`result` with `:nerves_cache` from `report/2`, or unchanged when there is none."
  @spec put_report(map(), layout(), Path.t()) :: map()
  def put_report(result, layout, project_dir) do
    case report(layout, project_dir) do
      nil -> result
      report -> Map.put(result, :nerves_cache, report)
    end
  end

  @doc """
  Moves every artifact a warm run extracted into `artifacts/`:

    * absent there: renamed into place (`installed`);
    * present with the same `.fingerprint`: left alone (`kept`);
    * present with a different one, or not a directory: the old entry is
      renamed to `<entry>.stale.<run_id>` and the new one into place
      (`replaced`), which is how a corrupt entry heals;
    * extracted without a `.fingerprint` (Nerves writes it last): not
      installed (`incomplete`).

  Every rename stays on the one filesystem, so a concurrent build sees no
  entry, the old complete one or the new complete one.
  """
  @spec install_staged(layout()) :: {:ok, install()} | {:error, term()}
  # Paths are the read-write /nerves-cache mount of a warm container.
  # sobelow_skip ["Traversal.FileModule"]
  def install_staged(%{mode: :staging} = layout) do
    target = Path.join(layout.cache_root, "artifacts")
    empty = %{installed: [], kept: [], replaced: [], incomplete: []}

    with :ok <- File.mkdir_p(target) do
      layout.artifacts_dir
      |> real_entries()
      |> Enum.reduce_while({:ok, empty}, &install_one(&1, &2, layout, target))
    end
  end

  defp install_one(name, {:ok, acc}, layout, target) do
    source = Path.join(layout.artifacts_dir, name)
    dest = Path.join(target, name)

    case install_entry(source, dest, dest <> @stale <> staging_name(layout.run_id)) do
      {:ok, outcome} -> {:cont, {:ok, Map.update!(acc, outcome, &(&1 ++ [name]))}}
      {:error, reason} -> {:halt, {:error, {:nerves_install_failed, name, reason}}}
    end
  end

  defp install_entry(source, dest, stale) do
    case fingerprint(source) do
      {:ok, staged} -> install_at_dest(source, dest, stale, staged)
      :error -> {:ok, :incomplete}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp install_at_dest(source, dest, stale, staged) do
    case File.lstat(dest) do
      {:error, :enoent} ->
        with :ok <- File.rename(source, dest), do: {:ok, :installed}

      {:ok, %File.Stat{type: :directory}} ->
        if fingerprint(dest) == {:ok, staged},
          do: {:ok, :kept},
          else: replace(source, dest, stale)

      {:ok, %File.Stat{}} ->
        replace(source, dest, stale)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp replace(source, dest, stale) do
    with :ok <- File.rename(dest, stale),
         :ok <- File.rename(source, dest) do
      {:ok, :replaced}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp fingerprint(dir) do
    case File.read(Path.join(dir, ".fingerprint")) do
      {:ok, value} when value != "" -> {:ok, value}
      _ -> :error
    end
  end

  @doc """
  Removes a warm run's staging dir and the entries it set aside. Other runs'
  leftovers are `Portal.Workers.Sweep`'s.
  """
  @spec cleanup(layout()) :: :ok
  # sobelow_skip ["Traversal.FileModule"]
  def cleanup(%{mode: :staging} = layout) do
    _ = File.rm_rf(Path.dirname(layout.artifacts_dir))
    artifacts = Path.join(layout.cache_root, "artifacts")
    suffix = @stale <> staging_name(layout.run_id)

    case File.ls(artifacts) do
      {:ok, names} ->
        for name <- names,
            String.ends_with?(name, suffix),
            do: File.rm_rf(Path.join(artifacts, name))

        :ok

      {:error, _reason} ->
        :ok
    end
  end

  def cleanup(_layout), do: :ok
end
