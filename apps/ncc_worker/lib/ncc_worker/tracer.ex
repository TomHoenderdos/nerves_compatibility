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
  `timeout` on the PATH nothing is run. A timed-out compile (exit 124)
  is `{:error, :timeout}` (`{:error, :killed}` for a 137, which an
  out-of-memory kill gives too); the caller treats
  every error as "portability could not be judged". The timeout is the
  smaller of `timeout_ms` and what is left of the run (`timeout_sec/2`).
  """

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
         {:ok, ebin} <- install(Path.join(trace_dir, "ebin")) do
      env =
        Keyword.get(opts, :env, []) ++
          trace_env(trace_dir, packages, opts) ++ Keyword.get(opts, :extra_env, [])

      args =
        ["--kill-after=10", "#{timeout_sec}", elixir] ++
          ["-pa", ebin, "-S", "mix", "ncc.trace_compile"]

      exec(timeout, args, project_dir, env, timeout_sec, opts)
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

  @doc "Writes the tracer's beams into `ebin`."
  @spec install(String.t()) :: {:ok, String.t()} | {:error, term()}
  # The worker's own run dir; module names are a fixed list.
  # sobelow_skip ["Traversal.FileModule"]
  def install(ebin) do
    File.mkdir_p!(ebin)
    Enum.each(@modules, &File.write!(Path.join(ebin, "#{&1}.beam"), object_code!(&1)))
    {:ok, ebin}
  rescue
    e -> {:error, {:install_failed, Exception.message(e)}}
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

  defp exec(timeout, args, project_dir, env, timeout_sec, opts) do
    into = log_sink(Keyword.get(opts, :log_file))
    task = Task.async(fn -> cmd(timeout, args, project_dir, env, into) end)
    backstop = (timeout_sec + 10) * 1000 + @backstop_ms

    case Task.yield(task, backstop) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, @timeout_exit}} -> {:error, :timeout}
      {:ok, {:ok, @killed_exit}} -> {:error, :killed}
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:exited, reason}}
      nil -> {:error, :timeout}
    end
  end

  # The judge compile runs package code, as the host compile does; the
  # executables are the image's timeout and elixir and the arguments are
  # fixed.
  # sobelow_skip ["CI.System"]
  defp cmd(command, args, project_dir, env, into) do
    {_output, status} =
      System.cmd(command, args, cd: project_dir, env: env, stderr_to_stdout: true, into: into)

    {:ok, status}
  rescue
    e -> {:error, {:cmd_failed, Exception.message(e)}}
  end

  # The caller's own log file in the run's output dir.
  defp log_sink(nil), do: ""
  # sobelow_skip ["Traversal.FileModule"]
  defp log_sink(path), do: File.stream!(path, [:append])
end
