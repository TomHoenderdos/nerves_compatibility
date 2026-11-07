defmodule NccWorker.Portability do
  @moduledoc """
  The compile-time half of the precompiled portability verdict (spec R1-R4),
  in phase P1: it only adds refusals. `run/3` runs the traced judge compile
  (`NccWorker.Tracer`) and `judge/5` reads its `NccWorker.Tracer.Report`;
  callers AND the verdict with rule 1 (`NccWorker.BuildSelection.portable?/4`),
  which stays unchanged.

  Order, first failure wins:

    1. an incomplete trace: any `Report` problem, a missing or failed start,
       closure, stats or end, `unjudged > 0`, or any event `Events.decide/4`
       could not judge, wherever it is attributed;
    2. a refusal outside every window (it counts against everything);
    3. a refusal in the package's window (R1, R4 through `Events`);
    4. the package's window broken (missing, lowered depth, failed
       integrity, no sentinel);
    5. R2 on the package's `ebin` (`BuildRoot`);
    6. the rebar3 rules on the package (`Rebar`);
    7. host taint of a closure dependency (R3), the first in compile order:
       its window broken or without a sentinel, a refusal in its window, R2,
       the rebar3 static rules or rebar3 trace coverage.

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

  Only the package's closure counts (controller ruling M7): events, child
  traces and refusals of an app outside `Context.closure_of/2` of the
  package are dropped, and so is a stray child trace (`unknown`, an
  elixir_make `erl -eval` sub-VM: the spawn is itself traced in the Mix VM).
  An unjudged event is never dropped. Events in a native-pattern quiet
  interval are the tracer's own loading of a native dependency: dropped too,
  except an unjudged one or an integrity refusal, which count as outside
  every window.

  Never raises: anything unexpected is "portability could not be judged",
  which publishes nothing and changes no status.
  """

  alias Compatibility.Portability, as: Reasons
  alias NccWorker.{BuildCache, DepsLock}
  alias NccWorker.Portability.{BuildRoot, Context, Events, MappedLibs, Rebar}
  alias NccWorker.Tracer
  alias NccWorker.Tracer.Report

  @type verdict :: %{status: :pass | :skip, reason: String.t() | nil, observations: map()}

  @default_timeout_ms 30 * 60 * 1000
  @caps %{
    "config_reads" => 200,
    "elixir_version" => 50,
    "native_calls" => 50,
    "mix_exs_allowed" => 50,
    "build_root_source_path" => 50
  }
  @max_refusals 100
  @max_problems 20
  @integrity "compile-time tracing or system flag: "

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
  Runs the traced judge compile of `package` in `project_dir` and judges it.
  Options:

    * `env:` (required), the host compile's env;
    * `releases:` (required), `lock_snapshot/1` taken before any compile;
      without it nothing runs and the verdict is could-not-judge;
    * `hex_home:`, the run's verified Hex cache (default: `HEX_HOME` in
      `env`; without either no dependency source file is readable);
    * `run_started_at:`, the run's start in monotonic seconds, which bounds
      the compile by what is left of the run (`NccWorker.Tracer`);
    * `trace_dir:` (default `<project_dir>/../trace`), `log_file:`,
      `timeout_ms:`, `extra_env:`, `reap:`, `cmd:` (tests).

  Never raises. Adds `observations["trace_stats"]["wall_ms"]` and
  `observations["trace_stats"]["judge_compile"]`: `"finished"` when the
  traced compile exited 0, `"not_run"` when it never started for want of
  `releases:` (the build is the host compile's, untouched), and
  `"not_finished"` otherwise (a crash, a timeout, a non-zero exit, an
  exhausted budget, the judge itself raising): the build under `_build` may
  then be half-written, and callers must not judge it.
  """
  @spec run(String.t(), String.t(), keyword()) :: verdict()
  def run(project_dir, package, opts) do
    started = System.monotonic_time(:millisecond)

    project_dir
    |> guarded_run(package, opts)
    |> put_stat("wall_ms", System.monotonic_time(:millisecond) - started)
  end

  defp guarded_run(project_dir, package, opts) do
    case releases(opts) do
      {:ok, releases} ->
        traced_run(project_dir, package, opts, releases)

      :error ->
        "no mix.lock snapshot taken before the compile"
        |> not_judged()
        |> put_stat("judge_compile", "not_run")
    end
  rescue
    e -> unfinished("judge failed: " <> Exception.message(e))
  catch
    kind, reason -> unfinished("judge failed: #{kind} #{inspect(reason, limit: 20)}")
  end

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
    native = native_deps(project_dir)
    traced = Tracer.run(project_dir, [package], tracer_opts(opts, env, trace_dir, native))
    ctx_opts = [releases: releases, hex_home: hex_home(opts, env)]

    project_dir
    |> verdict(package, traced, trace_dir, native, ctx_opts)
    |> put_stat("judge_compile", judge_compile(traced))
  end

  defp judge_compile({:ok, 0}), do: "finished"
  defp judge_compile(_traced), do: "not_finished"

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
      run_started_at: Keyword.get(opts, :run_started_at)
    ] ++ Keyword.take(opts, [:reap, :cmd])
  end

  defp verdict(project_dir, package, {:ok, 0}, trace_dir, native, ctx_opts),
    do: judge(project_dir, package, Report.read(trace_dir), native, ctx_opts)

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
  this process's `HEX_HOME` now, which only tests should rely on. Never
  raises.
  """
  @spec judge(String.t(), String.t(), Report.t(), [String.t()], keyword()) :: verdict()
  def judge(project_dir, package, report, native, opts \\ [])

  def judge(project_dir, package, %Report{} = report, native, opts) do
    project_dir |> facts(package, report, native, opts) |> verdict_of()
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
    package_r2 = build_root(ctx, ctx.package)
    deps = dep_results(ctx, report, decided)

    %{
      ctx: ctx,
      report: report,
      decided: decided,
      trace_problems: trace_problems(report, ctx) ++ unjudged ++ libs.problems,
      libs: libs,
      package_window: window_problem(report, ctx.package),
      package_r2: package_r2,
      package_rebar: rebar(ctx, report, ctx.package),
      deps: deps
    }
  end

  # Every event as `{owner, decision}`: the Mix VM's by `Context.owner/2`,
  # a closure dependency's child VM's by its app (child clocks do not align
  # with the Mix VM's windows). One `MixExsSlice.analyse/1` per `mix.exs`.
  defp decide_all(report, ctx, scope) do
    main = for event <- report.events, do: {Context.owner(ctx, event), event}

    children =
      for {app, child} <- Enum.sort(report.children),
          Context.dep?(ctx, app),
          event <- child.events,
          do: {app, event}

    owned = main ++ children
    slices = Events.mix_exs_slices(ctx, Enum.reject(owned, &match?({:quiet, _}, &1)))

    for {owner, event} <- owned,
        decision = Events.decide(event, ctx, owner, slices),
        kept = keep(owner, decision, scope),
        kept != nil,
        do: kept
  end

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
      nil -> {:error, "no ebin for #{inspect(app)}"}
      ebin -> ebin |> BuildRoot.check(Context.roots(ctx), &Context.closure_file?(ctx, &1)) |> r2()
    end
  end

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
      dest -> rebar3(static_rebar(ctx, app, dest), ctx, report, app)
    end
  end

  defp rebar3({:refuse, _} = refusal, _ctx, _report, _app), do: refusal
  defp rebar3({:unjudged, _} = unjudged, _ctx, _report, _app), do: unjudged

  defp rebar3(:ok, ctx, report, app),
    do: Rebar.coverage(Context.ebin(ctx, app), Map.get(report.children, app))

  # The static rules on the app's rebar.config from its verified Hex
  # tarball and its rebar3 parents' (their overrides), then the
  # mix.rebar.config rebar3 read. A script on disk refuses too.
  defp static_rebar(ctx, app, dest) do
    parents = Context.rebar3_parents(ctx, app)

    with {:ok, own} <- Rebar.tarball_sources(Context.tarball(ctx, app)),
         {:ok, inherited} <- parent_sources(ctx, parents) do
      own = %{own | script?: own.script? or disk_script?(dest)}
      Rebar.check_sources(own, inherited, mix_rebar_config(ctx, app))
    end
  end

  defp parent_sources(ctx, parents) do
    Enum.reduce_while(parents, {:ok, []}, fn parent, {:ok, acc} ->
      case Rebar.tarball_sources(Context.tarball(ctx, parent)) do
        {:ok, sources} -> {:cont, {:ok, acc ++ [sources]}}
        {:unjudged, why} -> {:halt, {:unjudged, "rebar3 parent #{parent}: #{why}"}}
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
    %{status: status, reason: reason, observations: observations(facts, problems)}
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
      "nif_check" => if(facts.libs.waived, do: "waived", else: "ok"),
      "problems" => problems |> Enum.uniq() |> Enum.take(@max_problems)
    })
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
    |> Enum.map(&elem(&1, 1))
    |> Enum.uniq()
    |> Enum.take(cap)
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
      "rebar3_untraced_last" => gaps
    })
  end

  defp dep_rebar(deps), do: Enum.map(deps, fn {app, result} -> {app, result.rebar} end)

  defp owner_name(owner) when is_binary(owner), do: owner
  defp owner_name(owner) when is_atom(owner), do: Atom.to_string(owner)
  defp owner_name(owner), do: inspect(owner)
end
