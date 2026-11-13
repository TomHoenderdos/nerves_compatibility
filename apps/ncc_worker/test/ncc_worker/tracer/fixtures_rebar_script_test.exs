defmodule NccWorker.Tracer.FixturesRebarScriptTest do
  # A rebar3 dependency's rebar.config.script on real compiles. Mix
  # evaluates the script in its own traced VM when it loads the
  # dependencies, outside every window, and writes the result to
  # mix.rebar.config, the config rebar3 reads; rebar3 does not evaluate it
  # again. Each case is its own project: a refusal outside every window
  # counts against everything in it.
  # Starts real `elixir` VMs: one such module at a time (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.TracerFixtures

  import NccWorker.TracerFixtures, only: [lib: 3]

  @moduletag timeout: 600_000

  @scripts %{
    "env" => """
    case os:getenv("FX_SCRIPT_MODE") of
        "extra" -> [{erl_opts, [debug_info]} | CONFIG];
        _ -> CONFIG
    end.
    """,
    "host" => """
    _ = file:read_file("/etc/hosts"),
    CONFIG.
    """,
    "hook" => """
    [{pre_hooks, [{compile, "true"}]} | CONFIG].
    """,
    # yamerl 0.10.0's real script, vendored unchanged from its Hex tarball.
    "yamerl" =>
      File.read!(Path.join(__DIR__, "../../fixtures/rebar/yamerl-0.10.0.rebar.config.script")),
    # Writes where it is evaluated, to show which VMs evaluate it.
    "marker" => """
    file:write_file(os:getenv("FX_SCRIPT_MARKER"),
                    io_lib:format("~p~n", [code:is_loaded('Elixir.Mix') =/= false]),
                    [append]),
    CONFIG.
    """
  }

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "ncc-fixtures-rebar-script-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    hex_home = Path.join(root, "hex")

    runs =
      @scripts
      |> Task.async_stream(fn {name, script} -> {name, compile(root, hex_home, name, script)} end,
        timeout: :infinity,
        ordered: false,
        max_concurrency: 4
      )
      |> Map.new(fn {:ok, {name, run}} -> {name, run} end)

    %{runs: runs}
  end

  defp compile(root, hex_home, name, script) do
    dir = Path.join(root, name)
    config = "{erl_opts, []}.\n"

    deps = %{
      "fx_r3s" => %{
        manager: :rebar3,
        files: %{
          "src/fx_r3s.erl" => "-module(fx_r3s).\n-export([x/0]).\nx() -> ok.\n",
          "rebar.config.script" => script
        }
      },
      "fx_uses_r3s" => lib("fx_uses_r3s", "defmodule FxUsesR3s do\nend\n", %{deps: ["fx_r3s"]})
    }

    proj = TracerFixtures.project(dir, ["fx_uses_r3s"], deps)
    File.write!(Path.join(proj, "mix.lock"), "%{}\n")
    marker = Path.join(dir, "marker.txt")
    # The builder has no GitHub Actions variables; CI does, so unset them.
    env = [{"FX_SCRIPT_MARKER", marker}, {"GITHUB_ACTIONS", nil}, {"GITHUB_TOKEN", nil}]

    release =
      TracerFixtures.hex_release(
        Path.join(hex_home, name),
        "fx_r3s",
        ["src", "rebar.config", "rebar.config.script"],
        %{"rebar.config" => config, "rebar.config.script" => script}
      )

    %{
      proj: proj,
      marker: marker,
      traced: TracerFixtures.trace(proj, ["fx_uses_r3s"], extra_env: env),
      judge_opts: [releases: Map.new([release]), hex_home: Path.join(hex_home, name)]
    }
  end

  defp verdict(ctx, run, app) do
    run = ctx.runs[run]
    TracerFixtures.judge(run.proj, app, run.traced, [], run.judge_opts)
  end

  test "the traced compiles completed", ctx do
    for {name, %{traced: traced}} <- ctx.runs do
      assert {:ok, 0} = traced.result, "#{name}: #{traced.log}"
    end
  end

  test "only Mix evaluates the script, once, in the traced VM", ctx do
    assert File.read!(ctx.runs["marker"].marker) == "true\n"
    # The write is the trace's, outside every window.
    assert %{status: :skip, reason: "compile-time write outside ebin: " <> _} =
             verdict(ctx, "marker", "fx_r3s")
  end

  test "a script that reads the environment publishes with the read as an input", ctx do
    for app <- ["fx_r3s", "fx_uses_r3s"] do
      v = verdict(ctx, "env", app)
      assert %{status: :pass, compile_inputs: inputs} = v, "#{app}: #{inspect(v.observations)}"

      assert [%{"kind" => "env", "name" => "FX_SCRIPT_MODE", "set_by" => "host"}] =
               Enum.filter(inputs, &(&1["name"] == "FX_SCRIPT_MODE")),
             app
    end
  end

  # yamerl's script always reads GITHUB_TOKEN. Unset on the builder, it is
  # recorded as unset, so a client without it matches.
  test "yamerl's script publishes with its unset GitHub variables as inputs", ctx do
    unset =
      :error |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)

    for app <- ["fx_r3s", "fx_uses_r3s"] do
      v = verdict(ctx, "yamerl", app)
      assert %{status: :pass, compile_inputs: inputs} = v, "#{app}: #{inspect(v.observations)}"

      for name <- ["GITHUB_ACTIONS", "GITHUB_TOKEN"] do
        assert [%{"kind" => "env", "value" => ^unset, "set_by" => "host"}] =
                 Enum.filter(inputs, &(&1["name"] == name)),
               "#{app} #{name}"
      end
    end
  end

  test "a script that reads the host refuses the build", ctx do
    for app <- ["fx_r3s", "fx_uses_r3s"] do
      assert %{status: :skip, reason: "compile-time host read: file:read_file/1 /etc/hosts" <> _} =
               verdict(ctx, "host", app),
             app
    end
  end

  test "a hook the script adds refuses through the mix.rebar.config Mix wrote", ctx do
    for app <- ["fx_r3s", "fx_uses_r3s"] do
      assert %{
               status: :skip,
               reason:
                 "closure dependency observed the host: fx_r3s (rebar3 build runs pre_hooks)"
             } = verdict(ctx, "hook", app),
             app
    end
  end
end
