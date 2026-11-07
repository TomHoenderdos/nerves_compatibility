defmodule NccWorker.OsKill do
  @moduledoc """
  SIGKILL for OS processes, without depending on a `kill` binary: a slim
  toolchain image may not carry one (procps). The BEAM has no call that
  signals an arbitrary OS pid, so without the binary the signal goes through
  the POSIX shell's `kill` builtin (`sh -c 'kill "$@"'`); with neither the
  result is `{:error, :no_kill}`. Never raises.

  Whether a process actually died is for the caller to check (`/proc`):
  a failed signal to a process that is already gone is not an error.
  """

  @type target :: [String.t()] | {:group, String.t()}
  @type finder :: (String.t() -> String.t() | nil)

  @spec kill(target(), finder()) :: :ok | {:error, :no_kill}
  def kill(target, find \\ &System.find_executable/1)

  def kill([], _find), do: :ok

  def kill(target, find) do
    case {find.("kill"), find.("sh")} do
      {nil, nil} -> {:error, :no_kill}
      {nil, sh} -> run(sh, ["-c", ~s(kill "$@"), "sh" | argv(target)])
      {kill, _sh} -> run(kill, argv(target))
    end
  end

  @doc "The kill(1) arguments for `target`: a group id is a negative pid."
  @spec argv(target()) :: [String.t()]
  def argv({:group, pgid}), do: ["-KILL", "--", "-" <> pgid]
  def argv(pids) when is_list(pids), do: ["-KILL", "--" | pids]

  # Literal argv: the resolved kill or sh, fixed flags and pids read from
  # /proc or a port; the shell script is a constant and takes them as "$@".
  # sobelow_skip ["CI.System"]
  defp run(command, args) do
    _ = System.cmd(command, args, stderr_to_stdout: true)
    :ok
  rescue
    _ -> {:error, :no_kill}
  end

  @doc """
  The live members of process group `pgid` among `pids`, from each one's
  `/proc/<pid>/stat` as `stat` reads it (nil when gone). A zombie is left
  out: it runs nothing and writes nothing.
  """
  @spec group_members(String.t(), [String.t()], (String.t() -> String.t() | nil)) ::
          [String.t()]
  def group_members(pgid, pids, stat) do
    for pid <- pids, fields = stat_fields(stat.(pid)), live_in?(fields, pgid), do: pid
  end

  # Fields after the command name, which may itself hold ") ".
  defp stat_fields(nil), do: nil

  defp stat_fields(line) do
    case :binary.matches(line, ") ") do
      [] ->
        nil

      matches ->
        {at, _} = List.last(matches)
        line |> binary_part(at + 2, byte_size(line) - at - 2) |> String.split(" ")
    end
  end

  defp live_in?([state, _ppid, pgid | _], pgid), do: state != "Z"
  defp live_in?(_fields, _pgid), do: false

  @doc """
  The live members of group `pgid` on this host, or `:no_proc` without a
  `/proc` to read.
  """
  @spec group_members(String.t()) :: [String.t()] | :no_proc
  # sobelow_skip ["Traversal.FileModule"]
  def group_members(pgid) do
    case File.ls("/proc") do
      {:ok, entries} ->
        pids = Enum.filter(entries, &(Integer.parse(&1) != :error and &1 != System.pid()))
        group_members(pgid, pids, &read_stat/1)

      {:error, _} ->
        :no_proc
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_stat(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, line} -> String.trim_trailing(line)
      {:error, _} -> nil
    end
  end
end
