defmodule NccWorker.Tracer.FixturesAbsentPathsTest do
  # A dependency's mix.exs that wildcards paths its tarball does not hold
  # (opentelemetry_semantic_conventions' `guides/**/*.md`, telemetry_registry's
  # `edoc/*.md`), on real traced compiles: decided by the tree check when the
  # tree matched its tarball, a host read without a snapshot, and could not be
  # judged when such a path is there at judge time.
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.Portability.Trees
  alias NccWorker.TracerFixtures

  @moduletag timeout: 900_000

  # Like opentelemetry_semantic_conventions', project/0 is no keyword list
  # literal, so the mix.exs slice cannot clear the reads by itself.
  @mix_exs """
  defmodule FxGuides.MixProject do
    use Mix.Project

    def project do
      {app, version} = {:fx_guides, "0.1.0"}
      [app: app, version: version, deps: [], docs: [extras: guides() ++ edoc()]]
    end

    defp guides, do: Path.wildcard("guides/**/*.md")
    defp edoc, do: for(file <- Path.wildcard("edoc/*.md"), file != "edoc/README.md", do: file)
  end
  """
  @source """
  defmodule FxGuides do
    def hello, do: :world
  end
  """
  @contents %{"mix.exs" => @mix_exs, "lib/fx_guides.ex" => @source}
  @dep %{mix_exs: @mix_exs, files: Map.delete(@contents, "mix.exs")}

  @groups %{
    "clean" => &__MODULE__.noop/1,
    "late" => &__MODULE__.add_guide/1
  }

  def noop(_proj), do: :ok

  def add_guide(proj) do
    dir = Path.join([proj, "deps", "fx_guides", "guides"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.md"), "# a\n")
  end

  setup_all do
    root =
      Path.join(System.tmp_dir!(), "ncc-fixtures-absent-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)
    hex_home = Path.join(root, "hex")

    {app, release} =
      TracerFixtures.hex_release(hex_home, "fx_guides", Map.keys(@contents), @contents)

    releases = %{app => release}

    runs =
      @groups
      |> Task.async_stream(
        fn {name, after_trace} ->
          proj =
            TracerFixtures.project(Path.join(root, name), ["fx_guides"], %{"fx_guides" => @dep})

          trees = Trees.snapshot(proj, releases, hex_home, [])
          traced = TracerFixtures.trace(proj, ["fx_guides"])
          after_trace.(proj)
          {name, %{proj: proj, traced: traced, trees: trees}}
        end,
        timeout: :infinity,
        ordered: false
      )
      |> Map.new(fn {:ok, run} -> run end)

    %{runs: runs, opts: [releases: releases, hex_home: hex_home]}
  end

  defp verdict(ctx, name, opts) do
    run = ctx.runs[name]
    assert {:ok, 0} = run.traced.result, run.traced.log
    TracerFixtures.judge(run.proj, "fx_guides", run.traced, [], ctx.opts ++ opts)
  end

  test "absent paths in a matched tree are decided by the tree check", ctx do
    trees = ctx.runs["clean"].trees
    assert %{"fx_guides" => {:ok, _}} = trees
    assert %{status: :pass} = v = verdict(ctx, "clean", trees: trees)
    assert v.observations["tree_check"] == %{"fx_guides" => "ok"}
  end

  test "without a snapshot the same reads are host reads", ctx do
    assert %{status: :skip, reason: reason} = verdict(ctx, "clean", [])
    assert reason =~ "host read"
  end

  test "an absent path that is there at judge time cannot be judged", ctx do
    assert %{status: :skip, reason: "portability could not be judged"} =
             v = verdict(ctx, "late", trees: ctx.runs["late"].trees)

    assert Enum.any?(
             v.observations["problems"],
             &String.contains?(&1, "dependency tree changed after the check: fx_guides")
           ),
           inspect(v.observations["problems"])
  end
end
