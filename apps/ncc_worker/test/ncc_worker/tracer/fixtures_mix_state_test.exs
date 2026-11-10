defmodule NccWorker.Tracer.FixturesMixStateTest do
  # Real traced compiles (the :real_vm group) of packages that read Mix state
  # through a module name the static target grep cannot see.
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.TracerFixtures

  import NccWorker.TracerFixtures, only: [lib: 2, lib: 3, mix_exs: 2]

  @moduletag timeout: 600_000

  @deps %{
    "fx_dyn_target" =>
      lib("fx_dyn_target", """
      defmodule FxDynTarget do
        @t Module.concat(["Mi" <> "x"]).target()
        def t, do: @t
      end
      """),
    "fx_build_path" =>
      lib("fx_build_path", """
      defmodule FxBuildPath do
        @rpi String.contains?(Mix.Project.build_path(), "rpi")
        def rpi?, do: @rpi
      end
      """),
    "fx_project_version" =>
      lib("fx_project_version", """
      defmodule FxProjectVersion do
        @v Mix.Project.config()[:version]
        def v, do: @v
      end
      """),
    "fx_mixexs_target" =>
      lib("fx_mixexs_target", "defmodule FxMixexsTarget do\nend\n", %{
        mix_exs:
          mix_exs(
            "fx_mixexs_target",
            ~s|, description: to_string(Module.concat(["Mi" <> "x"]).target())|
          )
      })
  }

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "ncc-fixtures-mix-state-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    proj = TracerFixtures.project(root, Map.keys(@deps), @deps)
    %{proj: proj, traced: TracerFixtures.trace(proj, Map.keys(@deps))}
  end

  defp verdict(ctx, app), do: TracerFixtures.judge(ctx.proj, app, ctx.traced)

  test "the traced compile completed", ctx do
    assert {:ok, 0} = ctx.traced.result, ctx.traced.log
  end

  test "a dynamic Mix.target read in a module body refuses", ctx do
    assert %{status: :skip, reason: "compile-time host read: Mix.target/0" <> _} =
             verdict(ctx, "fx_dyn_target")
  end

  # Mix.Project.build_path/1 reads MIX_BUILD_PATH itself (System.get_env/1),
  # which the env channel refused before mix_state existed: the observation
  # is new, the refusal is not, and it is not the mix_state channel's.
  test "Mix.Project.build_path is observed, not refused by mix_state; config/0 passes", ctx do
    assert %{status: :skip, reason: "compile-time host read: os:getenv/1" <> _, observations: obs} =
             verdict(ctx, "fx_build_path")

    refute Enum.any?(obs["refusals"], &String.contains?(&1["reason"], "Mix.")),
           inspect(obs["refusals"])

    assert Enum.any?(
             obs["mix_project_paths"],
             &(&1["owner"] == "fx_build_path" and &1["mfa"] == "Mix.Project.build_path/0")
           ),
           inspect(obs["mix_project_paths"])

    assert %{status: :pass} = verdict(ctx, "fx_project_version")
  end

  test "Mix.target in a dependency's own mix.exs is not refused", ctx do
    assert %{status: :pass} = verdict(ctx, "fx_mixexs_target")
  end
end
