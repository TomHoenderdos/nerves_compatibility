defmodule NccWorker.Tracer.FixturesDifferentialTest do
  # Differential builds on real traced compiles
  # (`NccWorker.Portability.run/3` with `differential: true`,
  # `NccWorker.Portability.Differential`): a scheduler count or HOME read
  # whose value reaches no beam publishes after two variant builds, one that
  # reaches a beam refuses, at either end of the count's domain; a
  # dependent of a package whose beam holds the count publishes when its
  # own beams do not; and a rebar3 dependency's `rebar.config.script`
  # reading the plain arguments publishes only when no argument its own
  # literals or a Mix user's command words name changes its config but for
  # `deps`. Starts real `elixir` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.{Portability, TracerFixtures}

  import NccWorker.TracerFixtures, only: [lib: 2, lib: 3]

  @moduletag timeout: 1_200_000

  @deps %{
    # codepagex's shape: the count sizes a compile-time stream, whose
    # ordered results are baked.
    "fx_dv_pool" =>
      lib("fx_dv_pool", """
      defmodule FxDvPool do
        @l [1, 2, 3]
           |> Task.async_stream(&(&1 * 2), max_concurrency: System.schedulers_online())
           |> Enum.map(fn {:ok, v} -> v end)
        def l, do: @l
      end
      """),
    # ex_cldr's shape: the count baked into a function.
    "fx_dv_baked" =>
      lib("fx_dv_baked", """
      defmodule FxDvBaked do
        @max System.schedulers_online() * 2
        def max, do: @max
      end
      """),
    # Only a threshold of it baked: 1 is below it, the builder above.
    "fx_dv_many" =>
      lib("fx_dv_many", """
      defmodule FxDvMany do
        @many System.schedulers_online() > 1
        def many?, do: @many
      end
      """),
    # A power-of-two count picks a bitmask, any other a rem/2 (review B4):
    # built on 8 schedulers, as on an 8-CPU builder.
    # Review N3: parity and divisibility of the count, which 1 and a prime
    # share. Each built on a builder count whose answer is 1's.
    "fx_dv_even" =>
      lib(
        "fx_dv_even",
        "defmodule FxDvEven do\n  @even rem(System.schedulers_online(), 2) == 0\n  def even?, do: @even\nend\n"
      ),
    "fx_dv_by4" =>
      lib(
        "fx_dv_by4",
        "defmodule FxDvBy4 do\n  @by4 rem(System.schedulers_online(), 4) == 0\n  def by4?, do: @by4\nend\n"
      ),
    "fx_dv_by3" =>
      lib(
        "fx_dv_by3",
        "defmodule FxDvBy3 do\n  @by3 rem(System.schedulers_online(), 3) == 0\n  def by3?, do: @by3\nend\n"
      ),
    "fx_dv_pow2" =>
      lib("fx_dv_pow2", """
      defmodule FxDvPow2 do
        n = System.schedulers_online()
        @mask Bitwise.band(n, n - 1) == 0
        def strategy, do: if(@mask, do: :band, else: :rem)
      end
      """),
    # Review B1: the count gates an env read, only above 64 schedulers.
    "fx_dv_gate" =>
      lib("fx_dv_gate", """
      defmodule FxDvGate do
        @v if System.schedulers_online() > 64, do: System.get_env("FX_GATE"), else: nil
        def v, do: @v
      end
      """),
    "fx_dv_home" =>
      lib("fx_dv_home", """
      defmodule FxDvHome do
        _ = :init.get_argument(:home)
        def x, do: 1
      end
      """),
    # Its length only: HOME itself is one of R2's roots, which refuse first.
    "fx_dv_home_baked" =>
      lib("fx_dv_home_baked", """
      defmodule FxDvHomeBaked do
        {:ok, [[home]]} = :init.get_argument(:home)
        @home length(home)
        def home, do: @home
      end
      """),
    # ex_cldr_numbers' shape: a dependent of a beam that holds the count,
    # calling it at runtime only.
    "fx_dv_user" =>
      lib("fx_dv_user", "defmodule FxDvUser do\n  def max, do: FxDvBaked.max()\nend\n", %{
        deps: ["fx_dv_baked"]
      })
  }

  # gproc's shape: `"doc"` among the plain arguments changes only `deps`.
  @doc_script """
  Args = case init:get_plain_arguments() of
      [_|A] -> A;
      _ -> []
  end.
  case lists:member("doc", Args) of
      false -> CONFIG;
      true -> lists:keystore(deps, 1, CONFIG,
                  {deps, [{edown, ".*", {git, "git://github.com/uwiger/edown.git", "HEAD"}}]})
  end.
  """

  # `mix test` puts "test" among them: the config gains a define.
  @test_script """
  case lists:member("test", init:get_plain_arguments()) of
      true -> [{erl_opts, [{d, 'TEST'}]} | CONFIG];
      false -> CONFIG
  end.
  """

  # Review N1: the shape of a Mix user's plain arguments, which no builder
  # VM has: `mix compile` gives `[<install>/bin/mix, "compile"]`.
  @position_script """
  case init:get_plain_arguments() of
      [_, "compile" | _] -> [{erl_opts, [{d, 'MIXC'}]} | CONFIG];
      _ -> CONFIG
  end.
  """

  # Review N2: an effect on the Mix VM under a literal (`mix test --cover`).
  @cover_script """
  case lists:member("--cover", init:get_plain_arguments()) of
      true -> 'Elixir.Code':put_compiler_option(docs, false);
      false -> ok
  end,
  CONFIG.
  """

  # gproc 1.2.0's script files, vendored unchanged from its Hex tarball: a
  # reviewed release (`ReviewedScripts`).
  @gproc Path.join(__DIR__, "../../fixtures/rebar/gproc-1.2.0")
  defp gproc_files do
    for path <- ~w(rebar.config.script priv/check_edown.script priv/remove_deps.script
                   src/gproc.app.src.script),
        into: %{},
        do: {path, File.read!(Path.join(@gproc, path))}
  end

  setup_all do
    # The real path: on macOS `/var` is a link to `/private/var`, and Mix
    # links a build's `priv` by a path relative to the one it was given, so
    # a first build under `/var/...` gets a dangling `priv` link (a variant
    # under the real temp dir would not).
    root =
      Path.join(
        NccWorker.Portability.Context.realpath(System.tmp_dir!()),
        "ncc-fixtures-differential-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    proj = TracerFixtures.project(Path.join(root, "p"), Map.keys(@deps), @deps)

    # One package at a time: each run rebuilds the closure into _build/host.
    verdicts =
      for app <- ~w(fx_dv_pool fx_dv_baked fx_dv_many fx_dv_home fx_dv_home_baked fx_dv_user),
          into: %{} do
        {app, run(root, proj, app, [])}
      end

    off = run(root, proj, "fx_dv_pool", differential: false)
    pow2 = run(root, proj, "fx_dv_pow2", env: [{"ERL_ZFLAGS", "+S 8:8"}])

    divisors =
      for {app, s} <- [{"fx_dv_even", 3}, {"fx_dv_by4", 6}, {"fx_dv_by3", 8}], into: %{} do
        {app, run(root, proj, app, env: [{"ERL_ZFLAGS", "+S #{s}:#{s}"}])}
      end

    gate = run(root, proj, "fx_dv_gate", env: [{"ERL_ZFLAGS", "+S 8:8"}, {"FX_GATE", nil}])

    # Each rebar3 script in a project of its own: a read outside every
    # window counts against everything in it.
    scripts =
      for {name, script} <- [
            {"doc", @doc_script},
            {"test", @test_script},
            {"pos", @position_script},
            {"cover", @cover_script}
          ],
          into: %{} do
        {name, script_run(root, name, %{"rebar.config.script" => script})}
      end
      |> Map.put("gproc", script_run(root, "gproc", gproc_files(), "gproc", "1.2.0"))

    %{
      verdicts: verdicts,
      off: off,
      pow2: pow2,
      divisors: divisors,
      gate: gate,
      scripts: scripts
    }
  end

  # Builds under asdf find their install through HOME, which a variant moves.
  defp asdf do
    dir = System.get_env("ASDF_DATA_DIR") || Path.expand("~/.asdf")
    if File.dir?(dir), do: [{"ASDF_DATA_DIR", dir}], else: []
  end

  defp run(root, proj, app, opts) do
    Portability.run(
      proj,
      app,
      env: TracerFixtures.env(proj) ++ asdf() ++ Keyword.get(opts, :env, []),
      releases: Keyword.get(opts, :releases, %{}),
      hex_home: Keyword.get(opts, :hex_home),
      mode: :judge,
      trace_dir: Path.join(root, "trace-#{app}"),
      log_file: Path.join(root, "#{app}.log"),
      timeout_ms: 240_000,
      run_started_at: System.monotonic_time(:second),
      differential: Keyword.get(opts, :differential, true),
      differential_gap_ms: 0
    )
  end

  # A project of one rebar3 dependency, `app` (default `fx_dv_r3_<name>`),
  # whose tarball holds `files` beside its config and module.
  defp script_run(root, name, files, app \\ nil, version \\ "0.1.0") do
    app = app || "fx_dv_r3_#{name}"
    dir = Path.join(root, "r3-#{name}")
    src = "-module(#{app}).\n-export([x/0]).\nx() -> ok.\n"
    config = "{erl_opts, []}.\n"

    deps = %{
      app => %{
        manager: :rebar3,
        rebar_config: config,
        files: Map.put(files, "src/#{app}.erl", src)
      }
    }

    proj = TracerFixtures.project(dir, [app], deps)
    File.write!(Path.join(proj, "mix.lock"), "%{}\n")
    hex_home = Path.join(dir, "hex")

    app_src =
      ~s({application, #{app}, [{vsn, "0.1.0"}, {description, "fixture"}, ) <>
        ~s({applications, [kernel, stdlib]}]}.\n)

    release =
      TracerFixtures.hex_release(
        hex_home,
        app,
        ["src", "priv", "rebar.config" | Map.keys(files)],
        Map.merge(files, %{
          "rebar.config" => config,
          "src/#{app}.erl" => src,
          "src/#{app}.app.src" => app_src
        }),
        [{"version", version}]
      )

    run(dir, proj, app, releases: Map.new([release]), hex_home: hex_home)
  end

  defp log(v), do: inspect(v.observations, pretty: true, limit: 60)

  test "a count that reaches no beam publishes after two variants", ctx do
    v = ctx.verdicts["fx_dv_pool"]
    assert %{status: :pass, reason: nil} = v, log(v)
    assert v.observations["trace_stats"]["differential"] == "same"

    assert %{"reads" => [read | _], "variants" => ["low", "high"]} =
             v.observations["differential"]

    assert read["read"] == "schedulers" and read["owner"] == "fx_dv_pool"
    assert v.observations["problems"] == []
  end

  test "without the flag the same read refuses as before", ctx do
    assert %{status: :skip, reason: "compile-time host read: erlang:system_info/1" <> _} =
             ctx.off

    assert ctx.off.observations["trace_stats"]["differential"] == nil
    refute Map.has_key?(ctx.off.observations["trace_stats"], "differential_flag")
    refute Map.has_key?(ctx.off.observations, "varied_reads")
  end

  # The flag's own record on every verdict judged with it, whatever came of
  # it, for the requeue's pilot check.
  test "a verdict judged with the flag says so", ctx do
    for {app, v} <- ctx.verdicts,
        do: assert(v.observations["trace_stats"]["differential_flag"] == "on", app)

    assert ctx.gate.observations["trace_stats"]["differential_flag"] == "on"
  end

  test "a count baked into a function refuses, naming the read", ctx do
    v = ctx.verdicts["fx_dv_baked"]
    assert v.status == :skip, log(v)
    assert v.reason =~ ~r/\Acompile-time host read: erlang:system_info\/1 \(schedulers_online\)/
    assert v.reason =~ "; a differential build differs: ebin/Elixir.FxDvBaked.beam: "
    assert v.observations["trace_stats"]["differential"] == "differs"
  end

  test "a threshold of the count is caught at the low end", ctx do
    v = ctx.verdicts["fx_dv_many"]
    assert v.status == :skip, log(v)
    assert v.reason =~ "; a differential build differs: ebin/Elixir.FxDvMany.beam: "
  end

  # Review N3: the first builds ran on 3, 6 and 8 schedulers, whose answer
  # is 1's, so only `high` (240 = 2^4 x 3 x 5) can tell.
  test "parity and divisibility by 4 or by 3 of the count refuse", ctx do
    for {app, module} <- [
          {"fx_dv_even", "FxDvEven"},
          {"fx_dv_by4", "FxDvBy4"},
          {"fx_dv_by3", "FxDvBy3"}
        ] do
      v = ctx.divisors[app]
      assert v.status == :skip, "#{app}: " <> log(v)
      assert v.reason =~ ~r/\Acompile-time host read: erlang:system_info\/1 \(schedulers_online\)/
      assert v.reason =~ "; a differential build differs: ebin/Elixir.#{module}.beam: ", app
    end
  end

  test "a power-of-two test of the count refuses on a power-of-two builder", ctx do
    v = ctx.pow2
    # Review R3: the tracer's start line records the count the VM ran with.
    assert v.observations["trace_stats"]["schedulers_online"] == 8
    assert v.status == :skip, log(v)
    assert v.reason =~ ~r/\Acompile-time host read: erlang:system_info\/1 \(schedulers_online\)/
    assert v.reason =~ "; a differential build differs: ebin/Elixir.FxDvPow2.beam: "
  end

  # A user with more than 64 schedulers and FX_GATE set compiles another
  # `@v`; the first build never read FX_GATE, so no input would say so.
  test "a count that gates an env read refuses: the variant read more", ctx do
    v = ctx.gate
    assert v.status == :skip, log(v)
    assert v.reason =~ ~r/\Acompile-time host read: erlang:system_info\/1 \(schedulers_online\)/
    assert v.reason =~ "; a differential build (high) read what the first did not: env FX_GATE"
    assert v.compile_inputs == nil
  end

  test "HOME read and not kept publishes; HOME baked refuses", ctx do
    v = ctx.verdicts["fx_dv_home"]
    assert %{status: :pass} = v, log(v)
    assert [%{"read" => "home"} | _] = v.observations["differential"]["reads"]

    v = ctx.verdicts["fx_dv_home_baked"]
    assert v.status == :skip, log(v)
    assert v.reason =~ ~r/\Acompile-time host read: init:get_argument\/1 \(home\)/
    assert v.reason =~ "a differential build differs: ebin/Elixir.FxDvHomeBaked.beam"
  end

  test "a dependent of a beam that holds the count publishes when its own beams do not", ctx do
    v = ctx.verdicts["fx_dv_user"]
    assert %{status: :pass} = v, log(v)
    assert v.observations["taint"] == %{}

    assert Enum.any?(
             v.observations["differential"]["reads"],
             &(&1["owner"] == "fx_dv_baked" and &1["read"] == "schedulers")
           )
  end

  # Review N1, N2 (coordinator ruling): only reviewed scripts. gproc
  # 1.2.0's own scripts, as Hex ships them, pass after the two variants.
  test "gproc 1.2.0's reviewed scripts reading the plain arguments publish", ctx do
    v = ctx.scripts["gproc"]
    assert %{status: :pass} = v, log(v)
    assert v.observations["differential"]["scripts"] == ["gproc 1.2.0"]

    assert [%{"read" => "plain_args", "owner" => "outside", "arg" => %{"rebar_script" => true}}] =
             v.observations["differential"]["reads"]
  end

  # Every other script refuses, the reviewer's two false hits among them:
  # nothing evaluates it a second time.
  test "a script that is not a reviewed one refuses, whatever it does", ctx do
    for name <- ~w(doc test pos cover) do
      v = ctx.scripts[name]
      assert v.status == :skip, "#{name}: " <> log(v)

      assert v.reason ==
               "compile-time host read: init:get_plain_arguments/0 (dispatcher stack, first frame erl_eval); " <>
                 "fx_dv_r3_#{name} 0.1.0's rebar.config.script is not a reviewed one",
             name
    end
  end
end
