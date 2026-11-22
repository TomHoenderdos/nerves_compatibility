defmodule NccWorker.Tracer do
  @moduledoc """
  Runs the judge compile under the compile-time trace (precompiled
  portability spec, R1). Copies the tracer's beams (`src/ncc_tracer*.erl` and
  the `mix ncc.trace_compile` driver) into `<trace_dir>/ebin`, then runs
  `timeout --kill-after=10 <sec> elixir -pa <ebin> -S mix ncc.trace_compile`
  in the project, which recompiles the closure of `packages` one dependency
  at a time and writes `trace-*.jsonl` into `trace_dir`
  (`NccWorker.Tracer.Report`).

  The recompile replaces `_build/host/lib/<dep>` for every closure
  dependency, so whatever a caller scans and archives afterwards is the
  traced compile's own output.

  `mode: :host` makes the traced compile the run's host compile: it also
  compiles the project, after the closure (`NccWorker.HostTrace`). The
  default, `:judge`, recompiles the closure only. Any other mode raises
  `ArgumentError` before anything runs.

  The container is swept once the compile is over
  (`NccWorker.ProcessSweep.clear/1`, `sweep/2`), as
  `NccWorker.Portability.run/3` sweeps it before the judge reads anything:
  a process alive while a window is open could rewrite what the compile
  reads and put it back before any check looks, and one alive after it
  could rewrite what was judged before it is archived. A sweep that leaves
  survivors, or cannot run in a portal build, fails the trace
  (`left_running/0`).

  Inside the compile the driver sweeps too, before each dependency's window
  closes (`:ncc_tracer_sweep`, `window_sweep:`): a natively built
  dependency's `make`, cmake or cargo is not traced, and a process it leaves
  behind must not live on into a later window. The worker asks for it with
  its own start time (`NCC_TRACE_SWEEP`) only where its own sweep runs, and
  the driver sweeps only where pid 1 started then. One that leaves survivors
  or cannot run ends the compile with exit 87, `{:error,
  :window_sweep_failed}`.

  `timeout(1)` bounds the compile and kills its whole process group, so no
  orphaned compile goes on rewriting `_build` after this returns. Without
  `timeout` on the PATH nothing is run. Exit 124 (timed out) is
  `{:error, :timeout}` and exit 137 (killed: `timeout(1)`'s kill-after, or
  an out-of-memory kill) is `{:error, :killed}`; the caller treats every
  error as "portability could not be judged". The timeout is the smaller of
  `timeout_ms` and what is left of the run (`timeout_sec/2`, from
  `run_started_at:`, the run's start in monotonic seconds).

  A firmware target's trace (`NccWorker.FirmwareInputs`) runs the compile as
  that target's firmware build ran: `wrapper:` (an executable, `fakeroot`)
  goes between `timeout` and `elixir`; `argv:` is what the compile's
  `System.argv/0` returns (`["firmware"]`, not `["ncc.trace_compile"]`); and
  `late_env:` (`[{name, value}]`) is put in the compile's environment only
  once `Mix.Dep.load_and_cache/0` has evaluated every dependency's `mix.exs`,
  where Nerves's own `nerves_bootstrap.init` exports its env, and the
  dependencies are then loaded again, as the compile's own `deps.loadpaths`
  loads them after it: what they are compiled with (a dependency's `deps:`,
  a rebar3 dependency's evaluated `rebar.config.script`) comes from that
  second load. Neither of the
  last two reaches the VM through its env: the driver reads them from
  `driver.etf` in `trace_dir` before the tracer starts, and a trace whose
  file is unreadable fails.

  A differential build's variant (`NccWorker.Portability.Differential`)
  passes `plain_args:`, words put after the task on the command line: the
  Mix VM's plain arguments, which the driver ignores.

  A guarded-module proof build (`NccWorker.Portability.GuardedProof`, S9)
  asks for one more: `first:` (package names) compiles those packages'
  closure before the packages' own.
  """

  alias NccWorker.{OptionalDepsTargets, OsKill, ProcessSweep}

  @modules [
    :ncc_tracer,
    :ncc_tracer_channels,
    :ncc_tracer_stack,
    :ncc_tracer_config,
    :ncc_tracer_digest,
    :ncc_tracer_sweep,
    :"Elixir.Mix.Tasks.Ncc.TraceCompile"
  ]
  @default_timeout_ms 30 * 60 * 1000

  # `Portal.Builder` kills the container at 2 h, losing the whole run;
  # past this much of the run the judge compile is cut short, and with less
  # than @min_run_left_sec of it left it does not start at all.
  @run_ceiling_sec 105 * 60
  @min_run_left_sec 60

  @timeout_exit 124
  @killed_exit 137
  # The driver's own exit when a sweep at a window boundary failed
  # (`Elixir.Mix.Tasks.Ncc.TraceCompile`'s SWEEP_EXIT).
  @window_sweep_exit 87

  # How long after `timeout(1)`'s own deadline (plus its 10 s kill-after)
  # the Elixir side gives up waiting. A backstop only.
  @backstop_ms 30_000

  # How long leftover processes get to die once signalled.
  @reap_wait_ms 5_000

  # `trace_stats["tracer_error"]` of a trace around which processes were
  # left running that could not be killed: one may still write the build.
  @left_running ~w(group_survived cleanup_unverified writers_survived presweep_survived
                   sweep_survived)

  @spec run(String.t(), [String.t()], keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def run(project_dir, packages, opts) do
    trace_dir = Keyword.fetch!(opts, :trace_dir)
    mode = mode!(opts)
    words = plain_args(opts)

    with {:ok, timeout_sec} <- budget(opts),
         {:ok, timeout} <- executable("timeout"),
         {:ok, elixir} <- executable("elixir"),
         :ok <- reset(trace_dir),
         :ok <- driver_input(trace_dir, opts),
         :ok <- base_loaded(elixir, trace_dir, Keyword.get(opts, :env, [])),
         {:ok, ebin} <- install(Path.join(trace_dir, "ebin")),
         {:ok, installed} <- digests(ebin) do
      env =
        Keyword.get(opts, :env, []) ++
          trace_env(trace_dir, packages, mode, opts) ++ Keyword.get(opts, :extra_env, [])

      args =
        ["--kill-after=10", "#{timeout_sec}"] ++
          wrapper(opts) ++
          [elixir, "-pa", ebin, "-S", "mix", "ncc.trace_compile"] ++ words

      result = exec(timeout, args, project_dir, env, timeout_sec, opts)
      swept = sweep(opts, :after)
      reaped = reap(env, opts)
      checked = unchanged(ebin, installed)
      :ok = unseal(ebin)
      Enum.find([swept, result, reaped, checked], result, &match?({:error, _}, &1))
    end
  end

  @base_loaded "base-loaded"

  @doc """
  The trace errors (`trace_stats["tracer_error"]`) that mean processes were
  left running around the traced compile that could not be killed, and may
  still write what it built: `NccWorker.HostTrace` and
  `NccWorker.FirmwareInputs` neither remove nor publish anything then.
  """
  @spec left_running() :: [String.t()]
  def left_running, do: @left_running

  @doc """
  Sweeps the container (`NccWorker.ProcessSweep.clear/1`) `:before` or
  `:after` a traced compile: `:ok`, or `{:error, {:presweep_survived |
  :sweep_survived, procs}}` / `{:error, {:presweep_unavailable |
  :sweep_unavailable, why}}`. `sweep:` (tests) replaces `clear/0`; one that
  raises could not show the container clean either.
  """
  @spec sweep(keyword(), :before | :after) ::
          :ok | {:error, {atom(), [ProcessSweep.proc()] | String.t()}}
  def sweep(opts, at) when at in [:before, :after] do
    clear = Keyword.get(opts, :sweep, &ProcessSweep.clear/0)

    case guarded_sweep(clear) do
      :ok -> :ok
      {:error, {:survivors, procs}} -> {:error, {sweep_error(at, :survived), procs}}
      {:error, {:unavailable, why}} -> {:error, {sweep_error(at, :unavailable), why}}
    end
  end

  defp guarded_sweep(clear) do
    case clear.() do
      :ok -> :ok
      {:error, {kind, _}} = error when kind in [:survivors, :unavailable] -> error
      other -> {:error, {:unavailable, "unexpected sweep result #{inspect(other, limit: 5)}"}}
    end
  rescue
    e -> {:error, {:unavailable, "sweep failed: " <> Exception.message(e)}}
  catch
    kind, reason -> {:error, {:unavailable, "sweep failed: #{kind} #{inspect(reason, limit: 5)}"}}
  end

  defp sweep_error(:before, :survived), do: :presweep_survived
  defp sweep_error(:before, :unavailable), do: :presweep_unavailable
  defp sweep_error(:after, :survived), do: :sweep_survived
  defp sweep_error(:after, :unavailable), do: :sweep_unavailable

  @doc """
  How much of a run, in seconds from its start, may pass before no compile
  may run any longer (`Portal.Builder` kills the container at 2 h).
  """
  @spec run_ceiling_sec() :: pos_integer()
  def run_ceiling_sec, do: @run_ceiling_sec

  @doc """
  The judge compile's timeout in seconds: `timeout_ms` rounded up, cut to
  what is left of the run when `run_elapsed_sec` is known. `:exhausted` when
  less than a minute of the run is left.
  """
  @spec timeout_sec(pos_integer(), non_neg_integer() | nil) :: pos_integer() | :exhausted
  def timeout_sec(timeout_ms, nil), do: max(div(timeout_ms + 999, 1000), 1)

  def timeout_sec(timeout_ms, run_elapsed_sec) do
    left = @run_ceiling_sec - run_elapsed_sec

    if left < @min_run_left_sec,
      do: :exhausted,
      else: min(timeout_sec(timeout_ms, nil), left)
  end

  defp budget(opts) do
    elapsed =
      case Keyword.get(opts, :run_started_at) do
        nil -> nil
        started -> max(System.monotonic_time(:second) - started, 0)
      end

    case timeout_sec(Keyword.get(opts, :timeout_ms, @default_timeout_ms), elapsed) do
      :exhausted -> {:error, :run_budget_exhausted}
      sec -> {:ok, sec}
    end
  end

  @doc """
  Writes the tracer's beams into `ebin`, replacing whatever was there, and
  leaves the files and the dir read-only. That stops a package's
  compile-time code from rewriting them by accident; one that deliberately
  makes them writable again is caught by `run/3`, which compares the files
  with what it installed once the compile is over, and by the report
  reader, which compares the md5s each child VM's tracer reports with the
  Mix VM's.
  """
  @spec install(String.t()) :: {:ok, String.t()} | {:error, term()}
  # The worker's own run dir; module names are a fixed list.
  # sobelow_skip ["Traversal.FileModule"]
  def install(ebin) do
    _ = File.chmod(ebin, 0o755)
    File.rm_rf!(ebin)
    File.mkdir_p!(ebin)

    for module <- @modules do
      path = Path.join(ebin, "#{module}.beam")
      File.write!(path, object_code!(module))
      File.chmod!(path, 0o444)
    end

    File.chmod!(ebin, 0o555)
    {:ok, ebin}
  rescue
    e -> {:error, {:install_failed, Exception.message(e)}}
  end

  # Writable again, so the run dir can be removed; the files stay read-only.
  # sobelow_skip ["Traversal.FileModule"]
  defp unseal(ebin) do
    _ = File.chmod(ebin, 0o755)
    :ok
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp digests(ebin) do
    {:ok, Map.new(File.ls!(ebin), &{&1, :crypto.hash(:sha256, File.read!(Path.join(ebin, &1)))})}
  rescue
    e -> {:error, {:tracer_unreadable, Exception.message(e)}}
  end

  # Every file installed is still there with the same content, and none
  # was added.
  defp unchanged(ebin, installed) do
    case digests(ebin) do
      {:ok, ^installed} ->
        :ok

      {:ok, now} ->
        names = Map.keys(installed) ++ Map.keys(now)
        changed = names |> Enum.uniq() |> Enum.sort() |> Enum.reject(&(installed[&1] == now[&1]))
        {:error, {:tracer_modified, changed}}

      {:error, _} = error ->
        error
    end
  end

  # From the code server rather than a path: inside the worker escript the
  # beams live in the escript's archive.
  # sobelow_skip ["Traversal.FileModule"]
  defp object_code!(module) do
    case :code.get_object_code(module) do
      {^module, binary, _file} -> binary
      :error -> module |> :code.which() |> List.to_string() |> File.read!()
    end
  end

  # The modules a bare VM of this toolchain has loaded once it runs code
  # (`elixir -e`, with the compile's own environment): erts's, kernel's,
  # stdlib's and Elixir's boot; and Mix's own modules every way a user
  # compiles a dependency has loaded by then (`MixBase`, measured per
  # toolchain, round 4). The tracer takes as loaded for the user only a
  # module both loaded before it started and in this list (round 3, R2-6);
  # one Mix, Hex or the driver loaded otherwise is traced and judged like
  # any other. A list that cannot be made fails the trace.
  # sobelow_skip ["CI.System", "Traversal.FileModule"]
  defp base_loaded(elixir, trace_dir, env) do
    script =
      ~S{IO.write(Enum.join([System.version() <> " " <> System.otp_release()] ++ Enum.map(:code.all_loaded(), &Atom.to_string(elem(&1, 0))), "\n"))}

    case System.cmd(elixir, ["-e", script], env: env, cd: trace_dir, stderr_to_stdout: true) do
      {out, 0} ->
        [toolchain | loaded] = String.split(out, "\n", trim: true)
        [version, otp] = String.split(toolchain, " ")
        mix = NccWorker.Tracer.MixBase.modules(NccWorker.Tracer.MixBase.pair(version, otp))
        File.write(Path.join(trace_dir, @base_loaded), Enum.join(loaded ++ mix, "\n"))

      {out, code} ->
        {:error, {:base_loaded, code, String.slice(out, 0, 500)}}
    end
  rescue
    e -> {:error, {:base_loaded, Exception.message(e)}}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp reset(dir) do
    # A sealed ebin left by an earlier run cannot be emptied until writable.
    _ = File.chmod(Path.join(dir, "ebin"), 0o755)
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    :ok
  rescue
    e -> {:error, {:trace_dir, Exception.message(e)}}
  end

  defp executable(name) do
    case System.find_executable(name) do
      nil -> {:error, {:not_found, name}}
      path -> {:ok, path}
    end
  end

  @doc """
  The `mode:` option: `:judge` (the default) or `:host`. Anything else raises
  `ArgumentError`.
  """
  @spec mode!(keyword()) :: :judge | :host
  def mode!(opts) do
    case Keyword.get(opts, :mode, :judge) do
      mode when mode in [:judge, :host] -> mode
      other -> raise ArgumentError, "unknown tracer mode: #{inspect(other)}"
    end
  end

  # A differential build's variant asks for more plain arguments for the
  # Mix VM (`NccWorker.Portability.Differential`): after the task, whose
  # driver ignores its arguments. Anything but a list of strings raises
  # before anything runs.
  defp plain_args(opts) do
    case Keyword.get(opts, :plain_args, []) do
      words when is_list(words) ->
        if Enum.all?(words, &(is_binary(&1) and not String.contains?(&1, <<0>>))),
          do: words,
          else: raise(ArgumentError, "plain_args: not a list of strings")

      other ->
        raise ArgumentError, "plain_args: #{inspect(other)}"
    end
  end

  defp wrapper(opts) do
    case Keyword.get(opts, :wrapper) do
      nil -> []
      path when is_binary(path) -> [path]
    end
  end

  @driver_input "driver.etf"

  @doc "The file in `trace_dir` the driver reads `argv:` and `late_env:` from."
  @spec driver_input_file(String.t()) :: String.t()
  def driver_input_file(trace_dir), do: Path.join(trace_dir, @driver_input)

  # Written only for a trace that asks for either, as an ETF map the driver
  # reads with `binary_to_term/2`'s `safe`.
  # sobelow_skip ["Traversal.FileModule"]
  defp driver_input(trace_dir, opts) do
    argv = Keyword.get(opts, :argv)
    late = Keyword.get(opts, :late_env, [])

    cond do
      argv == nil and late == [] ->
        :ok

      not strings?(List.wrap(argv)) or not Enum.all?(late, &env_pair?/1) ->
        {:error, :bad_driver_input}

      true ->
        input = :erlang.term_to_binary(%{argv: argv, late_env: late})

        case File.write(driver_input_file(trace_dir), input) do
          :ok -> :ok
          {:error, why} -> {:error, {:driver_input, why}}
        end
    end
  end

  defp strings?(list), do: Enum.all?(list, &is_binary/1)

  defp env_pair?({name, value}),
    do: Compatibility.CompileInputs.name?(name) and is_binary(value) and not (value =~ <<0>>)

  defp env_pair?(_pair), do: false

  defp trace_env(trace_dir, packages, mode, opts) do
    [
      {"NCC_TRACE_DIR", trace_dir},
      {"NCC_TRACE_PACKAGE", Enum.join(packages, ",")},
      {"NCC_TRACE_NATIVE", opts |> Keyword.get(:native, []) |> Enum.join(",")},
      {"NCC_TRACE_HOLDERS", opts |> Keyword.get(:holders, []) |> holders_env()},
      {"NCC_TRACE_MODE", Atom.to_string(mode)},
      {"NCC_TRACE_SWEEP", Keyword.get_lazy(opts, :window_sweep, &window_sweep/0)},
      {"NCC_TRACE_BASE", Path.join(trace_dir, @base_loaded)},
      # S9's guarded-module proof build only (`NccWorker.Portability.GuardedProof`):
      # packages whose closure compiles first. Unset otherwise, so every
      # other compile's env is as before.
      {"NCC_TRACE_FIRST", first_env(Keyword.get(opts, :first, []))},
      {"MIX_OS_DEPS_COMPILE_PARTITION_COUNT", nil}
    ]
  end

  defp first_env([]), do: nil
  defp first_env(names), do: Enum.join(names, ",")

  # `holders:` (S4, a relocation's second build): `[{app, module}]`, the
  # modules whose calls later windows record (`:ncc_tracer.holders/2`).
  defp holders_env(holders), do: Enum.map_join(holders, ",", fn {app, mod} -> "#{app}:#{mod}" end)

  @doc "The driver's exit status when a sweep at a window boundary failed."
  @spec window_sweep_exit() :: pos_integer()
  def window_sweep_exit, do: @window_sweep_exit

  # The worker's own start time as pid 1, which the driver's sweep checks
  # before it kills anything (`:ncc_tracer_sweep`): asked for only where the
  # worker's own sweep runs, its container. One that cannot be read is
  # passed as one that never matches, so the trace fails rather than goes
  # unswept.
  defp window_sweep do
    if ProcessSweep.environment() == :ok do
      case ProcessSweep.start_time(1) do
        {:ok, start} -> Integer.to_string(start)
        :error -> "unknown"
      end
    end
  end

  # The compile runs in a monitored, unlinked process: a crash there is an
  # error here, never an exit signal that takes the worker down with it.
  # `cmd:` replaces `cmd/5` (tests only).
  defp exec(timeout, args, project_dir, env, timeout_sec, opts) do
    caller = self()
    ref = make_ref()
    log = Keyword.get(opts, :log_file)
    cmd = Keyword.get(opts, :cmd, &cmd/5)

    {pid, monitor} =
      spawn_monitor(fn ->
        send(
          caller,
          {ref, :result, guarded_cmd(cmd, [caller, ref, timeout, [args, project_dir, env], log])}
        )
      end)

    backstop = (timeout_sec + 10) * 1000 + @backstop_ms
    outcome = await(pid, monitor, ref, backstop)

    case kill_group(ref, Keyword.get(opts, :cleanup_find, &System.find_executable/1)) do
      :ok -> exec_result(outcome)
      {:error, _} = error -> error
    end
  end

  defp exec_result(outcome) do
    case outcome do
      {:ok, {:ok, @timeout_exit}} -> {:error, :timeout}
      {:ok, {:ok, @killed_exit}} -> {:error, :killed}
      {:ok, {:ok, @window_sweep_exit}} -> {:error, :window_sweep_failed}
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:exited, reason}}
      nil -> {:error, :timeout}
    end
  end

  defp guarded_cmd(cmd, argv) do
    apply(cmd, argv)
  rescue
    e -> {:error, {:cmd_failed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:cmd_failed, {kind, reason}}}
  end

  # Past the backstop the process is killed, as `Task.shutdown/2` did.
  defp await(pid, monitor, ref, backstop) do
    receive do
      {^ref, :result, result} ->
        Process.demonitor(monitor, [:flush])
        {:ok, result}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:exit, reason}
    after
      backstop ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        end

        # A result sent just before the kill landed is dropped.
        receive do
          {^ref, :result, _result} -> :ok
        after
          0 -> :ok
        end

        nil
    end
  end

  # The BEAM starts every port program (System.cmd, rebar3, a Makefile's
  # cc) in a process group of its own, so kill_group/1 does not reach them.
  # Whatever still carries the judge compile's MIX_BUILD_PATH once it is
  # over is killed (`OptionalDepsTargets.reap_writers/1`, /proc, so Linux);
  # one that survives fails the run.
  defp reap(env, opts) do
    find = Keyword.get(opts, :cleanup_find, &System.find_executable/1)
    reap = Keyword.get(opts, :reap, &OptionalDepsTargets.reap_writers(&1, find))

    case List.keyfind(env, "MIX_BUILD_PATH", 0) do
      {_, build_path} when is_binary(build_path) -> reap.(build_path)
      _ -> :ok
    end
  end

  # `timeout(1)` makes itself the leader of a new process group, so its pid
  # is the group's id. Whatever the compile left running in the group (a
  # backgrounded job) is killed here, after a normal exit as after a
  # timeout. That reaches only what forked without a port: a port program,
  # or a process that started a session of its own (setsid), has left the
  # group; reap/2 kills those by build path, and `sweep/2` kills whatever
  # else is left (`NccWorker.ProcessSweep`).
  #
  # The signal does not need kill(1) (`NccWorker.OsKill`). What fails the run
  # is a member that survives, as /proc shows it; without /proc a group that
  # could not be signalled at all cannot be shown empty, and fails it too.
  defp kill_group(ref, find) do
    receive do
      {^ref, :os_pid, pid} ->
        pgid = Integer.to_string(pid)
        signalled = OsKill.kill({:group, pgid}, find)
        group_gone(pgid, signalled, find, System.monotonic_time(:millisecond) + @reap_wait_ms)
    after
      0 -> :ok
    end
  end

  defp group_gone(pgid, signalled, find, until) do
    case OsKill.group_members(pgid) do
      :no_proc when signalled == :ok ->
        :ok

      :no_proc ->
        {:error, :cleanup_unverified}

      [] ->
        :ok

      pids ->
        if System.monotonic_time(:millisecond) >= until do
          {:error, {:group_survived, pids}}
        else
          _ = OsKill.kill(pids, find)
          Process.sleep(100)
          group_gone(pgid, signalled, find, until)
        end
    end
  end

  # The judge compile runs package code, as the host compile does; the
  # executables are the image's timeout and elixir and the arguments are
  # fixed. A port rather than System.cmd, for timeout(1)'s pid.
  # sobelow_skip ["CI.System"]
  defp cmd(caller, ref, command, [args, project_dir, env], log) do
    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: args,
        cd: project_dir,
        env: port_env(env)
      ])

    with {:os_pid, pid} <- Port.info(port, :os_pid), do: send(caller, {ref, :os_pid, pid})
    {:ok, with_log(log, &collect(port, &1))}
  rescue
    e -> {:error, {:cmd_failed, Exception.message(e)}}
  end

  defp port_env(env) do
    for {name, value} <- env do
      {String.to_charlist(name), if(value, do: String.to_charlist(value), else: false)}
    end
  end

  defp collect(port, device) do
    receive do
      {^port, {:data, data}} ->
        if device, do: IO.binwrite(device, data)
        collect(port, device)

      {^port, {:exit_status, status}} ->
        status
    end
  end

  # The caller's own log file in the run's output dir.
  defp with_log(nil, fun), do: fun.(nil)

  # sobelow_skip ["Traversal.FileModule"]
  defp with_log(path, fun) do
    File.open!(path, [:append, :binary], fun)
  end
end
