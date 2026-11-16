defmodule NccWorker.Tracer.FixturesWindowSweepTest do
  # The driver's sweep at each window boundary on real traced compiles. The
  # worker asks for it (`NCC_TRACE_SWEEP`, its own start time as pid 1) only
  # in its container; anywhere else the sweep cannot run, and a trace that
  # was asked to sweep and could not is never judged. A sweep that kills
  # runs only in a container (the worker's integration tests): here pid 1 is
  # never the worker, so nothing is ever killed.
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.TracerFixtures

  @moduletag :tmp_dir
  @moduletag timeout: 600_000

  defp project(dir) do
    TracerFixtures.project(dir, ["fx_a", "fx_b"], %{
      "fx_a" => TracerFixtures.lib("fx_a", "defmodule FxA do\nend\n"),
      "fx_b" => TracerFixtures.lib("fx_b", "defmodule FxB do\nend\n", %{deps: ["fx_a"]})
    })
  end

  test "a trace asked to sweep where it cannot fails at its first window", %{tmp_dir: dir} do
    traced =
      TracerFixtures.trace(project(dir), ["fx_b"], extra_env: [{"NCC_TRACE_SWEEP", "-1"}])

    assert {:error, :window_sweep_failed} = traced.result, traced.log
    assert traced.report.start["window_sweep"] == true
    assert [%{app: "fx_a", result: "unavailable"}] = traced.report.sweeps

    assert "processes left running in fx_a's window could not be stopped" in traced.report.problems

    assert traced.log =~ "could not be stopped"
    # fx_b never compiled.
    assert Enum.map(traced.report.windows, & &1.app) == ["fx_a"]
  end

  test "a trace not asked to sweep sweeps nothing", %{tmp_dir: dir} do
    traced = TracerFixtures.trace(project(dir), ["fx_b"])

    assert {:ok, 0} = traced.result, traced.log
    assert traced.report.start["window_sweep"] == false
    assert traced.report.sweeps == []
    assert traced.report.problems == []
  end

  test "the verdict of a trace whose sweep failed is could-not-judge", %{tmp_dir: dir} do
    proj = project(dir)

    verdict =
      NccWorker.Portability.run(proj, "fx_b",
        env: TracerFixtures.env(proj),
        releases: {:ok, %{}},
        trace_dir: Path.join(dir, "trace"),
        extra_env: [{"NCC_TRACE_SWEEP", "-1"}],
        timeout_ms: 240_000
      )

    assert %{status: :skip, reason: "portability could not be judged"} = verdict
    stats = verdict.observations["trace_stats"]
    assert stats["tracer_error"] == "window_sweep_failed"
    assert stats["transient"] == true

    assert "processes left running in a window of the traced compile could not be stopped" in verdict.observations[
             "problems"
           ]
  end

  # A compile that looks a name up (rustler_precompiled's download of its NIF)
  # would make the Mix VM start the native resolver, `inet_gethost`, a port
  # program it restarts the moment it is killed: no window sweep could clear
  # it. The traced VM resolves with Erlang's own resolver, as the worker does.
  test "the traced VM never starts the native resolver", %{tmp_dir: dir} do
    source = """
    defmodule FxLookup do
      @lookup :inet_db.res_option(:lookup)
      File.write!(Path.join(__DIR__, "../lookup.txt"), inspect(@lookup))
      def lookup, do: @lookup
    end
    """

    proj =
      TracerFixtures.project(dir, ["fx_lookup"], %{
        "fx_lookup" => TracerFixtures.lib("fx_lookup", source)
      })

    traced = TracerFixtures.trace(proj, ["fx_lookup"])
    assert {:ok, 0} = traced.result, traced.log
    assert File.read!(Path.join([proj, "deps", "fx_lookup", "lookup.txt"])) == "[:file, :dns]"
  end
end
