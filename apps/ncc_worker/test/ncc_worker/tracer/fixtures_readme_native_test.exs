defmodule NccWorker.Tracer.FixturesReadmeNativeTest do
  # Judge revision 21 under the real tracer, with rule 2 on
  # (`makefile_rule2: true`, as production runs it): a README that mentions
  # `MIX_TARGET` does not make the package under test natively built in the
  # trace, as it does not in the static rules
  # (`NccWorker.BuildSelection.static_rules/4`, `NccWorker.TargetScan`).
  #
  # On Elixir 1.20, Module.ParallelChecker reads a protocol's beam back from
  # the package's own ebin while the package compiles (fledex 0.8.1 reading
  # Fledex.Color.beam). In a natively built package's ebin that read is
  # refused (`beam_reads/5` never allows the package's own), so a README
  # mention alone refused fledex. A package that really builds native code
  # (its mix.exs names elixir_make) still refuses it.
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.{NativeBuild, Portability, TracerFixtures}
  alias NccWorker.Portability.Context
  alias NccWorker.Tracer.Report

  @moduletag timeout: 900_000

  @readme "# Fx\n\nBuild firmware with `MIX_TARGET=rpi4 mix firmware`.\n"

  # A protocol, an impl beside it and one nested in a struct's module, as
  # fledex's Fledex.Color and Fledex.Color.RGBW have them.
  defp sources(mod) do
    %{
      "lib/color.ex" => """
      defprotocol #{mod}.Color do
        def to_int(color)
      end

      defimpl #{mod}.Color, for: Integer do
        def to_int(i), do: i
      end
      """,
      "lib/rgb.ex" => """
      defmodule #{mod}.Rgb do
        defstruct r: 0

        defimpl #{mod}.Color do
          def to_int(%{r: r}), do: r
        end
      end
      """
    }
  end

  defp package(root, name, mix_exs_extra) do
    mod = Macro.camelize(name)
    mix_exs = TracerFixtures.mix_exs(name, "") <> mix_exs_extra
    files = Map.put(sources(mod), "README.md", @readme)
    contents = Map.put(files, "mix.exs", mix_exs)
    dir = Path.join(root, name)
    home = Path.join(dir, "hex")

    {app, release} =
      TracerFixtures.hex_release(home, name, Map.keys(contents), contents, [
        {"build_tools", ["mix"]}
      ])

    releases = %{app => release}
    proj = TracerFixtures.project(dir, [name], %{name => %{mix_exs: mix_exs, files: files}})
    trace_dir = Path.join(dir, "trace")

    verdict =
      Portability.run(proj, name,
        env: TracerFixtures.env(proj),
        releases: {:ok, releases},
        hex_home: home,
        trace_dir: trace_dir,
        log_file: Path.join(dir, "trace.log"),
        makefile_rule2: true
      )

    split =
      NativeBuild.split(proj, &Context.release_tarball(home, releases, &1), nil, package: name)

    %{
      verdict: verdict,
      split: split,
      proj: proj,
      report: Report.read(trace_dir),
      opts: [releases: {:ok, releases}, hex_home: home]
    }
  end

  setup_all do
    root =
      Path.join(System.tmp_dir!(), "ncc-fixtures-readme-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)

    %{
      readme: package(root, "fx_readme", ""),
      native: package(root, "fx_readme_nat", "# built with :elixir_make\n")
    }
  end

  defp problems(v), do: inspect({v.reason, v.observations["problems"]})

  test "a README mention alone leaves the package declassified for rule 2", ctx do
    assert ctx.readme.split == {[], %{"fx_readme" => "mix"}}
    assert ctx.native.split == {["fx_readme_nat"], %{}}
  end

  test "the package passes, its own protocol beam read by the parallel checker", ctx do
    v = ctx.readme.verdict
    assert %{status: :pass, reason: nil} = v, problems(v)
    assert v.manager == "mix"
  end

  test "the same trace, judged with the package natively built, refuses that read", ctx do
    %{proj: proj, report: report, opts: opts} = ctx.readme
    v = Portability.judge(proj, "fx_readme", report, ["fx_readme"], opts)

    if Version.match?(System.version(), ">= 1.20.0") do
      assert %{status: :skip, reason: "compile-time host read: " <> rest} = v, problems(v)
      assert rest =~ "fx_readme/ebin/Elixir.FxReadme.Color.beam"
      assert rest =~ "Module.ParallelChecker"
    end
  end

  test "a package that builds native code still refuses its own beam read", ctx do
    v = ctx.native.verdict

    if Version.match?(System.version(), ">= 1.20.0") do
      assert %{status: :skip, reason: "compile-time host read: " <> rest} = v, problems(v)
      assert rest =~ "fx_readme_nat/ebin/Elixir.FxReadmeNat.Color.beam"
    end
  end
end
