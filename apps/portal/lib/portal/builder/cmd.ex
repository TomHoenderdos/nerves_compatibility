defmodule Portal.Builder.Cmd do
  @moduledoc """
  A command with a deadline. `System.cmd/3` waits for its command however
  long it takes, and a docker CLI talking to a daemon that is stuck on a
  container waits with it: a `docker kill` of a hung gVisor sandbox once
  held a build job's process for thirteen hours. Here the command's OS
  process is SIGKILLed at the deadline and the caller gets `{:error,
  :timeout}`.
  """

  # What an answer keeps of a command's output.
  @output_bytes 65_536

  @doc """
  Runs `exe` with `args`, no shell, stderr merged into stdout. Answers
  `{:ok, output, status}`, `{:error, :timeout}` past `timeout_ms` (the
  command killed), or `{:error, {:spawn_failed, message}}`.
  """
  @spec run(String.t(), [String.t()], non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, :timeout | {:spawn_failed, String.t()}}
  def run(exe, args, timeout_ms) do
    port = open(exe, args)
    collect(port, [], 0, System.monotonic_time(:millisecond) + timeout_ms)
  rescue
    e -> {:error, {:spawn_failed, Exception.message(e)}}
  end

  @doc """
  Opens `exe` with `args` as a port that reports its exit status: what
  `run/3` uses, and `Portal.Builder` for `docker run`, which streams.
  """
  @spec open(String.t(), [String.t()]) :: port()
  def open(exe, args) do
    Port.open({:spawn_executable, exe}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: Enum.map(args, &to_charlist/1)
    ])
  end

  @doc """
  Ends `port`'s OS process with SIGKILL and closes the port. Closing a
  port alone only closes its pipes, and a docker CLI blocked on the daemon
  never notices that.
  """
  @spec kill(port()) :: :ok
  def kill(port) do
    case Port.info(port, :os_pid) do
      # A pid this BEAM spawned; `kill` itself returns at once.
      {:os_pid, pid} ->
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      nil ->
        :ok
    end

    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  after
    flush(port)
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
        kill(port)
        {:error, :timeout}
    end
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end
end
