defmodule NccWorker.Tracer.FixturesRelocateNativeTest do
  # The umbrella re-review's R2: the third root has spaces, which a native
  # build tool may split (GNU make with an unquoted `$(MIX_APP_PATH)`) and
  # still exit 0 with its output in the wrong place. Relocation must then
  # refuse, never pass with a dependency that lacks its NIF. A package that
  # bakes its deps path depends, at runtime only, on a dependency natively
  # built by a stand-in for elixir_make (as `FixturesNativeSideTest`), whose
  # build script quotes the path, or does not. Starts real `elixir` VMs (the
  # :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.{Portability, TracerFixtures}
  alias NccWorker.Portability.Context

  import NccWorker.TracerFixtures, only: [lib: 3]

  @moduletag timeout: 1_200_000

  @tool %{
    files: %{
      "lib/elixir_make/compiler.ex" => """
      defmodule ElixirMake.Compiler do
        def compile do
          case Mix.Project.config()[:make_gen] do
            script when is_binary(script) ->
              env = [{"PRIV", Path.join(Mix.Project.app_path(), "priv")}]
              {_, 0} = System.cmd("sh", [script], env: env, stderr_to_stdout: true)

            _ ->
              :ok
          end

          {:ok, []}
        end
      end
      """,
      "lib/mix/tasks/compile.elixir_make.ex" => """
      defmodule Mix.Tasks.Compile.ElixirMake do
        use Mix.Task.Compiler
        def run(_args), do: ElixirMake.Compiler.compile()
      end
      """
    }
  }

  # The NIF in its priv, the path quoted.
  @quoted """
  mkdir -p "$PRIV"
  printf 'not really ELF' > "$PRIV/nif.so"
  """

  # The path unquoted, as many Makefiles have it: with a space in it the
  # NIF goes nowhere, and the script exits 0 all the same.
  @unquoted """
  mkdir -p "$PRIV"
  cd /
  touch $PRIV/nif.so 2>/dev/null
  exit 0
  """

  defp native(app, script) do
    module = Macro.camelize(app)

    mix_exs = """
    defmodule #{module}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{app},
          version: "0.1.0",
          make_gen: "gen.sh",
          compilers: [:elixir_make | Mix.compilers()],
          deps: [{:elixir_make, path: "../elixir_make"}]
        ]
      end
    end
    """

    body = "defmodule #{module} do\n  def f(x), do: x + 1\nend\n"

    %{
      files: %{"lib/#{app}.ex" => body, "gen.sh" => script},
      mix_exs: mix_exs,
      deps: ["elixir_make"]
    }
  end

  # fine's shape, with a runtime call into the native dependency in a nested
  # module (`FixturesNativeSideTest`'s 1.20 type checker note).
  defp fine(app, dep) do
    module = Macro.camelize(app)

    body = """
    defmodule #{module} do
      @include_dir Path.expand("c_include")
      def include_dir, do: @include_dir

      defmodule Run do
        def g, do: #{Macro.camelize(dep)}.f(1)
      end
    end
    """

    lib(app, body, %{deps: [dep, "fx_rn_pad"]})
  end

  @natives ~w(fx_rn_ok fx_rn_split)
  @packages ~w(fx_rn_fine_ok fx_rn_fine_split)

  setup_all do
    root =
      Path.join(
        Context.realpath(System.tmp_dir!()),
        "ncc-fixtures-relocate-native-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)

    deps = %{
      "elixir_make" => @tool,
      "fx_rn_pad" => lib("fx_rn_pad", "defmodule FxRnPad do\n  def p, do: :ok\nend\n", %{}),
      "fx_rn_ok" => native("fx_rn_ok", @quoted),
      "fx_rn_split" => native("fx_rn_split", @unquoted),
      "fx_rn_fine_ok" => fine("fx_rn_fine_ok", "fx_rn_ok"),
      "fx_rn_fine_split" => fine("fx_rn_fine_split", "fx_rn_split")
    }

    proj = TracerFixtures.project(Path.join(root, "p"), @packages, deps)
    deps_from_env!(proj)
    home = Path.join(root, "hex")

    releases =
      ["elixir_make", "fx_rn_pad" | @natives ++ @packages]
      |> Map.new(&release(home, proj, &1))
      |> Map.update!("elixir_make", &%{&1 | version: "0.10.1"})

    verdicts =
      for app <- @packages, into: %{} do
        File.rm_rf!(Path.join(proj, "_build"))
        {app, run(root, proj, app, releases, home)}
      end

    %{verdicts: verdicts}
  end

  defp deps_from_env!(proj) do
    file = Path.join(proj, "mix.exs")

    body =
      Regex.replace(~r/path: "deps\/([^"]+)"/, File.read!(file), fn _, app ->
        ~s|path: Path.join(System.fetch_env!("MIX_DEPS_PATH"), "#{app}")|
      end)

    File.write!(file, body)
  end

  defp release(home, proj, app) do
    dir = Path.join([proj, "deps", app])

    contents =
      for path <- Path.wildcard(Path.join(dir, "**"), match_dot: true),
          File.regular?(path),
          rel = Path.relative_to(path, dir),
          rel != "hex_metadata.config",
          into: %{},
          do: {rel, File.read!(path)}

    TracerFixtures.hex_release(home, app, Map.keys(contents), contents)
  end

  defp run(root, proj, app, releases, home) do
    Portability.run(proj, app,
      env: TracerFixtures.container_env(proj, root),
      releases: releases,
      hex_home: home,
      mode: :judge,
      native_side: true,
      trace_dir: Path.join(root, "trace-#{app}"),
      log_file: Path.join(root, "#{app}.log"),
      timeout_ms: 240_000,
      run_started_at: System.monotonic_time(:second),
      relocate: true,
      relocate_root: root
    )
  end

  defp log(ctx, app), do: inspect(ctx.verdicts[app], pretty: true, limit: 60)
  defp stat(v), do: v.observations["trace_stats"]["relocate"]

  test "a native dependency that quotes its paths: the package relocates", ctx do
    v = ctx.verdicts["fx_rn_fine_ok"]
    assert %{status: :pass, reason: nil} = v, log(ctx, "fx_rn_fine_ok")
    assert stat(v) == "relocated"
  end

  test "a native dependency whose NIF the spaced root lost: the package is refused", ctx do
    v = ctx.verdicts["fx_rn_fine_split"]
    assert v.status == :skip, log(ctx, "fx_rn_fine_split")
    assert stat(v) =~ "fx_rn_split's build differ in the second build"
  end
end
