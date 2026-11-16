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
  container's pid 1, does not reap them. A process whose first thread
  exited on its own (`pthread_exit/1`) also shows as a zombie while its
  other threads run on: one with a live thread under `/proc/<pid>/task` is
  no zombie here, and killing its pid kills those threads.

  `erl_child_setup` is recognised as a direct child of the BEAM whose `comm`
  is `erl_child_setup`. A process can rename itself and an orphan is
  reparented to the BEAM, so of several such children only the one that
  started first is kept: the real helper is forked while the BEAM boots,
  before any package code runs.

  It can only run in the container's worker: on Linux, with a `/proc`, and
  when the BEAM is pid 1, which it is as the container's entrypoint
  (`environment/0`). A portal build, one given its input through `NCC_INPUT`
  (`portal_build?/1`), does not fail open when the sweep cannot run: its
  result is made non-pass the same way, with a reason starting
  `"process sweep could not run: "`. A run without `NCC_INPUT`, such as a
  developer machine running the escript, is not swept and says so on stderr.

  The worker's own name lookups never start a process: the CLI switches the
  BEAM to Erlang's own resolver (`use_erlang_resolver/0`) before anything
  looks a name up. The native one is a port program, `inet_gethost`, that the
  BEAM starts through `erl_child_setup` and restarts when it dies, which a
  sweep would find every time; it is not allowed, so it must never run.

  `enforce_and_report/2`, which the CLI runs, also records how the sweep went
  as the result's top-level `process_sweep`: `"ok"`, `"skipped"` or
  `"tainted"`. That field is the container's own account, for monitoring: the
  portal does not trust it, only the verdicts it reads.

  The same sweep also runs around every traced compile (`clear/1`,
  `NccWorker.Portability` before it, `NccWorker.Tracer` after it): an
  untraced step before one (`mix deps.get`, a build, Nerves's env) runs
  package code that can leave a process behind, and one alive while a
  window is open could rewrite a dependency's source for the compile to
  read and put the tarball's bytes back before the window closes, which no
  check after it would see. Every program the worker launched has returned
  by then, as at the end of the run. Inside the compile the trace driver
  sweeps at each window boundary with the same rules (`:ncc_tracer_sweep`),
  for what a native build leaves running.
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

  @typedoc "How the sweep went, as the result's `process_sweep`."
  @type status :: String.t()

  @type option ::
          {:enabled?, boolean()}
          | {:environment, :ok | {:unavailable, String.t()}}
          | {:portal_build?, boolean()}
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
    {_status, result} = outcome(result, opts)
    result
  end

  @doc """
  `enforce/2`, with how the sweep went put in the result as `:process_sweep`
  (`"ok"`, `"skipped"` or `"tainted"`), which `result.json` carries at its
  top level.

  When the sweep cannot run (`environment/0`), a portal build
  (`:portal_build?`, default `portal_build?/1`) is `"tainted"` with the
  reason `"process sweep could not run: <why>"`; any other run is
  `"skipped"`, unchanged but for the field, with a line on stderr. Survivors
  are `"tainted"` either way.

  Options are `sweep/1`'s, plus `:portal_build?` and `:environment` (what
  `environment/0` would answer), for tests.
  """
  @spec enforce_and_report(map(), [option()]) :: map()
  def enforce_and_report(result, opts \\ []) do
    {status, result} = outcome(result, opts)
    Map.put(result, :process_sweep, status)
  end

  @doc """
  Sweeps the container between the steps of a run (see the moduledoc), with
  `enforce_and_report/2`'s rule for where the sweep cannot run.

  `:ok` when nothing but the worker runs any longer, or when the sweep
  cannot run and this is no portal build (`portal_build?/1`), whose result's
  sweep is `"skipped"` too. Otherwise `{:error, {:survivors, procs}}`, what
  still ran after the last round, or `{:error, {:unavailable, why}}`, a
  portal build whose sweep cannot run. Either error means the container
  could not be shown clean, so nothing that needed it may be judged.

  Options are `enforce_and_report/2`'s.
  """
  @spec clear([option()]) :: :ok | {:error, {:survivors, [proc()]} | {:unavailable, String.t()}}
  def clear(opts \\ []) do
    case run(opts) do
      :ok ->
        :ok

      {:unavailable, _why} = unavailable ->
        if Keyword.get_lazy(opts, :portal_build?, fn -> portal_build?() end),
          do: {:error, unavailable},
          else: :ok

      {:error, {:survivors, _}} = error ->
        error
    end
  end

  @doc "`clear/1`'s error in one line, as the result's reasons give it."
  @spec describe({:survivors, [proc()]} | {:unavailable, String.t()}) :: String.t()
  def describe({:unavailable, why}), do: "process sweep could not run: #{why}"
  def describe({:survivors, survivors}), do: survivors_reason(survivors)

  @spec outcome(map(), [option()]) :: {status(), map()}
  defp outcome(result, opts) do
    case run(opts) do
      :ok ->
        {"ok", result}

      {:unavailable, why} ->
        if Keyword.get_lazy(opts, :portal_build?, fn -> portal_build?() end) do
          reason = describe({:unavailable, why})
          IO.puts(:stderr, "Process sweep: #{reason}")
          {"tainted", taint(result, reason)}
        else
          IO.puts(:stderr, "Process sweep skipped: #{why} (no NCC_INPUT, not a portal build)")
          {"skipped", result}
        end

      {:error, {:survivors, survivors}} ->
        reason = survivors_reason(survivors)
        IO.puts(:stderr, "Process sweep: #{reason}")
        {"tainted", taint(result, reason)}
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
    case run(opts) do
      {:unavailable, _why} -> :skipped
      outcome -> outcome
    end
  end

  defp run(opts) do
    case availability(opts) do
      :ok ->
        do_sweep(
          Keyword.get(opts, :proc_root, "/proc"),
          Keyword.get_lazy(opts, :self_pid, fn -> String.to_integer(System.pid()) end),
          Keyword.get(opts, :kill, &kill/1),
          Keyword.get(opts, :rounds, @default_rounds),
          Keyword.get(opts, :interval_ms, @default_interval_ms)
        )

      {:unavailable, _why} = unavailable ->
        unavailable
    end
  end

  # `:enabled?` overrides the environment check outright; `:environment`
  # stands in for its answer.
  defp availability(opts) do
    case Keyword.fetch(opts, :enabled?) do
      {:ok, true} -> :ok
      {:ok, false} -> {:unavailable, "disabled"}
      :error -> Keyword.get_lazy(opts, :environment, &environment/0)
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
  `erl_child_setup`. Zombies are left out, unless one of their threads is
  live.
  """
  @spec strays(Path.t(), pos_integer()) :: [proc()]
  def strays(proc_root, self_pid) do
    procs = scan(proc_root)
    helper = helper_pid(procs, self_pid)

    Enum.reject(procs, fn proc ->
      proc.pid == self_pid or proc.pid == helper or not live?(proc_root, proc)
    end)
  end

  @dead ["Z", "X", "x"]

  defp live?(proc_root, %{state: state, pid: pid}) when state in @dead,
    do: live_thread?(proc_root, pid)

  defp live?(_proc_root, _proc), do: true

  # A zombie leader's threads, each under `task/<tid>/stat`. One that cannot
  # be listed has gone, threads and all.
  # sobelow_skip ["Traversal.FileModule"]
  defp live_thread?(proc_root, pid) do
    task_root = Path.join([proc_root, Integer.to_string(pid), "task"])

    case File.ls(task_root) do
      {:ok, tids} ->
        task_root
        |> scan_entries(tids)
        |> Enum.any?(&(&1.state not in @dead))

      {:error, _} ->
        false
    end
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

  @doc "The start time of `pid` (clock ticks since boot), from its `stat` under `proc_root`."
  @spec start_time(pos_integer(), Path.t()) :: {:ok, non_neg_integer()} | :error
  def start_time(pid, proc_root \\ "/proc") do
    case read_stat(proc_root, Integer.to_string(pid)) do
      [%{start_time: start}] -> {:ok, start}
      [] -> :error
    end
  end

  @doc "Every process under `proc_root` whose `stat` could be read."
  @spec scan(Path.t()) :: [proc()]
  def scan(proc_root) do
    case File.ls(proc_root) do
      {:ok, entries} -> scan_entries(proc_root, entries)
      {:error, _} -> []
    end
  end

  defp scan_entries(root, entries) do
    entries
    |> Enum.filter(&(&1 =~ ~r/^\d+$/))
    |> Enum.flat_map(&read_stat(root, &1))
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
  Resolves names with Erlang's own resolver, `/etc/hosts` then DNS as
  `/etc/resolv.conf` configures it, instead of the native `inet_gethost` port
  program, so no lookup the worker makes leaves a process for the sweep to
  find. Run before anything looks a name up.
  """
  @spec use_erlang_resolver() :: :ok
  def use_erlang_resolver, do: :inet_db.set_lookup([:file, :dns])

  @doc """
  Whether this is the container's worker: Linux, a `/proc`, and the BEAM as
  pid 1.
  """
  @spec container_worker?() :: boolean()
  def container_worker?, do: environment() == :ok

  @doc """
  `:ok` when the sweep can run here (see `container_worker?/0`), or
  `{:unavailable, why}` naming the first thing that is missing.
  """
  @spec environment() :: :ok | {:unavailable, String.t()}
  def environment do
    cond do
      :os.type() != {:unix, :linux} -> {:unavailable, "not Linux (#{inspect(:os.type())})"}
      not File.dir?("/proc/self") -> {:unavailable, "no /proc"}
      System.pid() != "1" -> {:unavailable, "the BEAM is pid #{System.pid()}, not 1"}
      true -> :ok
    end
  end

  @doc """
  Whether this run is a portal build: `NCC_INPUT` is set, whatever it names.
  The portal's runners always set it; a run without it reads the default
  input path and is someone running the escript by hand. `getenv` is for
  tests.
  """
  @spec portal_build?((String.t() -> String.t() | nil)) :: boolean()
  def portal_build?(getenv \\ &System.get_env/1), do: getenv.("NCC_INPUT") != nil

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
