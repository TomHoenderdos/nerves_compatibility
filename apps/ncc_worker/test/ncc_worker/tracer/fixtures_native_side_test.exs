defmodule NccWorker.Tracer.FixturesNativeSideTest do
  # S3 (`native_side: true`) under the real tracer: a dependency natively
  # built with a stand-in for elixir_make, whose compiler reads the host and
  # runs a `make` (a shell script) that writes the dependency's NIF into its
  # priv, and packages that call it only at runtime. The tool's activity is
  # set apart and the dependents pass, unless the native build reached the
  # dependency's beams: a source it generated in the tree, a module it
  # compiled into ebin, or a host read of the dependency's own code. Starts
  # real `elixir` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.TracerFixtures

  import NccWorker.TracerFixtures, only: [lib: 3]

  @moduletag timeout: 900_000

  # elixir_make's shape: a Mix compiler whose own code reads the host and
  # runs `make`, a program the tracer does not follow.
  @tool %{
    files: %{
      "lib/elixir_make/compiler.ex" => """
      defmodule ElixirMake.Compiler do
        def compile do
          _ = :os.type()
          _ = :erlang.system_info(:nif_version)
          _ = System.get_env("CC")

          case Mix.Project.config()[:make_gen] do
            script when is_binary(script) ->
              env = [
                {"COMPILE_PATH", Mix.Project.compile_path()},
                {"PRIV", Path.join(Mix.Project.app_path(), "priv")}
              ]

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

  # The NIF: a file in its priv, as `make` writes one.
  @nif """
  mkdir -p "$PRIV"
  printf 'not really ELF' > "$PRIV/nif.so"
  """

  # A source the native build generates in its own tree, which Mix then
  # compiles with no traced read.
  @gen_source @nif <>
                """
                cat > lib/gen.ex <<EOS
                defmodule FxSnGen.Gen do
                  def os, do: "$(uname -s)"
                end
                EOS
                """

  # A module the native build compiles into its own ebin.
  @gen_beam @nif <>
              """
              d=$(mktemp -d)
              cat > "$d/fx_sn_beam_gen.erl" <<EOS
              -module(fx_sn_beam_gen).
              -export([os/0]).
              os() -> "$(uname -s)".
              EOS
              mkdir -p "$COMPILE_PATH"
              erlc -o "$COMPILE_PATH" "$d/fx_sn_beam_gen.erl"
              rm -rf "$d"
              """

  defp native(app, script, lib_extra \\ "") do
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

    body = "defmodule #{module} do\n  def f(x), do: x + 1\n  #{lib_extra}\nend\n"

    %{
      files: %{"lib/#{app}.ex" => body, "gen.sh" => script},
      mix_exs: mix_exs,
      deps: ["elixir_make"]
    }
  end

  # The 1.20 type checker reads a remote module's beam only from a user
  # process with the dependency's ebin cached on the code path: a nested
  # module and a pad compiled in between (`FixturesNativeBeamTest`).
  defp nested(module, call),
    do: "defmodule #{module} do\n  defmodule Run do\n    def g, do: #{call}\n  end\nend\n"

  defp user(app, dep) do
    module = Macro.camelize(app)
    lib(app, nested(module, "#{Macro.camelize(dep)}.f(1)"), %{deps: [dep, "fx_sn_pad"]})
  end

  @natives ~w(fx_sn_nat fx_sn_gen fx_sn_beam fx_sn_os)
  @users ~w(fx_sn_user fx_sn_gen_user fx_sn_beam_user fx_sn_os_user)
  @native ["elixir_make" | @natives]

  defp deps do
    %{
      "elixir_make" => @tool,
      "fx_sn_pad" => lib("fx_sn_pad", "defmodule FxSnPad do\n  def p, do: :ok\nend\n", %{}),
      "fx_sn_nat" => native("fx_sn_nat", @nif),
      "fx_sn_gen" => native("fx_sn_gen", @gen_source),
      "fx_sn_beam" => native("fx_sn_beam", @gen_beam),
      # The dependency's own code reads the host: that is no native side.
      "fx_sn_os" => native("fx_sn_os", @nif, "@os :os.version()\n  def os, do: @os"),
      "fx_sn_user" => user("fx_sn_user", "fx_sn_nat"),
      "fx_sn_gen_user" => user("fx_sn_gen_user", "fx_sn_gen"),
      "fx_sn_beam_user" => user("fx_sn_beam_user", "fx_sn_beam"),
      "fx_sn_os_user" => user("fx_sn_os_user", "fx_sn_os")
    }
  end

  setup_all do
    root =
      Path.join(System.tmp_dir!(), "ncc-fixtures-nside-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)
    proj = TracerFixtures.project(Path.join(root, "p"), @users, deps())
    home = Path.join(root, "hex")

    releases =
      ["elixir_make", "fx_sn_pad" | @natives ++ @users]
      |> Map.new(&release(home, proj, &1))
      # The stand-in as a reviewed elixir_make release (review M3).
      |> Map.update!("elixir_make", &%{&1 | version: "0.10.1"})

    traced = TracerFixtures.trace(proj, @users, native: @native)
    %{proj: proj, traced: traced, opts: [releases: releases, hex_home: home]}
  end

  # A Hex release of `app` whose tarball holds the files its source dir
  # holds before anything compiles.
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

  defp verdict(ctx, package, opts \\ [native_side: true]),
    do: TracerFixtures.judge(ctx.proj, package, ctx.traced, @native, ctx.opts ++ opts)

  test "the traced compile finished and the native builds ran", ctx do
    assert {:ok, 0} = ctx.traced.result, ctx.traced.log
    assert ctx.traced.report.problems == [], inspect(ctx.traced.report.problems)

    for app <- @natives,
        do: assert(File.regular?(Path.join(ctx.proj, "_build/host/lib/#{app}/priv/nif.so")), app)
  end

  test "a runtime-only user of a natively built dependency passes with its native side apart",
       ctx do
    v = verdict(ctx, "fx_sn_user")
    assert %{status: :pass, reason: nil} = v, inspect({v.reason, v.observations["problems"]})
    assert Enum.any?(v.observations["native_build"], &(&1["owner"] == "fx_sn_nat"))
    assert v.observations["trace_stats"]["native_side"] == "on"

    if Version.match?(System.version(), ">= 1.20.0") do
      assert Enum.any?(v.observations["native_beam_reads"], &(&1["app"] == "fx_sn_nat"))
    end

    # Not as an unreviewed elixir_make release (review M3).
    opts = [
      native_side: true,
      releases: Map.update!(ctx.opts[:releases], "elixir_make", &%{&1 | version: "0.11.0"})
    ]

    assert %{status: :skip, observations: %{"native_build" => []}} =
             TracerFixtures.judge(
               ctx.proj,
               "fx_sn_user",
               ctx.traced,
               @native,
               Keyword.merge(ctx.opts, opts)
             )

    # Without the option the tool's own reads taint the dependency (and on
    # 1.20 the read of its beam refuses first, in the package's window).
    assert %{status: :skip, observations: %{"taint" => %{"fx_sn_nat" => taint}}} =
             verdict(ctx, "fx_sn_user", [])

    assert taint =~ "in ElixirMake.Compiler.compile/0"
  end

  # A dependency that stays tainted refuses its dependent as before: on 1.20
  # its beam read refuses first, in the dependent's window (revision 15), on
  # 1.19 the taint itself.
  defp assert_tainted(v, dep, taint) do
    assert %{status: :skip, reason: reason, observations: %{"taint" => %{^dep => ^taint}}} = v

    if Version.match?(System.version(), ">= 1.20.0"),
      do: assert(reason =~ "/#{dep}/ebin/"),
      else: assert(reason == "closure dependency observed the host: #{dep} (#{taint})")
  end

  test "a source the native build generated in the tree keeps the dependency tainted", ctx do
    assert_tainted(
      verdict(ctx, "fx_sn_gen_user"),
      "fx_sn_gen",
      "native build not set apart: source tree is not its verified tarball's"
    )
  end

  test "a module the native build compiled into ebin keeps the dependency tainted", ctx do
    assert_tainted(
      verdict(ctx, "fx_sn_beam_user"),
      "fx_sn_beam",
      "native build not set apart: beam not compiled from its own sources: fx_sn_beam_gen.beam"
    )
  end

  test "the dependency's own host read keeps it tainted", ctx do
    v = verdict(ctx, "fx_sn_os_user")
    taint = v.observations["taint"]["fx_sn_os"]
    assert taint =~ "os:version/0"
    assert_tainted(v, "fx_sn_os", taint)
  end
end
