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

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
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

    # Each rebar3 script in a project of its own: a read outside every
    # window counts against everything in it.
    scripts =
      for {name, script} <- [{"doc", @doc_script}, {"test", @test_script}], into: %{} do
        {name, script_run(root, name, script)}
      end

    %{verdicts: verdicts, off: off, scripts: scripts}
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
      env: TracerFixtures.env(proj) ++ asdf(),
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

  defp script_run(root, name, script) do
    app = "fx_dv_r3_#{name}"
    dir = Path.join(root, "r3-#{name}")
    src = "-module(#{app}).\n-export([x/0]).\nx() -> ok.\n"
    config = "{erl_opts, []}.\n"

    deps = %{
      app => %{
        manager: :rebar3,
        rebar_config: config,
        files: %{"src/#{app}.erl" => src, "rebar.config.script" => script}
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
        ["src", "rebar.config", "rebar.config.script"],
        %{
          "rebar.config" => config,
          "rebar.config.script" => script,
          "src/#{app}.erl" => src,
          "src/#{app}.app.src" => app_src
        }
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
    refute Map.has_key?(ctx.off.observations, "varied_reads")
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

  test "a script whose arguments change only deps publishes after the script check", ctx do
    v = ctx.scripts["doc"]
    assert %{status: :pass} = v, log(v)
    assert v.observations["differential"]["scripts"] == ["fx_dv_r3_doc"]

    assert [%{"read" => "plain_args", "owner" => "outside"}] =
             v.observations["differential"]["reads"]
  end

  test "a script whose config a Mix user's command line changes refuses", ctx do
    v = ctx.scripts["test"]
    assert v.status == :skip, log(v)
    assert v.reason =~ ~r/\Acompile-time host read: init:get_plain_arguments\/0/

    assert v.reason =~
             "; fx_dv_r3_test's rebar.config.script gives another config: erl_opts differs with"
  end
end
