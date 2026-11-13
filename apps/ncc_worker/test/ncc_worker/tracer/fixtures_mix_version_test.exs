defmodule NccWorker.Tracer.FixturesMixVersionTest do
  # A dependency's mix.exs that compares the Elixir version directly against
  # a literal and lets the answer pick its configuration (credo's
  # module-body `if`, sourceror's erlc_paths), on real traced compiles: a
  # requirement on a minor boundary is publishable, one that cuts inside the
  # running minor is not, and a read used any other way is not.
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.TracerFixtures

  @moduletag timeout: 900_000

  %Version{major: major, minor: minor, patch: patch} = Version.parse!(System.version())
  @boundary ">= #{major}.#{minor}.0-dev"
  @cut ">= #{major}.#{minor}.#{patch}"

  defp mix_exs(name, req) do
    """
    defmodule #{Macro.camelize(name)}.MixProject do
      use Mix.Project

      def project do
        [app: :#{name}, version: "0.1.0", deps: [], erlc_paths: erlc_paths()] ++ cli_entry()
      end

      if Version.match?(System.version(), #{inspect(req)}) do
        defp cli_entry, do: []
      else
        defp cli_entry, do: [preferred_cli_env: []]
      end

      defp erlc_paths do
        if Version.compare(System.version(), "1.13.0") == :lt, do: ["src", "old"], else: ["src"]
      end
    end
    """
  end

  @other """
  defmodule FxOther.MixProject do
    use Mix.Project
    def project, do: [app: :fx_other, version: "0.1.0", deps: [], erlc_paths: erlc_paths()]
    defp erlc_paths, do: [Enum.join(["src", System.version()], "-")]
  end
  """

  defp dep(name, mix_exs) do
    %{
      mix_exs: mix_exs,
      files: %{"lib/#{name}.ex" => "defmodule #{Macro.camelize(name)} do\nend\n"}
    }
  end

  setup_all do
    root =
      Path.join(System.tmp_dir!(), "ncc-fixtures-mixver-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)

    fixtures = %{
      "fx_minor" => mix_exs("fx_minor", @boundary),
      "fx_cut" => mix_exs("fx_cut", @cut),
      "fx_other" => @other
    }

    runs =
      fixtures
      |> Task.async_stream(
        fn {name, mix_exs} ->
          proj =
            TracerFixtures.project(Path.join(root, name), [name], %{name => dep(name, mix_exs)})

          {name, %{proj: proj, traced: TracerFixtures.trace(proj, [name])}}
        end,
        timeout: :infinity,
        ordered: false
      )
      |> Map.new(fn {:ok, run} -> run end)

    %{runs: runs}
  end

  defp verdict(ctx, name) do
    run = ctx.runs[name]
    assert {:ok, 0} = run.traced.result, run.traced.log
    TracerFixtures.judge(run.proj, name, run.traced)
  end

  test "a direct comparison on a minor boundary is publishable", ctx do
    assert %{status: :pass} = v = verdict(ctx, "fx_minor")

    assert [_ | _] = versions = v.observations["elixir_version"]
    assert Enum.all?(versions, &(&1["series"] == true)), inspect(versions)
  end

  test "a requirement that cuts inside the running minor refuses", ctx do
    assert %{status: :skip, reason: "compile-time Elixir patch dependence: Version.match?/2" <> _} =
             verdict(ctx, "fx_cut")
  end

  test "a read used any other way refuses", ctx do
    assert %{status: :skip, reason: "compile-time Elixir patch dependence: System.version/0" <> _} =
             verdict(ctx, "fx_other")
  end
end
