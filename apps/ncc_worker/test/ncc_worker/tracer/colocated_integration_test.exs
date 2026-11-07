defmodule NccWorker.Tracer.ColocatedIntegrationTest do
  @moduledoc """
  The spec's B1 fixture with the real phoenix_live_view: a component with a
  ColocatedHook writes under `_build/<env>/phoenix-colocated/<app>` while it
  compiles, which a precompiled install never produces. Needs Hex.pm; runs
  `mix deps.get` in its own temporary fixture project, never in this repo.

      mix test --include integration apps/ncc_worker/test/ncc_worker/tracer/colocated_integration_test.exs
  """
  use ExUnit.Case, async: false

  alias NccWorker.{Portability, TracerFixtures}

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 1_200_000

  test "a ColocatedHook in ~H refuses on its compile-time write", %{tmp_dir: dir} do
    proj =
      TracerFixtures.project(dir, ["fx_colocated"], %{
        "fx_colocated" => %{
          mix_exs: """
          defmodule FxColocated.MixProject do
            use Mix.Project
            def project, do: [app: :fx_colocated, version: "0.1.0", deps: [{:phoenix_live_view, "1.2.13"}]]
          end
          """,
          files: %{
            "lib/fx_colocated.ex" => ~S'''
            defmodule FxColocated do
              use Phoenix.Component

              def hook(assigns) do
                ~H"""
                <div id="fx" phx-hook=".Hook"></div>
                <script :type={Phoenix.LiveView.ColocatedHook} name=".Hook">
                  export default { mounted() {} }
                </script>
                """
              end
            end
            '''
          }
        }
      })

    # The run's own Hex cache: the tarballs deps.get verifies are the
    # source lists the judge reads dependency files against.
    hex_home = Path.join(dir, "hex-home")
    File.mkdir_p!(hex_home)
    hex_env = [{"HEX_HOME", hex_home}]

    {out, 0} =
      System.cmd("mix", ["deps.get"],
        cd: proj,
        env: TracerFixtures.env(proj) ++ hex_env,
        stderr_to_stdout: true
      )

    {:ok, releases} = Portability.lock_snapshot(proj)
    native = Portability.native_deps(proj)
    traced = TracerFixtures.trace(proj, ["fx_colocated"], native: native, extra_env: hex_env)
    assert {:ok, 0} = traced.result, out <> traced.log

    verdict =
      TracerFixtures.judge(proj, "fx_colocated", traced, native,
        releases: releases,
        hex_home: hex_home
      )

    assert verdict.status == :skip
    refusals = verdict.observations["refusals"]

    assert Enum.any?(
             refusals,
             &(&1["owner"] == "fx_colocated" and
                 &1["reason"] =~ "compile-time write outside ebin" and
                 &1["reason"] =~ "phoenix-colocated/fx_colocated")
           ),
           inspect(verdict, pretty: true, limit: :infinity)
  end
end
