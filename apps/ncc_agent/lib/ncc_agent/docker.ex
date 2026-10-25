defmodule NccAgent.Docker do
  @moduledoc """
  The agent's calls to `docker` (`config.docker_bin`): pull, inspect, and
  one worker container run with its output appended to a log and a
  wall-clock deadline, past which the container is killed.
  """

  alias NccAgent.Config

  @doc "Pulls `image_ref`."
  @spec pull(Config.t(), String.t()) :: :ok | {:error, String.t()}
  # `docker_bin` is the operator's NCC_DOCKER_BIN; arguments go to it as a
  # list, never through a shell.
  # sobelow_skip ["CI.System"]
  def pull(config, image_ref) do
    case System.cmd(bin(config), ["pull", image_ref], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> {:error, "docker pull exited #{status}: #{String.trim(out)}"}
    end
  end

  @doc "Whether `image_ref` is in the local image store."
  @spec present?(Config.t(), String.t()) :: boolean()
  # sobelow_skip ["CI.System"]
  def present?(config, image_ref) do
    match?(
      {_, 0},
      System.cmd(bin(config), ["image", "inspect", image_ref], stderr_to_stdout: true)
    )
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
        port =
          Port.open({:spawn_executable, bin(config)}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: argv
          ])

        deadline = System.monotonic_time(:millisecond) + timeout_ms
        receive_output(config, port, log, deadline, container_name(argv))
      rescue
        e -> {:error, {:spawn_failed, Exception.message(e)}}
      after
        File.close(log)
      end
    end
  end

  # sobelow_skip ["CI.System"]
  defp receive_output(config, port, log, deadline, name) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        IO.binwrite(log, data)
        receive_output(config, port, log, deadline, name)

      {^port, {:exit_status, status}} ->
        {:ok, status}
    after
      remaining ->
        if name, do: System.cmd(bin(config), ["kill", name], stderr_to_stdout: true)
        IO.binwrite(log, "\n[agent] wall-clock timeout exceeded - killed container #{name}\n")
        close(port)
        {:error, :timeout}
    end
  end

  defp close(port) do
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
