defmodule NccWorker.HostTrace do
  @moduledoc """
  A toolchain run's host compile, run under the compile-time trace
  (precompiled portability spec, R1): `mix deps.get`, then the traced
  compile in host mode (`NccWorker.Tracer`, `mode: :host`), which compiles
  every dependency of the package's closure in its own window and then the
  project, and its judgement (`NccWorker.Portability.run/3`). The closure is
  compiled once, traced, and those are the files the run judges and archives.

  No build cache is restored: a dependency the trace does not see compiled
  cannot be judged, so the traced compile builds every one itself.

  The host status never depends on the tracer. The traced compile is the
  build only when it exited 0 and its report says it ran in host mode
  (`trace_stats["trace_mode"]`). Anything else (a timeout, a kill, a
  non-zero exit, a tracer that could not start, a report in another mode)
  leaves `_build/host` untrusted, even where a half-built dependency's `.mix`
  manifests look valid. Then, in this order:

    1. every process still carrying the build's `MIX_BUILD_PATH` is killed
       (`OptionalDepsTargets.reap_writers/1`), because `Tracer.run/3`
       reports its first error only and writers can hide behind a timeout;
    2. `_build/host` is removed;
    3. an untraced `mix compile` (`OptionalDepsTargets.bounded_compile/4`),
       bounded only by what is left of the run, gives the status;
    4. the writers are reaped again.

  The verdict is then the transient "portability could not be judged",
  whatever the trace said: the files it judged are gone, so an untraced
  build never publishes precompiled files. `trace_stats["host_build"]` says
  which build the status is: `"traced"`, `"untraced"` or `"none"`.

  A traced compile that fails because the package does not compile cannot
  be told from a tracer fault that makes it fail: the driver's end line is
  written from inside the traced VM, where package code runs, so it cannot
  vouch for the tracer. Such a package is built a second time, untraced, and
  that build's failure is the status.

  The host compile fails without a rebuild when there is no time left in
  the run. It is a worker error (`status: :error`) when processes are left
  running that cannot be killed (`"group_survived"`, `"cleanup_unverified"`,
  `"writers_survived"`, or writers the reap above finds), or when
  `_build/host` cannot be removed: one of those processes may still be
  writing `_build`, so nothing is removed, rebuilt or judged.
  """

  alias Compatibility.Portability, as: Reasons
  alias NccWorker.{HexHome, LogTail, OptionalDepsTargets, Portability, Tracer, Worker}

  @survived ["group_survived", "cleanup_unverified", "writers_survived"]
  @left_running "the traced host compile left processes running"
  @no_time_left "no time left for the host compile"
  @untraced_timeout "the untraced host compile timed out"

  @type outcome :: :pass | {:fail, String.t()} | {:error, String.t()}

  @doc """
  Runs the host compile of `package_name` in `project_dir`. `paths` is the
  worker's `%{work_dir, output_dir}`. Options:

    * `releases:` (required), `NccWorker.Portability.lock_snapshot/1`;
    * `run_started_at:` (required), the run's start in monotonic seconds,
      which bounds both compiles by what is left of the run;
    * `log_tail_bytes:`;
    * `timeout_ms:`, `cmd:`, `reap:`, `portability:`, `fallback:`,
      `deps_get:`, `rm_rf:` (tests).
  """
  @spec compile(String.t(), String.t(), map(), keyword()) ::
          %{host: map(), verdict: Portability.verdict()}
  def compile(project_dir, package_name, paths, opts) do
    _ = Keyword.fetch!(opts, :run_started_at)
    log_file = Path.join([paths.output_dir, "logs", "host.log"])
    started = System.monotonic_time(:second)
    hex_home = HexHome.prepare(project_dir, "host")
    env = env(project_dir) ++ if(hex_home, do: [{"HEX_HOME", hex_home}], else: [])

    {outcome, verdict} =
      case deps_get(opts).(project_dir, env, log_file) do
        :ok -> traced(project_dir, package_name, paths, env, log_file, opts)
        {:error, reason} -> {{:fail, describe(reason)}, put_stat(not_run(), "host_build", "none")}
      end

    HexHome.publish(hex_home)

    %{
      host: host_result(outcome, project_dir, package_name, log_file, started, opts),
      verdict: verdict
    }
  end

  @doc """
  Whether a failed host compile from `compile/4` failed because the run's
  time ran out (no time left for the untraced compile, or that compile
  timed out), rather than because the package does not compile.
  """
  @spec out_of_time?(map()) :: boolean()
  def out_of_time?(%{status: :fail, error: error}),
    do: error in [@no_time_left, @untraced_timeout]

  def out_of_time?(_host), do: false

  defp traced(project_dir, package_name, paths, env, log_file, opts) do
    portability = Keyword.get(opts, :portability, &Portability.run/3)

    verdict =
      portability.(
        project_dir,
        package_name,
        [
          env: env,
          mode: :host,
          releases: Keyword.fetch!(opts, :releases),
          hex_home: System.get_env("HEX_HOME"),
          run_started_at: Keyword.fetch!(opts, :run_started_at),
          trace_dir: Path.join(paths.work_dir, "trace"),
          log_file: log_file
        ] ++ Keyword.take(opts, [:timeout_ms, :cmd, :reap, :makefile_rule2, :trees])
      )

    {outcome, host_build} = outcome(verdict, project_dir, env, log_file, opts)
    {outcome, verdict |> withhold(host_build) |> put_stat("host_build", host_build)}
  end

  defp outcome(verdict, project_dir, env, log_file, opts) do
    stats = get_in(verdict, [:observations, "trace_stats"]) || %{}

    cond do
      stats["judge_compile"] == "finished" and stats["trace_mode"] == "host" ->
        {:pass, "traced"}

      stats["tracer_error"] in @survived ->
        {{:error, @left_running}, "none"}

      true ->
        fallback(project_dir, env, log_file, opts, why(stats))
    end
  end

  defp why(%{"judge_compile" => "finished", "trace_mode" => mode}),
    do: "the traced compile ran in #{mode} mode"

  defp why(%{"tracer_error" => error}) when is_binary(error), do: error
  defp why(_stats), do: "the traced compile did not finish"

  defp fallback(project_dir, env, log_file, opts, why) do
    build_path = Path.join([project_dir, "_build", "host"])

    append_log(
      log_file,
      "==> the traced host compile is not the build (#{why}); " <>
        "compiling untraced from a clean _build/host"
    )

    with {:reap, :ok} <- {:reap, reap(build_path, opts)},
         {:budget, sec} when is_integer(sec) <- {:budget, budget(opts)},
         {:remove, :ok} <- {:remove, remove(build_path, opts)} do
      untraced(project_dir, build_path, env, log_file, sec, opts)
    else
      {:reap, _} -> {{:error, @left_running}, "none"}
      {:budget, :exhausted} -> {{:fail, @no_time_left}, "none"}
      {:remove, _} -> {{:error, "the traced host compile's build could not be removed"}, "none"}
    end
  end

  defp untraced(project_dir, build_path, env, log_file, sec, opts) do
    compile = Keyword.get(opts, :fallback, &OptionalDepsTargets.bounded_compile/4)
    result = compile.(project_dir, env, log_file, sec)

    case {reap(build_path, opts), result} do
      {{:error, _}, _} -> {{:error, "the host compile left processes running"}, "untraced"}
      {:ok, :ok} -> {:pass, "untraced"}
      {:ok, {:error, reason}} -> {{:fail, describe(reason)}, "untraced"}
    end
  end

  defp reap(build_path, opts) do
    case Keyword.get(opts, :reap, &OptionalDepsTargets.reap_writers/1).(build_path) do
      :ok -> :ok
      _ -> {:error, :writers_survived}
    end
  end

  # The untraced compile is the build's own, so only the run's ceiling
  # bounds it, never the traced compile's 30 min.
  defp budget(opts) do
    elapsed = max(System.monotonic_time(:second) - Keyword.fetch!(opts, :run_started_at), 0)
    Tracer.timeout_sec(Tracer.run_ceiling_sec() * 1000, elapsed)
  end

  # The run's own project dir.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove(build_path, opts) do
    rm_rf = Keyword.get(opts, :rm_rf, &File.rm_rf/1)

    case rm_rf.(build_path) do
      {:ok, _} -> if File.exists?(build_path), do: {:error, :still_there}, else: :ok
      {:error, reason, _file} -> {:error, reason}
    end
  end

  # Whatever the trace judged, a build that is not the traced one is never
  # judged by it: its files are not the ones the trace saw.
  defp withhold(verdict, "traced"), do: verdict

  defp withhold(verdict, _host_build) do
    obs = verdict.observations
    problems = Map.get(obs, "problems") || []

    %{
      status: :skip,
      reason: Reasons.could_not_judge(),
      observations:
        Map.put(obs, "problems", problems ++ ["the host build is not the traced compile"]),
      compile_env: nil
    }
    |> put_stat("transient", true)
  end

  defp host_result(outcome, project_dir, package_name, log_file, started, opts) do
    base = %{
      duration_sec: (System.monotonic_time(:second) - started) * 1.0,
      firmware_size_bytes: nil,
      log_tail: tail(log_file, Keyword.get(opts, :log_tail_bytes, 32_768)),
      beam_scan: nil,
      dependency_scans: nil,
      system_version: nil,
      phase_timings: %{cache_restored: 0.0, cache_candidates: 0.0},
      cache_candidates: []
    }

    case outcome do
      :pass ->
        build_path = Path.join([project_dir, "_build", "host"])

        Map.merge(base, %{
          status: :pass,
          error: nil,
          compile_env: Worker.host_compile_env(build_path, package_name)
        })

      {status, error} when status in [:fail, :error] ->
        Map.merge(base, %{status: status, error: error})
    end
  end

  defp not_run do
    %{
      status: :skip,
      reason: Reasons.could_not_judge(),
      observations: %{
        "problems" => ["host compile did not start"],
        "trace_stats" => %{"judge_compile" => "not_run", "transient" => true}
      },
      compile_env: nil
    }
  end

  defp put_stat(%{observations: obs} = verdict, key, value) do
    stats = Map.get(obs, "trace_stats") || %{}
    %{verdict | observations: Map.put(obs, "trace_stats", Map.put(stats, key, value))}
  end

  @doc false
  # The host compile's env, shared with the worker's other host builds.
  @spec env(String.t()) :: [{String.t(), String.t()}]
  def env(project_dir) do
    [
      {"MIX_BUILD_PATH", Path.join([project_dir, "_build", "host"])},
      {"MIX_DEPS_PATH", Path.join(project_dir, "deps")},
      {"MIX_ENV", "prod"}
    ]
  end

  defp deps_get(opts), do: Keyword.get(opts, :deps_get, &run_deps_get/3)

  # The fixed `mix deps.get`, as the host compile has always run it first.
  # sobelow_skip ["CI.System", "Traversal.FileModule"]
  defp run_deps_get(project_dir, env, log_file) do
    case System.cmd("mix", ["deps.get"],
           cd: project_dir,
           env: env,
           stderr_to_stdout: true,
           into: File.stream!(log_file, [:append])
         ) do
      {_, 0} -> :ok
      {_, code} -> {:error, "mix command exited with code #{code}"}
    end
  end

  # The worker's own log in its output mount.
  # sobelow_skip ["Traversal.FileModule"]
  defp append_log(log_file, line) do
    _ = File.write(log_file, line <> "\n", [:append])
    :ok
  end

  # The worker's own log in its output mount.
  # sobelow_skip ["Traversal.FileModule"]
  defp tail(log_file, max_bytes) do
    case File.read(log_file) do
      {:ok, text} -> LogTail.tail(text, max_bytes)
      {:error, _} -> ""
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(:timeout), do: @untraced_timeout
  defp describe(reason), do: inspect(reason, limit: 20)
end
