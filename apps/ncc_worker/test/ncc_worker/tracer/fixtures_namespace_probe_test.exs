defmodule NccWorker.Tracer.FixturesNamespaceProbeTest do
  # Starts real `elixir` and `mix` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.TracerFixtures

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  # Coverage drop 2026-11-22, F6: eventstore 1.4.x asks
  # `Code.ensure_loaded?(Postgrex.Timestamp)` with postgrex 0.23 locked,
  # which does not define it. fx_pg stands in for postgrex: its verified
  # tarball defines `FxPg` and not `FxPg.Timestamp`. Every user with this
  # closure has that release, so the probe is recorded for the portal's
  # module-index gate, as a declared-absent one is, rather than refused.
  defp project(dir, probe) do
    TracerFixtures.project(dir, ["fx_probe"], %{
      "fx_pg" => %{files: %{"lib/fx_pg.ex" => "defmodule FxPg do\n  def f, do: 1\nend\n"}},
      "fx_probe" => %{
        deps: ["fx_pg"],
        files: %{"lib/fx_probe.ex" => TracerFixtures.attr_module("FxProbe", probe)}
      }
    })
  end

  defp opts(dir, sources) do
    home = Path.join(dir, "hex")
    {app, release} = TracerFixtures.hex_release(home, "fx_pg", ["lib"], sources)
    [releases: %{app => release}, hex_home: home]
  end

  test "a probe of an absent module under a closure package's namespace is recorded",
       %{tmp_dir: dir} do
    proj = project(dir, "Code.ensure_loaded?(FxPg.Timestamp)")
    traced = TracerFixtures.trace(proj, ["fx_probe"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log

    sources = %{"lib/fx_pg.ex" => "defmodule FxPg do\n  def f, do: 1\nend\n"}
    verdict = TracerFixtures.judge(proj, "fx_probe", traced, [], opts(dir, sources))
    assert %{status: :pass} = verdict, inspect(Map.take(verdict, [:reason, :observations]))

    assert verdict.observations["declared_absent"] == [
             %{
               "kind" => "module_absent",
               "module" => "Elixir.FxPg.Timestamp",
               "declared" => [],
               "declared_apps" => [],
               "namespace" => "fx_pg",
               "via" => "Code.ensure_loaded?/1"
             }
           ]

    # A tarball that defines the probed module too (here behind a probe of
    # its own, so the build left it out): refused, as before.
    guarded =
      sources
      |> Map.put("lib/fx_pg/timestamp.ex", """
      if Code.ensure_loaded?(:fx_absent) do
        defmodule FxPg.Timestamp do
        end
      end
      """)

    assert %{status: :skip, reason: reason} =
             TracerFixtures.judge(
               proj,
               "fx_probe",
               traced,
               [],
               opts(Path.join(dir, "g"), guarded)
             )

    assert reason ==
             "compile-time probe of a dependency outside the closure: Elixir.FxPg.Timestamp via " <>
               "Code.ensure_loaded?/1"
  end
end
