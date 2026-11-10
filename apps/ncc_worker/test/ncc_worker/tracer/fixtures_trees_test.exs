defmodule NccWorker.Tracer.FixturesTreesTest do
  # Item 5e on real traced compiles: a package that lists and reads its own
  # tarball files at compile time, with its tree matching the tarball, with
  # an extra file, with a file modified and restored around the compile,
  # and with a file added after it.
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.Portability.Trees
  alias NccWorker.TracerFixtures

  import NccWorker.TracerFixtures, only: [mix_exs: 2]

  @moduletag timeout: 900_000

  @mix_exs mix_exs("fx_tree", "")
  @source """
  defmodule FxTree do
    @assets Path.wildcard("lib/assets/**") |> Enum.reject(&File.dir?/1) |> Enum.sort()
    @bodies Enum.map(@assets, &File.read!/1)
    def bodies, do: @bodies
  end
  """
  @contents %{
    "mix.exs" => @mix_exs,
    "lib/fx_tree.ex" => @source,
    "lib/assets/a.js" => "export default 1;\n"
  }
  @dep %{mix_exs: @mix_exs, files: Map.delete(@contents, "mix.exs")}

  @groups %{
    "clean" => {&__MODULE__.noop/1, &__MODULE__.noop/1},
    "extra" => {&__MODULE__.add_extra/1, &__MODULE__.noop/1},
    "restored" => {&__MODULE__.modify/1, &__MODULE__.restore/1},
    "late" => {&__MODULE__.noop/1, &__MODULE__.add_extra/1}
  }

  def noop(_proj), do: :ok
  def add_extra(proj), do: File.write!(asset(proj, "extra.js"), "export default 9;\n")
  def modify(proj), do: File.write!(asset(proj, "a.js"), "export default 666;\n")
  def restore(proj), do: File.write!(asset(proj, "a.js"), @contents["lib/assets/a.js"])
  defp asset(proj, name), do: Path.join([proj, "deps", "fx_tree", "lib", "assets", name])

  setup_all do
    root =
      Path.join(System.tmp_dir!(), "ncc-fixtures-trees-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)
    hex_home = Path.join(root, "hex")

    {app, release} =
      TracerFixtures.hex_release(hex_home, "fx_tree", Map.keys(@contents), @contents)

    releases = %{app => release}

    runs =
      @groups
      |> Task.async_stream(
        fn {name, {before, after_trace}} ->
          proj = TracerFixtures.project(Path.join(root, name), ["fx_tree"], %{"fx_tree" => @dep})
          before.(proj)
          trees = Trees.snapshot(proj, releases, hex_home, [])
          traced = TracerFixtures.trace(proj, ["fx_tree"])
          after_trace.(proj)
          {name, %{proj: proj, traced: traced, trees: trees}}
        end,
        timeout: :infinity,
        ordered: false
      )
      |> Map.new(fn {:ok, run} -> run end)

    %{runs: runs, opts: [releases: releases, hex_home: hex_home]}
  end

  defp verdict(ctx, name) do
    run = ctx.runs[name]
    assert {:ok, 0} = run.traced.result, run.traced.log
    TracerFixtures.judge(run.proj, "fx_tree", run.traced, [], ctx.opts ++ [trees: run.trees])
  end

  @differs "dependency tree differs from its tarball: "

  test "a tree that matches its tarball is publishable", ctx do
    assert %{status: :pass} = v = verdict(ctx, "clean")
    assert v.observations["tree_check"] == %{"fx_tree" => "ok"}
  end

  test "an extra file before the compile refuses", ctx do
    assert %{reason: @differs <> "fx_tree (extra file lib/assets/extra.js)"} =
             v = verdict(ctx, "extra")

    assert v.observations["tree_check"] == %{
             "fx_tree" => "differs: extra file lib/assets/extra.js"
           }
  end

  test "a file modified and restored around the compile refuses", ctx do
    assert %{reason: @differs <> "fx_tree (modified file lib/assets/a.js)"} =
             verdict(ctx, "restored")
  end

  # The tree matched before the compile, so this is no refusal: the files
  # the compile listed are no longer the ones the snapshot proved, and the
  # build cannot be judged (fail closed).
  test "a file added to a listed directory after the compile cannot be judged", ctx do
    assert %{status: :skip, reason: "portability could not be judged"} =
             v = verdict(ctx, "late")

    assert Enum.any?(
             v.observations["problems"],
             &String.contains?(
               &1,
               "dependency tree changed after the check: fx_tree (listing lib/assets)"
             )
           ),
           inspect(v.observations["problems"])
  end

  test "without a snapshot no tree is checked", ctx do
    run = ctx.runs["extra"]
    v = TracerFixtures.judge(run.proj, "fx_tree", run.traced, [], ctx.opts)
    refute v.reason =~ @differs
    assert v.observations["tree_check"] == %{}
  end
end
