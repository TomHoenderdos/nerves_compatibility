defmodule NccWorker.Portability.Differential do
  @moduledoc """
  Differential builds (the job's `differential` flag,
  `NCC_INPUT.judge.differential`): a compile-time read of a value the trace
  cannot follow, but the worker can change, is settled by building the
  package's closure again with that value changed and comparing what the
  package would publish (`docs/superpowers` S2 design note).

  `NccWorker.Portability.Events` observes those reads as `varied_reads`
  instead of refusing them, carrying the refusal each would be: the
  scheduler count (`system_info(schedulers_online | schedulers)`) and HOME
  (`init:get_argument(home)`) anywhere, the plain arguments only outside
  every window (Mix evaluating a rebar3 dependency's `rebar.config.script`).
  Then:

    * `hold/2` turns a passing verdict with any of them into a
      could-not-judge that carries what the pass would have said
      (`differential`), so a caller that judges a trace alone never
      publishes it. A verdict `PrivRepro` holds as well is could-not-judge
      for good: the two are not settled together;
    * `settle/6` (`NccWorker.Portability.run/3`) first runs the script
      check when a read was of the plain arguments
      (`NccWorker.Portability.ScriptCheck`: every scripted rebar3
      dependency's config is the same under the arguments its own literals
      name, but for `deps`); with no such dependency the read refuses;
    * then two variant builds, each the traced judge compile of the
      package's closure at a build root of its own (of the first build
      root's length where one fits, so a root in a literal reads as the
      first's), after a gap of a little over a second, with its own trace
      dir, and with the varied values at either end of their domain: `low`
      with `+S 1:1`, a short HOME and no extra plain arguments, `high` with
      `+S 256:256`, a long HOME and the Mix and rebar3 command words a Mix
      user's command line can hold (`@words`). Each must pass the judge, its
      own varied reads held as the first's were;
    * the package's app in each must be the first build's
      (`NccWorker.Portability.DifferentialBeams.compare_app/3`), and the
      first build must hash the same before the check and after the last
      variant.

  Then the verdict is the pass it held, with `observations["differential"]`
  (the reads, the variants, the scripts checked) and
  `trace_stats["differential"]` `"same"`. A different app, a variant that
  refused or a script whose config differs refuses: the reason is the first
  read's own refusal, then what differed, so it stays the host read it was.
  A variant that did not finish is transient could-not-judge
  (`"not_finished"`), anything else that could not be judged is
  `"not_judged"`. Variant dirs are removed either way. Never raises.

  No finite set of values proves a value cannot reach a build: a test
  against one value (`n == 12`) differs only there. Two variants at the
  ends of the domain catch a value copied into the output and every
  monotone use of it, which is what this route is limited to.
  """

  alias Compatibility.Portability, as: Reasons
  alias NccWorker.Portability.{DifferentialBeams, ForeignPriv, ScriptCheck}

  @gap_ms 1_100
  @hold_problem "varied host reads wait for differential builds"
  @together "varied host reads and own priv writes are not settled together"
  @max_reads 50
  # Mix task words a Mix user's command line holds that rebar3 scripts test
  # their arguments against, as rebar3 command names.
  @words ~w(compile test deps.compile deps.get release docs run xref dialyzer eunit ct
            escript.build phx.server prod --force)
  @variants [
    low: %{schedulers: 1, home: "h", plain_args: []},
    high: %{schedulers: 256, home: "home-of-a-much-longer-name", plain_args: @words}
  ]

  @doc "The problem a held verdict carries until `settle/6` decides it."
  @spec hold_problem() :: String.t()
  def hold_problem, do: @hold_problem

  @doc """
  Holds a passing `verdict` that has varied reads (see the moduledoc).
  `varied` holds the reads (`reads:`), the package's build dir (`build:`),
  the tree snapshot it was judged on (`trees:`) and the scripted rebar3
  dependencies' verified tarballs (`scripts:`, `[{app, bytes}]`).
  """
  @spec hold(map(), map()) :: map()
  def hold(verdict, %{reads: []}), do: verdict

  def hold(%{priv_repro: held} = verdict, %{reads: [_ | _]}) when is_map(held) do
    verdict
    |> Map.delete(:priv_repro)
    |> Map.merge(%{status: :skip, reason: Reasons.could_not_judge(), compile_env: nil})
    |> Map.put(:compile_inputs, nil)
    |> update_problems(&(List.delete(&1, priv_hold()) ++ [@together]))
    |> put_stat("not_judged")
  end

  def hold(%{status: :pass} = verdict, %{reads: [_ | _]} = varied) do
    held = %{
      compile_env: verdict.compile_env,
      compile_inputs: verdict.compile_inputs,
      built_priv: Map.get(verdict, :built_priv),
      foreign_priv: Map.get(verdict, :foreign_priv),
      foreign_priv_rule: Map.get(verdict, :foreign_priv_rule),
      reads: Enum.take(varied.reads, @max_reads),
      build: varied.build,
      trees: varied.trees,
      scripts: Map.get(varied, :scripts, [])
    }

    %{verdict | status: :skip, reason: Reasons.could_not_judge(), compile_env: nil}
    |> Map.put(:compile_inputs, nil)
    |> Map.put(:differential, held)
    |> ForeignPriv.unpass()
    |> update_problems(&(&1 ++ [@hold_problem]))
  end

  def hold(verdict, _varied), do: verdict

  defp priv_hold, do: NccWorker.Portability.PrivRepro.hold_problem()

  @doc """
  Decides a verdict `hold/2` held (see the moduledoc); any other verdict,
  and every verdict of a variant build itself (`differential: :variant`) or
  of `PrivRepro`'s second build (`priv_repro: false`), is returned as it
  is. `run` is `NccWorker.Portability.run/3`; `digest` hashes a build dir.
  `opts` are `run/3`'s, plus `differential_gap_ms:`, `differential_root:`
  and `script_check:` (tests).
  """
  @spec settle(map(), String.t(), String.t(), keyword(), fun(), fun()) :: map()
  def settle(%{differential: held} = verdict, project_dir, package, opts, run, digest)
      when is_map(held) do
    if Keyword.get(opts, :differential) == true and Keyword.get(opts, :priv_repro) != false,
      do: decide(verdict, held, project_dir, package, opts, run, digest),
      else: verdict
  rescue
    e -> could_not_judge(verdict, "differential build failed: " <> Exception.message(e), false)
  end

  def settle(verdict, _project_dir, _package, _opts, _run, _digest), do: verdict

  defp decide(verdict, held, project_dir, package, opts, run, digest) do
    before = digest.(held.build)

    with :ok <- scripts(held, opts),
         :ok <- variants(held, project_dir, package, opts, run),
         :ok <- unchanged(before, digest.(held.build)) do
      pass(verdict, held)
    else
      {:refuse, why} -> refuse(verdict, held, why)
      {:unjudged, why, transient?} -> could_not_judge(verdict, why, transient?)
    end
  end

  # The script check, when a read was of the plain arguments.
  defp scripts(held, opts) do
    cond do
      not Enum.any?(held.reads, &(&1["read"] == "plain_args")) ->
        :ok

      held.scripts == [] ->
        {:refuse, nil}

      true ->
        check = Keyword.get(opts, :script_check, &ScriptCheck.run/2)

        case check.(held.scripts, Keyword.take(opts, [:env, :extra_env])) do
          {:ok, _apps} ->
            :ok

          {:differs, app, why} ->
            {:refuse, "#{app}'s rebar.config.script gives another config: #{why}"}

          {:error, why} ->
            {:unjudged, "script check: #{why}", false}
        end
    end
  end

  defp variants(held, project_dir, package, opts, run) do
    Enum.reduce_while(@variants, :ok, fn {name, values}, :ok ->
      case variant(held, project_dir, package, opts, run, name, values) do
        :ok -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end

  # `dir` is a fresh directory this function names under the temp dir, and
  # the only one it removes.
  # sobelow_skip ["Traversal.FileModule"]
  defp variant(held, project_dir, package, opts, run, name, values) do
    base = Keyword.get_lazy(opts, :differential_root, &System.tmp_dir!/0)
    dir = Path.join(base, "ncc-dv#{System.unique_integer([:positive])}#{name}")
    first_root = first_root(held.build)
    root = variant_root(dir, first_root)

    try do
      # So a clock read to the second differs between the builds.
      Process.sleep(Keyword.get(opts, :differential_gap_ms, @gap_ms))
      File.mkdir_p!(Path.join(dir, values.home))
      built = run.(project_dir, package, variant_opts(opts, dir, root, values, held.trees))
      app = Path.join([root, "lib", Path.basename(held.build)])
      judged(built, name, fn -> compared(held.build, app, {first_root, root}, name) end)
    after
      File.rm_rf(dir)
    end
  end

  defp first_root(build), do: build |> Path.dirname() |> Path.dirname()

  # A root under `dir` of exactly `first`'s byte length when one fits,
  # else `dir/build`.
  defp variant_root(dir, first) do
    pad = byte_size(first) - byte_size(dir) - 1
    if pad >= 1, do: Path.join(dir, String.duplicate("b", pad)), else: Path.join(dir, "build")
  end

  # The first build's opts with the variant's values: its build root (the
  # env's `MIX_BUILD_PATH`, and the extra env's when it names one), its
  # HOME (Mix's and Hex's homes kept where they were), its scheduler count
  # (`ERL_ZFLAGS`, which every VM the compile starts reads), its plain
  # arguments, its own trace dir and log, judge mode, the tree snapshot the
  # first build was judged on and neither a second build nor variants of
  # its own.
  defp variant_opts(opts, dir, root, values, trees) do
    env = Keyword.fetch!(opts, :env)
    home = Path.join(dir, values.home)

    env =
      env
      |> keep_home("MIX_HOME", ".mix")
      |> keep_home("HEX_HOME", ".hex")
      |> List.keystore("MIX_BUILD_PATH", 0, {"MIX_BUILD_PATH", root})
      |> List.keystore("HOME", 0, {"HOME", home})
      |> zflags(values.schedulers)

    extra =
      opts
      |> Keyword.get(:extra_env, [])
      |> then(fn extra ->
        if List.keymember?(extra, "MIX_BUILD_PATH", 0),
          do: List.keystore(extra, "MIX_BUILD_PATH", 0, {"MIX_BUILD_PATH", root}),
          else: extra
      end)

    opts
    |> Keyword.drop([:trees, :trace_dir, :log_file, :mode, :env, :extra_env, :plain_args])
    |> Keyword.merge(
      env: env,
      extra_env: extra,
      mode: :judge,
      trees: trees,
      trace_dir: Path.join(dir, "trace"),
      log_file: Path.join(dir, "compile.log"),
      plain_args: values.plain_args,
      priv_repro: false,
      differential: :variant
    )
  end

  # Where Mix or Hex lives when the env names no home of its own: under the
  # first build's HOME, which the variant's HOME would move.
  defp keep_home(env, name, dir) do
    cond do
      value(env, name) != nil -> env
      System.get_env(name) not in [nil, ""] -> env
      true -> keep_under_home(env, name, dir)
    end
  end

  defp keep_under_home(env, name, dir) do
    case value(env, "HOME") || System.get_env("HOME") do
      home when is_binary(home) and home != "" ->
        List.keystore(env, name, 0, {name, Path.join(home, dir)})

      _ ->
        env
    end
  end

  defp zflags(env, n) do
    flags = Enum.join(Enum.reject([value(env, "ERL_ZFLAGS"), "+S #{n}:#{n}"], &is_nil/1), " ")
    List.keystore(env, "ERL_ZFLAGS", 0, {"ERL_ZFLAGS", flags})
  end

  defp value(env, name) do
    case List.keyfind(env, name, 0) do
      {_, value} when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp judged(built, name, compare) do
    cond do
      get_in(built, [:observations, "trace_stats", "judge_compile"]) != "finished" ->
        {:unjudged, "differential build did not finish (#{name}): #{problem(built)}", true}

      passed?(built) ->
        compare.()

      Reasons.could_not_judge?(built[:reason]) ->
        {:unjudged, "differential build (#{name}): #{problem(built)}", false}

      true ->
        {:refuse, "a differential build refused (#{built[:reason]})"}
    end
  end

  # Passed, or held for differential builds of its own, which it does not
  # get: then its only problem is the hold.
  defp passed?(%{status: :pass}), do: true

  defp passed?(%{differential: held} = built) when is_map(held),
    do: (get_in(built, [:observations, "problems"]) || []) == [@hold_problem]

  defp passed?(_built), do: false

  defp compared(first, app, roots, name) do
    case DifferentialBeams.compare_app(first, app, roots) do
      :ok -> :ok
      {:differs, why} -> {:refuse, "a differential build differs: #{why}"}
      {:error, why} -> {:unjudged, "differential build (#{name}) not compared: #{why}", false}
    end
  end

  defp problem(built) do
    stats = get_in(built, [:observations, "trace_stats"]) || %{}
    problems = get_in(built, [:observations, "problems"]) || []
    Enum.join(Enum.filter([stats["tracer_error"] | problems], &is_binary/1), "; ")
  end

  defp unchanged({:ok, digest}, {:ok, digest}), do: :ok

  defp unchanged(_before, _after),
    do: {:unjudged, "the first build changed while the differential builds ran", false}

  defp pass(verdict, held) do
    record = %{
      "reads" => held.reads,
      "variants" => Enum.map(@variants, fn {name, _} -> Atom.to_string(name) end),
      "scripts" => for({app, _} <- held.scripts, do: app)
    }

    %{verdict | status: :pass, reason: nil, compile_env: held.compile_env}
    |> Map.put(:compile_inputs, held.compile_inputs)
    |> put_built_priv(held)
    |> restore_foreign(held)
    |> Map.delete(:differential)
    |> update_problems(&List.delete(&1, @hold_problem))
    |> Map.update!(:observations, &Map.put(&1, "differential", record))
    |> put_stat("same")
  end

  defp put_built_priv(verdict, %{built_priv: nil}), do: verdict
  defp put_built_priv(verdict, %{built_priv: built}), do: Map.put(verdict, :built_priv, built)

  defp restore_foreign(verdict, held) do
    if Map.has_key?(verdict, :foreign_priv),
      do: Map.merge(verdict, Map.take(held, [:foreign_priv, :foreign_priv_rule])),
      else: verdict
  end

  # The first read's own refusal, then what the differential found.
  defp refuse(verdict, held, why) do
    read = hd(held.reads)["refusal"]
    reason = if why, do: read <> "; " <> why, else: read

    %{verdict | status: :skip, reason: reason}
    |> Map.delete(:differential)
    |> update_problems(&List.delete(&1, @hold_problem))
    |> put_stat("differs")
  end

  defp could_not_judge(verdict, why, transient?) do
    %{verdict | status: :skip, reason: Reasons.could_not_judge()}
    |> Map.delete(:differential)
    |> update_problems(&(List.delete(&1, @hold_problem) ++ [why]))
    |> put_stat(if(transient?, do: "not_finished", else: "not_judged"))
  end

  defp update_problems(%{observations: obs} = verdict, fun),
    do: %{verdict | observations: Map.put(obs, "problems", fun.(obs["problems"] || []))}

  defp update_problems(verdict, fun),
    do: update_problems(Map.put(verdict, :observations, %{}), fun)

  defp put_stat(%{observations: obs} = verdict, outcome) do
    stats = Map.put(obs["trace_stats"] || %{}, "differential", outcome)
    %{verdict | observations: Map.put(obs, "trace_stats", stats)}
  end
end
