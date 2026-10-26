defmodule NccAgent.NervesCache do
  @moduledoc """
  The agent's side of the shared Nerves cache (isolation design, section 1).

  A build mounts `<data>/nerves-cache` read-only at `/nerves-cache`. Inside
  the container the worker lays out its own per-run symlink farm over it
  (`NccWorker.NervesCache`) and reports what it had to extract itself as
  `result.json` `nerves_cache.misses`. Which of those misses are worth
  caching is the portal's call, not the agent's
  (`Portal.NervesCache.warm_pairs/2`: named by the run's lock, owned by the
  `nerves` Hex user, at most four), and the portal answers the lease's
  `complete` with them as `warm`. `warm/4` then runs a second, trusted
  container in `warm_nerves` mode with the cache mounted read-write for
  exactly those pairs. The agent has no allowlist of its own and never warms
  anything the portal did not name; `pairs/1` only re-checks the shape.

  `prepare_cache/1` makes sure the cache root and its `artifacts` are real
  directories before anything mounts or chowns them: a warm container has
  them read-write and could leave a symlink (to `/etc`, say) that the agent,
  as root, would otherwise follow.
  """

  require Logger

  alias Compatibility.Builder.Argv
  alias NccAgent.{Config, Docker, Fs, Job}

  @warm_pairs_per_run 4
  @warm_timeout_ms 2 * 60 * 60 * 1000
  @max_field_bytes 64
  # The same shape `Portal.NervesCache.pair_tuple/1` accepts: an official
  # Nerves system or toolchain package and a semantic version.
  @name ~r/\Anerves_(system|toolchain)_[a-z0-9_]+\z/

  @type pair :: %{name: String.t(), version: String.t()}

  @doc """
  Makes `<data>/nerves-cache` and its `artifacts` real directories. Anything
  else there (a symlink, a file) is logged, removed (`File.rm_rf/1` removes
  a link, not its target) and recreated empty; it is only a cache.
  """
  @spec prepare_cache(Config.t()) :: :ok
  def prepare_cache(config) do
    cache = Config.path(config, :nerves_cache)
    ensure_real_dir!(cache)
    ensure_real_dir!(Path.join(cache, "artifacts"))
  end

  # The cache dir is the agent's own, under its data dir.
  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_real_dir!(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:error, :enoent} ->
        File.mkdir_p!(path)

      other ->
        Logger.error("#{path} is not a directory (#{inspect(other)}): replaced with an empty one")
        File.rm_rf(path)
        File.mkdir_p!(path)
    end
  end

  @doc """
  The pairs of a `complete` answer's `warm` list with a well-formed `name`
  (an official `nerves_system_*` or `nerves_toolchain_*` package) and
  `version` (semantic), each at most 64 bytes, deduplicated, at most four.
  Anything else is dropped without a word: the portal chose the list, this
  only keeps a bad answer from naming an arbitrary package.
  """
  @spec pairs(term()) :: [pair()]
  def pairs(list) when is_list(list) do
    list
    |> Enum.flat_map(fn
      %{"name" => name, "version" => version} when is_binary(name) and is_binary(version) ->
        if valid_name?(name) and valid_version?(version),
          do: [%{name: name, version: version}],
          else: []

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Enum.take(@warm_pairs_per_run)
  end

  def pairs(_list), do: []

  defp valid_name?(name), do: byte_size(name) <= @max_field_bytes and Regex.match?(@name, name)

  defp valid_version?(version),
    do: byte_size(version) <= @max_field_bytes and match?({:ok, _}, Version.parse(version))

  @doc """
  Warms the shared cache with the pairs the portal named: `:skipped` when
  `pairs/1` leaves none, else one read-write `warm_nerves` container run
  under `<scratch>/<run_id>-warm`, removed afterwards (kept with
  `keep_scratch: true`, for tests).
  """
  @spec warm(Config.t(), map(), term(), keyword()) :: :ok | :skipped | {:error, term()}
  def warm(config, claim, pairs, opts \\ []) do
    case pairs(pairs) do
      [] -> :skipped
      pairs -> run_warm(config, claim, pairs, opts)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp run_warm(config, claim, pairs, opts) do
    run_id = "#{claim["run_id"]}-warm"
    scratch = Path.join(Config.path(config, :scratch), Argv.safe_name(run_id))
    dirs = dirs(scratch)
    runner_log = Path.join(scratch, "runner.log")
    File.rm_rf(scratch)

    try do
      Enum.each(Map.values(dirs), &File.mkdir_p!/1)
      prepare_cache(config)
      write_input(claim, run_id, pairs, dirs.work)

      # The warm container writes `staging/<run_id>` under the cache root and
      # renames finished artifacts into `artifacts/`, so both must be its.
      cache = Config.path(config, :nerves_cache)
      Fs.chown(config, Map.values(dirs), ["-R"])
      Fs.chown(config, [cache, Path.join(cache, "artifacts")], [])

      spec =
        config
        |> Job.argv_spec(Map.put(claim, "run_id", run_id), dirs)
        |> Map.put(:nerves_cache_mode, :warm)

      names = Enum.map_join(pairs, ", ", &"#{&1.name}-#{&1.version}")
      Logger.info("warming the Nerves cache with #{names} (#{run_id})")

      with :ok <- ensure_image(config, spec.image) do
        config |> Docker.run(Argv.build(spec), runner_log, @warm_timeout_ms) |> outcome(run_id)
      end
    after
      unless Keyword.get(opts, :keep_scratch, false), do: File.rm_rf(scratch)
    end
  end

  defp outcome({:ok, 0}, run_id) do
    Logger.info("warm #{run_id} exited 0")
    :ok
  end

  defp outcome({:ok, code}, run_id) do
    Logger.warning("warm #{run_id} exited #{code}")
    {:error, {:exit, code}}
  end

  defp outcome({:error, reason} = error, run_id) do
    Logger.warning("warm #{run_id} failed: #{inspect(reason)}")
    error
  end

  defp ensure_image(config, image) do
    if Docker.present?(config, image), do: :ok, else: Docker.pull(config, image)
  end

  defp dirs(scratch) do
    %{
      work: Path.join(scratch, "work"),
      out: Path.join(scratch, "out"),
      files: Path.join(scratch, "files"),
      tmp: Path.join(scratch, "tmp"),
      cache: Path.join(scratch, "cache")
    }
  end

  # The build's input with its package-specific parts dropped, as
  # `Portal.Workers.WarmNerves` shapes a local warm.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_input(claim, run_id, pairs, work_dir) do
    input =
      claim
      |> Map.get("input", %{})
      |> Map.drop(["package", "systems_filter", "argus", "egress_probe"])
      |> Map.merge(%{
        "mode" => "warm_nerves",
        "nerves_packages" => Enum.map(pairs, &%{"name" => &1.name, "version" => &1.version}),
        "run_id" => run_id
      })

    File.write!(Path.join(work_dir, "input.json"), Jason.encode_to_iodata!(input))
  end
end
