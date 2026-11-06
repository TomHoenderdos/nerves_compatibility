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

  `timeout(1)` bounds the compile and kills its whole process group, so no
  orphaned compile goes on rewriting `_build` after this returns. Without
  `timeout` on the PATH nothing is run. Exit 124 (timed out) is
  `{:error, :timeout}` and exit 137 (killed: `timeout(1)`'s kill-after, or
  an out-of-memory kill) is `{:error, :killed}`; the caller treats every
  error as "portability could not be judged". The timeout is the smaller of
  `timeout_ms` and what is left of the run (`timeout_sec/2`, from
  `run_started_at:`, the run's start in monotonic seconds).
  """

  alias NccWorker.OptionalDepsTargets

  @modules [
    :ncc_tracer,
    :ncc_tracer_channels,
    :ncc_tracer_stack,
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

  # How long after `timeout(1)`'s own deadline (plus its 10 s kill-after)
  # the Elixir side gives up waiting. A backstop only.
  @backstop_ms 30_000

  @spec run(String.t(), [String.t()], keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def run(project_dir, packages, opts) do
    trace_dir = Keyword.fetch!(opts, :trace_dir)

    with {:ok, timeout_sec} <- budget(opts),
         {:ok, timeout} <- executable("timeout"),
         {:ok, elixir} <- executable("elixir"),
         :ok <- reset(trace_dir),
         {:ok, ebin} <- install(Path.join(trace_dir, "ebin")),
         {:ok, installed} <- digests(ebin) do
      env =
        Keyword.get(opts, :env, []) ++
          trace_env(trace_dir, packages, opts) ++ Keyword.get(opts, :extra_env, [])

      args =
        ["--kill-after=10", "#{timeout_sec}", elixir] ++
          ["-pa", ebin, "-S", "mix", "ncc.trace_compile"]

      result = exec(timeout, args, project_dir, env, timeout_sec, opts)
      reaped = reap(env, opts)
      checked = unchanged(ebin, installed)
      :ok = unseal(ebin)
      Enum.find([result, reaped, checked], result, &match?({:error, _}, &1))
    end
  end

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

  defp trace_env(trace_dir, packages, opts) do
    [
      {"NCC_TRACE_DIR", trace_dir},
      {"NCC_TRACE_PACKAGE", Enum.join(packages, ",")},
      {"NCC_TRACE_NATIVE", opts |> Keyword.get(:native, []) |> Enum.join(",")},
      {"MIX_OS_DEPS_COMPILE_PARTITION_COUNT", nil}
    ]
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
    kill_group(ref)

    case outcome do
      {:ok, {:ok, @timeout_exit}} -> {:error, :timeout}
      {:ok, {:ok, @killed_exit}} -> {:error, :killed}
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
    reap = Keyword.get(opts, :reap, &OptionalDepsTargets.reap_writers/1)

    case List.keyfind(env, "MIX_BUILD_PATH", 0) do
      {_, build_path} when is_binary(build_path) -> reap.(build_path)
      _ -> :ok
    end
  end

  # `timeout(1)` makes itself the leader of a new process group, so its pid
  # is the group's id. Whatever the compile left running in the group (a
  # backgrounded job, a port program) is killed here, after a normal exit
  # as after a timeout. That reaches only what forked without a port: a
  # port program, or a process that started a session of its own (setsid),
  # has left the group; reap/2 kills those by build path, and the worker's
  # `NccWorker.ProcessSweep` stops anything left before the run ends.
  # Literal kill argv for a pid the port reported; no shell.
  # sobelow_skip ["CI.System"]
  defp kill_group(ref) do
    receive do
      {^ref, :os_pid, pid} ->
        _ = System.cmd("kill", ["-KILL", "--", "-#{pid}"], stderr_to_stdout: true)
        :ok
    after
      0 -> :ok
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
