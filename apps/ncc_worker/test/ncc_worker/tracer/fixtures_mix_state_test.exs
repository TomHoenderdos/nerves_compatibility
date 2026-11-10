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
    # app_path/1 returns `deps_app_path` before it reads anything else, on
    # every Elixir version (build_path/1 reads MIX_BUILD_PATH on some).
    "fx_app_path" =>
      lib("fx_app_path", """
      defmodule FxAppPath do
        @p Mix.Project.app_path(deps_app_path: "/x")
        def p, do: @p
      end
      """),
    # `@file "mix.exs"` makes a lib/ function's frame name the mix.exs; the
    # call is not a tail call, so that frame is on the stack.
    "fx_forged_file" =>
      lib("fx_forged_file", """
      defmodule FxForgedFile.Reader do
        @file "mix.exs"
        def t, do: elem({Module.concat(["Mi" <> "x"]).target()}, 0)
      end

      defmodule FxForgedFile do
        @t FxForgedFile.Reader.t()
        def t, do: @t
      end
      """),
    # The same, from a module named as the project module Mix pushed,
    # redefined in memory under the real mix.exs's path (the dependency's
    # compile runs in its directory).
    "fx_forged_project" =>
      lib("fx_forged_project", ~S'''
      defmodule FxForgedProject do
        :code.purge(FxForgedProject.MixProject)
        :code.delete(FxForgedProject.MixProject)
        :code.purge(FxForgedProject.MixProject)

        Code.compile_string("""
        defmodule FxForgedProject.MixProject do
          def project, do: [app: :fx_forged_project, version: "0.1.0", deps: []]
          def application, do: [extra_applications: [:logger]]
          def t, do: elem({Module.concat(["Mi" <> "x"]).target()}, 0)
        end
        """, Path.expand("mix.exs"))

        @t FxForgedProject.MixProject.t()
        def t, do: @t
      end
      '''),
    "fx_state_get" =>
      lib("fx_state_get", """
      defmodule FxStateGet do
        @t Module.concat(["Mix", "State"]).get(:target, :host)
        def t, do: @t
      end
      """),
    "fx_ets_lookup" =>
      lib("fx_ets_lookup", """
      defmodule FxEtsLookup do
        @t :ets.lookup(Mix.State, :target)
        def t, do: @t
      end
      """),
    # A package task whose run/1 tail-calls the read, run from another
    # package's module body: the value reaches package code.
    "fx_taskdef" =>
      lib("fx_taskdef", """
      defmodule Mix.Tasks.FxTask do
        use Mix.Task
        def run(_), do: Module.concat(["Mi" <> "x"]).target()
      end
      """),
    "fx_taskuse" =>
      lib(
        "fx_taskuse",
        """
        defmodule FxTaskuse do
          @t Mix.Task.run("fx_task")
          def t, do: @t
        end
        """,
        %{deps: ["fx_taskdef"]}
      ),
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

  # Observed only; the verdict is not asserted: what else a path function
  # reads (MIX_BUILD_PATH) depends on the Elixir version.
  test "Mix.Project.app_path is observed, never refused by mix_state", ctx do
    %{observations: obs} = verdict(ctx, "fx_app_path")

    assert Enum.any?(
             obs["mix_project_paths"],
             &(&1["owner"] == "fx_app_path" and &1["mfa"] == "Mix.Project.app_path/1")
           ),
           inspect(obs["mix_project_paths"])

    refute Enum.any?(obs["refusals"], &String.contains?(&1["reason"], "Mix.")),
           inspect(obs["refusals"])
  end

  test "Mix.Project.config/0 is not traced", ctx do
    assert %{status: :pass} = verdict(ctx, "fx_project_version")
  end

  test "a lib/ frame naming mix.exs with @file refuses", ctx do
    for app <- ["fx_forged_file", "fx_forged_project"] do
      assert %{status: :skip, reason: "compile-time host read: Mix.target/0" <> _} =
               verdict(ctx, app),
             app
    end
  end

  test "Mix.State and its table read for the target refuse", ctx do
    assert %{status: :skip, reason: "compile-time host read: Mix.State.get/2" <> _} =
             verdict(ctx, "fx_state_get")

    assert %{status: :skip, reason: "compile-time host read: ets:lookup/2" <> _} =
             verdict(ctx, "fx_ets_lookup")
  end

  test "a package task's Mix.target read, run from a module body, refuses", ctx do
    assert %{status: :skip, reason: "compile-time host read: " <> reason} =
             verdict(ctx, "fx_taskuse")

    assert reason =~ ~r/^(Mix\.target\/0|Mix\.State\.get\/2) /
    assert %{status: :pass} = verdict(ctx, "fx_taskdef")
  end

  test "Mix.target in a dependency's own mix.exs is not refused", ctx do
    assert %{status: :pass} = verdict(ctx, "fx_mixexs_target")
  end
end
