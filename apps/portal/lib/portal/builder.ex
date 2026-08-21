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

    with {:ok, _version} <- check_docker(),
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
  Remove a run's scratch directory. Best-effort.
  """
  @spec cleanup(String.t()) :: :ok
  def cleanup(run_id) do
    _ = File.rm_rf(Path.join(scratch_root(), safe_name(run_id)))
    :ok
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

  # ── Internals ──────────────────────────────────────────────────────────────

  defp ensure_directories(dirs) do
    Enum.each(dirs, &File.mkdir_p!/1)
    :ok
  rescue
    e -> {:error, {:scratch_setup_failed, Exception.message(e)}}
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
        ["--mount", "type=bind,source=#{hex_cache()},target=/hex-cache"]
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

    base ++ limits ++ mounts ++ env ++ [image_ref(job)]
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

  defp safe_name(run_id), do: String.replace(run_id, ~r/[^A-Za-z0-9_.\-]/, "_")

  defp log_command(args, log_file) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    header = """
    ================================================================================
    Portal.Builder - Docker Execution Log
    Started: #{timestamp}
    Command: docker #{Enum.join(args, " ")}
    ================================================================================

    """

    File.write!(log_file, header)
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

  defp read_log(log_file) do
    case File.read(log_file) do
      {:ok, content} -> content
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
