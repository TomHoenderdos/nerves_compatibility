defmodule NccWorker.Tracer.FixturesCheckerPoolTest do
  # Elixir's type checker sizing its pool from `schedulers_online`, on real
  # traced compiles. `Module.ParallelChecker.get/0` starts a checker with no
  # options for a module defined outside a parallel compile, and its init/1
  # reads `max(:erlang.system_info(:schedulers_online), 2)`. Started from a
  # stack with package code on it, that checker is the package's process by
  # lineage, so the read lands in the window: a Hex dependency's `mix.exs`
  # with code outside a plain `defmodule` (inflex, gen_state_machine,
  # phoenix_pubsub 1.1.2; a path dependency's `mix.exs` is evaluated before
  # every window, so a Mix alias of its own stands in for it here), and a
  # nested compile in a process of the package's. The read only caps how
  # many verification processes run at once: those builds publish, and so
  # do their dependents. The same read from any other frame still refuses.
  # Starts real `elixir` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.TracerFixtures

  import NccWorker.TracerFixtures, only: [lib: 2, lib: 3]

  @moduletag timeout: 600_000

  # A Mix alias of the dependency's own project, run in its window, that
  # defines a module through `Code.compile_string/1` and is not a tail call,
  # so the alias's own frame (the dependency's `mix.exs`) is on the stack
  # when the checker starts, as the frame of a `mix.exs` file's code is.
  @alias_mix_exs """
  defmodule FxCpAlias.MixProject do
    use Mix.Project

    def project,
      do: [app: :fx_cp_alias, version: "0.1.0", deps: [], aliases: [compile: [&helper/1, "compile"]]]

    defp helper(_args) do
      Code.compile_string("defmodule FxCpAlias.Helper do\\n  def h, do: 1\\nend\\n")
      :ok
    end
  end
  """

  @deps %{
    "fx_cp_alias" => %{
      mix_exs: @alias_mix_exs,
      files: %{"lib/fx_cp_alias.ex" => "defmodule FxCpAlias do\n  def x, do: 1\nend\n"}
    },
    # A module body compiling a module in a Task: no parallel compile in that
    # process, so `get/0` starts a checker of its own.
    "fx_cp_task" =>
      lib("fx_cp_task", """
      defmodule FxCpTask do
        _ =
          Task.async(fn ->
            Code.compile_string("defmodule FxCpTask.Inner do\\n  def y, do: 2\\nend\\n")
          end)
          |> Task.await()

        def x, do: 1
      end
      """),
    "fx_cp_user" =>
      lib(
        "fx_cp_user",
        "defmodule FxCpUser do\n  def x, do: FxCpTask.x() + FxCpAlias.x()\nend\n",
        %{deps: ["fx_cp_task", "fx_cp_alias"]}
      ),
    # The count baked into a module attribute.
    "fx_cp_body" =>
      lib("fx_cp_body", """
      defmodule FxCpBody do
        @n System.schedulers_online()
        def n, do: @n
      end
      """),
    # codepagex: `Task.async_stream/3`'s default `:max_concurrency`.
    "fx_cp_stream" =>
      lib("fx_cp_stream", """
      defmodule FxCpStream do
        @l [1, 2] |> Task.async_stream(& &1) |> Enum.map(fn {:ok, v} -> v end)
        def l, do: @l
      end
      """),
    "fx_cp_body_user" =>
      lib("fx_cp_body_user", "defmodule FxCpBodyUser do\n  def n, do: FxCpBody.n()\nend\n", %{
        deps: ["fx_cp_body"]
      })
  }

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "ncc-fixtures-checker-pool-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    proj = TracerFixtures.project(Path.join(root, "p"), Map.keys(@deps), @deps)
    %{proj: proj, traced: TracerFixtures.trace(proj, Map.keys(@deps), mode: :host)}
  end

  defp verdict(ctx, app), do: TracerFixtures.judge(ctx.proj, app, ctx.traced)

  # The checker's own read, in `app`'s window.
  defp pool_reads(ctx, app) do
    [window] = for %{app: ^app} = w <- ctx.traced.report.windows, do: w

    for %{"mfa" => "erlang:system_info/1", "arg" => %{"key" => "schedulers_online"}} = e <-
          ctx.traced.report.events,
        e["ts"] > window.open and e["ts"] < window.close,
        e["first"]["module"] == "Elixir.Module.ParallelChecker",
        do: e
  end

  test "a checker a dependency's own mix.exs code starts publishes", ctx do
    assert [%{"extent" => "lineage", "user" => nil, "first_kind" => "toolchain"}] =
             pool_reads(ctx, "fx_cp_alias")

    v = verdict(ctx, "fx_cp_alias")
    assert %{status: :pass} = v, inspect(v.observations, pretty: true)
  end

  test "a checker a nested compile starts publishes", ctx do
    assert [%{"extent" => "lineage", "user" => nil}] = pool_reads(ctx, "fx_cp_task")

    v = verdict(ctx, "fx_cp_task")
    assert %{status: :pass} = v, inspect(v.observations, pretty: true)
  end

  test "their dependent is not tainted by either", ctx do
    v = verdict(ctx, "fx_cp_user")
    assert %{status: :pass} = v, inspect(v.observations, pretty: true)
    assert v.observations["taint"] == %{}
  end

  test "the count read by package code still refuses, and taints a dependent", ctx do
    assert %{
             status: :skip,
             reason: "compile-time host read: erlang:system_info/1 (schedulers_online) in " <> _
           } = verdict(ctx, "fx_cp_body")

    assert %{
             status: :skip,
             reason:
               "closure dependency observed the host: fx_cp_body (compile-time host read: " <>
                 "erlang:system_info/1 (schedulers_online)" <> _
           } = verdict(ctx, "fx_cp_body_user")
  end

  test "Task.async_stream/3 sizing its own pool still refuses", ctx do
    assert %{
             status: :skip,
             reason:
               "compile-time host read: erlang:system_info/1 (schedulers_online) via " <>
                 "Task.Supervised.validate_stream_options/1" <> _
           } = verdict(ctx, "fx_cp_stream")
  end
end
