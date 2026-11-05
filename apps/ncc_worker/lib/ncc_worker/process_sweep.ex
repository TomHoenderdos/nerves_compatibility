defmodule NccWorker.ProcessSweep do
  @moduledoc """
  Ends every process in the build container but the worker itself before
  `result.json` is written, and keeps a result that could not do so from
  passing.

  The package under test runs code in this container: its `mix.exs`, its
  compile-time code and its build scripts. Anything that leaves a process
  behind could still be running while the worker archives files and writes
  `result.json`. By then every program the worker launched has returned, so
  the only processes that belong are the worker's own BEAM and that BEAM's
  `erl_child_setup` helper. `enforce/2` sends `SIGKILL` to every other pid it
  finds under `/proc`, one pid at a time (never a process group or `-1`), and
  scans again until none is left or its rounds run out. A result with
  anything still running is turned into a non-pass one (`taint/2`).

  Zombies are already dead and run no code: they are neither killed nor
  counted. They do linger, since the BEAM, which inherits orphans as the
  container's pid 1, does not reap them.

  `erl_child_setup` is recognised as a direct child of the BEAM whose `comm`
  is `erl_child_setup`. A process can rename itself and an orphan is
  reparented to the BEAM, so of several such children only the one that
  started first is kept: the real helper is forked while the BEAM boots,
  before any package code runs.

  Only active in the container's worker: on Linux, with a `/proc`, and when
  the BEAM is pid 1, which it is as the container's entrypoint. Anywhere else,
  such as a developer machine running the escript, it does nothing.
  """

  @allowed_helper "erl_child_setup"
  @default_rounds 20
  @default_interval_ms 100

  @type proc :: %{
          pid: pos_integer(),
          ppid: non_neg_integer(),
          comm: String.t(),
          state: String.t(),
          start_time: non_neg_integer()
        }

  @type option ::
          {:enabled?, boolean()}
          | {:proc_root, Path.t()}
          | {:self_pid, pos_integer()}
          | {:kill, ([pos_integer()] -> any())}
          | {:rounds, pos_integer()}
          | {:interval_ms, non_neg_integer()}

  @doc """
  Sweeps the container (see `sweep/1`) and returns `result`, or, when
  something survived, `result` made non-pass by `taint/2`.

  Options are `sweep/1`'s.
  """
  @spec enforce(map(), [option()]) :: map()
  def enforce(result, opts \\ []) do
    case sweep(opts) do
      :ok ->
        result

      :skipped ->
        result

      {:error, {:survivors, survivors}} ->
        reason = survivors_reason(survivors)
        IO.puts(:stderr, "Process sweep: #{reason}")
        taint(result, reason)
    end
  end

  @doc """
  Kills every process but the allowed ones and checks that they are gone.

  Returns `:ok` when nothing else is left, `{:error, {:survivors, procs}}`
  when something still runs after the last round, and `:skipped` when not
  running as the container's worker.

  Options, for tests: `:enabled?` (default: `container_worker?/0`),
  `:proc_root` (`"/proc"`), `:self_pid` (the BEAM's own, `System.pid/0`),
  `:kill` (a function given a list of pids to `SIGKILL`), `:rounds` and
  `:interval_ms` (the pause after each round's kills).
  """
  @spec sweep([option()]) :: :ok | :skipped | {:error, {:survivors, [proc()]}}
  def sweep(opts \\ []) do
    if Keyword.get_lazy(opts, :enabled?, &container_worker?/0) do
      do_sweep(
        Keyword.get(opts, :proc_root, "/proc"),
        Keyword.get_lazy(opts, :self_pid, fn -> String.to_integer(System.pid()) end),
        Keyword.get(opts, :kill, &kill/1),
        Keyword.get(opts, :rounds, @default_rounds),
        Keyword.get(opts, :interval_ms, @default_interval_ms)
      )
    else
      :skipped
    end
  end

  defp do_sweep(proc_root, self_pid, kill, rounds, interval_ms) do
    round = fn _round, :running ->
      case strays(proc_root, self_pid) do
        [] -> {:halt, :ok}
        procs -> {:cont, kill_round(procs, kill, interval_ms)}
      end
    end

    with :running <- Enum.reduce_while(1..rounds, :running, round) do
      case strays(proc_root, self_pid) do
        [] -> :ok
        survivors -> {:error, {:survivors, survivors}}
      end
    end
  end

  defp kill_round(procs, kill, interval_ms) do
    kill.(Enum.map(procs, & &1.pid))
    if interval_ms > 0, do: Process.sleep(interval_ms)
    :running
  end

  @doc """
  The live processes under `proc_root` other than the BEAM `self_pid` and its
  `erl_child_setup`. Zombies are left out.
  """
  @spec strays(Path.t(), pos_integer()) :: [proc()]
  def strays(proc_root, self_pid) do
    procs = scan(proc_root)
    helper = helper_pid(procs, self_pid)

    Enum.reject(procs, fn proc ->
      proc.pid == self_pid or proc.pid == helper or proc.state in ["Z", "X", "x"]
    end)
  end

  defp helper_pid(procs, self_pid) do
    procs
    |> Enum.filter(&(&1.ppid == self_pid and &1.comm == @allowed_helper))
    |> Enum.min_by(&{&1.start_time, &1.pid}, fn -> nil end)
    |> case do
      nil -> nil
      proc -> proc.pid
    end
  end

  @doc "Every process under `proc_root` whose `stat` could be read."
  @spec scan(Path.t()) :: [proc()]
  def scan(proc_root) do
    case File.ls(proc_root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(&1 =~ ~r/^\d+$/))
        |> Enum.flat_map(&read_stat(proc_root, &1))

      {:error, _} ->
        []
    end
  end

  # A process that exits between the listing and the read has no stat left,
  # which is the outcome the sweep wants anyway. The path is the proc root and
  # an all-digit entry name read from it.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_stat(proc_root, entry) do
    with {:ok, stat} <- File.read(Path.join([proc_root, entry, "stat"])),
         {:ok, proc} <- parse_stat(stat) do
      [proc]
    else
      _ -> []
    end
  end

  @doc """
  Parses one `/proc/<pid>/stat` line. `comm` sits in parentheses and may hold
  spaces and parentheses itself, so the fields after it are read from the
  last `)`.
  """
  @spec parse_stat(String.t()) :: {:ok, proc()} | :error
  def parse_stat(stat) do
    with [pid, rest] <- String.split(stat, " (", parts: 2),
         {pid, ""} <- Integer.parse(pid),
         [comm, after_comm] <- split_last(rest, ")"),
         # Fields 3 (state), 4 (ppid) ... 22 (starttime), counted from 1.
         [state, ppid | more] <- String.split(String.trim(after_comm), " "),
         {ppid, ""} <- Integer.parse(ppid),
         {start_time, ""} <- more |> Enum.at(17, "") |> Integer.parse() do
      {:ok, %{pid: pid, ppid: ppid, comm: comm, state: state, start_time: start_time}}
    else
      _ -> :error
    end
  end

  defp split_last(string, sep) do
    case :binary.matches(string, sep) do
      [] ->
        :error

      matches ->
        {at, _} = List.last(matches)
        [binary_part(string, 0, at), binary_part(string, at + 1, byte_size(string) - at - 1)]
    end
  end

  @doc """
  `result` with nothing in it passing: every system `:error` with `reason` as
  its error, no build cache candidates, and a toolchain build `"error"` with
  no files.
  """
  @spec taint(map(), String.t()) :: map()
  def taint(result, reason) do
    result
    |> Map.update(:systems, %{}, fn systems ->
      Map.new(systems, fn {name, sys} ->
        {name,
         sys
         |> Map.put(:status, :error)
         |> Map.put(:error, reason)
         |> Map.delete(:cache_candidates)}
      end)
    end)
    |> taint_toolchain_build(reason)
  end

  defp taint_toolchain_build(%{toolchain_build: %{} = build} = result, reason) do
    build = Map.merge(build, %{status: "error", reason: reason, file_manifest: nil})
    %{result | toolchain_build: build}
  end

  defp taint_toolchain_build(result, _reason), do: result

  defp survivors_reason(survivors) do
    listed = survivors |> Enum.take(10) |> Enum.map_join(", ", &"#{&1.pid} (#{&1.comm})")
    more = if length(survivors) > 10, do: " and #{length(survivors) - 10} more", else: ""
    "processes survived the sweep and could not be stopped: #{listed}#{more}"
  end

  @doc """
  Whether this is the container's worker: Linux, a `/proc`, and the BEAM as
  pid 1.
  """
  @spec container_worker?() :: boolean()
  def container_worker? do
    :os.type() == {:unix, :linux} and File.dir?("/proc/self") and System.pid() == "1"
  end

  # The shell's `kill` builtin, so the image needs no procps. One signal per
  # listed pid; one that has exited meanwhile only makes the command fail,
  # which the next scan sorts out.
  defp kill(pids) do
    System.cmd("sh", ["-c", ~s(kill -s KILL "$@"), "sh" | Enum.map(pids, &Integer.to_string/1)],
      stderr_to_stdout: true
    )
  rescue
    _ -> :error
  end
end
