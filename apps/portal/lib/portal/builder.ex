defmodule Portal.Builder do
  @moduledoc """
  Host-side Docker invocation for a single package build.

  Host-side replacement for the retired standalone runner. Keeps the `docker run`
  invocation contract stable for the worker: same mounts (`/work`, `/out`, `/files`,
  `/home/nerves/.nerves` ← nerves cache,
  `/hex-cache` ← hex cache), `--user uid:gid`, `--pull=never`, the worker image,
  `NCC_INPUT=/work/input.json`, container naming, and a wall-clock timeout.

  This module never writes to the database. `Portal.Workers.Build` calls
  `build/2`, interprets the returned exit code, and ingests the parsed
  `result.json` into `Portal.Catalog`.
  """

  require Logger

  # See `read_log/1`.
  @log_tail_bytes 1024 * 1024

  @total_timeout_ms :timer.hours(2)
  @zero_digest "sha256:0000000000000000000000000000000000000000000000000000000000000000"

  @type build_args :: %{
          required(:package) => String.t(),
          required(:version) => String.t(),
          required(:run_id) => String.t(),
          optional(:image) => String.t(),
          optional(:image_digest) => String.t(),
          optional(:systems_filter) => [String.t()] | nil
        }

  @type build_result :: %{
          exit_code: non_neg_integer(),
          result: map() | nil,
          files_dir: Path.t(),
          output_dir: Path.t(),
          log: String.t()
        }

  # ── Config ───────────────────────────────────────────────────────────────

  @doc "Configured worker docker image (tag or name@digest)."
  @spec docker_image() :: String.t()
  def docker_image, do: config(:docker_image, "ncc-worker:local")

  @doc "Root directory for per-run scratch dirs."
  @spec scratch_root() :: Path.t()
  def scratch_root, do: config(:scratch_root, Path.expand("~/.ncc-scratch"))

  @doc "Host path for the shared Nerves cache (mounted at /home/nerves/.nerves)."
  @spec nerves_cache() :: Path.t()
  def nerves_cache, do: config(:nerves_cache, Path.expand("~/.ncc-nerves-cache"))

  @doc "Host path for the shared Hex cache (mounted at /hex-cache)."
  @spec hex_cache() :: Path.t()
  def hex_cache, do: config(:hex_cache, Path.expand("~/.ncc-hex-cache"))

  @doc """
  Host path for the shared dependency build cache, or nil when it is off.

  Unset is the default and means the worker compiles every dependency from
  scratch, which is what it did before the cache existed. That makes turning it
  off a config change rather than a deploy, which is what you want for something
  whose failure mode is subtly wrong artifacts rather than a crash.
  """
  @spec build_cache() :: Path.t() | nil
  def build_cache, do: config(:build_cache, nil)

  @doc """
  Minimum free bytes on the scratch filesystem required to start a build.

  One scratch tree is ~3.5G and the build host runs `builds:3`, so three can be
  live at once. 25G is roughly two builds of headroom above that worst case.

  This is a per-build check at start, not a reservation: three builds can each
  pass it and still fill the disk between them. It turns a full disk into a
  clean, visible refusal instead of an `:enospc` mid-stream — maintaining the
  headroom in the first place is `Portal.Workers.Sweep`'s job.
  """
  @spec min_free_bytes() :: non_neg_integer()
  def min_free_bytes do
    # Env vars arrive as strings; config.exs supplies a number.
    case :min_free_disk_gb |> config(25) |> to_string() |> Float.parse() do
      {gb, _rest} -> trunc(gb * 1024 * 1024 * 1024)
      :error -> 25 * 1024 * 1024 * 1024
    end
  end

  @doc """
  Hard wall-clock ceiling for one build, in milliseconds.

  Exposed so the Oban config test can assert `Lifeline`'s `rescue_after` still
  sits above it. Rescuing a build that is genuinely still running starts a second
  container and a second multi-gigabyte scratch tree for the same work.
  """
  @spec total_timeout_ms() :: pos_integer()
  def total_timeout_ms, do: @total_timeout_ms

  defp config(key, default) do
    :portal
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Check that Docker is available; returns its server version.
  """
  @spec check_docker() :: {:ok, String.t()} | {:error, String.t()}
  def check_docker do
    case System.cmd("docker", ["version", "--format", "{{.Server.Version}}"],
           stderr_to_stdout: true
         ) do
      {version, 0} -> {:ok, String.trim(version)}
      {error, _} -> {:error, "Docker not available: #{error}"}
    end
  rescue
    e in ErlangError -> {:error, "Docker not available: #{Exception.message(e)}"}
  end

  @doc """
  Run one package build in a worker container and read its `result.json`.

  Creates per-run scratch dirs (`work_dir`/`output_dir`/`files_dir`) under
  `scratch_root/<run_id>`, writes `input.json`, runs the container, and reads
  `/out/result.json`.

  Returns `{:ok, %{exit_code:, result:, files_dir:, output_dir:, log:}}` where
  `result` is the parsed `result.json` (or `nil` if the container produced none).
  The caller maps `exit_code` → outcome. `{:error, reason}` is reserved for
  runner-side failures (docker unavailable, scratch setup, etc).
  """
  @spec build(build_args(), keyword()) :: {:ok, build_result()} | {:error, term()}
  def build(args, opts \\ []) do
    run_id = Map.fetch!(args, :run_id)
    image = Map.get(args, :image) || docker_image()
    image_digest = Map.get(args, :image_digest) || image_digest(image)

    scratch = Path.join(opts[:scratch_root] || scratch_root(), safe_name(run_id))
    work_dir = Path.join(scratch, "work")
    output_dir = Path.join(scratch, "out")
    files_dir = Path.join(scratch, "files")
    log_file = Path.join(output_dir, "runner.log")

    job = %{
      run_id: run_id,
      image_name: image,
      image_digest: image_digest,
      package: %{
        "name" => Map.fetch!(args, :package),
        "version" => Map.fetch!(args, :version),
        "source" => "hex"
      },
      systems_filter: Map.get(args, :systems_filter)
    }

    # Free space first: it is the cheapest check in the chain, and it is the
    # condition most likely to be true during an incident. Ahead of
    # `ensure_directories/1` so a refusal leaves nothing at all on disk, and
    # ahead of `check_docker/0` so the log carries the disk error rather than a
    # downstream `:enospc` from `IO.binwrite/2` — which is the exception that
    # took the host down.
    with :ok <- check_free_space(scratch_root()),
         {:ok, _version} <- check_docker(),
         :ok <- ensure_directories([work_dir, output_dir, files_dir, nerves_cache(), hex_cache()]),
         :ok <- write_worker_input(job, work_dir),
         {:ok, exit_code} <- run_container(job, work_dir, output_dir, files_dir, log_file) do
      result = read_result_json(output_dir)
      log = read_log(log_file)

      {:ok,
       %{
         exit_code: exit_code,
         result: result,
         files_dir: files_dir,
         output_dir: output_dir,
         log: log
       }}
    end
  end

  @doc """
  Re-read a finished run's output from its scratch directory.

  The counterpart to `build/2` for `Portal.Workers.Ingest`, which runs as a
  separate job and so cannot be handed the return value of the build that
  produced it. Same shape as `build/2` returns, minus a meaningful exit code:
  reaching this point at all means the container exited 0.

  `{:error, :missing_result_json}` means the scratch dir is gone or never held a
  result, which no retry can fix.
  """
  @spec load_run(String.t()) :: {:ok, build_result()} | {:error, term()}
  def load_run(run_id) do
    scratch = Path.join(scratch_root(), safe_name(run_id))
    output_dir = Path.join(scratch, "out")
    files_dir = Path.join(scratch, "files")

    case read_result_json(output_dir) do
      nil ->
        {:error, :missing_result_json}

      result ->
        {:ok,
         %{
           exit_code: 0,
           result: result,
           files_dir: files_dir,
           output_dir: output_dir,
           log: read_log(Path.join(output_dir, "runner.log"))
         }}
    end
  end

  @doc """
  Remove a run's scratch directory. Best-effort.
  """
  @spec cleanup(String.t()) :: :ok
  def cleanup(run_id) do
    _ = File.rm_rf(Path.join(scratch_root(), safe_name(run_id)))
    :ok
  end

  @doc """
  Where a run's `runner.log` lives. The file may not exist.

  Failure paths that never got a `build` map still want the log, and it is about
  to be deleted along with the scratch dir. A path rather than the bytes: the
  only consumer keeps the last 16 KB, and one of its callers is the crash path,
  where what crashed the build is often a full disk. `LogSanitizer` reads the
  tail it needs and nothing else.
  """
  @spec runner_log_path(String.t()) :: Path.t()
  def runner_log_path(run_id) do
    scratch_root()
    |> Path.join(safe_name(run_id))
    |> Path.join("out")
    |> Path.join("runner.log")
  end

  @doc """
  Resolve the digest for a (usually local) image via `docker inspect`.

  Local images have no RepoDigest, so we fall back to the image Id. Returns a
  normalized `sha256:<64-hex>` string, or a zero digest if it can't be read.
  """
  @spec image_digest(String.t()) :: String.t()
  def image_digest(image_name) do
    case System.cmd("docker", ["inspect", "--format={{.Id}}", image_name], stderr_to_stdout: true) do
      {id, 0} -> id |> String.trim() |> normalize_digest()
      {_error, _} -> @zero_digest
    end
  rescue
    _ -> @zero_digest
  end

  @doc """
  Free bytes on the filesystem holding `path`, or nil when it cannot be measured.

  `df -Pk` rather than `:disksup`: os_mon is not started, and starting it would
  run memsup and cpu_sup on every node including the web host and every test run.
  `:disksup` also answers from a table it refreshes every 30 minutes — stale in
  the one direction that matters, since during a fill it reports the free space
  from before the fill began. `-P` is POSIX and gives identical single-line
  output on macOS (dev) and Linux (prod).
  """
  @spec free_bytes(Path.t()) :: non_neg_integer() | nil
  def free_bytes(path) do
    with dir when is_binary(dir) <- existing_ancestor(path),
         {out, 0} <- System.cmd("df", ["-Pk", dir], stderr_to_stdout: true),
         [_header, line | _] <- String.split(out, "\n", trim: true),
         [_fs, _blocks, _used, avail | _] <- String.split(line, ~r/\s+/, trim: true),
         {kb, ""} <- Integer.parse(avail) do
      kb * 1024
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Names of the docker containers running right now.

  `Portal.Workers.Sweep` uses this to refuse to delete the scratch dir of a build
  that is still executing. Returns an empty set when docker cannot be reached: a
  docker outage does not make directories live, and failing the sweep closed
  would disable reclamation exactly when the disk is most likely to be the
  underlying problem. The sweep's age floor is what makes that safe to do.
  """
  @spec running_containers() :: MapSet.t(String.t())
  def running_containers do
    case System.cmd("docker", ["ps", "--format", "{{.Names}}"], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split("\n", trim: true) |> MapSet.new(&String.trim/1)
      {_out, _status} -> MapSet.new()
    end
  rescue
    _ -> MapSet.new()
  end

  @doc """
  Directory name under `build_cache/0` for an image digest.

  `Portal.Workers.Sweep` prunes that directory, so the writer and the pruner have
  to agree on this exactly — if the two sanitizers ever drift apart, the sweep
  deletes the live cache. One function, one regex.
  """
  @spec cache_slug(String.t()) :: String.t()
  def cache_slug(digest), do: String.replace(digest, ~r/[^A-Za-z0-9._-]/, "_")

  @doc """
  Scratch directory name for a run id.

  Public because `Portal.Workers.Sweep` has to map a directory on disk back to
  the `run_id` in an Oban job's args, and must use this exact transform to do it.
  """
  @spec safe_name(String.t()) :: String.t()
  def safe_name(run_id), do: String.replace(run_id, ~r/[^A-Za-z0-9_.\-]/, "_")

  # ── Internals ──────────────────────────────────────────────────────────────

  defp ensure_directories(dirs) do
    Enum.each(dirs, &File.mkdir_p!/1)
    :ok
  rescue
    e -> {:error, {:scratch_setup_failed, Exception.message(e)}}
  end

  defp check_free_space(path) do
    required = min_free_bytes()

    case free_bytes(path) do
      nil ->
        # A preflight that cannot measure must not block every build. This leaves
        # the pre-existing failure mode (fill up, crash on :enospc) exactly as it
        # was, so nothing regresses when `df` is unavailable.
        Logger.warning("Could not measure free space on #{path}; skipping preflight")
        :ok

      free when free >= required ->
        :ok

      free ->
        {:error, {:insufficient_disk, free, required}}
    end
  end

  # `~/.ncc-scratch` does not exist until the first build creates it, and `df` on
  # a missing path exits non-zero.
  defp existing_ancestor("/"), do: "/"
  defp existing_ancestor("."), do: "."

  defp existing_ancestor(path) do
    if File.dir?(path), do: path, else: existing_ancestor(Path.dirname(path))
  end

  defp write_worker_input(job, work_dir) do
    input =
      %{
        "run_id" => job.run_id,
        "image" => %{"name" => job.image_name, "digest" => job.image_digest},
        "package" => job.package,
        "paths" => %{
          "work_dir" => "/work",
          "output_dir" => "/out",
          "files_dir" => "/files"
        }
      }
      |> maybe_put("systems_filter", job.systems_filter)

    File.write!(Path.join(work_dir, "input.json"), Jason.encode_to_iodata!(input))
    :ok
  rescue
    e -> {:error, {:input_write_failed, Exception.message(e)}}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp run_container(job, work_dir, output_dir, files_dir, log_file) do
    args = build_docker_args(job, work_dir, output_dir, files_dir)
    container_name = container_name(job.run_id)
    log_command(args, log_file)

    case run_docker(args, log_file, container_name) do
      {:ok, exit_code} -> {:ok, exit_code}
      {:error, reason} -> {:error, {:docker_execution_failed, reason}}
    end
  end

  @doc false
  # Builds the docker run argument list. Mounts and flags intentionally preserve
  # the worker container environment expected by apps/ncc_worker.
  @spec build_docker_args(map(), Path.t(), Path.t(), Path.t()) :: [String.t()]
  def build_docker_args(job, work_dir, output_dir, files_dir) do
    base = [
      "run",
      "--rm",
      "--pull=never",
      "--name",
      container_name(job.run_id),
      "--user",
      run_as_user(),
      "--cap-drop=ALL",
      "--security-opt=no-new-privileges"
    ]

    limits = resource_limits()

    mounts =
      List.flatten([
        ["--mount", "type=bind,source=#{work_dir},target=/work"],
        ["--mount", "type=bind,source=#{output_dir},target=/out"],
        ["--mount", "type=bind,source=#{files_dir},target=/files"],
        ["--mount", "type=bind,source=#{nerves_cache()},target=/home/nerves/.nerves"],
        ["--mount", "type=bind,source=#{hex_cache()},target=/hex-cache"],
        build_cache_mount(job)
      ])

    env = [
      "-e",
      "NCC_INPUT=/work/input.json",
      "-e",
      "LANG=C.UTF-8",
      "-e",
      "HOME=/home/nerves",
      "-e",
      "HEX_HOME=/hex-cache",
      # Nerves extracts prebuilt system tarballs with the external `tar`, and
      # GNU tar restores ownership by default when it believes it is root. On a
      # rootless daemon run_as_user is "0:0", so it does believe that, and every
      # chown then fails against --cap-drop=ALL: tar exits 2 and
      # Nerves.Artifact.Cache.put/2 raises. Dropping the chown is the fix, not
      # granting CAP_CHOWN back to a container that builds untrusted package
      # code. Under a rootful daemon we run as our own non-root uid, where this
      # is already tar's default, so it is a no-op there.
      "-e",
      "TAR_OPTIONS=--no-same-owner"
    ]

    base ++
      limits ++
      mounts ++ env ++ build_cache_env(job) ++ cpu_env() ++ concurrency_env() ++ [image_ref(job)]
  end

  # The cache is mounted per worker image rather than as one flat directory.
  # Artifacts are only interchangeable between builds that used the same Elixir,
  # OTP and Nerves toolchain, and the image is what pins all three, so making it
  # part of the path means a rebuilt image starts from an empty cache instead of
  # inheriting entries it cannot vouch for. The worker's own cache key covers
  # everything below that line; this covers the line itself.
  defp build_cache_mount(job) do
    case build_cache_dir(job) do
      nil -> []
      dir -> ["--mount", "type=bind,source=#{dir},target=/build-cache"]
    end
  end

  defp build_cache_env(job) do
    case build_cache_dir(job) do
      nil -> []
      _dir -> ["-e", "NCC_BUILD_CACHE=/build-cache"]
    end
  end

  # Created here rather than by the deployment: the directory is per image, so
  # its name is not known until a build runs. A failure to create it disables the
  # cache for that build instead of failing it, since a cache that cannot be
  # written is a slowdown and not an error.
  defp build_cache_dir(job) do
    case build_cache() do
      nil ->
        nil

      root ->
        dir = Path.join(root, image_slug(job))

        case File.mkdir_p(dir) do
          :ok -> dir
          {:error, _reason} -> nil
        end
    end
  end

  defp image_slug(job), do: cache_slug(job.image_digest || job.image_name || "unknown")

  # `--cpus` is a CFS quota, not a core assignment: `nproc` inside the container
  # still reports every core the host has. Nothing in the build reads the quota,
  # so each container started a BEAM with one scheduler per *host* core, and BEAM
  # schedulers busy-wait by default. Five concurrent builds on six cores left the
  # host at 21% system time with a run queue of 20: a fifth of the machine spent
  # spinning and being throttled instead of compiling. Tell the runtimes how much
  # CPU they actually have.
  #
  # ERL_FLAGS covers the worker's own VM and any `erl` it starts; mix and elixir
  # read ELIXIR_ERL_OPTIONS instead, and that is where the compile parallelism
  # lives. MAKEFLAGS caps the C builds that NIF-carrying deps kick off.
  defp cpu_env do
    case cpu_quota() do
      nil ->
        []

      quota ->
        beam_flags = "+S #{quota}:#{quota} +sbwt none +sbwtdcpu none +sbwtdio none"

        [
          "-e",
          "ERL_FLAGS=#{beam_flags}",
          "-e",
          "ELIXIR_ERL_OPTIONS=#{beam_flags}",
          "-e",
          "MAKEFLAGS=-j#{quota}"
        ]
    end
  end

  # Whole cores only, and never zero: a fractional cap still needs at least one
  # scheduler to make progress.
  defp cpu_quota do
    with value when not is_nil(value) <- config(:cpus, nil),
         {cpus, _rest} <- Float.parse(to_string(value)) do
      max(1, trunc(cpus))
    else
      _ -> nil
    end
  end

  # How many targets the worker may build at once inside one container. Unset
  # means one, the serial behaviour this started with. Worth raising only
  # together with the CPU cap: the targets share whatever `--cpus` allows, and
  # the gain comes from overlapping the single-threaded stretches (release
  # assembly, squashfs, fwup), not from finding more cores.
  defp concurrency_env do
    case config(:build_concurrency, nil) do
      nil -> []
      value -> ["-e", "NCC_BUILD_CONCURRENCY=#{value}"]
    end
  end

  # Buildroot cross-compiles will use every core they are given. On a host that
  # shares the machine with other services, an unbounded build starves them, so
  # deployments can cap what a single build may take. Unset means unbounded,
  # which is the historical behaviour and stays the default.
  defp resource_limits do
    [{:cpus, "--cpus"}, {:memory, "--memory"}]
    |> Enum.flat_map(fn {key, flag} ->
      case config(key, nil) do
        nil -> []
        value -> [flag, to_string(value)]
      end
    end)
  end

  # Local images (no registry slash) use the tag directly; remote images use
  # name@digest for reproducibility.
  defp image_ref(%{image_name: name, image_digest: digest}) do
    if String.contains?(name, "/"), do: "#{name}@#{digest}", else: name
  end

  # Matching our own uid keeps bind-mounted output owned by us on a normal
  # daemon. Under rootless Docker it does the opposite: the daemon runs in a
  # user namespace where our uid is already 0, so passing it literally lands
  # container writes on a subuid we cannot read back. Rootless hosts set
  # "0:0", which maps to the service user outside the namespace.
  defp run_as_user do
    case config(:run_as_user, nil) do
      nil ->
        {uid, gid} = current_user()
        "#{uid}:#{gid}"

      value ->
        to_string(value)
    end
  end

  defp current_user do
    {uid, 0} = System.cmd("id", ["-u"])
    {gid, 0} = System.cmd("id", ["-g"])
    {String.trim(uid), String.trim(gid)}
  end

  # Docker container names must match [a-zA-Z0-9][a-zA-Z0-9_.-]*. The "ncc-"
  # prefix guarantees a valid leading char.
  defp container_name(run_id), do: "ncc-#{safe_name(run_id)}"

  defp log_command(args, log_file), do: File.write!(log_file, command_log_header(args))

  @doc false
  # Public only so `Portal.Catalog.LogSanitizer`'s tests can assert against the
  # real header instead of a hand-copied one. The sanitizer strips this block
  # before the excerpt reaches the public request page, and it carries the full
  # docker argv and the host mount paths.
  @spec command_log_header([String.t()]) :: String.t()
  def command_log_header(args) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    """
    ================================================================================
    Portal.Builder - Docker Execution Log
    Started: #{timestamp}
    Command: docker #{Enum.join(args, " ")}
    ================================================================================

    """
  end

  defp run_docker(args, log_file, container_name) do
    log_device = File.open!(log_file, [:append])
    deadline = System.monotonic_time(:millisecond) + @total_timeout_ms

    try do
      port =
        Port.open(
          {:spawn_executable, System.find_executable("docker")},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: Enum.map(args, &String.to_charlist/1)
          ]
        )

      receive_docker_output(port, log_device, deadline, container_name)
    after
      File.close(log_device)
    end
  end

  defp receive_docker_output(port, log_device, deadline, container_name) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        IO.binwrite(log_device, data)
        receive_docker_output(port, log_device, deadline, container_name)

      {^port, {:exit_status, status}} ->
        footer = """

        ================================================================================
        Docker exit status: #{status}
        Completed: #{DateTime.utc_now() |> DateTime.to_iso8601()}
        ================================================================================
        """

        IO.write(log_device, footer)
        {:ok, status}
    after
      remaining ->
        force_kill_container(container_name, log_device)
        Port.close(port)

        {:error,
         "Docker command exceeded #{div(@total_timeout_ms, 1000)}s wall-clock timeout; " <>
           "container #{container_name} was killed"}
    end
  end

  defp force_kill_container(container_name, log_device) do
    _ = System.cmd("docker", ["kill", container_name], stderr_to_stdout: true)

    try do
      IO.write(
        log_device,
        "\n[builder] Wall-clock timeout exceeded - killed container #{container_name}\n"
      )
    rescue
      _ -> :ok
    end

    :ok
  end

  defp read_result_json(output_dir) do
    path = Path.join(output_dir, "result.json")

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, parsed} <- Jason.decode(content) do
      parsed
    else
      _ -> nil
    end
  end

  # The tail, never the whole file. This runs on the ingest path, where the only
  # two consumers are a 16 KB sanitized excerpt and a `catalog_runs.log` column
  # nothing in the app reads — and `runner.log` is written by streaming docker's
  # output, so its size is decided by a third-party build rather than by us. A
  # package stuck in a retry loop can emit gigabytes; `File.read/1` allocated
  # every byte of that inside the ingest transaction, three at a time on
  # `ingest:3`, only for both consumers to throw nearly all of it away.
  #
  # 1 MB is far above any honest log — production averages ~41 KB per run — and
  # it is the end that matters: whatever killed the runner is the last thing it
  # printed.
  #
  # `lstat` before opening, so the file is refused rather than followed if it is
  # a symlink. `/out` is a read-write bind mount and the container runs as the
  # invoking host user, so package code can leave `runner.log` pointing at any
  # file that user can read.
  defp read_log(log_file) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(log_file),
         {:ok, fd} <- :file.open(log_file, [:read, :binary, :raw]) do
      try do
        offset = max(size - @log_tail_bytes, 0)

        case :file.pread(fd, offset, min(size, @log_tail_bytes)) do
          {:ok, content} -> content
          _ -> ""
        end
      after
        :file.close(fd)
      end
    else
      _ -> ""
    end
  end

  defp normalize_digest(digest) do
    case String.split(digest, ":", parts: 2) do
      ["sha256", hash] ->
        hash = String.slice(hash, 0, 64)

        if String.length(hash) == 64 and String.match?(hash, ~r/^[0-9a-f]+$/i) do
          "sha256:#{String.downcase(hash)}"
        else
          @zero_digest
        end

      _ ->
        @zero_digest
    end
  end
end
