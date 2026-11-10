defmodule NccWorker.Tracer.FixturesWildcardTest do
  # kino's `Kino.JS.__paths__/1` (research C3): Path.wildcard over the
  # package's own tarball files at compile time. Real traced compile.
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.TracerFixtures

  import NccWorker.TracerFixtures, only: [attr_module: 2, mix_exs: 2]

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

  # A pattern whose literal start (`lib`) is the package's own, but whose
  # `..` climbs out of it: filelib lists the climbed-to directory itself,
  # and that inner read is judged by its real path.
  @escape %{
    files: %{
      "lib/fx_wild_out.ex" => attr_module("FxWildOut", ~S|Path.wildcard("lib/*/../../../*")|),
      "lib/sub/x.txt" => "x\n"
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

    {out_app, out_release} =
      TracerFixtures.hex_release(hex_home, "fx_wild_out", [
        "lib",
        "lib/fx_wild_out.ex",
        "lib/sub",
        "lib/sub/x.txt",
        "mix.exs"
      ])

    deps = %{"fx_wild" => @dep, "fx_wild_out" => @escape}
    proj = TracerFixtures.project(root, ["fx_wild", "fx_wild_out"], deps)

    %{
      proj: proj,
      traced: TracerFixtures.trace(proj, ["fx_wild", "fx_wild_out"]),
      opts: [releases: %{app => release, out_app => out_release}, hex_home: hex_home]
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

  test "a wildcard whose .. climbs out of the package refuses on its inner listing", ctx do
    assert {:ok, 0} = ctx.traced.result, ctx.traced.log

    v = TracerFixtures.judge(ctx.proj, "fx_wild_out", ctx.traced, [], ctx.opts)
    assert %{status: :skip} = v, inspect(v)
    refusals = for %{"owner" => "fx_wild_out", "reason" => r} <- v.observations["refusals"], do: r

    assert Enum.any?(
             refusals,
             &String.starts_with?(
               &1,
               "compile-time host read: file:list_dir/1 ./lib/sub/../../.. via Path.Wildcard.list_dir/1 in "
             )
           ),
           inspect(refusals)
  end
end
