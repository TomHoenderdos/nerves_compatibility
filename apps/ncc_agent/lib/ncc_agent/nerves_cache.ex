defmodule NccAgent.NervesCache do
  @moduledoc """
  The per-run view of the shared Nerves cache and its allowlisted warm
  (isolation design, section 1).

  A build mounts `<data>/nerves-cache` read-only at `/nerves-cache` and gets
  its own `work/nerves/artifacts/`: one symlink per cache entry, pointing at
  the container path `/nerves-cache/artifacts/<entry>`, so a cached artifact
  resolves through its link and a missing or mismatched one is extracted
  into the run's own dir (Nerves' `File.rm_rf!` on a mismatch removes the
  link, never the target). `work/nerves/dl/` starts empty.

  After a passing build, `warm/3` runs a second, trusted container with the
  cache mounted read-write in `warm_nerves` mode, for the run's misses that
  the portal's allowlist (`claim["warm_allowlist"]`) names, at most
  `@warm_pairs_per_run` of them. The agent never has an allowlist of its own.
  """

  require Logger

  alias Compatibility.Builder.Argv
  alias NccAgent.{Config, Docker, Fs, Job}

  @artifacts "/work/nerves/artifacts"
  @dl "/work/nerves/dl"
  @container_cache_artifacts "/nerves-cache/artifacts"
  @warm_pairs_per_run 4
  @warm_timeout_ms 2 * 60 * 60 * 1000
  @max_field_bytes 64
  @name ~r/\A[a-z][a-z0-9_]*\z/

  @type prepared :: %{
          env: [{String.t(), String.t()}],
          artifacts_dir: Path.t(),
          dl_dir: Path.t()
        }

  @type pair :: %{name: String.t(), version: String.t()}

  @doc """
  Creates the run's Nerves dirs under `work_dir`: the symlink farm onto the
  cache's artifacts and an empty dl dir. Returns the worker env for them.

  The cache root and its `artifacts` must be real directories: a warm
  container has them read-write and could leave a symlink (to `/etc`, say)
  that the agent, as root, would otherwise list and chown. Anything else is
  logged, removed (`File.rm_rf/1` removes a link, not its target) and
  recreated empty; it is only a cache. Only directory entries are linked.
  """
  @spec prepare(Config.t(), Path.t()) :: prepared()
  # `work_dir` is the job's own scratch dir; the cache dir is the agent's.
  # sobelow_skip ["Traversal.FileModule"]
  def prepare(config, work_dir) do
    cache = Config.path(config, :nerves_cache)
    cache_artifacts = Path.join(cache, "artifacts")
    ensure_real_dir!(cache)
    ensure_real_dir!(cache_artifacts)

    artifacts = Path.join(work_dir, "nerves/artifacts")
    dl = Path.join(work_dir, "nerves/dl")
    File.mkdir_p!(artifacts)
    File.mkdir_p!(dl)

    for entry <- File.ls!(cache_artifacts) |> Enum.sort(),
        real_dir?(Path.join(cache_artifacts, entry)) do
      File.ln_s!(Path.join(@container_cache_artifacts, entry), Path.join(artifacts, entry))
    end

    %{
      env: [{"NERVES_ARTIFACTS_DIR", @artifacts}, {"NERVES_DL_DIR", @dl}],
      artifacts_dir: artifacts,
      dl_dir: dl
    }
  end

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

  defp real_dir?(path), do: match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))

  @doc """
  The run's reported cache misses (`result["nerves_cache"]["misses"]`) with
  well-formed `name` (`[a-z][a-z0-9_]*`) and `version` (a semantic
  version), each at most 64 bytes, deduplicated. Untrusted: the worker
  reports it. `allowed/2` bounds the count.
  """
  @spec misses(map() | nil) :: [pair()]
  def misses(%{"nerves_cache" => %{"misses" => misses}}) when is_list(misses) do
    misses
    |> Enum.flat_map(fn
      %{"name" => name, "version" => version} when is_binary(name) and is_binary(version) ->
        if valid_name?(name) and valid_version?(version),
          do: [%{name: name, version: version}],
          else: []

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  def misses(_result), do: []

  defp valid_name?(name), do: byte_size(name) <= @max_field_bytes and Regex.match?(@name, name)

  defp valid_version?(version),
    do: byte_size(version) <= @max_field_bytes and match?({:ok, _}, Version.parse(version))

  @doc "The first four (`@warm_pairs_per_run`) pairs whose name is in the portal's `allowlist`."
  @spec allowed([pair()], [String.t()] | nil) :: [pair()]
  def allowed(misses, allowlist) when is_list(allowlist) do
    allowed = MapSet.new(allowlist, &to_string/1)

    misses
    |> Enum.filter(&MapSet.member?(allowed, &1.name))
    |> Enum.take(@warm_pairs_per_run)
  end

  def allowed(_misses, _allowlist), do: []

  @doc """
  Warms the shared cache with the run's allowlisted misses: `:skipped` when
  there are none, else one read-write `warm_nerves` container run under
  `<scratch>/<run_id>-warm`, removed afterwards (kept with
  `keep_scratch: true`, for tests).
  """
  @spec warm(Config.t(), map(), map() | nil, keyword()) :: :ok | :skipped | {:error, term()}
  def warm(config, claim, result, opts \\ []) do
    case allowed(misses(result), claim["warm_allowlist"]) do
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
      nerves = prepare(config, dirs.work)
      write_input(claim, run_id, pairs, dirs.work)

      cache = Config.path(config, :nerves_cache)
      Fs.chown(config, Map.values(dirs), ["-R"])
      Fs.chown(config, [cache, Path.join(cache, "artifacts")], [])

      spec =
        config
        |> Job.argv_spec(Map.put(claim, "run_id", run_id), dirs, nerves.env)
        |> Map.merge(%{nerves_cache_mode: :readwrite, hardening: true})

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

  # sobelow_skip ["Traversal.FileModule"]
  defp write_input(claim, run_id, pairs, work_dir) do
    input =
      claim
      |> Map.get("input", %{})
      |> Map.drop(["systems_filter", "argus"])
      |> Map.merge(%{
        "mode" => "warm_nerves",
        "nerves_packages" => Enum.map(pairs, &%{"name" => &1.name, "version" => &1.version}),
        "run_id" => run_id
      })

    File.write!(Path.join(work_dir, "input.json"), Jason.encode_to_iodata!(input))
  end
end
