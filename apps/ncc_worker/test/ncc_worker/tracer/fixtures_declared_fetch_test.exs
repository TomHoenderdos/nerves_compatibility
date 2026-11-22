defmodule NccWorker.Tracer.FixturesDeclaredFetchTest do
  # Starts real `elixir` and `mix` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.{Portability, TracerFixtures}

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @cnj "portability could not be judged"

  # Coverage drop 2026-11-22, F7: fx_probe declares fx_opt (optional) and
  # this build lacks it; fx_opt's tarball is not in the run's Hex cache, so
  # the pre-judge fetch decides whether its modules are known. A fetch that
  # failed is no verdict on the package: the probe it left unknown makes a
  # transient could-not-judge, which the portal retries. A fetch that works
  # judges as round 3 does; one that fails again stays a refusal.
  test "a probe refusal after a failed declared fetch is transient", %{tmp_dir: dir} do
    home = Path.join(dir, "hex")

    req = [
      {"name", "fx_opt"},
      {"app", "fx_opt"},
      {"optional", true},
      {"requirement", "~> 0.1"},
      {"repository", "hexpm"}
    ]

    {app, release} =
      TracerFixtures.hex_release(home, "fx_probe", ["lib", "mix.exs"], %{}, [
        {"requirements", [req]}
      ])

    proj =
      TracerFixtures.project(Path.join(dir, "p"), ["fx_probe"], %{
        "fx_probe" => %{
          files: %{
            "lib/fx_probe.ex" =>
              TracerFixtures.attr_module("FxProbe", "Code.ensure_loaded?(FxOpt.Codec)")
          }
        }
      })

    run = fn fetch, n ->
      File.rm_rf!(Path.join(proj, "_build"))

      Portability.run(proj, "fx_probe",
        env: TracerFixtures.env(proj),
        releases: %{app => release},
        hex_home: home,
        trace_dir: Path.join(dir, "trace#{n}"),
        log_file: Path.join(dir, "trace#{n}.log"),
        timeout_ms: 240_000,
        mode: :host,
        declared_fetch: fetch
      )
    end

    me = self()

    failed = fn names, _opts ->
      send(me, {:fetch, names})
      {:ok, %{fetched: [], failed: names}}
    end

    assert %{status: :skip, reason: @cnj, observations: obs} = run.(failed, 1)
    assert_received {:fetch, ["fx_opt"]}
    assert obs["trace_stats"]["transient"] == true
    assert obs["trace_stats"]["declared_unknown"] == ["fx_opt"]
    assert obs["trace_stats"]["declared_fetch"]["failed"] == ["fx_opt"]

    assert Enum.any?(
             obs["problems"],
             &(&1 =~ "declared dependencies could not be fetched: fx_opt" and
                 &1 =~ "Elixir.FxOpt.Codec via Code.ensure_loaded?/1")
           )

    # The fetch off, as the test helper sets it: the refusal stands, final.
    off = fn _names, _opts -> {:error, :off} end
    assert %{status: :skip, reason: reason, observations: obs} = run.(off, 2)
    assert reason =~ "compile-time probe of a dependency outside the closure: Elixir.FxOpt.Codec"
    assert obs["trace_stats"]["transient"] == false

    # The retry's fetch gets the tarball: judged as round 3 judges it.
    fetched = fn ["fx_opt"], opts ->
      TracerFixtures.hex_release(opts[:home], "fx_opt", ["lib"], %{
        "lib/fx_opt.ex" => "defmodule FxOpt do\n  defmodule Codec do\n  end\nend\n"
      })

      {:ok, %{fetched: ["fx_opt-0.1.0"], failed: []}}
    end

    verdict = run.(fetched, 3)
    assert %{status: :pass} = verdict, inspect(Map.take(verdict, [:reason, :observations]))
    assert [%{"module" => "Elixir.FxOpt.Codec"}] = verdict.observations["declared_absent"]
  end
end
