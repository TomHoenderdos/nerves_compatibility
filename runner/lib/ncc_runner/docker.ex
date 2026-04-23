defmodule NccRunner.Docker do
  @moduledoc """
  Docker container execution with security hardening and platform compatibility.

  Handles:
  - Building docker run commands with appropriate flags
  - Graceful degradation on macOS where some flags aren't supported
  - Capturing stdout/stderr and exit codes
  - Validating Docker availability
  """

  require Logger

  alias NccRunner.Job

  @type run_opts :: %{
          work_dir: Path.t(),
          output_dir: Path.t(),
          files_dir: Path.t(),
          cache_dir: nil | Path.t(),
          log_file: Path.t()
        }

  @type run_result :: %{
          exit_code: non_neg_integer(),
          duration_ms: non_neg_integer(),
          docker_version: String.t(),
          flags_skipped: [String.t()]
        }

  # Wall-clock ceiling for a single docker run. A noisy build that keeps
  # emitting output can't extend this the way the old per-message receive
  # timeout allowed — see commit history for the 7-hour zombie container
  # this replaces.
  @total_timeout_ms :timer.hours(2)

  @doc """
  Check if Docker is available and get version info.
  """
  @spec check_docker() :: {:ok, String.t()} | {:error, String.t()}
  def check_docker() do
    case System.cmd("docker", ["version", "--format", "{{.Server.Version}}"],
           stderr_to_stdout: true
         ) do
      {version, 0} ->
        {:ok, String.trim(version)}

      {error, _} ->
        {:error, "Docker not available: #{error}"}
    end
  end

  @doc """
  Run a Docker container for the given job.

  Returns a map with exit code, duration, and metadata about the run.
  """
  @spec run(Job.t(), run_opts()) :: {:ok, run_result()} | {:error, String.t()}
  def run(%Job{} = job, opts) do
    start_time = System.monotonic_time(:millisecond)

    container_name = container_name(job)

    with {:ok, docker_version} <- check_docker(),
         :ok <- ensure_directories(opts),
         :ok <- write_worker_input(job, opts.work_dir, opts.files_dir),
         {args, flags_skipped} <- build_docker_args(job, opts) do
      log_command(args, opts.log_file)

      case run_docker(args, opts.log_file, container_name) do
        {:ok, exit_code} ->
          duration_ms = System.monotonic_time(:millisecond) - start_time

          result = %{
            exit_code: exit_code,
            duration_ms: duration_ms,
            docker_version: docker_version,
            flags_skipped: flags_skipped
          }

          {:ok, result}

        {:error, reason} ->
          {:error, "Docker execution failed: #{reason}"}
      end
    end
  end

  @doc """
  Build the complete docker run argument list.

  Returns {args, flags_skipped} where flags_skipped lists any flags
  that were omitted due to platform incompatibility.
  """
  @spec build_docker_args(Job.t(), run_opts()) :: {[String.t()], [String.t()]}
  def build_docker_args(%Job{} = job, opts) do
    flags_skipped = []

    # Base arguments. --name lets the timeout handler kill a specific
    # container by id rather than relying on Port.close (which closes the
    # Erlang-side pipe but leaves the docker subprocess running).
    base_args = [
      "run",
      "--rm",
      "--pull=never",
      "--name",
      container_name(job)
    ]

    # User configuration (needed for Linux to fix permissions)
    user_args = add_user_config(flags_skipped)

    # Security flags (best effort)
    {security_args, flags_skipped} = add_security_flags(flags_skipped)

    # Platform configuration
    platform_args =
      case docker_config(job, :platform) do
        nil -> detect_platform_args()
        platform -> ["--platform", platform]
      end

    # Resource limits
    {resource_args, flags_skipped} = add_resource_limits(job, flags_skipped)

    # Network configuration
    network_args = add_network_config(job)

    # Volume mounts
    mount_args = build_mounts(opts)

    # Environment variables
    env_args = build_env_vars(opts)

    # Image reference
    image_arg = Job.image_ref(job)

    args =
      base_args ++
        user_args ++
        security_args ++
        platform_args ++
        resource_args ++
        network_args ++
        mount_args ++
        env_args ++
        [image_arg]

    {args, flags_skipped}
  end

  # Private helpers

  defp ensure_directories(opts) do
    dirs = [opts.work_dir, opts.output_dir, opts.files_dir]
    dirs = if opts.cache_dir, do: [opts.cache_dir | dirs], else: dirs

    Enum.each(dirs, &File.mkdir_p!/1)
    :ok
  end

  defp write_worker_input(%Job{} = job, work_dir, _files_dir) do
    input_path = Path.join(work_dir, "input.json")

    input_data =
      job
      |> Job.worker_input()
      |> Map.put("paths", %{
        "work_dir" => "/work",
        "output_dir" => "/out",
        "files_dir" => "/files"
      })

    json = input_data |> JSON.encode_to_iodata!()
    File.write!(input_path, json)
  end

  defp add_user_config(_flags_skipped) do
    # Run the container as the host user so bind-mounted files on Linux end up
    # owned by the invoker rather than the image's baked-in uid.
    {uid, gid} = current_user()
    ["--user", "#{uid}:#{gid}"]
  end

  defp current_user() do
    {uid, 0} = System.cmd("id", ["-u"])
    {gid, 0} = System.cmd("id", ["-g"])
    {String.trim(uid), String.trim(gid)}
  end

  # Docker container names must match [a-zA-Z0-9][a-zA-Z0-9_.-]*. The "ncc-"
  # prefix guarantees a valid leading char; run_id gets any disallowed chars
  # (spaces, slashes, '+' in SemVer prereleases, etc.) replaced with '_'.
  defp container_name(%Job{run_id: run_id}) do
    safe = String.replace(run_id, ~r/[^A-Za-z0-9_.\-]/, "_")
    "ncc-#{safe}"
  end

  defp add_security_flags(flags_skipped) do
    # Try common security flags - some may not work on Docker Desktop for Mac
    security_flags = [
      "--cap-drop=ALL",
      "--security-opt=no-new-privileges"
    ]

    {security_flags, flags_skipped}
  end

  defp detect_platform_args() do
    # Let Docker use the native platform by default
    # Users can override via job.docker.platform if needed
    []
  end

  defp add_resource_limits(%Job{docker: docker}, flags_skipped) when is_map(docker) do
    args = []
    skipped = flags_skipped

    # Memory limit
    {args, skipped} =
      case Map.get(docker, :memory) do
        nil -> {args, skipped}
        memory -> {args ++ ["--memory", memory], skipped}
      end

    # CPU limit
    {args, skipped} =
      case Map.get(docker, :cpus) do
        nil -> {args, skipped}
        cpus -> {args ++ ["--cpus", cpus], skipped}
      end

    # PIDs limit (may not work on macOS)
    {args, skipped} =
      case Map.get(docker, :pids_limit) do
        nil ->
          {args, skipped}

        pids_limit ->
          # Try to add it, but note it might fail on macOS
          if macos?() do
            {args, ["--pids-limit (not supported on macOS)" | skipped]}
          else
            {args ++ ["--pids-limit", to_string(pids_limit)], skipped}
          end
      end

    {args, skipped}
  end

  defp add_resource_limits(_job, flags_skipped), do: {[], flags_skipped}

  defp add_network_config(%Job{docker: docker}) when is_map(docker) do
    args = []

    # Network mode
    args =
      case Map.get(docker, :network_mode) do
        nil -> args
        mode -> args ++ ["--network", mode]
      end

    # Extra hosts
    case Map.get(docker, :extra_hosts) do
      nil ->
        args

      hosts when is_list(hosts) ->
        Enum.reduce(hosts, args, fn host, acc ->
          acc ++ ["--add-host", host]
        end)

      _ ->
        args
    end
  end

  defp add_network_config(_job), do: []

  defp build_mounts(opts) do
    nerves_cache = System.get_env("NCC_NERVES_CACHE") || Path.expand("~/.ncc-nerves-cache")
    File.mkdir_p!(nerves_cache)

    mounts = [
      ["--mount", "type=bind,source=#{opts.work_dir},target=/work"],
      ["--mount", "type=bind,source=#{opts.output_dir},target=/out"],
      ["--mount", "type=bind,source=#{opts.files_dir},target=/files"],
      ["--mount", "type=bind,source=#{nerves_cache},target=/home/nerves/.nerves"]
    ]

    mounts =
      if opts.cache_dir do
        mounts ++ [["--mount", "type=bind,source=#{opts.cache_dir},target=/hex-cache"]]
      else
        mounts
      end

    List.flatten(mounts)
  end

  defp build_env_vars(opts) do
    # HOME points at the baked-in nerves user dir so Mix/Hex/Nerves find their
    # archives regardless of the runtime uid we're running as.
    base_vars = [
      "-e", "NCC_INPUT=/work/input.json",
      "-e", "LANG=C.UTF-8",
      "-e", "HOME=/home/nerves"
    ]

    if opts.cache_dir do
      base_vars ++ ["-e", "HEX_HOME=/hex-cache"]
    else
      base_vars
    end
  end

  defp docker_config(%Job{docker: docker}, key) when is_map(docker) do
    Map.get(docker, key)
  end

  defp docker_config(_job, _key), do: nil

  defp log_command(args, log_file) do
    command_line = "docker " <> Enum.join(args, " ")
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    header = """
    ================================================================================
    NCC Runner - Docker Execution Log
    Started: #{timestamp}
    ================================================================================
    Command: #{command_line}
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
    # Kill the container FIRST. Logging could raise (e.g. default-encoded log
    # devices can't transcode non-latin1 chars), and if that happens before
    # we call docker kill, the container outlives the runner — which is the
    # exact zombie-container class of bug this fix was meant to prevent. Use
    # ASCII-only text in the log message for the same reason.
    _ = System.cmd("docker", ["kill", container_name], stderr_to_stdout: true)

    try do
      IO.write(
        log_device,
        "\n[runner] Wall-clock timeout exceeded - killed container #{container_name}\n"
      )
    rescue
      _ -> :ok
    end

    :ok
  end

  defp macos?() do
    match?({:unix, :darwin}, :os.type())
  end
end
