defmodule NccWorker.Portability.ScriptCheckTest do
  # `ScriptCheck.run/2` on real `elixir` VMs evaluating a rebar3
  # dependency's `rebar.config.script` from its tarball, as Mix does.
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.Portability.ScriptCheck
  alias NccWorker.TracerFixtures

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

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

  @test_script """
  case lists:member("test", init:get_plain_arguments()) of
      true -> [{erl_opts, [{d, 'TEST'}]} | CONFIG];
      false -> CONFIG
  end.
  """

  defp tarball(dir, app, files) do
    home = Path.join(dir, "hex-#{app}")
    contents = Map.merge(%{"rebar.config" => "{erl_opts, []}.\n{deps, []}.\n"}, files)
    TracerFixtures.hex_release(home, app, Map.keys(contents), contents)
    {app, File.read!(Path.join(home, "packages/hexpm/#{app}-0.1.0.tar"))}
  end

  defp run(scripts), do: ScriptCheck.run(scripts, env: [])

  test "a script whose arguments change only deps passes", %{tmp_dir: dir} do
    assert {:ok, ["fx_doc"]} =
             run([tarball(dir, "fx_doc", %{"rebar.config.script" => @doc_script})])
  end

  test "a script's own literal among the arguments is tried", %{tmp_dir: dir} do
    assert {:differs, "fx_eunit", why} =
             run([tarball(dir, "fx_eunit", %{"rebar.config.script" => @eunit_script})])

    assert why =~ "erl_opts differs with"
  end

  test "a Mix user's command words are tried", %{tmp_dir: dir} do
    assert {:differs, "fx_test", "erl_opts differs with " <> _} =
             run([tarball(dir, "fx_test", %{"rebar.config.script" => @test_script})])
  end

  test "a literal of another script file of the dependency is tried", %{tmp_dir: dir} do
    script = """
    {ok, C} = file:script(filename:join(filename:dirname(SCRIPT), "priv/x.script"),
                          [{'CONFIG', CONFIG}]),
    C.
    """

    files = %{
      "rebar.config.script" => script,
      "priv/x.script" => String.replace(@eunit_script, "eunit", "proper")
    }

    assert {:differs, "fx_nested", _} = run([tarball(dir, "fx_nested", files)])
  end

  test "a dependency without a script is not checked", %{tmp_dir: dir} do
    assert {:ok, []} = run([tarball(dir, "fx_plain", %{})])
  end

  test "a script that fails to evaluate cannot be judged", %{tmp_dir: dir} do
    assert {:error, "fx_bad: evaluation exited " <> _} =
             run([tarball(dir, "fx_bad", %{"rebar.config.script" => "erlang:error(no).\n"})])
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
end
