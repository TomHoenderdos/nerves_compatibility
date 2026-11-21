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
  (`init:get_argument(home)`) anywhere, the plain arguments only as Mix's
  evaluation of a rebar3 dependency's `rebar.config.script` reads them
  (outside every window, the tracer's `rebar_script` flag). Then:

    * `hold/2` turns a passing verdict with any of them into a
      could-not-judge that carries what the pass would have said
      (`differential`), and what its compile read, so a caller that judges
      a trace alone never publishes it. A verdict `PrivRepro` holds as well
      is could-not-judge for good: the two are not settled together;
    * `settle/6` (`NccWorker.Portability.run/3`) first runs the script
      check when a read was of the plain arguments
      (`NccWorker.Portability.ScriptCheck`, one wall budget: in Mix VMs in
      the run's project, every scripted dependency's config reproduces the
      first build's `mix.rebar.config` and stays the same under the
      arguments its own literals and a Mix user's words name, but for
      `deps`); with no such dependency the read refuses;
    * then two variant builds, each the traced judge compile of the
      package's closure at a fresh build root of a random name (made
      exclusively, of the first build root's length where one fits, so a
      root in a literal reads as the first's, and still empty once the
      container is swept), after a gap of a little over a second, with its
      own trace dir, and with the varied values at either end of their
      domain: `low` with `+S 1:1`, a short HOME (`/tmp/h<4 hex>`, shorter
      than `/home/nerves`) and no extra plain arguments, `high` with
      `+S 240:240` (even, no power of two, divisible by 2, 3, 4, 5, 6, 8,
      10, 12, 15 and 16: parity, a power-of-two test and those
      divisibilities answer otherwise than for 1), a long HOME and the command words a Mix user's line can hold
      (`ScriptCheck.words/0`). Each must pass the judge, its own varied
      reads held as the first's were, and read nothing the first build did
      not (review B1: a compile input, config item, varied read, or env or
      config read, by what it names, never its value);
    * the package's app in each must be the first build's
      (`NccWorker.Portability.DifferentialBeams.compare_app/3`), and the
      first build must hash the same before the check and after the last
      variant.

  Then the verdict is the pass it held, with `observations["differential"]`
  (the reads, the variants, the scripts checked) and
  `trace_stats["differential"]` `"same"`. A different app, a variant that
  refused or read more, or a script whose config differs refuses: the
  reason is the first read's own refusal, then what differed, so it stays
  the host read it was. A variant that did not finish is transient
  could-not-judge (`"not_finished"`), anything else that could not be
  judged is `"not_judged"`. Variant dirs are removed either way. Never
  raises.

  No finite set of values proves a value cannot reach a build. Two
  variants at the ends of the domain catch a value copied into the output
  and every monotone use of it, and 1 against 240 catches parity, a
  power-of-two test and divisibility by 2, 3, 4, 5, 6, 8, 10, 12, 15 or 16.
  The residual: a test against one exact value (`n == 12`); a threshold
  above 240; a window that holds none of 1, 240 and the builder's count (`n
  in 9..64` on an 8-CPU builder); divisibility by a k that divides none of
  them (7, 9, 32 on an 8-CPU builder); a HOME of one exact value or prefix;
  and a condition that pairs one read's low end with another's high end,
  since the values move together (low, low; high, high). Two varied reads
  at one site (a helper or macro several callers reach) are one read, so a
  variant reaching that site from a new caller is not "read more" (review
  R2): the value is varied there anyway, so this is the pairing residual.
  """

  alias Compatibility.Portability, as: Reasons
  alias NccWorker.Portability.{Context, DifferentialBeams, ForeignPriv, ScriptCheck}
  alias NccWorker.Tracer

  @gap_ms 1_100
  @script_budget_ms 5 * 60 * 1000
  @min_script_budget_ms 10_000
  @hold_problem "varied host reads wait for differential builds"
  @together "varied host reads and own priv writes are not settled together"
  @max_reads 50
  # The reads a pass records in `observations["differential"]`.
  @max_recorded 20
  # 1 is the smallest count; 240 = 2^4 x 3 x 5 is even, no power of two, and
  # divisible by 2, 3, 4, 5, 6, 8, 10, 12, 15 and 16, so parity, a
  # power-of-two test and those divisibilities answer for 240 what they do
  # not for 1, whatever the builder's own count (review B4, N3). HOME: `low`
  # a short one under `/tmp` (shorter than the worker's `/home/nerves`),
  # `high` a long one.
  @variants [
    low: %{schedulers: 1, home: :short, plain_args: []},
    high: %{schedulers: 240, home: "home-of-a-much-longer-name", plain_args: ScriptCheck.words()}
  ]
  @short_root "/tmp"

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
      scripts: Map.get(varied, :scripts, []),
      observed: observed(verdict)
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

    with :ok <- scripts(held, project_dir, opts),
         :ok <- variants(held, project_dir, package, opts, run),
         :ok <- unchanged(before, digest.(held.build)) do
      pass(verdict, held)
    else
      {:refuse, why} -> refuse(verdict, held, why, nil)
      {:refuse, why, read} -> refuse(verdict, held, why, read)
      {:unjudged, why, transient?} -> could_not_judge(verdict, why, transient?)
    end
  end

  # The script check, when a read was of the plain arguments.
  defp scripts(held, project_dir, opts) do
    cond do
      not Enum.any?(held.reads, &(&1["read"] == "plain_args")) ->
        :ok

      held.scripts == [] ->
        {:refuse, nil, "plain_args"}

      true ->
        run_script_check(held, project_dir, opts, script_budget_ms(opts))
    end
  end

  # One wall budget for the whole script check (coordinator ruling 5): at
  # most `@script_budget_ms`, and a third of what is left of the run, so the
  # two variants keep the rest. Too little is transient: a later run has
  # the time.
  defp script_budget_ms(opts) do
    cap = Keyword.get(opts, :script_budget_ms, @script_budget_ms)

    case Keyword.get(opts, :run_started_at) do
      started when is_integer(started) ->
        left = Tracer.run_ceiling_sec() - (System.monotonic_time(:second) - started)
        min(cap, div(max(left, 0) * 1000, 3))

      _ ->
        cap
    end
  end

  defp run_script_check(_held, _project_dir, _opts, budget) when budget < @min_script_budget_ms,
    do: {:unjudged, "no time left for the script check", true}

  defp run_script_check(held, project_dir, opts, budget) do
    check = Keyword.get(opts, :script_check, &ScriptCheck.run/2)

    check_opts =
      Keyword.take(opts, [:env, :extra_env]) ++
        [project_dir: project_dir, build_root: first_root(held.build), budget_ms: budget]

    case check.(held.scripts, check_opts) do
      {:ok, _apps} ->
        :ok

      {:differs, app, why} ->
        {:refuse, "#{app}'s rebar.config.script gives another config: #{why}", "plain_args"}

      {:error, why} ->
        {:unjudged, "script check: #{why}", false}
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

  # `dir` (the variant's trace dir, log and long HOME) and `root` (its
  # build path) are fresh: random names (`differential_name:`, tests), made
  # exclusively, so a dir that exists already (a stale build of the package
  # someone placed there, which Mix would not compile again) is never used
  # nor removed; `root` is checked empty again once the container is swept
  # (`run/3`'s `fresh:`). They are the only dirs this function removes.
  # sobelow_skip ["Traversal.FileModule"]
  defp variant(held, project_dir, package, opts, run, name, values) do
    # The real path: Mix links a build dir's `include`, `priv` and `src` by
    # relative paths, which a link above the dir (macOS's `/var`) breaks.
    base = Keyword.get_lazy(opts, :differential_root, &System.tmp_dir!/0)
    base = Context.realpath(base) || base
    random = Keyword.get(opts, :differential_name, &random_name/0).()
    dir = Path.join(base, "ncc-dv#{random}#{name}")
    first_root = first_root(held.build)
    root = variant_root(base, "v#{random}#{name}", first_root)

    with :ok <- fresh(dir),
         :ok <- fresh(root, dir) do
      try do
        # So a clock read to the second differs between the builds.
        Process.sleep(Keyword.get(opts, :differential_gap_ms, @gap_ms))

        with_home(values.home, dir, opts, fn home ->
          built =
            run.(project_dir, package, variant_opts(opts, dir, root, home, values, held.trees))

          app = Path.join([root, "lib", Path.basename(held.build)])

          judged(built, name, fn ->
            with :ok <- ran_with(built, name, values.schedulers),
                 :ok <- read_no_more(held, built, name),
                 do: compared(held.build, app, {first_root, root}, name)
          end)
        end)
      after
        File.rm_rf(dir)
        File.rm_rf(root)
      end
    end
  end

  # 48 random bits, 12 hex digits: short enough for a variant root of the
  # worker's `/work/proj/_build/host` length under `/tmp`.
  defp random_name, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  # An empty dir made now, or an unjudged outcome; `made` is removed when
  # `path` cannot be made.
  # sobelow_skip ["Traversal.FileModule"]
  defp fresh(path, made \\ nil) do
    case File.mkdir(path) do
      :ok ->
        :ok

      {:error, why} ->
        if made, do: File.rm_rf(made)
        {:unjudged, "a variant dir is not fresh: #{Path.basename(path)} (#{inspect(why)})", false}
    end
  end

  # The variant's HOME, for `fun`: under `dir` for a long one; for `:short`,
  # a fresh `h<4 hex>` made exclusively under `/tmp`
  # (`differential_short_root:`, tests), another name tried when one
  # exists, and removed afterwards.
  # sobelow_skip ["Traversal.FileModule"]
  defp with_home(:short, _dir, opts, fun) do
    base = Keyword.get(opts, :differential_short_root, @short_root)

    home =
      Enum.find_value(1..8, fn _ ->
        home = Path.join(base, "h" <> Base.encode16(:crypto.strong_rand_bytes(2), case: :lower))
        if File.mkdir(home) == :ok, do: home
      end) || raise "no fresh short HOME under #{base}"

    try do
      fun.(home)
    after
      File.rm_rf(home)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp with_home(name, dir, _opts, fun) do
    home = Path.join(dir, name)
    File.mkdir_p!(home)
    fun.(home)
  end

  defp first_root(build), do: build |> Path.dirname() |> Path.dirname()

  # A root directly under `base`, named from `stem`, of exactly `first`'s
  # byte length when one fits (the worker's `/work/proj/_build/host` under
  # `/tmp` does), else `base/<stem>-build`, which no other path names.
  defp variant_root(base, stem, first) do
    pad = byte_size(first) - byte_size(base) - 1 - byte_size(stem)

    if pad >= 0,
      do: Path.join(base, stem <> String.duplicate("b", pad)),
      else: Path.join(base, stem <> "-build")
  end

  # The first build's opts with the variant's values: its build root (the
  # env's `MIX_BUILD_PATH`, and the extra env's when it names one), its
  # HOME (Mix's and Hex's homes kept where they were), its scheduler count
  # (`ERL_ZFLAGS`, which every VM the compile starts reads), its plain
  # arguments, its own trace dir and log, judge mode, the tree snapshot the
  # first build was judged on and neither a second build nor variants of
  # its own.
  defp variant_opts(opts, dir, root, home, values, trees) do
    env = Keyword.fetch!(opts, :env)

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
    |> Keyword.drop([:trees, :trace_dir, :log_file, :mode, :env, :extra_env, :plain_args, :fresh])
    |> Keyword.merge(
      env: env,
      extra_env: extra,
      mode: :judge,
      trees: trees,
      trace_dir: Path.join(dir, "trace"),
      log_file: Path.join(dir, "compile.log"),
      plain_args: values.plain_args,
      fresh: [root],
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

  # `ERL_ZFLAGS` comes last on the command line, so its `+S` wins over the
  # builder's `ERL_FLAGS` (measured); every VM the compile starts reads it.
  # No busy-waiting schedulers (review R3): with 240 of them on a few vCPUs a
  # spinning scheduler costs CPU and nothing else.
  defp zflags(env, n) do
    own = "+S #{n}:#{n} +sbwt none +sbwtdcpu none +sbwtdio none"
    flags = Enum.join(Enum.reject([value(env, "ERL_ZFLAGS"), own], &is_nil/1), " ")
    List.keystore(env, "ERL_ZFLAGS", 0, {"ERL_ZFLAGS", flags})
  end

  # Review R3: the count the variant's Mix VM ran with, as the tracer's start
  # line records it (`trace_stats["schedulers_online"]`), must be the one
  # asked for, else the variant varied nothing and the build refuses.
  defp ran_with(built, name, asked) do
    case get_in(built, [:observations, "trace_stats", "schedulers_online"]) do
      ^asked ->
        :ok

      other ->
        {:refuse,
         "a differential build (#{name}) ran with #{inspect(other)} schedulers, not #{asked}"}
    end
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

  # Review B1: a varied value may gate another read (a count above a
  # threshold reading an env var). A variant that read anything the first
  # build did not, whose value no input of the first build records, refuses:
  # a compile input or a config item (`compile_inputs`, `compile_env`) by
  # what it names, never its value (HOME read by name differs in value
  # alone), a varied read, or an env or config read its observations list.
  # Never added with the builder's value (coordinator ruling). A first
  # build whose observed list reached its cap cannot tell.
  defp read_no_more(held, built, name) do
    case variant_reads(built) do
      {:ok, theirs} -> read_no_more(more(held, theirs), name)
      :error -> {:unjudged, "differential build (#{name}) recorded no compile inputs", false}
    end
  end

  defp read_no_more({:extra, what}, name),
    do: {:refuse, "a differential build (#{name}) read what the first did not: #{what}"}

  defp read_no_more({:capped, kind}, name),
    do:
      {:unjudged, "#{kind} over their cap: a differential build (#{name}) cannot be compared",
       false}

  defp read_no_more(:ok, _name), do: :ok

  # What a variant read: its pass's inputs, or the ones its own hold kept.
  defp variant_reads(%{status: :pass} = built),
    do: reads_of(built[:compile_inputs], built[:compile_env], [], built)

  defp variant_reads(%{differential: held} = built) when is_map(held),
    do: reads_of(held[:compile_inputs], held[:compile_env], held[:reads] || [], built)

  defp variant_reads(_built), do: :error

  defp reads_of(inputs, env, reads, built) when is_list(inputs) and is_list(env) do
    {:ok, %{inputs: inputs, env: env, reads: reads, observed: observed(built)}}
  end

  defp reads_of(_inputs, _env, _reads, _built), do: :error

  @value_keys ["value", "seen", "matched", :value]
  @env_cap 50
  @config_cap 200

  # The env and config reads a verdict's observations list, by what they
  # name, and whether a list reached its cap (`NccWorker.Portability`'s).
  defp observed(verdict) do
    obs = Map.get(verdict, :observations) || %{}
    env = list(obs["env_reads"])
    config = list(obs["config_reads"])

    %{
      env: MapSet.new(env, &{&1["name"], &1["all"]}),
      config: MapSet.new(config, &config_read/1),
      env_capped: length(env) >= @env_cap,
      config_capped: length(config) >= @config_cap
    }
  end

  defp list(items) when is_list(items), do: Enum.filter(items, &is_map/1)
  defp list(_items), do: []

  defp config_read(item) do
    arg = if is_map(item["arg"]), do: item["arg"], else: %{}
    Map.take(arg, ["app", "key", "all"])
  end

  # The first thing a variant read that the first build did not, in this
  # order: a compile input, a config item, a varied read, an env read, a
  # config read (the last two `:capped` when the first's list was full).
  defp more(held, theirs) do
    Enum.find_value(
      [
        fn -> extra_input(held, theirs) end,
        fn -> extra_config_item(held, theirs) end,
        fn -> extra_varied(held, theirs) end,
        fn ->
          extra_observed(
            theirs.observed.env,
            held.observed.env,
            held.observed.env_capped,
            "env reads",
            &"env read #{elem(&1, 0) || "(all)"}"
          )
        end,
        fn ->
          extra_observed(
            theirs.observed.config,
            held.observed.config,
            held.observed.config_capped,
            "config reads",
            &"config read #{&1["app"]} #{&1["key"]}"
          )
        end
      ],
      :ok,
      & &1.()
    )
  end

  defp extra_input(held, theirs) do
    first = MapSet.new(held.compile_inputs || [], &identity/1)
    item = Enum.find(theirs.inputs, &(identity(&1) not in first))
    if item, do: {:extra, describe_input(item)}
  end

  defp extra_config_item(held, theirs) do
    first = MapSet.new(held.compile_env || [], &identity/1)

    case Enum.find(theirs.env, &(identity(&1) not in first)) do
      nil ->
        nil

      item ->
        {:extra, "config #{item[:app] || item["app"]} #{inspect(item[:path] || item["path"])}"}
    end
  end

  defp extra_varied(held, theirs) do
    first = MapSet.new(held.reads, &read_identity/1)
    read = Enum.find(theirs.reads, &(read_identity(&1) not in first))
    if read, do: {:extra, "#{read["read"]} in #{read["owner"]}"}
  end

  defp extra_observed(theirs, first, capped?, kind, describe) do
    case Enum.find(theirs, &(&1 not in first)) do
      nil -> nil
      _extra when capped? -> {:capped, kind}
      extra -> {:extra, describe.(extra)}
    end
  end

  defp identity(item) when is_map(item), do: Map.drop(item, @value_keys)
  defp identity(item), do: item

  # A read by its site, never its module: a module body's is
  # `elixir_compiler_<n>`, numbered in the order the parallel compiler ran
  # the bodies, which another scheduler count changes.
  defp read_identity(read) when is_map(read),
    do: Map.take(read, ~w(owner read mfa arg file line))

  defp read_identity(read), do: read

  defp describe_input(%{"kind" => "env", "name" => name}), do: "env #{name}"

  defp describe_input(%{"kind" => "config_order", "app" => app, "path" => path}),
    do: "config #{app} #{inspect(path)}"

  defp describe_input(%{"kind" => kind}), do: "#{kind} input"
  defp describe_input(_item), do: "an input"

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
      "reads" => Enum.take(held.reads, @max_recorded),
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

  # The first read's own refusal (of `kind` when the script check found
  # it), then what the differential found.
  defp refuse(verdict, held, why, kind) do
    first = Enum.find(held.reads, hd(held.reads), &(kind == nil or &1["read"] == kind))
    reason = if why, do: first["refusal"] <> "; " <> why, else: first["refusal"]

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
