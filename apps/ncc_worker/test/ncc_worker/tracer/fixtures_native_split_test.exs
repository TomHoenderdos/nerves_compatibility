defmodule NccWorker.Tracer.FixturesNativeSplitTest do
  # The native list under rule 2 (`makefile_rule2: true`, as production
  # runs it) once `NativeBuild.split/4` takes both the compile's deps dir
  # and the package under test (`package:`, judge revision 21): a natively
  # built dependency stays native whether the package option is given or
  # not. Were the option list handed over in the deps dir's place, an empty
  # one would list no `deps/` at all and every dependency would be
  # non-native: its tree checked as a tarball's, and a dependent's
  # compile-time call into it allowed. Real traced compiles, with Hex
  # releases for the build tools and the tree check.
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.{NativeBuild, Portability, TracerFixtures}
  alias NccWorker.Portability.Context

  import NccWorker.TracerFixtures, only: [mix_exs: 2]

  @moduletag timeout: 900_000

  # Natively built for rule 2: its mix.exs names elixir_make as a word.
  @nat_mix_exs mix_exs("fx_split_nat", "") <> "# built with :elixir_make\n"
  @nat %{
    "mix.exs" => @nat_mix_exs,
    "lib/fx_split_nat.ex" => "defmodule FxSplitNat do\n  def value, do: 42\nend\n"
  }

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "ncc-fixtures-native-split-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    home = Path.join(root, "hex")

    user_lib = "defmodule FxSplitUser do\n  @x FxSplitNat.value()\n  def x, do: @x\nend\n"

    deps = %{
      "fx_split_nat" => %{mix_exs: @nat_mix_exs, files: Map.delete(@nat, "mix.exs")},
      "fx_split_user" => TracerFixtures.lib("fx_split_user", user_lib, %{deps: ["fx_split_nat"]})
    }

    proj = TracerFixtures.project(Path.join(root, "p"), ["fx_split_user"], deps)

    # Each release holds the files as the fixture wrote them.
    releases =
      Map.new(~w(fx_split_nat fx_split_user), fn app ->
        files = ["mix.exs", "lib/#{app}.ex"]
        contents = Map.new(files, &{&1, File.read!(Path.join([proj, "deps", app, &1]))})

        TracerFixtures.hex_release(home, app, files, contents, [{"build_tools", ["mix"]}])
      end)

    snap = [releases: {:ok, releases}, hex_home: home, makefile_rule2: true]
    tarball_of = &Context.release_tarball(home, releases, &1)

    splits = %{
      none: NativeBuild.split(proj, tarball_of),
      deps: NativeBuild.split(proj, tarball_of, Path.join(proj, "deps")),
      package: NativeBuild.split(proj, tarball_of, nil, package: "fx_split_user"),
      both: NativeBuild.split(proj, tarball_of, Path.join(proj, "deps"), package: "fx_split_user")
    }

    trees = %{
      without: Portability.tree_snapshot(proj, snap),
      with: Portability.tree_snapshot(proj, snap ++ [package: "fx_split_user"])
    }

    verdict =
      Portability.run(proj, "fx_split_user",
        env: TracerFixtures.env(proj),
        releases: {:ok, releases},
        hex_home: home,
        trees: trees.without,
        makefile_rule2: true,
        mode: :judge,
        trace_dir: Path.join(root, "trace"),
        log_file: Path.join(root, "trace.log"),
        timeout_ms: 240_000,
        run_started_at: System.monotonic_time(:second)
      )

    %{proj: proj, tarball_of: tarball_of, splits: splits, trees: trees, verdict: verdict}
  end

  test "the native dependency stays native with and without the package option", ctx do
    for {how, split} <- ctx.splits do
      assert {["fx_split_nat"], declassified} = split, inspect(how)
      refute Map.has_key?(declassified, "fx_split_nat"), inspect(how)
    end
  end

  test "an option list in the deps dir's place raises, never reads no deps/", ctx do
    for opts <- [[], [package: "fx_split_user"]] do
      assert_raise FunctionClauseError, fn ->
        NativeBuild.split(ctx.proj, ctx.tarball_of, opts)
      end
    end
  end

  test "the tree snapshot leaves the native dependency unverified either way", ctx do
    for {how, trees} <- ctx.trees do
      assert trees["fx_split_nat"] == {:unverified, "native build"}, inspect(how)
      assert {:ok, _members} = trees["fx_split_user"], inspect(how)
    end
  end

  test "the dependent's compile-time call into the native dependency refuses", ctx do
    v = ctx.verdict

    assert %{
             status: :skip,
             reason: "calls natively built dependency at compile time: FxSplitNat.value/0"
           } = v,
           inspect({v.reason, v.observations["problems"]})
  end
end
