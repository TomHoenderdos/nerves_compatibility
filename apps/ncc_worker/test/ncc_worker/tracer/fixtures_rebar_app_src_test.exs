defmodule NccWorker.Tracer.FixturesRebarAppSrcTest do
  # Review S5 S2, on real compiles: rebar3 evaluates a dependency's
  # `src/<app>.app.src.script`, and runs a `.app.src` `{vsn, {cmd, ...}}`,
  # itself, in its own VM, where the trace sees no Mix frame below the code
  # and drops what it does. Both cases ask the host for its architecture
  # (`uname -m`), and the `.app` rebar3 writes, a published file, carries
  # the answer. The judge refuses both from the verified tarball.
  # Starts real `elixir` VMs: one such module at a time (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.TracerFixtures

  import NccWorker.TracerFixtures, only: [lib: 3]

  @moduletag timeout: 600_000

  @app_src ~s|{application, fx_r3a, [{vsn, "0.1.0"}, {description, "fixture"}, | <>
             ~s|{applications, [kernel, stdlib]}]}.\n|

  @cases %{
    # The reviewer's fixture: the script adds the builder's arch to the env.
    "script" => %{
      "src/fx_r3a.app.src" => @app_src,
      "src/fx_r3a.app.src.script" => """
      [{application, fx_r3a, Opts}] = CONFIG,
      Arch = string:trim(os:cmd("uname -m")),
      [{application, fx_r3a, [{env, [{arch, Arch}]} | Opts]}].
      """
    },
    "vsn_cmd" => %{
      "src/fx_r3a.app.src" =>
        ~s|{application, fx_r3a, [{vsn, {cmd, "echo 0.1.0-$(uname -m)"}}, | <>
          ~s|{description, "fixture"}, {applications, [kernel, stdlib]}]}.\n|
    }
  }

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "ncc-fixtures-rebar-app-src-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    hex_home = Path.join(root, "hex")
    {arch, 0} = System.cmd("uname", ["-m"])

    runs =
      @cases
      |> Task.async_stream(fn {name, files} -> {name, compile(root, hex_home, name, files)} end,
        timeout: :infinity,
        ordered: false,
        max_concurrency: 2
      )
      |> Map.new(fn {:ok, {name, run}} -> {name, run} end)

    %{runs: runs, arch: String.trim(arch)}
  end

  defp compile(root, hex_home, name, files) do
    dir = Path.join(root, name)
    config = "{erl_opts, []}.\n"

    deps = %{
      "fx_r3a" => %{
        manager: :rebar3,
        files: Map.put(files, "src/fx_r3a.erl", "-module(fx_r3a).\n-export([x/0]).\nx() -> ok.\n")
      },
      "fx_uses_r3a" => lib("fx_uses_r3a", "defmodule FxUsesR3a do\nend\n", %{deps: ["fx_r3a"]})
    }

    proj = TracerFixtures.project(dir, ["fx_uses_r3a"], deps)
    File.write!(Path.join(proj, "mix.lock"), "%{}\n")

    release =
      TracerFixtures.hex_release(
        Path.join(hex_home, name),
        "fx_r3a",
        ["src", "rebar.config"],
        Map.put(files, "rebar.config", config)
      )

    %{
      proj: proj,
      traced: TracerFixtures.trace(proj, ["fx_uses_r3a"]),
      judge_opts: [
        releases: Map.new([release]),
        hex_home: Path.join(hex_home, name),
        nif_waiver: true
      ]
    }
  end

  defp built_app(run),
    do: File.read!(Path.join(run.proj, "_build/host/lib/fx_r3a/ebin/fx_r3a.app"))

  defp verdict(run, app), do: TracerFixtures.judge(run.proj, app, run.traced, [], run.judge_opts)

  test "the traced compiles completed, and rebar3 wrote the host's answer into the .app", ctx do
    for {name, %{traced: traced}} <- ctx.runs do
      assert {:ok, 0} = traced.result, "#{name}: #{traced.log}"
    end

    assert built_app(ctx.runs["script"]) =~ ~s|{arch,"#{ctx.arch}"}|
    assert built_app(ctx.runs["vsn_cmd"]) =~ ~s|{vsn,"0.1.0-#{ctx.arch}"}|
  end

  test "an .app.src.script refuses the dependency and its dependents", ctx do
    run = ctx.runs["script"]

    # The traced compile is the dependent's (the script fixtures' layout):
    # the dependency's refusal is a closure taint for both.
    for app <- ["fx_r3a", "fx_uses_r3a"] do
      assert %{
               status: :skip,
               reason:
                 "closure dependency observed the host: fx_r3a (rebar3 build evaluates an .app.src.script)"
             } = verdict(run, app),
             app
    end
  end

  test "a vsn command refuses the dependency and its dependents", ctx do
    run = ctx.runs["vsn_cmd"]

    # The traced compile is the dependent's (the script fixtures' layout):
    # the dependency's refusal is a closure taint for both.
    for app <- ["fx_r3a", "fx_uses_r3a"] do
      assert %{
               status: :skip,
               reason:
                 "closure dependency observed the host: fx_r3a (rebar3 build computes its .app.src vsn)"
             } = verdict(run, app),
             app
    end
  end
end
