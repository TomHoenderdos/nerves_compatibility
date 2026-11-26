defmodule NccWorker.Tracer.FixturesDefinedModulesTest do
  # Starts real `elixir` and `mix` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.TracerFixtures

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  # S10 fix round 1 (the client review's B2/B3): a package's modules are
  # more than its ebin. A compile can define modules in memory that a later
  # dependency's compile in the same VM finds: the `.exs` its `mix.exs` or
  # its `lib/` loads, `Code.compile_string/2`, `Module.create/3`. The tracer
  # lists every module loaded at the end that no ebin holds, with the
  # source its compile names, and the judge attributes each to the closure
  # application whose dir holds that source: the package's are its
  # `defined_modules`, which the portal serves beside its ebin and client
  # 0.10 reads as the package's exact module list.
  # A helper the `mix.exs` defines (a `Code.require_file/2` there reads the
  # cwd, a host read the judge refuses).
  @mix_exs """
  defmodule FxDefMixHelper do
    def x, do: 1
  end

  defmodule FxDef.MixProject do
    use Mix.Project
    def project, do: [app: :fx_def, version: "0.1.0", deps: []]
    def application, do: [extra_applications: [:logger]]
  end
  """

  defp project(dir, lib) do
    TracerFixtures.project(dir, ["fx_def"], %{
      "fx_def" => %{
        mix_exs: @mix_exs,
        files: %{
          "lib/fx_def.ex" => lib
        }
      }
    })
  end

  test "the package's in-memory modules are its defined_modules", %{tmp_dir: dir} do
    lib = """
    defmodule FxDef do
      Module.create(FxDef.Made, quote(do: def(x, do: 3)), Macro.Env.location(__ENV__))
      def x, do: FxDef.Made.x()
    end
    """

    proj = project(dir, lib)
    traced = TracerFixtures.trace(proj, ["fx_def"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log

    names = for %{"module" => m} <- traced.report.ending["in_memory"], do: m
    assert "Elixir.FxDefMixHelper" in names
    assert traced.report.ending["in_memory_over"] == false

    # What a compiled file defines, `Module.create/3` in a module body
    # included, the compiler writes to the ebin: the manifest lists those.
    ebin = Path.join([proj, "_build", "host", "lib", "fx_def", "ebin"])

    for m <- ~w(Elixir.FxDef Elixir.FxDef.Made),
        do: assert(File.regular?(Path.join(ebin, m <> ".beam")), m)

    refute "Elixir.FxDef.Made" in names

    # The rest: the package's `mix.exs` and the helper it defines. Not the
    # wrapper project's own `mix.exs`, nor Elixir's `elixir_compiler_<n>`.
    verdict = TracerFixtures.judge(proj, "fx_def", traced)
    assert %{status: :pass} = verdict, inspect(Map.take(verdict, [:reason, :observations]))
    assert verdict.defined_modules == ~w(Elixir.FxDef.MixProject Elixir.FxDefMixHelper)
  end
end
