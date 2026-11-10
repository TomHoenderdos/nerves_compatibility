defmodule NccWorker.Tracer.FixturesCodeLoadingTest do
  # Item 5a under the real tracer: a rebar3 parse transform whose first call
  # into syntax_tools makes the rebar3 VM (an archive escript) load erl_syntax
  # in the calling process, parse_trans's refusal (research C1), now passes.
  # What must still refuse: the same reads from package frames, after an
  # explicit code:ensure_loaded/1 too; an on_load of a package module (its
  # own process, no code-server frames); erl_prim_loader:read_file/1 called
  # directly. Starts real VMs: one such module at a time (:real_vm).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.{Portability, TracerFixtures}

  import NccWorker.TracerFixtures, only: [lib: 3]

  @moduletag timeout: 600_000

  @host_read "compile-time host read: "

  defp pt(module, body) do
    """
    -module(#{module}).
    -export([parse_transform/2]).
    parse_transform(Forms, _Options) ->
    #{body}
        Forms.
    """
  end

  defp transformed(app, pt),
    do: "-module(#{app}).\n-compile({parse_transform, #{pt}}).\n-export([f/0]).\nf() -> ok.\n"

  defp r3(files), do: %{manager: :rebar3, files: files}

  @deps %{
    "fx_r3_lazy" => %{
      manager: :rebar3,
      files: %{
        "src/fx_r3_lazy_pt.erl" => """
        -module(fx_r3_lazy_pt).
        -export([parse_transform/2]).
        parse_transform(Forms, _Options) ->
            _ = erl_syntax:string("undefined"),
            Forms.
        """,
        "src/fx_r3_lazy.erl" =>
          "-module(fx_r3_lazy).\n-compile({parse_transform, fx_r3_lazy_pt}).\n" <>
            "-export([f/0]).\nf() -> ok.\n"
      }
    },
    "fx_uses_r3_lazy" =>
      lib("fx_uses_r3_lazy", "defmodule FxUsesR3Lazy do\nend\n", %{deps: ["fx_r3_lazy"]})
  }

  # Each must-refuse case is its own rebar3 app, so its refusal is its own.
  @refusing %{
    # Loads a module itself (flagged, accepted), then reads the host from
    # its own frame.
    "fx_r3_own" =>
      {"fx_r3_own_pt",
       """
           {module, _} = code:ensure_loaded(erl_prettypr),
           _ = prim_file:read_link("/usr"),
       """},
    # The same reads, from its own frame, with nothing loaded.
    "fx_r3_same" =>
      {"fx_r3_same_pt",
       """
           _ = erlang:system_info(os_type),
           _ = prim_file:read_link("/usr"),
       """},
    # erl_prim_loader called directly on an OTP beam: the same path
    # resolution, but no code-server frames under it.
    "fx_r3_direct" =>
      {"fx_r3_direct_pt",
       """
           _ = erl_prim_loader:read_file(code:which(lists)),
       """}
  }

  @onload_files %{
    "src/fx_r3_onload_pt.erl" => """
    -module(fx_r3_onload_pt).
    -export([parse_transform/2]).
    -on_load(init/0).
    init() ->
        _ = erlang:system_info(os_type),
        _ = prim_file:read_link("/usr"),
        ok.
    parse_transform(Forms, _Options) -> Forms.
    """,
    "src/fx_r3_onload.erl" =>
      "-module(fx_r3_onload).\n-compile({parse_transform, fx_r3_onload_pt}).\n" <>
        "-export([f/0]).\nf() -> ok.\n"
  }

  defp deps do
    refusing =
      for {app, {pt, body}} <- @refusing, into: %{} do
        {app, r3(%{"src/#{pt}.erl" => pt(pt, body), "src/#{app}.erl" => transformed(app, pt)})}
      end

    @deps |> Map.merge(refusing) |> Map.put("fx_r3_onload", r3(@onload_files))
  end

  setup_all do
    tmp = Portability.Context.realpath(System.tmp_dir!())
    root = Path.join(tmp, "ncc-fixtures-code-loading-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    hex_home = Path.join(root, "hex")
    deps = deps()

    releases =
      for {app, %{manager: :rebar3}} <- deps, into: %{} do
        TracerFixtures.hex_release(hex_home, app, ["src", "rebar.config"], %{
          "rebar.config" => "{erl_opts, []}.\n"
        })
      end

    proj = TracerFixtures.project(root, Map.keys(deps), deps)
    File.write!(Path.join(proj, "mix.lock"), "%{}\n")
    packages = ["fx_uses_r3_lazy", "fx_r3_onload" | Map.keys(@refusing)]

    %{
      proj: proj,
      traced: TracerFixtures.trace(proj, packages),
      opts: [releases: releases, hex_home: hex_home]
    }
  end

  defp flagged(ctx, app) do
    child = ctx.traced.report.children[app]
    assert child, "no rebar3 child trace for #{app}"
    Enum.filter(child.events, &(&1["arg"]["code_loading"] == true))
  end

  defp refusals(ctx, app) do
    v = TracerFixtures.judge(ctx.proj, app, ctx.traced, [], ctx.opts)
    assert %{status: :skip} = v, "#{app}: #{inspect(v, pretty: true)}"
    for %{"owner" => ^app, "reason" => r} <- v.observations["refusals"], do: r
  end

  test "the traced compile completed", ctx do
    assert {:ok, 0} = ctx.traced.result, ctx.traced.log
    assert ctx.traced.report.problems == []
  end

  test "OTP loading a module for a parse transform does not taint it", ctx do
    # The reads were traced and flagged: if erl_syntax was already loaded
    # in this rebar3, switch the transform to another unloaded OTP module.
    # The os_type reads are path handling (erl_prim_loader:pathtype/1 is a
    # path frame), counted and not written, so only read_link lines remain.
    events = flagged(ctx, "fx_r3_lazy")

    assert events != [],
           inspect(Enum.map(ctx.traced.report.children["fx_r3_lazy"].events, & &1["mfa"]))

    assert events |> Enum.map(& &1["mfa"]) |> Enum.uniq() |> Enum.sort() ==
             ["prim_file:read_link/1"]

    v = TracerFixtures.judge(ctx.proj, "fx_uses_r3_lazy", ctx.traced, [], ctx.opts)
    assert %{status: :pass} = v, inspect(v.observations["refusals"])
  end

  test "the same reads from a package frame still refuse, after its own ensure_loaded too",
       ctx do
    for app <- ["fx_r3_own", "fx_r3_same"] do
      reasons = refusals(ctx, app)

      assert Enum.any?(
               reasons,
               &String.starts_with?(&1, @host_read <> "prim_file:read_link/1 /usr")
             ),
             "#{app}: #{inspect(reasons)}"
    end

    assert Enum.any?(refusals(ctx, "fx_r3_same"), &(&1 =~ @host_read <> "erlang:system_info/1")),
           inspect(refusals(ctx, "fx_r3_same"))
  end

  test "an on_load of a package module that reads the host still refuses", ctx do
    reasons = refusals(ctx, "fx_r3_onload")

    assert Enum.any?(
             reasons,
             &String.starts_with?(&1, @host_read <> "prim_file:read_link/1 /usr")
           ),
           inspect(reasons)
  end

  test "erl_prim_loader:read_file/1 called directly still refuses", ctx do
    assert flagged(ctx, "fx_r3_direct") == []
    reasons = refusals(ctx, "fx_r3_direct")

    assert Enum.any?(reasons, &String.starts_with?(&1, @host_read <> "prim_file:read_link/1")),
           inspect(reasons)
  end
end
