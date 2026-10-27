defmodule NccWorker.OptionalDepsTargets do
  @moduledoc """
  The optional-dependency pass for a firmware run, per target.

  A firmware package publishes one set of files per Nerves target, built
  from `_build/<target>/lib/<package>`. A real application almost always has
  the package's optional dependencies in its lock, and the package compiles
  differently with them loadable, so files built without them match no such
  application (`NccWorker.DepsLock.unresolved_optional_deps/2`). After the
  firmware builds have settled every status, this recompiles the package on
  each passing target with them added and republishes that target's files.

  Nothing here changes a status, a firmware image, `firmware_size_bytes`,
  `log_tail`, `error`, `dependency_scans` or `cache_candidates`: only a kept
  target's `beam_scan` and `compile_env` are replaced, and it gains its own
  `deps_lock`. The pass's compile is never stored in the build cache, whose
  key would describe the lock without the optional dependencies.

  In order (see `run/2`):

    1. The run-level lock, read before anything changes: it is the run's
       `deps_lock` and `package_checksum`, the lock the status build saw.
    2. `mix.exs` and `mix.lock` snapshotted, the optional dependencies
       injected into `mix.exs` once, and each passing target's first build
       renamed to `_build/<target>/lib/.<package>.status-build`.
    3. Serially, per target, with its own env: `mix deps.get` and
       `NccWorker.LockPolicy.validate/1`. Serial because they share the root
       `mix.lock`.
    4. Concurrently, per target that got through 3: `mix compile`, no
       firmware, bounded by the per-system timeout, into the target's log.
    5. A target whose compile passed is rescanned and its moved-aside first
       build deleted. Any other target gets back exactly its first build:
       whatever the pass left is removed and the first build renamed back.
    6. `mix.exs` and `mix.lock` restored from the snapshot, so nothing after
       the pass sees the optional dependencies.

  A first build or a snapshot that cannot be put back is the only error,
  `{:error, {:optional_deps_revert_failed, reason}}`: publishing files nobody
  checked would be worse than a retried run. Everything else drops the
  optional dependencies for the targets it concerns, with one of the reasons
  "deps_get_failed", "lock_policy_violation", "target_compile_failed",
  "mix_exs_edit_failed", "stale_build_not_removed", "deps_lock_unreadable",
  "timeout" (per-system timeout, or the pass's budget ran out) or
  "run_budget_exhausted" (the run had used more than 75 minutes, so the pass
  did not start), and "no_passing_target" in the summary when no target
  passed. A dropped target's leftover writers are killed before its first
  build goes back (`reap_writers/1`); one that survives is a revert failure.

  Every step that would run `mix`, reach Hex or touch the snapshot goes
  through a runner (`t:runners/0`), so tests replace them and stay offline.
  """

  alias NccWorker.{AppFile, BeamScan, DepsLock, LockPolicy, Project}

  @typedoc "A system's name and the env and log its firmware build used."
  @type target ::
          {String.t(), %{env: [{String.t(), String.t()}], log_file: String.t()}}

  @type params :: %{
          required(:project_dir) => String.t(),
          required(:package) => String.t(),
          # From `NccWorker.Project.optional_deps_to_add/1`.
          required(:deps) => [%{app: String.t(), package: String.t(), requirement: String.t()}],
          # The firmware builds' results, by system name.
          required(:systems) => %{String.t() => map()},
          # In system order; the first one's drop reason names the summary's.
          required(:targets) => [target()],
          required(:timeout_sec) => pos_integer(),
          required(:concurrency) => pos_integer(),
          # The pass's wall-clock budget from its start (default 1200 s):
          # a target not started by then is dropped as "timeout", and each
          # compile gets at most what is left.
          optional(:budget_sec) => non_neg_integer(),
          # How long the run had taken when the pass was called. Over 75
          # minutes the pass does not start ("run_budget_exhausted").
          optional(:run_elapsed_sec) => non_neg_integer()
        }

  @type summary :: %{added: [String.t()], dropped: [String.t()], reason: String.t() | nil}

  @type outcome :: %{
          systems: %{String.t() => map()},
          optional_deps: summary(),
          deps_lock: DepsLock.t() | nil,
          package_checksum: String.t() | nil
        }

  @typedoc """
  Every key optional; a missing one runs the real thing.

    * `deps_get` -- `(project_dir, env, log_file)`, `mix deps.get`
    * `lock_policy` -- `(project_dir)`, `NccWorker.LockPolicy.validate/1`
    * `compile` -- `(project_dir, env, log_file, timeout_sec)`, `mix compile`;
      `{:error, :timeout}` when it ran out of time
    * `scan` -- `(build_path, package)`, the package's beam scan
    * `compile_env` -- `(build_path, package)`, its `.app`'s compile_env
    * `inject` -- `(project_dir, deps)`, `NccWorker.Project.inject_optional_deps/2`
    * `rename` -- `(from, to)`, `File.rename/2`
    * `restore` -- `(snapshot)`, `NccWorker.Project.restore/1`
    * `read_lock` / `package_checksum` -- `(project_dir, package)`,
      `NccWorker.DepsLock`
    * `reap` -- `(build_path)`, kills what a dropped target's compile left running
      (`reap_writers/1`); `{:error, reason}` when some survive
    * `now` -- `()`, monotonic seconds, for the budget
  """
  @type runners :: %{optional(atom()) => function()}

  # How long past the per-system timeout a compile task may run before it is
  # killed from here. `timeout(1)` stops the compile itself at the per-system
  # timeout; this only catches an image without it.
  @kill_grace_sec 60

  # `timeout(1)`'s exit when the command timed out (TERM). 137 is a SIGKILL,
  # which is `--kill-after` only once the time is up; before that it is
  # mix itself killed (OOM), a failed compile.
  @timeout_exit 124
  @killed_exit 137

  # The pass's own wall-clock budget, from its start, unless
  # NCC_OPTIONAL_PASS_BUDGET_SEC says otherwise (`NccWorker.Worker`).
  @default_budget_sec 1200

  # Past this much of the run, the pass does not start at all:
  # `Portal.Builder` kills the container at 2 h, and that kill loses the
  # whole run, statuses included.
  @run_budget_sec 75 * 60

  # How long the reaper waits for killed writers to be gone.
  @reap_wait_ms 5_000
  @reap_poll_ms 100

  @doc """
  Runs the pass. Returns the systems with the pass applied, the run-level
  `optional_deps` summary, and the run-level lock read before the pass.
  """
  @spec run(params(), runners()) ::
          {:ok, outcome()} | {:error, {:optional_deps_revert_failed, term()}}
  def run(params, runners \\ %{}) do
    r = Map.merge(default_runners(), runners)
    budget_sec = Map.get(params, :budget_sec, @default_budget_sec)
    params = Map.put(params, :deadline, r.now.() + budget_sec)

    # Before the pass can touch mix.lock.
    run_lock = %{
      deps_lock: r.read_lock.(params.project_dir, params.package),
      package_checksum: r.package_checksum.(params.project_dir, params.package)
    }

    with {:ok, systems, summary} <- pass(params, r) do
      {:ok, Map.merge(run_lock, %{systems: systems, optional_deps: summary})}
    end
  end

  defp pass(%{deps: []} = params, _r), do: {:ok, params.systems, summary([], [], nil)}

  defp pass(params, r) do
    case passing_targets(params) do
      [] ->
        {:ok, params.systems, summary([], Enum.map(params.deps, & &1.app), "no_passing_target")}

      passing ->
        if Map.get(params, :run_elapsed_sec, 0) > @run_budget_sec,
          do: skip_for_run_budget(params, passing),
          else: snapshot_and_inject(params, r, passing)
    end
  end

  # Nothing is touched: every passing target keeps its first build.
  defp skip_for_run_budget(params, passing) do
    names = Enum.map(params.deps, & &1.app)
    outcomes = Enum.map(passing, &{&1, {:dropped, "run_budget_exhausted"}})
    Enum.each(outcomes, fn {target, outcome} -> log_outcome(target, names, outcome) end)
    {:ok, apply_outcomes(params, names, outcomes, nil), summarise(names, outcomes)}
  end

  defp time_left(params, r), do: params.deadline - r.now.()

  defp passing_targets(%{systems: systems, targets: targets}) do
    Enum.filter(targets, fn {name, _target} -> match?(%{status: :pass}, systems[name]) end)
  end

  defp snapshot_and_inject(params, r, passing) do
    names = Enum.map(params.deps, & &1.app)

    with {:ok, snapshot} <- Project.snapshot(params.project_dir),
         {:inject, {:ok, injected}, _snapshot} <-
           {:inject, r.inject.(params.project_dir, params.deps), snapshot} do
      case injected do
        # The template declares them all: nothing to build differently.
        [] -> {:ok, params.systems, summary([], [], nil)}
        injected -> run_targets(params, r, passing, snapshot, injected)
      end
    else
      {:inject, {:error, _reason}, snapshot} ->
        outcomes = Enum.map(passing, &{&1, {:dropped, "mix_exs_edit_failed"}})
        Enum.each(passing, &log_header(&1, names))
        finish(params, r, snapshot, names, outcomes)

      {:error, _reason} ->
        outcomes = Enum.map(passing, &{&1, {:dropped, "mix_exs_edit_failed"}})
        {:ok, apply_outcomes(params, names, outcomes, nil), summarise(names, outcomes)}
    end
  end

  defp run_targets(params, r, passing, snapshot, names) do
    Enum.each(passing, &log_header(&1, names))

    {moved, outcomes} =
      Enum.reduce(passing, {[], []}, fn target, {moved, outcomes} ->
        case move_aside(params, r, target) do
          :ok -> {moved ++ [target], outcomes}
          {:error, _} -> {moved, outcomes ++ [{target, {:dropped, "stale_build_not_removed"}}]}
        end
      end)

    {fetched, fetch_outcomes} = fetch_serially(params, r, moved)
    lock = if fetched == [], do: nil, else: r.read_lock.(params.project_dir, params.package)
    compile_outcomes = compile_targets(params, r, fetched, lock)

    # In the targets' own order, so the summary's reason is the first one's.
    outcomes = outcomes ++ fetch_outcomes ++ compile_outcomes
    ordered = Enum.map(passing, fn target -> List.keyfind(outcomes, target, 0) end)

    finish(params, r, snapshot, names, ordered, moved, lock)
  end

  defp fetch_serially(params, r, moved) do
    Enum.reduce(moved, {[], []}, fn {_name, %{env: env, log_file: log_file}} = target,
                                    {fetched, outcomes} ->
      deps_get = fn project_dir, fetch_env -> r.deps_get.(project_dir, fetch_env, log_file) end

      case fetch_before_deadline(params, r, env, deps_get) do
        :ok -> {fetched ++ [target], outcomes}
        {:dropped, _reason} = dropped -> {fetched, outcomes ++ [{target, dropped}]}
      end
    end)
  end

  # A target not started by the deadline keeps its first build.
  defp fetch_before_deadline(params, r, env, deps_get) do
    if time_left(params, r) > 0,
      do: fetch(params, r, env, deps_get),
      else: {:dropped, "timeout"}
  end

  defp fetch(params, r, env, deps_get) do
    case Project.fetch_optional_deps(params.project_dir, params.package, env, deps_get) do
      :ok ->
        case r.lock_policy.(params.project_dir) do
          :ok -> :ok
          {:error, _} -> {:dropped, "lock_policy_violation"}
        end

      {:error, {:rm_rf_failed, _reason, _path}} ->
        {:dropped, "stale_build_not_removed"}

      {:error, _reason} ->
        {:dropped, "deps_get_failed"}
    end
  end

  # A kept target's files would be published with no lock of their own and
  # match against the run's, which does not name what they were built with.
  defp compile_targets(_params, _r, fetched, nil),
    do: Enum.map(fetched, &{&1, {:dropped, "deps_lock_unreadable"}})

  defp compile_targets(params, r, fetched, _lock) do
    fetched
    |> Task.async_stream(&compile_target(params, r, &1),
      max_concurrency: params.concurrency,
      timeout: (params.timeout_sec + @kill_grace_sec) * 1000,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(fetched)
    |> Enum.map(fn
      {{:ok, outcome}, target} -> {target, outcome}
      # `compile_target/3` cannot raise or exit, so a task only ever exits
      # killed by the backstop timeout.
      {{:exit, :timeout}, target} -> {target, {:dropped, "timeout"}}
    end)
  end

  # Whatever raises in here (the compile, the scan, the compile_env read)
  # drops the target rather than crashing the worker: the task is linked to
  # the caller.
  defp compile_target(params, r, target) do
    case safely(fn -> compile_target!(params, r, target) end) do
      {:error, _reason} -> {:dropped, "target_compile_failed"}
      outcome -> outcome
    end
  end

  defp compile_target!(params, r, {_name, %{env: env, log_file: log_file}}) do
    build_path = build_path(env)
    timeout_sec = min(params.timeout_sec, time_left(params, r))

    with {:time, true} <- {:time, timeout_sec > 0},
         :ok <- r.compile.(params.project_dir, env, log_file, timeout_sec) do
      {:kept, r.scan.(build_path, params.package), r.compile_env.(build_path, params.package)}
    else
      {:time, false} -> {:dropped, "timeout"}
      {:error, :timeout} -> {:dropped, "timeout"}
      _error -> {:dropped, "target_compile_failed"}
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # Without a target that got as far as being moved aside.
  defp finish(params, r, snapshot, names, outcomes),
    do: finish(params, r, snapshot, names, outcomes, [], nil)

  defp finish(params, r, snapshot, names, outcomes, moved, lock) do
    put_back =
      outcomes
      |> Enum.filter(fn {target, _outcome} -> target in moved end)
      |> Enum.map(fn {target, outcome} -> settle(params, r, target, outcome) end)

    Enum.each(outcomes, fn {target, outcome} -> log_outcome(target, names, outcome) end)

    case Enum.find(put_back ++ [r.restore.(snapshot)], &(&1 != :ok)) do
      nil ->
        {:ok, apply_outcomes(params, names, outcomes, lock), summarise(names, outcomes)}

      {:error, reason} ->
        {:error, {:optional_deps_revert_failed, reason}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp move_aside(params, r, {_name, %{env: env}}) do
    {lib, aside} = lib_paths(env, params.package)

    with {:ok, _} <- File.rm_rf(aside) do
      r.rename.(lib, aside)
    end
  end

  # A kept target's first build is no longer needed; one left behind only
  # costs disk, since nothing reads that name.
  # sobelow_skip ["Traversal.FileModule"]
  defp settle(params, _r, {_name, %{env: env, log_file: log_file}}, {:kept, _scan, _ce}) do
    {_lib, aside} = lib_paths(env, params.package)

    case File.rm_rf(aside) do
      {:ok, _} -> :ok
      {:error, reason, path} -> append_log(log_file, "==> could not remove #{path}: #{reason}")
    end

    :ok
  end

  # A dropped target's compile may have left writers behind: `timeout(1)`
  # kills only its own process group and every port child (make, cc, cargo)
  # gets one of its own; an OOM-killed mix leaves its children; a runner that
  # raised may have left mix itself running. Each inherits the target's
  # MIX_BUILD_PATH, so they are found by it and killed before the first build
  # goes back, whatever the drop reason; one that survives would write into
  # it, so that is a revert failure instead.
  defp settle(params, r, {_name, %{env: env}} = target, {:dropped, _reason}) do
    case r.reap.(build_path(env)) do
      :ok -> put_back(params, r, target)
      {:error, reason} -> {:error, reason}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp put_back(params, r, {_name, %{env: env}}) do
    {lib, aside} = lib_paths(env, params.package)

    case File.rm_rf(lib) do
      {:ok, _} -> r.rename.(aside, lib)
      {:error, reason, path} -> {:error, {:rm_rf_failed, reason, path}}
    end
  end

  defp lib_paths(env, package) do
    lib = Path.join(build_path(env), "lib")
    {Path.join(lib, package), Path.join(lib, ".#{package}.status-build")}
  end

  defp build_path(env) do
    {_, build_path} = List.keyfind(env, "MIX_BUILD_PATH", 0)
    build_path
  end

  defp apply_outcomes(params, names, outcomes, lock) do
    Enum.reduce(outcomes, params.systems, fn {{name, _target}, outcome}, systems ->
      Map.update!(systems, name, &apply_outcome(&1, names, outcome, lock))
    end)
  end

  defp apply_outcome(system, names, {:kept, scan, compile_env}, lock) do
    Map.merge(system, %{
      beam_scan: scan,
      compile_env: compile_env,
      deps_lock: lock,
      optional_deps: summary(names, [], nil)
    })
  end

  defp apply_outcome(system, names, {:dropped, reason}, _lock),
    do: Map.put(system, :optional_deps, summary([], names, reason))

  # The names were injected together, so a target keeps all of them or none.
  defp summarise(names, outcomes) do
    if Enum.any?(outcomes, &match?({_target, {:kept, _, _}}, &1)) do
      summary(names, [], nil)
    else
      [{_target, {:dropped, reason}} | _] = outcomes
      summary([], names, reason)
    end
  end

  defp summary(added, dropped, reason), do: %{added: added, dropped: dropped, reason: reason}

  defp log_header({_name, %{log_file: log_file}}, names),
    do: append_log(log_file, "==> optional dependencies: #{Enum.join(names, ", ")}")

  defp log_outcome({_name, %{log_file: log_file}}, names, {:kept, _scan, _compile_env}),
    do: append_log(log_file, "==> optional dependencies kept: #{Enum.join(names, ", ")}")

  defp log_outcome({_name, %{log_file: log_file}}, names, {:dropped, reason}) do
    append_log(
      log_file,
      "==> optional dependencies dropped (#{reason}): #{Enum.join(names, ", ")}; " <>
        "publishing the first build"
    )
  end

  # The target's own log under the worker's output mount.
  # sobelow_skip ["Traversal.FileModule"]
  defp append_log(log_file, line) do
    File.mkdir_p(Path.dirname(log_file))
    File.write(log_file, line <> "\n", [:append])
  end

  defp default_runners do
    %{
      deps_get: &deps_get/3,
      lock_policy: &LockPolicy.validate/1,
      compile: &compile/4,
      scan: &scan/2,
      compile_env: &compile_env/2,
      inject: &Project.inject_optional_deps/2,
      rename: &File.rename/2,
      restore: &Project.restore/1,
      read_lock: &DepsLock.read/2,
      package_checksum: &DepsLock.package_checksum/2,
      reap: &reap_writers/1,
      now: fn -> System.monotonic_time(:second) end
    }
  end

  @doc false
  # Kills every process whose environment names `build_path` as its
  # MIX_BUILD_PATH and waits until none is left. `:ok` without /proc (not
  # Linux), where there is nothing to look in.
  @spec reap_writers(String.t()) :: :ok | {:error, {:writers_survived, [String.t()]}}
  def reap_writers(build_path) do
    needle = "MIX_BUILD_PATH=" <> build_path <> <<0>>

    case writers(needle) do
      :no_proc ->
        :ok

      [] ->
        :ok

      pids ->
        kill(pids)
        wait_for_writers(needle, System.monotonic_time(:millisecond) + @reap_wait_ms)
    end
  end

  defp wait_for_writers(needle, until) do
    case writers(needle) do
      [] ->
        :ok

      pids ->
        if System.monotonic_time(:millisecond) >= until do
          {:error, {:writers_survived, pids}}
        else
          kill(pids)
          Process.sleep(@reap_poll_ms)
          wait_for_writers(needle, until)
        end
    end
  end

  # A zombie's environ reads empty, so a killed process stops matching as
  # soon as it is dead, whether or not its parent has reaped it.
  # sobelow_skip ["Traversal.FileModule"]
  defp writers(needle) do
    own = System.pid()

    case File.ls("/proc") do
      {:ok, entries} ->
        for pid <- entries,
            pid != own,
            Integer.parse(pid) != :error,
            {:ok, environ} <- [File.read("/proc/#{pid}/environ")],
            String.starts_with?(environ, needle) or String.contains?(environ, <<0>> <> needle),
            do: pid

      {:error, _} ->
        :no_proc
    end
  end

  # Literal kill argv for pids read from /proc; no shell.
  # sobelow_skip ["CI.System"]
  defp kill(pids) do
    System.cmd("kill", ["-KILL" | pids], stderr_to_stdout: true)
    :ok
  end

  defp deps_get(project_dir, env, log_file) do
    case mix(["deps.get"], project_dir, env, log_file) do
      0 -> :ok
      code -> {:error, {:deps_get_failed, "mix deps.get exited with code #{code}"}}
    end
  end

  # `timeout(1)` stops the compile and everything it started at the
  # per-system timeout, so a dropped target's lib dir is never written to
  # after it has been put back.
  defp compile(project_dir, env, log_file, timeout_sec) do
    {command, args} =
      case System.find_executable("timeout") do
        nil -> {"mix", ["compile"]}
        timeout -> {timeout, ["--kill-after=10", "#{timeout_sec}", "mix", "compile"]}
      end

    started = System.monotonic_time(:second)
    code = cmd(command, args, project_dir, env, log_file)
    timed_out? = System.monotonic_time(:second) - started >= timeout_sec

    compile_outcome(code, command != "mix", timed_out?)
  end

  defp compile_outcome(0, _bounded?, _timed_out?), do: :ok
  defp compile_outcome(@timeout_exit, true, _timed_out?), do: {:error, :timeout}
  defp compile_outcome(@killed_exit, true, true), do: {:error, :timeout}

  defp compile_outcome(code, _bounded?, _timed_out?),
    do: {:error, "mix compile exited with code #{code}"}

  defp mix(args, project_dir, env, log_file), do: cmd("mix", args, project_dir, env, log_file)

  # Literal argument lists for mix or the resolved timeout executable; no
  # shell. log_file is a worker-generated output path.
  # sobelow_skip ["CI.System", "Traversal.FileModule"]
  defp cmd(command, args, project_dir, env, log_file) do
    {_, code} =
      System.cmd(command, args,
        cd: project_dir,
        env: env,
        stderr_to_stdout: true,
        into: File.stream!(log_file, [:append])
      )

    code
  end

  defp scan(build_path, package) do
    case BeamScan.analyze(build_path, package) do
      {:ok, scan} -> scan
      {:error, reason} -> %{"errors" => ["beam scan failed: #{inspect(reason)}"]}
    end
  end

  # The compile's own `.app`, not the release copy the first build read:
  # `mix compile` assembles no release.
  defp compile_env(build_path, package),
    do:
      AppFile.read_compile_env(Path.join([build_path, "lib", package, "ebin", "#{package}.app"]))
end
