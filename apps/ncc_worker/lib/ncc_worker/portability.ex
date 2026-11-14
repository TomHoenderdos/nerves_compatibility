defmodule NccWorker.Portability do
  @moduledoc """
  The compile-time half of the precompiled portability verdict (spec R1-R4),
  in phase P1: it only adds refusals. `run/3` runs the traced judge compile
  (`NccWorker.Tracer`) and `judge/5` reads its `NccWorker.Tracer.Report`;
  callers AND the verdict with rule 1 (`NccWorker.BuildSelection.portable?/4`),
  which stays unchanged.

  Order, first failure wins:

    1. an incomplete trace: any `Report` problem, a missing or failed start,
       closure, stats or end, `unjudged > 0`, any event `Events.decide/4`
       could not judge, wherever it is attributed, or a closure dependency
       whose `ebin`/`priv` no longer match the digest taken when its window
       closed (`built_check:`, on unless turned off and always in `run/3`;
       no digest then, none now, no build dir or no time left in the
       recompute budget is a mismatch too);
    1b. a declassified closure dependency built by another manager than its
       tarball's `build_tools` give (item 1, `judge/5`'s `declassified:`, "manager mismatch");
    1c. a closure dependency whose source tree was not its verified Hex
       tarball's before the compile (item 5e, `Trees`, `judge/5`'s `trees:`,
       "dependency tree differs from its tarball"); a file or listing the
       compile read that changed after that check is could-not-judge (1);
    2. a refusal outside every window (it counts against everything);
    3. a refusal in the package's window (R1, R4 through `Events`);
    4. the package's window broken (missing, lowered depth, failed
       integrity, no sentinel);
    5. R2 on the package's `ebin` (`BuildRoot`), where a bare source path
       also refuses when the module that holds it runs programs
       (`BuildRoot.program_source_paths/3`);
    6. the rebar3 rules on the package (`Rebar`);
    7. host taint of a closure dependency (R3), the first in compile order:
       its window broken or without a sentinel, a refusal in its window, R2,
       the rebar3 static rules or rebar3 trace coverage.

  Compile-time config reads (R5) and Elixir-version reads are judged over the
  package's whole closure (`ConfigReads`, `ElixirVersion`): their refusals
  belong to the window they fell in, so in a dependency's window they taint
  it (step 7), and their problems (a toolchain read no reviewed list covers,
  no config snapshot, no Elixir version) make the trace incomplete (step
  1). A passing verdict carries `compile_env`, the closure's config reads
  as manifest items valued from the trace's config snapshot; every other
  verdict has it nil. It also carries `compile_inputs`, the closure's
  compile-time environment reads and the config reads a client must check
  itself (`CompileInputs`); every other verdict has it nil.

  Steps 1, 4, an `ebin` R2 cannot read (for the package or any closure
  dependency) and the package's own rebar3 coverage are "portability could
  not be judged"; the details go to `observations["problems"]`. Everything
  else is a refusal with its own reason. Native taint is the
  `native_closure` channel in the package's window (`Events`).

  `erlang:load_nif/2` is not call-traceable, so native libraries a compile
  maps are checked from the tracer's `/proc/self/maps` snapshots instead
  (`MappedLibs`): a new library outside the OTP root, the Elixir install and
  the closure's native dependencies refuses for the window it first shows
  up in (outside every window when it first shows at the end), and no maps
  is could-not-judge (waived only by `NCC_TRACE_ALLOW_NO_NIF_CHECK=1`, which
  the ncc_worker test helper sets on macOS and the worker never sets;
  `judge/5` also takes `nif_waiver:`).

  Only the package's closure counts, so a verdict cannot pass on another
  package's refusal: events, child traces and refusals of an app outside
  `Context.closure_of/2` of the package are dropped, and so is a stray child trace (`unknown`, an
  elixir_make `erl -eval` sub-VM: the spawn is itself traced in the Mix VM).
  An unjudged event is never dropped. Events in a native-pattern quiet
  interval are the tracer's own loading of a native dependency: dropped too,
  except an unjudged one or an integrity refusal, which count as outside
  every window.

  Never raises: anything unexpected is "portability could not be judged",
  which publishes nothing and changes no status.
  """

  alias Compatibility.Portability, as: Reasons
  alias NccWorker.{BuildCache, DepsLock, NativeBuild}

  alias NccWorker.Portability.{
    BuildRoot,
    CompileInputs,
    ConfigReads,
    Context,
    ElixirVersion,
    Events,
    MappedLibs,
    Probes,
    Rebar,
    Trees
  }

  alias NccWorker.Tracer
  alias NccWorker.Tracer.Report

  @type verdict :: %{
          required(:status) => :pass | :skip,
          required(:reason) => String.t() | nil,
          required(:observations) => map(),
          optional(:compile_env) => [ConfigReads.item()] | nil,
          optional(:compile_inputs) => [map()] | nil,
          optional(:manager) => String.t() | nil
        }

  @default_timeout_ms 30 * 60 * 1000
  @caps %{
    "config_reads" => 200,
    "elixir_version" => 50,
    "native_calls" => 50,
    "mix_exs_allowed" => 50,
    "build_root_source_path" => 50,
    "build_root_recompile_dir" => 50,
    "mix_project_paths" => 50,
    "env_reads" => 50,
    "env_writes" => 50,
    "config_writes" => 50
  }
  @max_refusals 100
  @max_problems 20
  @integrity "compile-time tracing or system flag: "
  # The built check's recompute: all digests together, and one digest
  # (`ncc_tracer_digest`'s own default).
  @built_budget_ms 5 * 60 * 1000
  @digest_timeout_ms 60_000

  # The judge's revision (precompiled judge refinements spec, principle 4):
  # bumped by every change to what the judge accepts, written into each
  # toolchain build's `judge_revision`, and what the portal reopens skipped
  # rows by (`Portal.Catalog`, `@judge_reopen`). Never key anything on
  # reason text instead. 3: compile-time env reads and config values the
  # snapshot cannot give are recorded inputs, not refusals (bumped by two
  # while `makefile_rule2` exists). 5: rebar3's own log and colour config
  # reads are dropped, a baked source path refuses only in a module that
  # runs programs, installed OTP code may call into a module the trace
  # loaded when its `.app` lists that module's application, and a
  # dependency's `rebar.config.script` is judged by its reads and result
  # (bumped by two while `makefile_rule2` exists). 7: rule 2's text checks
  # match whole tool names, a rebar3 parent's script overrides come from its
  # `mix.rebar.config`, rebar3 hooks count only on compile commands and
  # `platform_define` is judged per branch, a `rebar3_hex` plugin from Hex is
  # let through, a mix.exs read of a path the verified tarball lacks is the
  # tree check's, a literal Version comparison in mix.exs is judged over the
  # minor series, and a source directory held only by `__mix_recompile__?/0`
  # is observed (bumped by two while `makefile_rule2` exists).
  @judge_revision 7

  @doc "The judge revision a toolchain build made with `opts` records."
  # `NCC_INPUT.judge.makefile_rule2` adds one, so turning item 1 on
  # re-judges every skipped row once without an image change. While that
  # flag exists, the next refinement to ship bumps `@judge_revision` by two.
  @spec judge_revision(keyword()) :: pos_integer()
  def judge_revision(opts \\ []),
    do: @judge_revision + if(makefile_rule2?(opts), do: 1, else: 0)

  @doc """
  The project's Hex releases from its `mix.lock`, for `run/3`'s `releases:`.
  Take it right after `deps.get` and before any compile: an untraced build
  step could rewrite the lock and a tarball together later.
  """
  @spec lock_snapshot(String.t()) :: {:ok, map()} | :error
  def lock_snapshot(project_dir) do
    case DepsLock.hex_releases(project_dir) do
      {:ok, releases} when is_map(releases) -> {:ok, releases}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  Runs the traced compile of `package` in `project_dir` and judges it. In
  `:judge` mode that compile recompiles the package's closure only; in
  `:host` mode it is the run's host compile, which also compiles the project
  (`NccWorker.Tracer`). Options:

    * `env:` (required), the host compile's env;
    * `releases:` (required), `lock_snapshot/1` taken before any compile;
      without it nothing runs and the verdict is could-not-judge;
    * `hex_home:`, the run's verified Hex cache (default: `HEX_HOME` in
      `env`; without either no dependency source file is readable);
    * `run_started_at:`, the run's start in monotonic seconds, which bounds
      the compile by what is left of the run (`NccWorker.Tracer`);
    * `mode:`, `:judge` (default) or `:host`, passed to `NccWorker.Tracer.run/3`;
      any other value runs nothing and the verdict is could-not-judge;
    * `trees:`, item 5e: the `tree_snapshot/2` taken before the closure's
      first compile, or `:off` for no tree check (today's verdict). Without
      it (or with `nil`, `first_tree_snapshot/3`'s "too late") `run/3` takes the snapshot itself, which is right only before any
      compile: when the build dir already holds one of the closure's apps it
      checks nothing and the verdict is could-not-judge;
    * `makefile_rule2:`, item 1 of the judge refinements (see
      `NccWorker.NativeBuild`): `true` takes off the native list the
      dependencies whose native build file Mix never runs, and the judge
      holds them to the trace's manager (`judge/5`'s `declassified:`); a
      `deps/` that cannot be listed is then could-not-judge. Anything but
      `true` is off;
    * `trace_dir:` (default `<project_dir>/../trace`), `log_file:`,
      `timeout_ms:`, `extra_env:`, `reap:`, `cmd:` (tests).

  Never raises. Adds `observations["trace_stats"]["wall_ms"]` and
  `observations["trace_stats"]["judge_compile"]`, which names the traced
  compile in either mode: `"finished"` when it exited 0, `"not_run"` when it
  never started for want of `releases:` or for an unknown `mode:` (in
  `:judge` mode the build is the host compile's, untouched; in `:host` mode
  nothing was built), and
  `"not_finished"` otherwise (a crash, a timeout, a non-zero exit, an
  exhausted budget, the judge itself raising): the build under `_build` may
  then be half-written, and callers must not judge it.

  Also adds `observations["trace_stats"]["transient"]`: `true` when the
  verdict says nothing about the package, because the judge compile did not
  finish (`judge_compile` other than `"finished"`: a timeout, a kill, an
  exhausted run budget, processes that survived the cleanup, a crash) or its
  report was over the read budget (`"report_over_budget"`,
  `NccWorker.Tracer.Report`). A later run may judge it, so the portal retries
  such a build. `false` otherwise: a pass, a refusal, or a could-not-judge the
  same package and lock would get again (a missing or unverified tarball, a
  rebar3 parent's script, a beam R2 cannot read, a missing `ebin`).

  `compile_ms`, `report_ms` and `judge_ms` split `wall_ms` into the traced
  compile, reading its report and judging it (the last two only when the
  compile finished); `tracer_error` names why a compile did not finish (`nil`
  when it exited 0): the error `NccWorker.Tracer.run/3` returned (`"timeout"`,
  `"killed"`, `"run_budget_exhausted"`, `"group_survived"`,
  `"cleanup_unverified"`, `"writers_survived"`, `"tracer_modified"`,
  `"exited"`, `"cmd_failed"`, ...) or `"exit_<n>"` for a non-zero exit.
  `trace_mode` (only when the compile finished) is the mode the report's start
  line names (`NccWorker.Tracer.Report.mode/1`, `"judge"` without one): a
  caller that asked for `:host` takes `_build` as the build only when it says
  `"host"` (`NccWorker.HostTrace`).
  """
  @spec run(String.t(), String.t(), keyword()) :: verdict()
  def run(project_dir, package, opts) do
    started = System.monotonic_time(:millisecond)

    project_dir
    |> guarded_run(package, opts)
    |> put_stat("wall_ms", System.monotonic_time(:millisecond) - started)
    |> put_transient()
  end

  defp put_transient(%{status: :pass} = verdict), do: put_stat(verdict, "transient", false)

  defp put_transient(%{observations: obs} = verdict) do
    stats = Map.get(obs, "trace_stats") || %{}

    transient =
      stats["judge_compile"] != "finished" or stats["report_over_budget"] == true

    put_stat(verdict, "transient", transient)
  end

  defp guarded_run(project_dir, package, opts) do
    case {releases(opts), Keyword.get(opts, :mode, :judge)} do
      {_releases, mode} when mode not in [:judge, :host] ->
        not_run("unknown tracer mode: #{inspect(mode)}")

      {{:ok, releases}, _mode} ->
        traced_run(project_dir, package, opts, releases)

      {:error, _mode} ->
        not_run("no mix.lock snapshot taken before the compile")
    end
  rescue
    e -> unfinished("judge failed: " <> Exception.message(e))
  catch
    kind, reason -> unfinished("judge failed: #{kind} #{inspect(reason, limit: 20)}")
  end

  # The traced compile never started: `_build` is as it was.
  defp not_run(why), do: why |> not_judged() |> put_stat("judge_compile", "not_run")

  # Nothing says the judge compile ran to its end, so `_build` may hold a
  # half-written build no caller may judge.
  defp unfinished(why), do: why |> not_judged() |> put_stat("judge_compile", "not_finished")

  defp releases(opts) do
    case Keyword.get(opts, :releases) do
      {:ok, map} when is_map(map) -> {:ok, map}
      map when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  defp traced_run(project_dir, package, opts, releases) do
    env = Keyword.fetch!(opts, :env)
    trace_dir = Keyword.get_lazy(opts, :trace_dir, fn -> default_trace_dir(project_dir) end)
    home = hex_home(opts, env)
    {native, declassified, split_problem} = native_split(project_dir, opts, releases, home)

    {trees_ms, {trees, tree_problem}} =
      timed(fn -> trees(project_dir, opts, env, releases, home, native) end)

    hooks = hook_scripts(project_dir, env ++ Keyword.get(opts, :extra_env, []))

    {compile_ms, traced} =
      timed(fn ->
        Tracer.run(project_dir, [package], tracer_opts(opts, env, trace_dir, native))
      end)

    ctx_opts = [
      releases: releases,
      hex_home: home,
      declassified: declassified,
      trees: trees,
      hook_scripts: hooks
    ]

    project_dir
    |> verdict(package, traced, trace_dir, native, ctx_opts)
    |> unsplit(split_problem)
    |> unsplit(tree_problem)
    |> put_stat("judge_compile", judge_compile(traced))
    |> put_stat("trees_ms", trees_ms)
    |> put_stat("compile_ms", compile_ms)
    |> put_stat("tracer_error", tracer_error(traced))
    |> put_stat("makefile_rule2", makefile_rule2?(opts))
  end

  # Item 1 (behind `makefile_rule2: true`): the native list without the
  # dependencies whose native build file Mix never runs, which the judge
  # then holds to the manager the trace recorded (`declassified:`). The
  # `build_tools` come from each dependency's tarball verified against the
  # lock snapshot, never from `mix.lock` itself.
  # `NativeBuild.split/2` reads an unlistable `deps/` as no dependencies at
  # all; with the flag on that is a problem instead (fail closed), which
  # `unsplit/2` turns into could-not-judge once the compile is over.
  # sobelow_skip ["Traversal.FileModule"]
  defp native_split(project_dir, opts, releases, home) do
    cond do
      not makefile_rule2?(opts) ->
        {native_deps(project_dir), %{}, nil}

      match?({:ok, _}, File.ls(Path.join(project_dir, "deps"))) ->
        {native, declassified} =
          NativeBuild.split(project_dir, &Context.release_tarball(home, releases, &1))

        {native, declassified, nil}

      true ->
        {[], %{}, "deps/ could not be listed for rule 2 (makefile_rule2)"}
    end
  end

  defp makefile_rule2?(opts), do: Keyword.get(opts, :makefile_rule2) == true

  @doc false
  # Public for tests. The sha256 of each reviewed rebar3 hook script
  # (`Rebar.reviewed_hooks/0`) under `deps/`, taken before the compile, for
  # the apps whose variable the compile's `env` and this VM's environment
  # (which the compile inherits) both leave unset. A script that is not a
  # regular file, or any set value, even an empty one, leaves the app out:
  # its hook then counts.
  @spec hook_scripts(String.t(), [{String.t(), String.t() | nil}]) :: %{String.t() => String.t()}
  def hook_scripts(project_dir, env) do
    for {app, {file, var}} <- Rebar.reviewed_hooks(),
        System.get_env(var) == nil,
        not Enum.any?(env, &match?({^var, value} when is_binary(value), &1)),
        sha = regular_sha256(Path.join([project_dir, "deps", app, file])),
        sha != nil,
        into: %{},
        do: {app, sha}
  end

  @max_hook_script_bytes 1024 * 1024

  # sobelow_skip ["Traversal.FileModule"]
  defp regular_sha256(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_hook_script_bytes <-
           File.lstat(path),
         {:ok, bytes} <- File.read(path) do
      :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
    else
      _ -> nil
    end
  end

  @doc """
  Item 5e's tree snapshot (`NccWorker.Portability.Trees.snapshot/5`) of
  `project_dir` for `run/3`'s `trees:`, with the native list `run/3` would
  use for the same `opts` (`releases:`, `hex_home:` (default `HEX_HOME`),
  `makefile_rule2:`). Take it before the first compile of the closure,
  right after the `deps.get` that fetched it: a compile writes into a
  dependency's own source dir (Mix's leex and yecc compilers put the `.erl`
  they generate in `src/`). Never raises; `%{}` (nothing checked) when it
  cannot be taken.
  """
  @spec tree_snapshot(String.t(), keyword()) :: %{String.t() => Trees.tree()}
  def tree_snapshot(project_dir, opts) do
    case releases(opts) do
      {:ok, releases} ->
        home = Keyword.get_lazy(opts, :hex_home, fn -> System.get_env("HEX_HOME") end)
        {native, _declassified, _problem} = native_split(project_dir, opts, releases, home)
        Trees.snapshot(project_dir, releases, home, native)

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  @doc """
  `tree_snapshot/2` for a run whose first compile is still to come (the
  full run's, taken after `Project.add_package/3`'s `deps.get`), or `nil`
  when the build dir `env` names already holds one of the locked apps: some
  step compiled the closure before it (a `deps.get` hook such as Nerves 1's
  nerves_bootstrap), so the trees may already hold what that compile wrote
  (leex and yecc output in `src/`). `nil` passed on as `run/3`'s `trees:`
  is could-not-judge, as no `trees:` at all is once the closure is
  compiled, never a refusal. Never raises.
  """
  @spec first_tree_snapshot(String.t(), [{String.t(), String.t()}], keyword()) ::
          %{String.t() => Trees.tree()} | nil
  def first_tree_snapshot(project_dir, env, opts) do
    case releases(opts) do
      {:ok, releases} ->
        if compiled_apps(project_dir, env, releases) == [],
          do: tree_snapshot(project_dir, opts)

      :error ->
        tree_snapshot(project_dir, opts)
    end
  rescue
    _ -> nil
  end

  # `run/3`'s trees: the caller's pre-compile snapshot (`trees:`, `:off` for
  # none), else (no `trees:`, or `nil`, `first_tree_snapshot/3`'s "too late")
  # one taken now, which is before any compile only when the build dir holds
  # none of the closure's apps; otherwise nothing is checked and the verdict
  # is could-not-judge (a snapshot after a compile would refuse what the
  # compile itself wrote). An app native now is never checked, whatever the
  # snapshot said.
  defp trees(project_dir, opts, env, releases, home, native) do
    case Keyword.get(opts, :trees) do
      trees when is_map(trees) ->
        {Map.new(trees, fn {app, tree} -> {app, unless_native(app, tree, native)} end), nil}

      :off ->
        {%{}, nil}

      _none ->
        case compiled_apps(project_dir, env, releases) do
          [] ->
            {Trees.snapshot(project_dir, releases, home, native), nil}

          apps ->
            {%{},
             "no tree snapshot taken before the closure was compiled: " <>
               Enum.join(Enum.take(apps, 5), ", ")}
        end
    end
  end

  defp unless_native(app, tree, native),
    do: if(app in native, do: {:unverified, "native build"}, else: tree)

  # The locked apps the build dir the compile writes already holds an ebin of.
  # sobelow_skip ["Traversal.FileModule"]
  defp compiled_apps(project_dir, env, releases) do
    build =
      env_value(env, "MIX_BUILD_PATH") ||
        Path.join([project_dir, "_build", env_value(env, "MIX_ENV") || "dev"])

    releases
    |> Map.keys()
    |> Enum.sort()
    |> Enum.filter(&File.dir?(Path.join([build, "lib", &1, "ebin"])))
  end

  @doc false
  # Public for tests: a finished compile's verdict is not passed when
  # `native_split/4` could not list `deps/`.
  @spec unsplit(verdict(), String.t() | nil) :: verdict()
  def unsplit(verdict, nil), do: verdict

  def unsplit(%{observations: obs} = verdict, problem) do
    %{
      verdict
      | status: :skip,
        reason: Reasons.could_not_judge(),
        observations: Map.put(obs, "problems", [problem | Map.get(obs, "problems") || []])
    }
    |> Map.put(:compile_env, nil)
    |> Map.put(:compile_inputs, nil)
  end

  defp judge_compile({:ok, 0}), do: "finished"
  defp judge_compile(_traced), do: "not_finished"

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  # Short and stable, for `trace_stats` and for callers that tell a compile
  # that left processes behind from one that merely failed. `Tracer.run/3`
  # already turns exits 124 and 137 into `:timeout` and `:killed`.
  defp tracer_error({:ok, 0}), do: nil
  defp tracer_error({:ok, status}) when is_integer(status), do: "exit_#{status}"
  defp tracer_error({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)

  defp tracer_error({:error, reason}) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: Atom.to_string(elem(reason, 0))

  defp tracer_error(_other), do: "other"

  defp default_trace_dir(project_dir), do: Path.join(Path.dirname(project_dir), "trace")

  defp hex_home(opts, env) do
    case Keyword.get(opts, :hex_home) do
      home when is_binary(home) -> home
      _ -> env_value(env, "HEX_HOME")
    end
  end

  defp env_value(env, name) do
    case List.keyfind(env, name, 0) do
      {_, value} when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp tracer_opts(opts, env, trace_dir, native) do
    [
      trace_dir: trace_dir,
      native: native,
      env: env,
      log_file: Keyword.get(opts, :log_file),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      extra_env: Keyword.get(opts, :extra_env, []),
      run_started_at: Keyword.get(opts, :run_started_at),
      mode: Keyword.get(opts, :mode, :judge)
    ] ++ Keyword.take(opts, [:reap, :cmd])
  end

  defp verdict(project_dir, package, {:ok, 0}, trace_dir, native, ctx_opts) do
    {report_ms, report} = timed(fn -> Report.read(trace_dir) end)

    {judge_ms, verdict} =
      timed(fn ->
        judge(project_dir, package, report, native, ctx_opts ++ [built_check: true])
      end)

    verdict
    |> put_stat("report_over_budget", report.over_budget)
    |> put_stat("trace_mode", Atom.to_string(Report.mode(report)))
    |> put_stat("report_ms", report_ms)
    |> put_stat("judge_ms", judge_ms)
  end

  defp verdict(_project_dir, _package, {:ok, status}, _trace_dir, _native, _ctx_opts),
    do: not_judged("traced compile exited #{inspect(status)}")

  defp verdict(_project_dir, _package, {:error, reason}, _trace_dir, _native, _ctx_opts),
    do: not_judged("tracer: " <> inspect(reason, limit: 20))

  defp verdict(_project_dir, _package, other, _trace_dir, _native, _ctx_opts),
    do: not_judged("tracer: " <> inspect(other, limit: 20))

  defp not_judged(why),
    do: %{status: :skip, reason: Reasons.could_not_judge(), observations: %{"problems" => [why]}}

  defp put_stat(%{observations: obs} = verdict, key, value) do
    stats = Map.get(obs, "trace_stats") || %{}
    %{verdict | observations: Map.put(obs, "trace_stats", Map.put(stats, key, value))}
  end

  @doc "The dependencies under `deps/` that build native code or read the target (spec R3 native taint)."
  @spec native_deps(String.t()) :: [String.t()]
  # The run's own project dir.
  # sobelow_skip ["Traversal.FileModule"]
  def native_deps(project_dir) do
    deps = Path.join(project_dir, "deps")

    case File.ls(deps) do
      {:ok, names} ->
        names |> Enum.sort() |> Enum.reject(&BuildCache.dep_target_agnostic?(deps, &1))

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Judges one read trace. `opts` go to `Context.build/5` (`releases:`,
  `hex_home:`); without them the context reads the project's `mix.lock` and
  this process's `HEX_HOME` now, which only tests should rely on.
  Every closure dependency's build dir must also match the digest the tracer
  took when its window closed, all of them recomputed within
  `built_budget_ms:` (default 5 minutes; `built_clock:` for tests);
  `built_check: false` turns that off for a hand-built report with no
  `built` lines (`run/3` always checks). `declassified:` is what
  `NativeBuild.split/2` declassified (`%{app => manager}`, item 1, default
  none): each such dependency in the package's closure must have been built
  by that manager, as the trace's closure line records. `trees:` is the
  `NccWorker.Portability.Trees.snapshot/5` taken before the compile (item
  5e, default none, so no tree is checked): a closure dependency whose tree
  differed from its tarball refuses, and the files and listings the compile
  read are re-checked. The verdict's
  `manager` is the package's own manager from that line (nil when unknown).
  Never raises.
  """
  @spec judge(String.t(), String.t(), Report.t(), [String.t()], keyword()) :: verdict()
  def judge(project_dir, package, report, native, opts \\ [])

  def judge(project_dir, package, %Report{} = report, native, opts) do
    Context.with_link_cache(fn ->
      project_dir |> facts(package, report, native, opts) |> verdict_of()
    end)
  rescue
    e -> not_judged("judge failed: " <> Exception.message(e))
  catch
    kind, reason -> not_judged("judge failed: #{kind} #{inspect(reason, limit: 20)}")
  end

  def judge(_project_dir, _package, other, _native, _opts),
    do: not_judged("not a trace report: " <> inspect(other, limit: 5))

  # --- gathering ---------------------------------------------------------------

  defp facts(project_dir, package, report, native, opts) do
    ctx = Context.build(project_dir, package, report, native, opts)
    scope = MapSet.new(Context.closure_of(ctx, ctx.package))
    decided = decide_all(report, ctx, scope)
    unjudged = for {_owner, {:unjudged, why}} <- decided, do: why
    decided = for {owner, decision} <- decided, in_scope?(owner, scope), do: {owner, decision}

    libs =
      mapped_libs(report, ctx, scope, Keyword.get_lazy(opts, :nif_waiver, &MappedLibs.waived?/0))

    decided = decided ++ libs.decided
    elixir = elixir_of(report)

    config =
      ConfigReads.judge(
        decided,
        elixir,
        report.config_env,
        ConfigReads.trees(ctx),
        ctx.nested,
        ConfigReads.app_defaults(ctx)
      )

    version = ElixirVersion.judge(decided, elixir)
    decided = decided ++ config.refusals ++ version.refusals
    package_r2 = package_build_root(ctx)
    deps = dep_results(ctx, report, decided)

    %{
      ctx: ctx,
      scope: scope,
      report: report,
      decided: decided,
      config: config,
      inputs: CompileInputs.build(decided, config.inputs),
      trace_problems:
        trace_problems(report, ctx) ++
          built_problems(ctx, report, opts) ++
          unjudged ++ libs.problems ++ config.problems ++ version.problems,
      libs: libs,
      package_window: window_problem(report, ctx.package),
      package_r2: package_r2,
      package_rebar: rebar(ctx, report, ctx.package),
      deps: deps,
      manager_mismatch: manager_mismatch(ctx, scope, Keyword.get(opts, :declassified, %{})),
      tree_refusal: tree_refusal(ctx, scope)
    }
  end

  # Item 5e: a closure dependency whose source tree was not its verified
  # tarball's before the compile refuses, the first by app name.
  defp tree_refusal(ctx, scope) do
    ctx.trees
    |> Enum.sort()
    |> Enum.find_value(fn
      {app, {:differs, detail}} ->
        if MapSet.member?(scope, app), do: Reasons.tree_differs() <> "#{app} (#{detail})"

      _ ->
        nil
    end)
  end

  # Item 1: a closure dependency rule 2 took off the native list because its
  # verified tarball's `build_tools` and its files say Mix runs mix or
  # rebar3 must have been built by exactly that manager, as the trace's
  # closure line records Mix's own answer. Another manager, or none recorded, refuses: its Makefile may
  # have run.
  defp manager_mismatch(ctx, scope, declassified) do
    declassified
    |> Enum.sort()
    |> Enum.find_value(fn {app, computed} ->
      traced = Context.manager(ctx, app)

      if MapSet.member?(scope, app) and traced != computed,
        do:
          Reasons.manager_mismatch() <>
            "#{app} (trace #{traced || "none"}, tarball #{computed})"
    end)
  end

  defp elixir_of(%Report{start: %{"elixir" => elixir}}) when is_binary(elixir), do: elixir
  defp elixir_of(_report), do: nil

  # Every event as `{owner, decision}`: the Mix VM's by `Context.owner/2`,
  # a closure dependency's child VM's by its app (child clocks do not align
  # with the Mix VM's windows). One `MixExsSlice.analyse/1` per `mix.exs`.
  # Each VM's events are decided with that VM's own ensure_loaded probes
  # (`Context.ensured`): pids and times mean nothing in another VM.
  defp decide_all(report, ctx, scope) do
    main = for event <- report.events, do: {Context.owner(ctx, event), event}

    children =
      for {app, child} <- Enum.sort(report.children),
          Context.dep?(ctx, app),
          do: {"child:" <> app, for(event <- child.events, do: {app, event})}

    vms = [{"main", main} | children]
    owned = Enum.flat_map(vms, &elem(&1, 1))
    slices = Events.mix_exs_slices(ctx, Enum.reject(owned, &match?({:quiet, _}, &1)))

    for {vm_name, vm} <- vms,
        vm_ctx = %{ctx | ensured: Probes.ensured(vm)},
        {owner, event} <- vm,
        decision = event |> Events.decide(vm_ctx, owner, slices) |> in_vm(vm_name),
        kept = keep(owner, decision, scope),
        kept != nil,
        do: kept
  end

  # Env reads and writes keep the VM they were made in: timestamps compare
  # only within one VM (`CompileInputs`).
  defp in_vm({:observe, kind, item}, vm) when kind in ["env_reads", "env_writes"],
    do: {:observe, kind, Map.put(item, "vm", vm)}

  defp in_vm(decision, _vm), do: decision

  # An unjudged event counts wherever it fell (`:any`, never in scope). An
  # integrity refusal (the trace itself tampered with) refuses wherever it
  # fell too: from a quiet interval or an owner outside the package's
  # closure (its window or its child VM) it counts as `:outside`.
  defp keep(_owner, {:unjudged, _} = decision, _scope), do: {:any, decision}

  defp keep(owner, {:refuse, @integrity <> _} = decision, scope),
    do: if(in_scope?(owner, scope), do: {owner, decision}, else: {:outside, decision})

  defp keep(:quiet, _decision, _scope), do: nil
  defp keep(_owner, :ignore, _scope), do: nil
  defp keep(owner, decision, _scope), do: {owner, decision}

  defp in_scope?(:outside, _scope), do: true
  defp in_scope?(owner, scope), do: MapSet.member?(scope, owner)

  # The loaded-library check (`MappedLibs`, which says why). The Mix VM's
  # snapshots in order (start, every window close, end): a library first
  # seen at a window's close belongs to that window's app (Mix compiles one
  # dependency at a time), one first seen at the end to no window
  # (`:outside`, against everything). A closure child VM's start against its
  # `libs` lines (a child that compiled nothing wrote none: its start alone;
  # one that compiled and wrote none is unavailable)
  # counts against its app. Only owners in the package's closure count, as
  # for events. Allowed: the OTP root, the Elixir install, and a native
  # closure dependency's own dirs (never the package's) (its NIF, loaded when the tracer sets its
  # patterns; calls into it are the native_closure channel).
  defp mapped_libs(report, ctx, scope, waiver) do
    allowed? = &lib_allowed?(ctx, scope, &1)

    children =
      for {app, child} <- Enum.sort(report.children), Context.dep?(ctx, app) do
        {app, MappedLibs.check(child.start, child_snapshots(child), allowed?)}
      end

    results = Enum.filter(main_libs(report, allowed?) ++ children, &in_scope?(elem(&1, 0), scope))

    Enum.reduce(results, %{decided: [], problems: [], native: [], waived: false}, fn
      {owner, {:refuse, reason}}, acc ->
        %{acc | decided: acc.decided ++ [{owner, {:refuse, reason}}]}

      {_owner, {:ok, libs}}, acc ->
        %{acc | native: Enum.uniq(acc.native ++ libs)}

      {_owner, :unavailable}, acc when waiver ->
        %{acc | waived: true}

      {_owner, :unavailable}, acc ->
        %{acc | problems: Enum.uniq(acc.problems ++ ["native library check unavailable"])}
    end)
  end

  # A child's `libs` lines. A child that compiled nothing wrote none and its
  # start is all there is; one that compiled and wrote none is unavailable.
  defp child_snapshots(%{libs: [_ | _] = libs}), do: libs
  defp child_snapshots(%{compiles: [_ | _]}), do: []
  defp child_snapshots(child), do: [child.start]

  defp main_libs(report, allowed?) do
    closes =
      report.windows
      |> Enum.filter(&is_integer(&1.close))
      |> Enum.sort_by(& &1.close)
      |> Enum.map(&{&1.app, Map.get(&1, :libs)})

    {_last, results} =
      Enum.reduce(closes ++ [{:outside, report.ending}], {report.start, []}, fn {owner, snap},
                                                                                {prev, acc} ->
        {snap, [{owner, MappedLibs.check(prev, [snap], allowed?)} | acc]}
      end)

    Enum.reverse(results)
  end

  defp lib_allowed?(ctx, scope, path) do
    real = Context.realpath(path) || path

    dirs =
      [ctx.otp_root, ctx.elixir_root] ++
        for app <- scope,
            app != ctx.package,
            Context.dep?(ctx, app),
            ctx.deps[app].native?,
            do: [ctx.deps[app].build, ctx.deps[app].dest]

    dirs |> List.flatten() |> Enum.any?(&(is_binary(&1) and String.starts_with?(real, &1 <> "/")))
  end

  # What the trace itself says about whether it can be used at all. The
  # Report collects most of these; a report built some other way (tests,
  # a later reader) is held to the same checks here, each passed only by an
  # explicit value.
  defp trace_problems(report, ctx) do
    ending = report.ending || %{}

    [
      {report.refused_start != nil, "tracer refused to start"},
      {report.start == nil, "no start line"},
      {report.closure == nil, "no closure line"},
      {report.ending == nil, "no end line"},
      {report.ending != nil and ending["status"] != "ok",
       "traced compile ended #{inspect(ending["status"])}"},
      {ending != %{} and not clean_end?(ending), "the end failed its checks"},
      {report.overflow != [], "trace overflowed"},
      {not match?(%{"unjudged" => 0}, report.stats), "stats missing or unjudged events"},
      {report.closure != nil and not Context.dep?(ctx, ctx.package),
       "package not in the traced closure"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
    |> Kernel.++(report.problems)
  end

  # R3: no closure dependency is judged without a trace of its own compile.
  # The tracer took a digest of each dependency's ebin and priv when its
  # window closed; one that is missing, or that differs from the build dir
  # now, means the files judged are not the files the trace saw compiled
  # (restored, reused or rewritten since). Fails closed: no digest then, no
  # digest now, or no build dir is never a match.
  #
  # The recompute is bounded as a whole (`built_budget_ms:`, default 5 min)
  # on top of each digest's own limits: a dependency checked once the
  # budget is spent is not judged ("no time left").
  defp built_problems(ctx, report, opts) do
    if Keyword.get(opts, :built_check, true) do
      clock = Keyword.get(opts, :built_clock, fn -> System.monotonic_time(:millisecond) end)
      deadline = clock.() + Keyword.get(opts, :built_budget_ms, @built_budget_ms)

      ctx
      |> Context.closure_of(ctx.package)
      |> Enum.map(&built_mismatch(ctx, report, &1, deadline - clock.()))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&("built outside the trace: " <> &1))
    else
      []
    end
  end

  defp built_mismatch(_ctx, _report, app, left_ms) when left_ms <= 0, do: "#{app} (no time left)"

  defp built_mismatch(ctx, report, app, left_ms) do
    recorded = Map.get(report.built || %{}, app)

    case {recorded, Map.get(ctx.deps, app)} do
      {%{digest: want}, %{build: dir}} when is_binary(want) and is_binary(dir) ->
        compare_built(app, want, digest_now(dir, left_ms))

      {%{error: why}, _dep} when is_binary(why) ->
        "#{app} (digest failed at window close: #{why})"

      {%{digest: want}, _dep} when is_binary(want) ->
        "#{app} (no build dir)"

      _ ->
        "#{app} (no digest recorded)"
    end
  end

  defp compare_built(_app, want, {:ok, want, _files}), do: nil
  defp compare_built(app, _want, {:ok, _other, _files}), do: app

  defp compare_built(app, _want, {:error, why}),
    do: "#{app} (digest failed now: #{inspect(why, limit: 5, printable_limit: 200)})"

  # The digest's own limits, its time cut to what is left of the budget.
  defp digest_now(dir, left_ms) do
    case :ncc_tracer_digest.dir(dir, %{timeout_ms: min(left_ms, @digest_timeout_ms)}) do
      {:ok, digest, files} when is_binary(digest) -> {:ok, digest, files}
      {:error, why} -> {:error, why}
      other -> {:error, {:unexpected, other}}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp clean_end?(ending) do
    ending["overflow"] == false and
      Enum.all?(~w(depth_ok final_sentinel integrity_ok delivered), &(ending[&1] == true))
  end

  defp window_problem(report, app) do
    case Enum.filter(report.windows, &match?(%{app: ^app}, &1)) do
      [window] -> window_checks(report, window)
      [] -> "no window for #{inspect(app)}"
      _ -> "#{app}'s window is broken (more than one)"
    end
  end

  defp window_checks(report, %{app: app, open: open, close: close} = window) do
    cond do
      not (is_integer(open) and is_integer(close)) ->
        "#{app}'s window is broken"

      not intact?(window) ->
        "#{app}'s window is broken"

      not Enum.any?(report.sentinels, &sentinel_in?(&1, app, open, close)) ->
        "sentinel missing in #{app}'s window"

      true ->
        nil
    end
  end

  defp intact?(window) do
    Map.get(window, :depth_ok) == true and Map.get(window, :integrity_ok) == true and
      Map.get(window, :delivered) == true
  end

  defp sentinel_in?(%{app: app, ts: ts} = sentinel, app, open, close) when is_integer(ts),
    do: ts >= open and ts <= close and Map.get(sentinel, :integrity_ok) == true

  defp sentinel_in?(_sentinel, _app, _open, _close), do: false

  # R2: `nil` (clean), `{:observe, list}`, `{:refuse, reason}` or
  # `{:error, why}`.
  defp build_root(ctx, app) do
    case Context.ebin(ctx, app) do
      nil ->
        {:error, "no ebin for #{inspect(app)}"}

      ebin ->
        ebin
        |> BuildRoot.check(Context.roots(ctx), &Context.closure_file?(ctx, &1), r2_opts(ctx))
        |> r2()
    end
  end

  # R2 for the package's own beams (closure dependencies are not published
  # by this build): a bare source path, otherwise an observation, refuses
  # when the module that holds it runs programs
  # (`BuildRoot.program_source_paths/3`).
  defp package_build_root(ctx) do
    case Context.ebin(ctx, ctx.package) do
      nil ->
        {:error, "R2: no ebin for #{inspect(ctx.package)}"}

      ebin ->
        ebin
        |> BuildRoot.program_source_paths(
          Context.roots(ctx),
          &Context.closure_file?(ctx, &1),
          r2_opts(ctx)
        )
        |> r2()
    end
  end

  # A template root only `__mix_recompile__?/0` holds is an observation
  # (`BuildRoot`, "build_root_recompile_dir").
  defp r2_opts(ctx), do: [closure_dir?: &Context.closure_dir?(ctx, &1)]

  defp r2(:ok), do: nil
  defp r2({:observe, list}) when is_list(list), do: {:observe, list}
  defp r2({:refuse, reason}) when is_binary(reason), do: {:refuse, reason}
  defp r2({:error, why}), do: {:error, "R2: #{why}"}
  defp r2(other), do: {:error, "R2: unexpected #{inspect(other, limit: 5)}"}

  # The rebar3 rules: `nil` for a Mix-built app, else `{:refuse, reason}`,
  # `{:error, why}` (coverage, taint for a dependency), `{:unjudged, why}`
  # (could not be judged), `{:gap, module}` or `:ok`.
  defp rebar(ctx, report, app) do
    if Context.manager(ctx, app) == "rebar3", do: rebar3(ctx, report, app)
  end

  defp rebar3(ctx, report, app) do
    case Context.dest(ctx, app) do
      nil -> {:unjudged, "rebar3 source dir missing"}
      dest -> rebar3(static_rebar(ctx, report, app, dest), ctx, report, app)
    end
  end

  defp rebar3({:refuse, _} = refusal, _ctx, _report, _app), do: refusal
  defp rebar3({:unjudged, _} = unjudged, _ctx, _report, _app), do: unjudged

  defp rebar3(:ok, ctx, report, app),
    do: Rebar.coverage(Context.ebin(ctx, app), Map.get(report.children, app))

  # The static rules on the app's rebar.config from its verified Hex
  # tarball and its rebar3 parents' (their overrides), then the
  # mix.rebar.config rebar3 read. A script on disk counts as one in the
  # tarball: judged by that mix.rebar.config and the trace (`Rebar`).
  defp static_rebar(ctx, report, app, dest) do
    parents = Context.rebar3_parents(ctx, app)

    with {:ok, own} <- Rebar.tarball_sources(Context.tarball(ctx, app)),
         {:ok, inherited} <- parent_sources(ctx, parents) do
      own = %{own | script?: own.script? or disk_script?(dest)}
      own = Map.put(own, :reviewed, reviewed_hooks(ctx, report, app))
      Rebar.check_sources(own, inherited, mix_rebar_config(ctx, app))
    end
  end

  # The reviewed compile hooks `app` may run (`Rebar.allowed_hooks/3`):
  # none when the compile wrote the hook's variable anywhere it was traced,
  # as rebar3 inherits the Mix VM's environment.
  defp reviewed_hooks(ctx, report, app) do
    case Map.get(Rebar.reviewed_hooks(), app) do
      {_file, var} ->
        if env_written?(report, var),
          do: [],
          else: Rebar.allowed_hooks(app, Context.tarball(ctx, app), ctx.hook_scripts[app])

      nil ->
        []
    end
  end

  defp env_written?(report, var) do
    events = report.events ++ Enum.flat_map(report.children, fn {_app, c} -> c.events end)

    # A write whose name the trace did not record as a string counts.
    Enum.any?(events, fn
      %{"channel" => "env_write", "arg" => %{"name" => name}} when is_binary(name) -> name == var
      %{"channel" => "env_write"} -> true
      _ -> false
    end)
  end

  # A scripted parent's overrides are what its script evaluated to: Mix
  # wrote them into the parent's own mix.rebar.config (`Rebar`).
  defp parent_sources(ctx, parents) do
    Enum.reduce_while(parents, {:ok, []}, fn parent, {:ok, acc} ->
      case Rebar.tarball_sources(Context.tarball(ctx, parent)) do
        {:ok, %{script?: true} = sources} ->
          {:cont, {:ok, acc ++ [Map.put(sources, :mix_config, mix_rebar_config(ctx, parent))]}}

        {:ok, sources} ->
          {:cont, {:ok, acc ++ [sources]}}

        {:unjudged, why} ->
          {:halt, {:unjudged, "rebar3 parent #{parent}: #{why}"}}
      end
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp disk_script?(dest), do: File.exists?(Path.join(dest, "rebar.config.script"))

  # The config Mix wrote for rebar3 (`REBAR_CONFIG`), next to the ebin.
  defp mix_rebar_config(ctx, app) do
    case Context.ebin(ctx, app) do
      nil -> {:unjudged, "rebar3 build dir missing"}
      ebin -> Path.join(Path.dirname(ebin), "mix.rebar.config")
    end
  end

  # Every closure dependency but the package, in compile order (the
  # closure line's), with what R3 makes of it.
  defp dep_results(ctx, report, decided) do
    scope = Context.closure_of(ctx, ctx.package)

    for %{"app" => app} <- closure_deps(report),
        app != ctx.package,
        app in scope,
        do: {app, dep_result(ctx, report, decided, app)}
  end

  defp closure_deps(%Report{closure: %{"deps" => deps}}) when is_list(deps),
    do: Enum.filter(deps, &match?(%{"app" => app} when is_binary(app), &1))

  defp closure_deps(_report), do: []

  defp dep_result(ctx, report, decided, app) do
    r2 = build_root(ctx, app)
    rebar = rebar(ctx, report, app)

    taint =
      Enum.find_value(
        [
          fn -> window_problem(report, app) end,
          fn -> first_refusal(decided, app) end,
          fn -> refusal_of(r2) end,
          fn -> unless match?({:error, _}, r2), do: rebar_taint(rebar) end
        ],
        & &1.()
      )

    %{taint: taint, r2: r2, rebar: rebar}
  end

  defp refusal_of({:refuse, reason}), do: reason
  defp refusal_of(_result), do: nil

  # For a dependency, a rebar3 coverage error is host taint (spec R3: its
  # rebar3 sentinel missing), unless R2 could not read its ebin, which makes
  # the whole verdict could-not-judge instead.
  defp rebar_taint({:refuse, reason}), do: reason
  defp rebar_taint({:error, why}), do: why
  defp rebar_taint(_result), do: nil

  defp first_refusal(decided, owner) do
    Enum.find_value(decided, fn
      {^owner, {:refuse, reason}} -> reason
      _ -> nil
    end)
  end

  # --- the verdict -------------------------------------------------------------

  defp verdict_of(facts) do
    problems = problems(facts)

    reason =
      Enum.find_value(
        [
          fn -> if facts.trace_problems != [], do: Reasons.could_not_judge() end,
          fn -> facts.manager_mismatch end,
          fn -> facts.tree_refusal end,
          fn -> first_refusal(facts.decided, :outside) end,
          fn -> first_refusal(facts.decided, facts.ctx.package) end,
          fn -> if facts.package_window, do: Reasons.could_not_judge() end,
          fn -> package_r2(facts.package_r2) end,
          fn -> package_rebar(facts.package_rebar) end,
          fn -> closure(facts.deps) end
        ],
        & &1.()
      )

    status = if reason, do: :skip, else: :pass

    %{
      status: status,
      reason: reason,
      observations: observations(facts, problems),
      compile_env: if(status == :pass, do: facts.config.items),
      compile_inputs: if(status == :pass, do: facts.inputs),
      manager: Context.manager(facts.ctx, facts.ctx.package)
    }
  end

  defp package_r2({:refuse, reason}), do: reason
  defp package_r2({:error, _why}), do: Reasons.could_not_judge()
  defp package_r2(_result), do: nil

  defp package_rebar({:refuse, reason}), do: reason
  defp package_rebar({:error, _why}), do: Reasons.could_not_judge()
  defp package_rebar({:unjudged, _why}), do: Reasons.could_not_judge()
  defp package_rebar(_result), do: nil

  # The first dependency in compile order that is host-tainted, or whose
  # beams R2 cannot read or whose rebar3 build could not be judged.
  defp closure(deps) do
    Enum.find_value(deps, fn
      {app, %{taint: taint}} when is_binary(taint) ->
        "closure dependency observed the host: #{app} (#{taint})"

      {_app, %{r2: {:error, _}}} ->
        Reasons.could_not_judge()

      {_app, %{rebar: {:unjudged, _}}} ->
        Reasons.could_not_judge()

      _ ->
        nil
    end)
  end

  defp problems(facts) do
    package = facts.ctx.package

    facts.trace_problems ++
      List.wrap(facts.package_window) ++
      error_text(package, facts.package_r2) ++
      error_text(package, facts.package_rebar) ++
      Enum.flat_map(facts.deps, fn {app, result} ->
        error_text(app, result.r2) ++ unjudged_text(app, result.rebar)
      end)
  end

  defp error_text(app, {:error, why}), do: ["#{app}: #{why}"]
  defp error_text(app, {:unjudged, why}), do: ["#{app}: #{why}"]
  defp error_text(_app, _result), do: []

  defp unjudged_text(app, {:unjudged, why}), do: ["#{app}: #{why}"]
  defp unjudged_text(_app, _result), do: []

  # --- observations ------------------------------------------------------------

  defp observations(facts, problems) do
    observed =
      for {owner, {:observe, kind, item}} <- facts.decided,
          do: {kind, Map.put(item, "owner", owner_name(owner))}

    refusals =
      for {owner, {:refuse, reason}} <- facts.decided,
          do: %{"owner" => owner_name(owner), "reason" => reason}

    @caps
    |> Map.new(fn {kind, cap} -> {kind, collect(observed ++ r2_observed(facts), kind, cap)} end)
    |> Map.merge(%{
      "trace_stats" => stats(facts),
      "refusals" => refusals |> Enum.uniq() |> Enum.take(@max_refusals),
      "taint" => for({app, %{taint: t}} when is_binary(t) <- facts.deps, into: %{}, do: {app, t}),
      "native_libs" => Enum.take(facts.libs.native, 50),
      "config_unreviewed" => Enum.take(facts.config.unreviewed, 50),
      "nif_check" => if(facts.libs.waived, do: "waived", else: "ok"),
      "tree_check" => tree_summary(facts),
      "problems" => problems |> Enum.uniq() |> Enum.take(@max_problems)
    })
  end

  defp tree_summary(%{ctx: ctx, scope: scope}) do
    for {app, tree} <- ctx.trees, MapSet.member?(scope, app), into: %{} do
      case tree do
        {:ok, _members} -> {app, "ok"}
        {:differs, detail} -> {app, "differs: " <> detail}
        {:unverified, why} -> {app, "unverified: " <> why}
      end
    end
  end

  defp r2_observed(facts) do
    results = [
      {facts.ctx.package, facts.package_r2} | Enum.map(facts.deps, &{elem(&1, 0), elem(&1, 1).r2})
    ]

    for {app, {:observe, list}} <- results,
        {:observe, kind, path} <- list,
        do: {kind, %{"owner" => owner_name(app), "path" => path}}
  end

  defp collect(observed, kind, cap) do
    observed
    |> Enum.filter(&(elem(&1, 0) == kind))
    |> Enum.map(&(&1 |> elem(1) |> public_item()))
    |> Enum.uniq()
    |> Enum.take(cap)
  end

  # What the build observed, without any value a read returned or a write
  # set: values go to `compile_env` and `compile_inputs` only, where a
  # private name is never recorded (`CompileInputs`). Nor a write's time,
  # which only orders it against reads: a `mix.exs` Mix evaluates again
  # makes the same write, which is one item.
  defp public_item(item) do
    item = Map.drop(item, ["returned", "value", "ts"])

    case item do
      %{"arg" => %{} = arg} -> %{item | "arg" => Map.delete(arg, "value")}
      _ -> item
    end
  end

  defp stats(%{report: report} = facts) do
    gaps =
      for {app, {:gap, module}} <- [
            {facts.ctx.package, facts.package_rebar} | dep_rebar(facts.deps)
          ],
          into: %{},
          do: {app, module}

    (report.stats || %{})
    |> Map.delete("kind")
    |> Map.merge(%{
      "windows" => length(report.windows),
      "sentinels" => length(report.sentinels),
      "events_read" => length(report.events),
      "children" => map_size(report.children),
      "rebar3_untraced_last" => gaps,
      "config_items" => length(facts.config.items),
      "config_dropped" => facts.config.dropped
    })
  end

  defp dep_rebar(deps), do: Enum.map(deps, fn {app, result} -> {app, result.rebar} end)

  defp owner_name(owner) when is_binary(owner), do: owner
  defp owner_name(owner) when is_atom(owner), do: Atom.to_string(owner)
  defp owner_name(owner), do: inspect(owner)
end
