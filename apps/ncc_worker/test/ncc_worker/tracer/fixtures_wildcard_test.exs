defmodule NccWorker.Tracer.FixturesWildcardTest do
  # kino's `Kino.JS.__paths__/1` (research C3): Path.wildcard over the
  # package's own tarball files at compile time. Real traced compile.
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.TracerFixtures

  import NccWorker.TracerFixtures, only: [mix_exs: 2]

  @moduletag timeout: 600_000

  @dep %{
    mix_exs: mix_exs("fx_wild", ""),
    files: %{
      "lib/fx_wild.ex" => """
      defmodule FxWild do
        @assets Path.wildcard("lib/assets/**") |> Enum.reject(&File.dir?/1) |> Enum.sort()
        @bodies Enum.map(@assets, &File.read!/1)
        def bodies, do: @bodies
      end
      """,
      "lib/assets/a.js" => "export default 1;\n",
      "lib/assets/b/c.js" => "export default 2;\n"
    }
  }

  setup_all do
    root =
      Path.join(System.tmp_dir!(), "ncc-fixtures-wildcard-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)
    hex_home = Path.join(root, "hex")

    files = [
      "lib",
      "lib/assets",
      "lib/assets/a.js",
      "lib/assets/b/c.js",
      "lib/fx_wild.ex",
      "mix.exs"
    ]

    {app, release} = TracerFixtures.hex_release(hex_home, "fx_wild", files)
    proj = TracerFixtures.project(root, ["fx_wild"], %{"fx_wild" => @dep})

    %{
      proj: proj,
      traced: TracerFixtures.trace(proj, ["fx_wild"]),
      opts: [releases: %{app => release}, hex_home: hex_home]
    }
  end

  test "Path.wildcard over the package's own tarball files is publishable", ctx do
    assert {:ok, 0} = ctx.traced.result, ctx.traced.log

    assert Enum.any?(
             ctx.traced.report.events,
             &(&1["mfa"] == "filelib:wildcard/2" and &1["arg"]["path"] == "lib/assets" and
                 &1["arg"]["listing"] == true)
           )

    v = TracerFixtures.judge(ctx.proj, "fx_wild", ctx.traced, [], ctx.opts)
    assert %{status: :pass} = v, inspect(v.observations["refusals"])
  end
end
