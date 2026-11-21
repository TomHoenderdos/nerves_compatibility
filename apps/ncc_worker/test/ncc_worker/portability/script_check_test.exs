defmodule NccWorker.Portability.ScriptCheckTest do
  # `ScriptCheck.run/2` on real VMs: a traced judge compile of a project of
  # rebar3 dependencies with scripts (the first build, whose
  # `mix.rebar.config` files anchor the check), then the check's own Mix
  # VMs in that project, evaluating every script as Mix does when it loads
  # the dependencies. Starts real `elixir` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.Portability.ScriptCheck
  alias NccWorker.TracerFixtures

  @moduletag timeout: 600_000

  # gproc 1.2.0's `priv/check_edown.script`, shortened: `"doc"` among the
  # plain arguments adds a git `edown` to `deps`, and nothing else.
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

  @eunit_script """
  case lists:member("eunit", init:get_plain_arguments()) of
      true -> [{erl_opts, [{d, 'TEST'}]} | CONFIG];
      false -> CONFIG
  end.
  """

  @test_script String.replace(@eunit_script, "eunit", "test")

  # Review B2: a branch only Mix's own VM takes (tls_certificate_check's
  # guard), testing a word `iex -S mix` puts among the plain arguments.
  @guarded_script """
  case erlang:function_exported('Elixir.Mix', module_info, 1) of
      true ->
          case lists:member("--no-halt", init:get_plain_arguments()) of
              true -> [{erl_opts, [{d, 'IEX'}]} | CONFIG];
              false -> CONFIG
          end;
      false -> CONFIG
  end.
  """

  # The traced compile's own task among the arguments: only the first build
  # sees it, so a check that does not reproduce that build refuses.
  @traced_script """
  case lists:member("ncc.trace_compile", init:get_plain_arguments()) of
      true -> [{erl_opts, [{d, 'TRACED'}]} | CONFIG];
      false -> CONFIG
  end.
  """

  @nested_script """
  {ok, C} = file:script(filename:join(filename:dirname(SCRIPT), "priv/x.script"),
                        [{'CONFIG', CONFIG}]),
  C.
  """

  # tls_certificate_check 1.36.0's real script, vendored unchanged: under
  # Mix it keeps the config; elsewhere it takes rebar 2's branch, which
  # drops `warn_missing_spec` from `erl_opts`.
  @tls_script File.read!(
                Path.join(
                  __DIR__,
                  "../../fixtures/rebar/tls_certificate_check-1.36.0.rebar.config.script"
                )
              )

  @apps %{
    "fx_sc_doc" => %{"rebar.config.script" => @doc_script},
    "fx_sc_eunit" => %{"rebar.config.script" => @eunit_script},
    "fx_sc_test" => %{"rebar.config.script" => @test_script},
    "fx_sc_guarded" => %{"rebar.config.script" => @guarded_script},
    "fx_sc_traced" => %{"rebar.config.script" => @traced_script},
    "fx_sc_nested" => %{
      "rebar.config.script" => @nested_script,
      "priv/x.script" => String.replace(@eunit_script, "eunit", "proper")
    },
    "fx_sc_tls" => %{"rebar.config.script" => @tls_script},
    "fx_sc_plain" => %{}
  }

  @config "{erl_opts, [debug_info, warn_missing_spec]}.\n{deps, []}.\n"

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "ncc-script-check-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    first = first_build(Path.join(root, "a"), @apps)

    # Ends the check's VM alone (it names the check's own task), so the
    # first build compiles: a project of its own, as it ends every load. (A
    # script that raises is no failure: Mix then keeps the static config, in
    # the user's VM as here.)
    bad = """
    case lists:member("ncc.script_eval", init:get_plain_arguments()) of
        true -> erlang:halt(3);
        false -> CONFIG
    end.
    """

    %{
      first: first,
      bad: first_build(Path.join(root, "b"), %{"fx_sc_bad" => %{"rebar.config.script" => bad}})
    }
  end

  # The project, the traced judge compile of all its apps (each a rebar3
  # dependency whose `src` holds one module), and each app's verified
  # tarball.
  defp first_build(dir, apps) do
    deps =
      Map.new(apps, fn {app, files} ->
        src = "-module(#{app}).\n-export([x/0]).\n-spec x() -> ok.\nx() -> ok.\n"

        {app,
         %{
           manager: :rebar3,
           rebar_config: @config,
           files: Map.merge(files, %{"src/#{app}.erl" => src})
         }}
      end)

    proj = TracerFixtures.project(dir, Map.keys(apps), deps)
    File.write!(Path.join(proj, "mix.lock"), "%{}\n")
    traced = TracerFixtures.trace(proj, Map.keys(apps))
    {:ok, 0} = traced.result

    tarballs =
      Map.new(apps, fn {app, files} ->
        home = Path.join(dir, "hex-#{app}")
        contents = Map.merge(%{"rebar.config" => @config}, files)
        TracerFixtures.hex_release(home, app, Map.keys(contents), contents)
        {app, File.read!(Path.join(home, "packages/hexpm/#{app}-0.1.0.tar"))}
      end)

    %{proj: proj, tarballs: tarballs}
  end

  defp check(%{proj: proj, tarballs: tarballs}, apps, extra \\ []) do
    scripts = for app <- apps, do: {app, Map.fetch!(tarballs, app)}

    # `extra` first: Keyword.fetch!/2 takes the first value.
    ScriptCheck.run(
      scripts,
      extra ++
        [
          env: TracerFixtures.env(proj),
          project_dir: proj,
          build_root: Path.join([proj, "_build", "host"])
        ]
    )
  end

  test "a script whose arguments change only deps passes", ctx do
    assert {:ok, ["fx_sc_doc"]} = check(ctx.first, ["fx_sc_doc"])
  end

  test "a script's own literal among the arguments is tried", ctx do
    assert {:differs, "fx_sc_eunit", why} = check(ctx.first, ["fx_sc_eunit"])
    assert why =~ "erl_opts differs with"
  end

  test "a Mix user's command words are tried", ctx do
    assert {:differs, "fx_sc_test", "erl_opts differs with " <> _} =
             check(ctx.first, ["fx_sc_test"])
  end

  test "a literal of another script file of the dependency is tried", ctx do
    assert {:differs, "fx_sc_nested", _} = check(ctx.first, ["fx_sc_nested"])
  end

  # Review B2: the check's VM is Mix's, so the Mix-guarded branch is the
  # one evaluated, and `iex -S mix`'s words are among those tried.
  test "a branch only Mix takes is evaluated, with iex's words", ctx do
    assert {:differs, "fx_sc_guarded", "erl_opts differs with " <> _} =
             check(ctx.first, ["fx_sc_guarded"])
  end

  test "tls_certificate_check's script takes the branch the real build took", ctx do
    assert {:ok, ["fx_sc_tls"]} = check(ctx.first, ["fx_sc_tls"])

    config = File.read!(Path.join(ctx.first.proj, "_build/host/lib/fx_sc_tls/mix.rebar.config"))
    assert config =~ "warn_missing_spec"
  end

  test "a check whose evaluation does not reproduce the first build's config refuses", ctx do
    assert {:differs, "fx_sc_traced", why} = check(ctx.first, ["fx_sc_traced"])
    assert why =~ "does not reproduce the first build's mix.rebar.config"
  end

  test "an app with no mix.rebar.config of the first build refuses", ctx do
    File.rm_rf!(Path.join(ctx.first.proj, "_build/other"))

    assert {:differs, "fx_sc_doc", "no mix.rebar.config of the first build to reproduce"} =
             check(ctx.first, ["fx_sc_doc"],
               build_root: Path.join(ctx.first.proj, "_build/other")
             )
  end

  test "a dependency without a script is not checked", ctx do
    assert {:ok, []} = check(ctx.first, ["fx_sc_plain"])
  end

  test "several apps are checked by the same evaluations", ctx do
    assert {:ok, ["fx_sc_doc", "fx_sc_tls"]} = check(ctx.first, ["fx_sc_doc", "fx_sc_tls"])
  end

  # Coordinator ruling 5: the whole check has one wall budget.
  test "a check past its time budget stops and cannot be judged", ctx do
    started = System.monotonic_time(:millisecond)

    assert {:error, "over its time budget of 0 s" <> _} =
             check(ctx.first, ["fx_sc_eunit"], budget_ms: 1)

    assert System.monotonic_time(:millisecond) - started < 30_000
  end

  test "an evaluation that fails cannot be judged", ctx do
    assert {:error, "evaluation exited " <> _} = check(ctx.bad, ["fx_sc_bad"])
  end

  test "literals are the scripts' plain printable strings" do
    files = %{
      "rebar.config.script" =>
        ~s|lists:member("doc", A), "a\\\\b", "x y", "#{String.duplicate("z", 80)}"|,
      "priv/s.script" => ~s|"eunit".|,
      "README.md" => ~s|"not a script"|
    }

    assert ScriptCheck.literals(files) == ["doc", "eunit", "x y"]
  end

  test "iex's words are among the command words" do
    for word <- ~w(iex +iex --no-halt), do: assert(word in ScriptCheck.words())
  end
end
