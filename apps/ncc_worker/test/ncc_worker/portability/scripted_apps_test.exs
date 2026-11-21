defmodule NccWorker.Portability.ScriptedAppsTest do
  # `NccWorker.Portability.scripted_apps/2`: the verified tarballs the
  # script check evaluates, when a varied read was of the plain arguments.
  use ExUnit.Case, async: true

  alias NccWorker.Portability
  alias NccWorker.Portability.Context
  alias NccWorker.TracerFixtures

  @moduletag :tmp_dir

  @script "CONFIG.\n"

  defp release(home, app, script?) do
    contents = %{"rebar.config" => "{erl_opts, []}.\n"}
    contents = if script?, do: Map.put(contents, "rebar.config.script", @script), else: contents
    TracerFixtures.hex_release(home, app, Map.keys(contents), contents)
  end

  test "closure dependencies Mix does not build, and compiled ones outside it", %{tmp_dir: dir} do
    home = Path.join(dir, "hex")
    lib = Path.join(dir, "_build/host/lib")

    releases =
      Map.new([
        release(home, "r3_dep", true),
        # Review L1: a closure dependency whose manager the closure line
        # leaves unknown is checked too.
        release(home, "unknown_dep", true),
        release(home, "mix_dep", true),
        release(home, "plain_dep", false),
        release(home, "outside_built", true),
        release(home, "outside_unbuilt", true)
      ])

    File.mkdir_p!(Path.join(lib, "outside_built"))
    File.write!(Path.join(lib, "outside_built/mix.rebar.config"), "{erl_opts,[]}.\n")

    dep = fn manager -> %{manager: manager, build: Path.join(lib, "x"), children: []} end

    ctx = %Context{
      hex: {home, releases},
      deps: %{
        "r3_dep" => dep.("rebar3"),
        "unknown_dep" => dep.(nil),
        "mix_dep" => dep.("mix"),
        "plain_dep" => dep.("rebar3")
      }
    }

    assert Portability.scripted_apps(ctx, lib) |> Enum.map(&elem(&1, 0)) ==
             ["outside_built", "r3_dep", "unknown_dep"]
  end
end
