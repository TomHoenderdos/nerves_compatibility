defmodule NccWorker.Tracer.FixturesEnvTest do
  # Compile-time env reads on real compiles: published with compile_inputs,
  # never refused. Starts real `elixir` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.TracerFixtures

  import NccWorker.TracerFixtures, only: [lib: 2, lib: 3]

  @moduletag timeout: 600_000

  @deps %{
    "fx_env_unset" =>
      lib("fx_env_unset", """
      defmodule FxEnvUnset do
        @v System.get_env("FX_ENV_NEVER_SET")
        def v, do: @v
      end
      """),
    "fx_env_set" =>
      lib("fx_env_set", """
      defmodule FxEnvSet do
        @v System.get_env("FX_ENV_SET")
        def v, do: @v
      end
      """),
    "fx_env_all" =>
      lib("fx_env_all", """
      defmodule FxEnvAll do
        @n map_size(System.get_env())
        def n, do: @n
      end
      """),
    "fx_env_huge" =>
      lib("fx_env_huge", """
      defmodule FxEnvHuge do
        @n byte_size(System.get_env("FX_ENV_HUGE") || "")
        def n, do: @n
      end
      """),
    "fx_env_private" =>
      lib("fx_env_private", """
      defmodule FxEnvPrivate do
        @t System.get_env("FX_API_TOKEN")
        def t, do: @t
      end
      """),
    # The circuits shape: mix.exs reads one variable and sets another, lib/
    # reads the one it set.
    "fx_env_shape" =>
      lib(
        "fx_env_shape",
        """
        defmodule FxEnvShape do
          @backend System.get_env("FX_SHAPE_BACKEND")
          def backend, do: @backend
        end
        """,
        %{
          mix_exs: """
          defmodule FxEnvShape.MixProject do
            use Mix.Project

            def project do
              set_make_env()
              [app: :fx_env_shape, version: "0.1.0", deps: []]
            end

            defp set_make_env do
              unless System.get_env("FX_SHAPE_CROSS"),
                do: System.put_env("FX_SHAPE_BACKEND", "host")
            end
          end
          """
        }
      ),
    "fx_env_cmd" =>
      lib("fx_env_cmd", """
      defmodule FxEnvCmd do
        @o :os.cmd(~c"true")
        def o, do: @o
      end
      """)
  }

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "ncc-fixtures-env-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    proj = TracerFixtures.project(Path.join(root, "p"), Map.keys(@deps), @deps)

    traced =
      TracerFixtures.trace(proj, Map.keys(@deps),
        extra_env: [
          {"FX_ENV_SET", "on"},
          {"FX_ENV_HUGE", String.duplicate("x", 70_000)},
          {"FX_API_TOKEN", "s3cret-value"}
        ]
      )

    %{proj: proj, traced: traced}
  end

  defp rec(term),
    do: term |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)

  defp verdict(ctx, app), do: TracerFixtures.judge(ctx.proj, app, ctx.traced)

  defp passes(ctx, app) do
    v = verdict(ctx, app)
    assert %{status: :pass} = v, "#{app}: #{inspect(v.observations, pretty: true)}"
    v
  end

  defp env(v, name), do: Enum.find(v.compile_inputs, &(&1["name"] == name))

  test "an unset variable read at module level publishes, recorded unset", ctx do
    assert env(passes(ctx, "fx_env_unset"), "FX_ENV_NEVER_SET") ==
             %{
               "kind" => "env",
               "name" => "FX_ENV_NEVER_SET",
               "value" => rec(:error),
               "set_by" => "host"
             }
  end

  test "a set variable publishes with the builder's value", ctx do
    assert %{"value" => value, "set_by" => "host"} = env(passes(ctx, "fx_env_set"), "FX_ENV_SET")
    assert value == rec({:ok, "on"})
  end

  test "reading the whole environment publishes with env_all", ctx do
    assert %{"kind" => "env_all"} in passes(ctx, "fx_env_all").compile_inputs
  end

  test "a huge value publishes as unrecordable", ctx do
    assert %{"value" => "unrecordable"} = env(passes(ctx, "fx_env_huge"), "FX_ENV_HUGE")
  end

  test "a private-looking name never records its value", ctx do
    v = passes(ctx, "fx_env_private")
    assert %{"value" => "unrecordable"} = env(v, "FX_API_TOKEN")
    text = inspect(v, limit: :infinity, printable_limit: :infinity)
    refute text =~ "s3cret-value"
    refute text =~ rec({:ok, "s3cret-value"})
  end

  test "the circuits shape: the lib read is the build's own value", ctx do
    v = passes(ctx, "fx_env_shape")

    assert %{"set_by" => "build", "inputs" => "recorded", "value" => value} =
             env(v, "FX_SHAPE_BACKEND")

    assert value == rec({:ok, "host"})
    assert %{"set_by" => "host", "value" => cross} = env(v, "FX_SHAPE_CROSS")
    assert cross == rec(:error)
  end

  test "other host reads still refuse", ctx do
    assert %{status: :skip, reason: "compile-time host read: os:cmd/1" <> _} =
             verdict(ctx, "fx_env_cmd")
  end
end
