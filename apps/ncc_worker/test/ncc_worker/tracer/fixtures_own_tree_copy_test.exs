defmodule NccWorker.Tracer.FixturesOwnTreeCopyTest do
  # Judge revision 27 under the real tracer: a dependency's own `mix.exs`
  # alias copying one file of its own verified tarball onto another file of
  # that tarball with the same bytes, before Mix compiles it (phoenix's
  # `compile: [&copy_core_components/1, "compile"]`, which copies
  # `installer/templates/phx_web/components/core_components.ex.eex` onto
  # `priv/templates/phx.gen.live/core_components.ex.eex`). It passes, as the
  # package and as a closure dependency, when the package's whole tree is
  # still its verified tarball's after the compile. A copy that changes a
  # file's bytes, adds a file, is made by compiled code or by a process the
  # alias spawned, or lands in another package's tree still refuses. Starts
  # real `elixir` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.Portability.Context
  alias NccWorker.TracerFixtures

  import NccWorker.TracerFixtures, only: [lib: 3]

  @moduletag timeout: 900_000

  @tpl "<%= @name %> components\n"

  # Phoenix's shape: the alias copies a file the tarball ships twice.
  defp copying(app, body, from, to) do
    mod = Macro.camelize(app)

    """
    defmodule #{mod}.MixProject do
      use Mix.Project

      def project,
        do: [app: :#{app}, version: "0.1.0", deps: deps(), aliases: [compile: [&copy/1, "compile"]]]

      defp deps, do: []

      defp copy(_) do
        #{body}
      end
    end
    """
    |> String.replace("FROM", inspect(from))
    |> String.replace("TO", inspect(to))
  end

  @cp ~s|File.cp!(Path.join(__DIR__, FROM), Path.join(__DIR__, TO))|

  defp package(app, mix_exs, files),
    do:
      Map.merge(
        %{
          "mix.exs" => mix_exs,
          "lib/#{app}.ex" => "defmodule #{Macro.camelize(app)} do\n  def x, do: :x\nend\n"
        },
        files
      )

  defp contents do
    %{
      "fx_cp" =>
        package(
          "fx_cp",
          copying("fx_cp", @cp, "installer/core.ex.eex", "priv/templates/gen/core.ex.eex"),
          %{"installer/core.ex.eex" => @tpl, "priv/templates/gen/core.ex.eex" => @tpl}
        ),
      # The tarball's destination differs from the source: the copy changes it.
      "fx_cp_diff" =>
        package(
          "fx_cp_diff",
          copying("fx_cp_diff", @cp, "installer/core.ex.eex", "priv/templates/gen/core.ex.eex"),
          %{"installer/core.ex.eex" => @tpl, "priv/templates/gen/core.ex.eex" => "older\n"}
        ),
      # The same copy from an alias fun whose own frame stays on the stack.
      "fx_cp_frame" =>
        package(
          "fx_cp_frame",
          copying(
            "fx_cp_frame",
            "#{@cp}\n    :ok",
            "installer/core.ex.eex",
            "priv/templates/gen/core.ex.eex"
          ),
          %{"installer/core.ex.eex" => @tpl, "priv/templates/gen/core.ex.eex" => @tpl}
        ),
      # The destination is no file of the tarball.
      "fx_cp_new" =>
        package(
          "fx_cp_new",
          copying("fx_cp_new", @cp, "installer/core.ex.eex", "priv/templates/gen/new.ex.eex"),
          %{"installer/core.ex.eex" => @tpl, "priv/templates/gen/core.ex.eex" => @tpl}
        ),
      # The same copy from a process the alias spawns.
      "fx_cp_spawn" =>
        package(
          "fx_cp_spawn",
          copying(
            "fx_cp_spawn",
            "Task.await(Task.async(fn -> #{@cp} end))",
            "installer/core.ex.eex",
            "priv/templates/gen/core.ex.eex"
          ),
          %{"installer/core.ex.eex" => @tpl, "priv/templates/gen/core.ex.eex" => @tpl}
        ),
      # The same from a task whose fun keeps its own mix.exs frame.
      "fx_cp_task" =>
        package(
          "fx_cp_task",
          copying(
            "fx_cp_task",
            "Task.await(Task.async(fn ->\n      #{@cp}\n      :ok\n    end))",
            "installer/core.ex.eex",
            "priv/templates/gen/core.ex.eex"
          ),
          %{"installer/core.ex.eex" => @tpl, "priv/templates/gen/core.ex.eex" => @tpl}
        ),
      # The same copy made by its compiled code, not its mix.exs.
      "fx_cp_lib" => %{
        "mix.exs" => TracerFixtures.mix_exs("fx_cp_lib", ""),
        "lib/fx_cp_lib.ex" => """
        defmodule FxCpLib do
          root = Path.expand("..", __DIR__)
          File.cp!(Path.join(root, "installer/core.ex.eex"), Path.join(root, "priv/templates/gen/core.ex.eex"))
          def x, do: :x
        end
        """,
        "installer/core.ex.eex" => @tpl,
        "priv/templates/gen/core.ex.eex" => @tpl
      },
      # Its alias makes fx_cp's own copy, in fx_cp's tree.
      "fx_cp_other" =>
        package(
          "fx_cp_other",
          copying(
            "fx_cp_other",
            @cp,
            "../fx_cp/installer/core.ex.eex",
            "../fx_cp/priv/templates/gen/core.ex.eex"
          ),
          %{}
        )
    }
  end

  setup_all do
    # The real path: on macOS the tmp dir sits behind the /var symlink, and
    # Mix's relative priv links, computed from the unresolved path, would
    # dangle (the worker's /work is a real path).
    root =
      Path.join(
        Context.realpath(System.tmp_dir!()),
        "ncc-fixtures-own-tree-copy-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    home = Path.join(root, "hex")
    contents = contents()

    releases =
      for {app, files} <- contents,
          into: %{},
          do: TracerFixtures.hex_release(home, app, Map.keys(files), files)

    deps =
      contents
      |> Map.new(fn {app, files} ->
        {app, %{mix_exs: files["mix.exs"], files: Map.delete(files, "mix.exs")}}
      end)
      |> Map.put(
        "fx_cp_user",
        lib("fx_cp_user", "defmodule FxCpUser do\n  def x, do: FxCp.x()\nend\n", %{
          deps: ["fx_cp"]
        })
      )

    top = ~w(fx_cp fx_cp_user fx_cp_frame fx_cp_diff fx_cp_new fx_cp_spawn fx_cp_task fx_cp_lib
               fx_cp_other)
    proj = TracerFixtures.project(root, top, deps)
    traced = TracerFixtures.trace(proj, top)

    %{proj: proj, traced: traced, opts: [releases: releases, hex_home: home]}
  end

  defp verdict(ctx, package, opts \\ []),
    do: TracerFixtures.judge(ctx.proj, package, ctx.traced, [], Keyword.merge(ctx.opts, opts))

  defp show(v),
    do: inspect({v.reason, v.observations["refusals"], v.observations["problems"]}, pretty: true)

  defp copy_refusal?(v, app, mfa \\ "file:copy/2") do
    String.starts_with?(v.reason || "", "compile-time write outside ebin: #{mfa} ") and
      v.reason =~ "/#{app}/priv/templates/gen/"
  end

  test "the traced compile finished", %{traced: traced, proj: proj} do
    assert {:ok, 0} = traced.result, traced.log
    assert traced.report.problems == [], inspect(traced.report.problems)
    assert File.read!(Path.join(proj, "deps/fx_cp/priv/templates/gen/core.ex.eex")) == @tpl
  end

  test "a mix.exs alias copying its own file onto the same bytes passes", ctx do
    v = verdict(ctx, "fx_cp")
    assert %{status: :pass, reason: nil} = v, show(v)

    copies = v.observations["own_tree_copies"]
    assert Enum.any?(copies, &(&1["mfa"] == "file:copy/2"))
    assert Enum.any?(copies, &(&1["mfa"] == "file:write_file_info/3"))

    for item <- copies do
      assert %{"owner" => "fx_cp", "app" => "fx_cp", "path" => "priv/templates/gen/core.ex.eex"} =
               item
    end

    assert Enum.any?(copies, &(&1["source"] == "installer/core.ex.eex"))
  end

  test "so does a package that has it in its closure", ctx do
    v = verdict(ctx, "fx_cp_user")
    assert %{status: :pass, reason: nil} = v, show(v)
    assert v.observations["taint"] == %{}
    assert Enum.all?(v.observations["own_tree_copies"], &(&1["owner"] == "fx_cp"))
  end

  test "so does an alias fun whose own frame stays on the stack", ctx do
    v = verdict(ctx, "fx_cp_frame")
    assert %{status: :pass, reason: nil} = v, show(v)
    assert [_ | _] = copies = v.observations["own_tree_copies"]
    assert Enum.all?(copies, &(&1["file"] =~ "/deps/fx_cp_frame/mix.exs"))
  end

  test "with no verified tarball the copy refuses as before", ctx do
    v = verdict(ctx, "fx_cp", releases: %{})
    assert v.status == :skip
    assert copy_refusal?(v, "fx_cp"), show(v)

    v = verdict(ctx, "fx_cp_user", releases: %{})
    assert v.status == :skip
    assert v.reason =~ "closure dependency observed the host: fx_cp (compile-time write outside"
  end

  test "a copy that changes a file of the tarball refuses", ctx do
    v = verdict(ctx, "fx_cp_diff")
    assert v.status == :skip
    assert copy_refusal?(v, "fx_cp_diff"), show(v)
  end

  test "a copy onto a path the tarball does not hold refuses", ctx do
    v = verdict(ctx, "fx_cp_new")
    assert v.status == :skip
    assert copy_refusal?(v, "fx_cp_new"), show(v)
  end

  test "a copy from a process the alias spawned refuses", ctx do
    for app <- ["fx_cp_spawn", "fx_cp_task"] do
      v = verdict(ctx, app)
      assert v.status == :skip
      assert copy_refusal?(v, app), show(v)
    end
  end

  test "a copy the package's compiled code makes refuses", ctx do
    v = verdict(ctx, "fx_cp_lib")
    assert v.status == :skip
    assert copy_refusal?(v, "fx_cp_lib"), show(v)
  end

  test "a copy in another package's tree refuses", ctx do
    v = verdict(ctx, "fx_cp_other")
    assert v.status == :skip
    assert copy_refusal?(v, "fx_cp"), show(v)
  end
end
