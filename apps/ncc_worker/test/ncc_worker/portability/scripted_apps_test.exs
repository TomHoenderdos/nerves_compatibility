defmodule NccWorker.Portability.ScriptedAppsTest do
  # `NccWorker.Portability.script_releases/1`: the locked releases whose
  # rebar.config.script Mix may have evaluated, and whether each is a
  # reviewed one (`ReviewedScripts`), when a varied read was of the plain
  # arguments.
  use ExUnit.Case, async: true

  alias NccWorker.Portability
  alias NccWorker.Portability.Context
  alias NccWorker.TracerFixtures

  @moduletag :tmp_dir

  @gproc Path.join(__DIR__, "../../fixtures/rebar/gproc-1.2.0")

  defp gproc_files do
    for path <- ~w(rebar.config.script priv/check_edown.script priv/remove_deps.script
                   src/gproc.app.src.script),
        into: %{"rebar.config" => "{erl_opts, []}.\n"},
        do: {path, File.read!(Path.join(@gproc, path))}
  end

  defp release(home, app, files, meta \\ []) do
    files = Map.put_new(files, "rebar.config", "{erl_opts, []}.\n")
    TracerFixtures.hex_release(home, app, Map.keys(files), files, meta)
  end

  test "every release Mix may have scripted, reviewed or not, or unverified", %{tmp_dir: dir} do
    home = Path.join(dir, "hex")
    script = %{"rebar.config.script" => "CONFIG.\n"}

    releases =
      Map.new([
        release(home, "gproc", gproc_files(), [{"version", "1.2.0"}]),
        release(home, "r3_dep", script),
        # Review L1: a closure dependency whose manager the closure line
        # leaves unknown is counted too.
        release(home, "unknown_dep", script),
        release(home, "mix_dep", script),
        release(home, "plain_dep", %{}),
        release(home, "outside", script),
        # Review N5: a script member that is a link.
        release(home, "linked", %{
          "real.script" => "CONFIG.\n",
          "rebar.config.script" => {:symlink, "real.script"}
        }),
        # A script on disk its tarball does not hold.
        release(home, "on_disk", %{})
      ])
      # A release whose tarball is not in the cache cannot be told.
      |> Map.put("gone", %{name: "gone", version: "1.0.0", checksum: String.duplicate("0", 64)})

    dep = fn manager -> %{manager: manager, build: Path.join(dir, "x"), children: []} end

    deps_path = Path.join(dir, "deps")
    File.mkdir_p!(Path.join(deps_path, "on_disk"))
    File.write!(Path.join([deps_path, "on_disk", "rebar.config.script"]), "CONFIG.\n")

    ctx = %Context{
      deps_path: deps_path,
      hex: {home, releases},
      deps: %{
        "gproc" => dep.("rebar3"),
        "r3_dep" => dep.("rebar3"),
        "unknown_dep" => dep.(nil),
        "mix_dep" => dep.("mix"),
        "plain_dep" => dep.("rebar3")
      }
    }

    assert Portability.script_releases(ctx) == [
             %{app: "gone", release: nil, status: :unverified, why: "no verified tarball"},
             %{app: "gproc", release: "gproc 1.2.0", status: :reviewed},
             %{
               app: "linked",
               release: nil,
               status: :unverified,
               why: "rebar.config.script is a symlink in its tarball"
             },
             %{
               app: "on_disk",
               release: nil,
               status: :unverified,
               why: "a rebar.config.script on disk its tarball does not hold"
             },
             %{app: "outside", release: "outside 0.1.0", status: :unreviewed},
             %{app: "r3_dep", release: "r3_dep 0.1.0", status: :unreviewed},
             %{app: "unknown_dep", release: "unknown_dep 0.1.0", status: :unreviewed}
           ]
  end
end
