defmodule NccWorker.Tracer.FixturesTracerHiddenTest do
  # Starts real `elixir` and `mix` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.TracerFixtures

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  # The tracer's own modules (its ebin: `Mix.Tasks.Ncc.TraceCompile` and the
  # `ncc_tracer*` modules) exist in no untraced compile. Two ways a compile
  # met them although it named none of them (coverage drop 2026-11-22, F1).

  defp mix(proj, args) do
    {out, status} =
      System.cmd("mix", args, cd: proj, env: TracerFixtures.env(proj), stderr_to_stdout: true)

    assert status == 0, out
    out
  end

  defp tracer_probes(traced) do
    Enum.filter(traced.report.events, fn e ->
      e["channel"] == "probe" and e["arg"]["app"] == "ncc_tracer"
    end)
  end

  defp tracer_problems(verdict) do
    Enum.filter(verdict.observations["problems"] || [], &(&1 =~ "ncc_tracer"))
  end

  # Mix evaluates every dependency's mix.exs before it prunes the code path
  # for the first compile, so a scan there (`Mix.Task.load_all/0`) walks
  # the whole path the VM started with: the tracer's ebin too, which an
  # untraced compile does not have.
  test "a mix.exs scan of the code path finds none of the tracer's modules", %{tmp_dir: dir} do
    proj =
      TracerFixtures.project(dir, ["fx_scan"], %{
        "fx_scan" => %{
          mix_exs: """
          defmodule FxScan.MixProject do
            use Mix.Project
            IO.puts("FX_SCAN=" <> inspect(Enum.filter(Mix.Task.load_all(), &(inspect(&1) =~ "Ncc"))))
            def project, do: [app: :fx_scan, version: "0.1.0", deps: []]
          end
          """,
          files: %{"lib/fx_scan.ex" => TracerFixtures.attr_module("FxScan", ":ok")}
        }
      })

    assert mix(proj, ["compile"]) =~ "FX_SCAN=[]\n"

    File.rm_rf!(Path.join(proj, "_build"))
    traced = TracerFixtures.trace(proj, ["fx_scan"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log
    assert traced.log =~ "FX_SCAN=[]\n"
    assert tracer_probes(traced) == []

    verdict = TracerFixtures.judge(proj, "fx_scan", traced)
    assert tracer_problems(verdict) == []
  end

  # A Mix compiler runs in the driver's process, so a warning it prints
  # formats a stack that holds the driver's frames, and
  # `Exception.format_application/1` asks the application controller which
  # application holds each frame's module. The tracer loads no application,
  # so the answer for its own module is `undefined`, as it is untraced.
  test "a warning's stack through the driver's frames is no concern", %{tmp_dir: dir} do
    proj =
      TracerFixtures.project(dir, ["fx_scan"], %{
        "fx_tool" => %{
          files: %{
            "lib/fx_tool.ex" => """
            defmodule Mix.Tasks.Compile.Fxwarn do
              use Mix.Task.Compiler
              def run(_args) do
                IO.warn("the :fxwarn compiler is deprecated")
                :noop
              end
            end
            """
          }
        },
        "fx_scan" => %{
          deps: ["fx_tool"],
          mix_exs: """
          defmodule FxScan.MixProject do
            use Mix.Project
            def project do
              [app: :fx_scan, version: "0.1.0", compilers: [:fxwarn] ++ Mix.compilers(),
               deps: [{:fx_tool, path: "../fx_tool"}]]
            end
          end
          """,
          files: %{"lib/fx_scan.ex" => TracerFixtures.attr_module("FxScan", ":ok")}
        }
      })

    traced = TracerFixtures.trace(proj, ["fx_scan"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log
    assert traced.log =~ "the :fxwarn compiler is deprecated"

    # The event shape (pinned on this toolchain).
    assert [lookup | _] = tracer_probes(traced)
    assert lookup["mfa"] == "application_controller:get_application_module/1"
    assert lookup["arg"]["module"] == "Elixir.Mix.Tasks.Ncc.TraceCompile"
    assert lookup["arg"]["by_package"] == false
    assert lookup["caller"]["module"] == "Elixir.Exception"
    assert lookup["caller"]["function"] == "format_application"

    assert Enum.all?(
             tracer_probes(traced),
             &(&1["mfa"] == "application_controller:get_application_module/1")
           )

    verdict = TracerFixtures.judge(proj, "fx_scan", traced)
    assert tracer_problems(verdict) == []
    assert %{status: :pass} = verdict, inspect(Map.take(verdict, [:reason, :observations]))
  end
end
