defmodule NccAgent.Docker do
  @moduledoc """
  The agent's calls to `docker` (`config.docker_bin`): pull, inspect, kill
  (one container, or the leftovers of a previous boot), and one worker container run with its output appended to a log and a
  wall-clock deadline, past which the container is killed. Every call has
  a deadline; `runner.log` stops growing at `NccAgent.Caps`'
  `:runner_log_bytes` while the output keeps being drained.
  """

  require Logger

  alias NccAgent.{Caps, Config}

  @pull_timeout_ms 30 * 60_000
  @inspect_timeout_ms 60_000
  @kill_timeout_ms 60_000
  # What a short command's answer keeps of its output, for error messages.
  @output_bytes 65_536

  @doc "Pulls `image_ref`, for at most 30 minutes."
  @spec pull(Config.t(), String.t()) :: :ok | {:error, String.t()}
  def pull(config, image_ref) do
    case cmd(config, ["pull", image_ref], @pull_timeout_ms) do
      {:ok, _out, 0} -> :ok
      {:ok, out, status} -> {:error, "docker pull exited #{status}: #{String.trim(out)}"}
      {:error, :timeout} -> {:error, "docker pull timed out"}
      {:error, reason} -> {:error, "docker pull failed: #{inspect(reason)}"}
    end
  end

  @doc "Whether `image_ref` is in the local image store."
  @spec present?(Config.t(), String.t()) :: boolean()
  def present?(config, image_ref),
    do: match?({:ok, _, 0}, cmd(config, ["image", "inspect", image_ref], @inspect_timeout_ms))

  @doc "Kills container `name`, for at most 60 s; a failure is logged."
  @spec kill(Config.t(), String.t()) :: :ok | {:error, term()}
  def kill(config, name) do
    case cmd(config, ["kill", name], @kill_timeout_ms) do
      {:ok, _out, 0} ->
        :ok

      {:ok, out, status} ->
        Logger.warning("docker kill #{name} exited #{status}: #{String.trim(out)}")
        {:error, {:exit, status}}

      {:error, reason} ->
        Logger.warning("docker kill #{name} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Kills every running worker container (named `ncc-*`), best effort: what
  an agent that stopped mid-job left running. Each failure is logged.
  Answers the ids it tried to kill.
  """
  @spec kill_leftovers(Config.t()) :: [String.t()]
  def kill_leftovers(config) do
    case cmd(config, ["ps", "-q", "--filter", "name=ncc-"], @inspect_timeout_ms) do
      {:ok, out, 0} ->
        ids = String.split(out, ~r/\s+/, trim: true)

        for id <- ids do
          Logger.warning("killing leftover worker container #{id}")
          kill(config, id)
        end

        ids

      {:ok, out, status} ->
        Logger.warning("docker ps exited #{status}: #{String.trim(out)}")
        []

      {:error, reason} ->
        Logger.warning("docker ps failed: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Runs `docker <argv>`, appending its output to `log_path`. Past
  `timeout_ms` the container (`argv`'s `--name`) is killed and the answer
  is `{:error, :timeout}`.
  """
  @spec run(Config.t(), [String.t()], Path.t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :timeout | term()}
  # `log_path` is the runner log in the job's own scratch dir.
  # sobelow_skip ["Traversal.FileModule"]
  def run(config, argv, log_path, timeout_ms) do
    with {:ok, log} <- File.open(log_path, [:append, :binary]) do
      try do
        port = open(config, argv)
        written = log_size(log_path)
        deadline = System.monotonic_time(:millisecond) + timeout_ms
        sink = %{log: log, written: written, cap: Caps.get(:runner_log_bytes)}
        receive_output(config, port, sink, deadline, container_name(argv))
      rescue
        e -> {:error, {:spawn_failed, Exception.message(e)}}
      after
        File.close(log)
      end
    end
  end

  defp receive_output(config, port, sink, deadline, name) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        receive_output(config, port, write(sink, data), deadline, name)

      {^port, {:exit_status, status}} ->
        {:ok, status}
    after
      remaining ->
        if name, do: kill(config, name)

        IO.binwrite(
          sink.log,
          "\n[agent] wall-clock timeout exceeded - killed container #{name}\n"
        )

        close(port)
        {:error, :timeout}
    end
  end

  defp write(%{written: written, cap: cap} = sink, _data) when written >= cap, do: sink

  defp write(sink, data) do
    room = sink.cap - sink.written

    if byte_size(data) <= room do
      IO.binwrite(sink.log, data)
      %{sink | written: sink.written + byte_size(data)}
    else
      IO.binwrite(sink.log, binary_part(data, 0, room))
      IO.binwrite(sink.log, "\n[agent] runner.log truncated at #{human_size(sink.cap)}\n")
      %{sink | written: sink.cap}
    end
  end

  defp human_size(bytes) when rem(bytes, 1_048_576) == 0, do: "#{div(bytes, 1_048_576)} MiB"
  defp human_size(bytes), do: "#{bytes} bytes"

  defp log_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> 0
    end
  end

  # A short command with a deadline, keeping the start of its output.
  defp cmd(config, args, timeout_ms) do
    port = open(config, args)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect(port, [], 0, deadline)
  rescue
    e -> {:error, {:spawn_failed, Exception.message(e)}}
  end

  defp collect(port, acc, size, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when size < @output_bytes ->
        collect(port, [acc, data], size + byte_size(data), deadline)

      {^port, {:data, _data}} ->
        collect(port, acc, size, deadline)

      {^port, {:exit_status, status}} ->
        {:ok, IO.iodata_to_binary(acc), status}
    after
      remaining ->
        close(port)
        {:error, :timeout}
    end
  end

  # `docker_bin` is the operator's NCC_DOCKER_BIN; arguments go to it as a
  # list, never through a shell.
  defp open(config, args) do
    Port.open({:spawn_executable, bin(config)}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: args
    ])
  end

  # Closing a port does not end its process: a hung docker CLI is killed.
  # sobelow_skip ["CI.System"]
  defp close(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      nil ->
        :ok
    end

    Port.close(port)
  rescue
    ArgumentError -> :ok
  after
    flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end

  defp container_name(argv) do
    case Enum.drop_while(argv, &(&1 != "--name")) do
      ["--name", name | _] -> name
      _ -> nil
    end
  end

  @doc "The last `bytes` of `log_path` as valid UTF-8; empty when it does not exist."
  @spec log_tail(Path.t(), pos_integer()) :: String.t()
  # sobelow_skip ["Traversal.FileModule"]
  def log_tail(log_path, bytes \\ 4096) do
    with {:ok, %File.Stat{size: size}} <- File.stat(log_path),
         {:ok, io} <- File.open(log_path, [:read, :binary]) do
      try do
        case :file.pread(io, max(size - bytes, 0), bytes) do
          {:ok, data} -> String.replace_invalid(data, "")
          _ -> ""
        end
      after
        File.close(io)
      end
    else
      _ -> ""
    end
  end

  defp bin(config), do: System.find_executable(config.docker_bin) || config.docker_bin
end
