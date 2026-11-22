defmodule NccWorker.Tracer.FixturesGuardedTest do
  # Starts real `elixir` and `mix` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.{BuildIdentity, TracerFixtures}

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  # Coverage drop 2026-11-22, F4: websock_adapter's
  # `if Code.ensure_loaded?(:cowboy_websocket) do defmodule
  # WebSockAdapter.CowboyAdapter ... end`, as 0.7.2 ships it (the reviewed
  # entry keys on the file, the probe and the locked release). The builder
  # has no cowboy, so the module is not built and websock_adapter's own
  # build refuses. A dependent that only calls `WebSockAdapter` builds the
  # same beams in a world where the guarded module exists (an unpruned
  # project with a `cowboy_websocket` compiled first, as Mix.install
  # compiles), so websock_adapter's refusal does not taint it. One that
  # refers to the guarded module, or probes it at compile time, stays
  # refused.
  @adapter """
  if Code.ensure_loaded?(:cowboy_websocket) do
    defmodule WebSockAdapter.CowboyAdapter do
      @moduledoc false
      def init(req, state), do: {:cowboy_websocket, req, state}
    end
  end
  """

  @main """
  defmodule WebSockAdapter do
    def upgrade(websock, state), do: tuple_for(websock, state)
    defp tuple_for(websock, state), do: {WebSockAdapter.CowboyAdapter, {websock, state}, %{}}
  end
  """

  @refusal "compile-time probe of a dependency outside the closure: cowboy_websocket via " <>
             "Code.ensure_loaded?/1"

  defp project(dir, dep_body, extra \\ %{}) do
    TracerFixtures.project(
      dir,
      ["fx_dep"],
      Map.merge(
        %{
          "websock_adapter" => %{
            files: %{
              "lib/websock_adapter.ex" => @main,
              "lib/websock_adapter/cowboy_adapter.ex" => @adapter
            }
          },
          "fx_dep" => %{
            deps: ["websock_adapter"],
            files: %{"lib/fx_dep.ex" => dep_body}
          }
        },
        extra
      )
    )
  end

  defp opts(dir) do
    home = Path.join(dir, "hex")

    {app, release} =
      TracerFixtures.hex_release(home, "websock_adapter", ["lib"], %{}, [{"version", "0.7.2"}])

    [releases: %{app => release}, hex_home: home]
  end

  defp compile(proj) do
    {out, status} =
      System.cmd("mix", ["compile"],
        cd: proj,
        env: TracerFixtures.env(proj),
        stderr_to_stdout: true
      )

    assert status == 0, out
  end

  defp app_beams(proj, app) do
    ebin = Path.join([proj, "_build", "host", "lib", app, "ebin"])

    for path <- Path.wildcard(Path.join(ebin, "*.beam")),
        into: %{},
        do: {Path.basename(path), File.read!(path)}
  end

  # The user's world: an unpruned project (Mix.install does not prune) with
  # a `cowboy_websocket` that compiles before websock_adapter.
  defp with_cowboy(dir, dep_body) do
    proj =
      project(dir, dep_body, %{
        "fx_cowboy" => %{
          files: %{
            "src/cowboy_websocket.erl" =>
              "-module(cowboy_websocket).\n-export([upgrade/0]).\nupgrade() -> ok.\n"
          }
        },
        "websock_adapter" => %{
          deps: ["fx_cowboy"],
          files: %{
            "lib/websock_adapter.ex" => @main,
            "lib/websock_adapter/cowboy_adapter.ex" => @adapter
          }
        }
      })

    path = Path.join(proj, "mix.exs")

    File.write!(
      path,
      String.replace(File.read!(path), "deps: [", "prune_code_paths: false, deps: [",
        global: false
      )
    )

    proj
  end

  @dependent """
  defmodule FxDep do
    def connect(websock, state), do: WebSockAdapter.upgrade(websock, state)
  end
  """

  test "a dependent that only calls the prober builds the same beams in both worlds",
       %{tmp_dir: dir} do
    # Both worlds in the same dir: `CInf` holds the source path.
    root = Path.join(dir, "w")
    proj = project(root, @dependent)
    traced = TracerFixtures.trace(proj, ["fx_dep"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log

    # The builder took the branch without the guarded module.
    refute Map.has_key?(
             app_beams(proj, "websock_adapter"),
             "Elixir.WebSockAdapter.CowboyAdapter.beam"
           )

    verdict = TracerFixtures.judge(proj, "fx_dep", traced, [], opts(dir))
    assert %{status: :pass} = verdict, inspect(Map.take(verdict, [:reason, :observations]))

    assert verdict.observations["guarded_taint"] == [
             %{
               "app" => "websock_adapter",
               "entries" => ["websock_adapter:cowboy_adapter"],
               "reasons" => [@refusal]
             }
           ]

    assert %{"owner" => "websock_adapter", "reason" => @refusal} in verdict.observations[
             "refusals"
           ]

    # The user's world: the guarded module exists, the dependent's beams
    # are byte for byte the builder's.
    # A firmware target's verdict refuses on any refusal of the closure:
    # nothing is waived there.
    firmware = TracerFixtures.judge(proj, "fx_dep", traced, [], opts(dir) ++ [target: "rpi4"])
    assert %{status: :skip} = firmware

    builder = app_beams(proj, "fx_dep")
    File.rm_rf!(root)
    user = with_cowboy(root, @dependent)
    assert user == proj
    compile(user)

    assert Map.has_key?(
             app_beams(user, "websock_adapter"),
             "Elixir.WebSockAdapter.CowboyAdapter.beam"
           )

    assert BuildIdentity.differences(app_beams(user, "fx_dep"), builder) == []
  end

  # The prober's own build is refused as before.
  test "the prober's own build still refuses", %{tmp_dir: dir} do
    proj = project(dir, @dependent)
    traced = TracerFixtures.trace(proj, ["websock_adapter"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log

    assert %{status: :skip, reason: @refusal} =
             TracerFixtures.judge(proj, "websock_adapter", traced, [], opts(dir))
  end

  # A dependent that refers to the guarded module (the checker reads its
  # signature), or calls or probes it at compile time (a traced probe),
  # stays tainted or refused.
  for {name, body, reason} <- [
        {"calls the guarded module",
         """
         defmodule FxDep do
           @compile {:no_warn_undefined, WebSockAdapter.CowboyAdapter}
           def init(req, state), do: WebSockAdapter.CowboyAdapter.init(req, state)
         end
         """, "closure dependency observed the host: websock_adapter (#{@refusal})"},
        {"probes the guarded module at compile time",
         TracerFixtures.attr_module("FxDep", "Code.ensure_loaded?(WebSockAdapter.CowboyAdapter)"),
         "compile-time probe of a dependency outside the closure: " <>
           "Elixir.WebSockAdapter.CowboyAdapter via Code.ensure_loaded?/1"},
        {"calls the guarded module at compile time",
         TracerFixtures.attr_module(
           "FxDep",
           "(try do WebSockAdapter.CowboyAdapter.init(1, 2) rescue _ -> :none end)"
         ),
         "compile-time probe of a dependency outside the closure: " <>
           "Elixir.WebSockAdapter.CowboyAdapter via code:ensure_loaded/1"}
      ] do
    @body body
    @reason reason
    test "a dependent that #{name} is refused", %{tmp_dir: dir} do
      proj = project(dir, @body)
      traced = TracerFixtures.trace(proj, ["fx_dep"], mode: :host)
      assert {:ok, 0} = traced.result, traced.log

      verdict = TracerFixtures.judge(proj, "fx_dep", traced, [], opts(dir))
      assert %{status: :skip, reason: @reason} = verdict, inspect(verdict.reason)
      assert verdict.observations["guarded_taint"] == []
    end
  end
end
