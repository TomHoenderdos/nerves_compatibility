defmodule NccWorker.Tracer.FixturesTargetTest do
  # A firmware target's compile-time inputs on real compiles
  # (`NccWorker.Portability.target_inputs/3`, judge revision 19): the
  # circuits_i2c shape built for a Nerves target, with a stand-in for
  # elixir_make, the reviewed native build tool. Starts real `elixir` VMs
  # (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.TracerFixtures

  import NccWorker.TracerFixtures, only: [lib: 3]

  @moduletag timeout: 600_000

  @toolchain "/opt/nerves-fx/toolchain-15"

  # elixir_make's shape: a Mix compiler that reads the host to run `make`.
  @tool %{
    files: %{
      "lib/elixir_make/compiler.ex" => """
      defmodule ElixirMake.Compiler do
        def compile do
          _ = System.get_env("PATH")
          _ = :os.type()

          # elixir_make's make/2 runs a `make_env` fun from the package's
          # project config.
          case Mix.Project.config()[:make_env] do
            fun when is_function(fun, 0) -> _ = fun.()
            _ -> :ok
          end

          {:ok, []}
        end

        def os, do: Atom.to_string(elem(:os.type(), 1))
        def hook(_args), do: System.put_env("FX_BOARD_DEV", os())
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

  # circuits_i2c's mix.exs: the backend from the app's config, else from
  # whether Nerves set CROSSCOMPILE on a target; an alias fun puts the mode
  # where lib/ reads it at compile time.
  defp board_mix_exs(app, lib_extra) do
    module = Macro.camelize(app)

    {"""
     defmodule #{module}.MixProject do
       use Mix.Project

       def project do
         [
           app: :#{app},
           version: "0.1.0",
           compilers: [:elixir_make | Mix.compilers()],
           deps: [{:elixir_make, path: "../elixir_make"}],
           aliases: [compile: [&set_make_env/1, "compile"]]
         ]
       end

       def application, do: [env: [default_backend: default_backend()]]

       defp default_backend, do: default_backend(Mix.env(), Mix.target())
       defp default_backend(_env, :host), do: {#{module}, test: true}

       defp default_backend(env, _target) do
         case System.fetch_env("CROSSCOMPILE") do
           {:ok, _} -> #{module}
           :error -> default_backend(env, :host)
         end
       end

       defp set_make_env(_args) do
         backend = Application.get_env(:#{app}, :default_backend, default_backend())
         System.put_env("FX_BOARD_DEV", mode(backend))
       end

       defp mode({_, opts}), do: if(opts[:test], do: "test", else: "normal")
       defp mode(_backend), do: "normal"
     end
     """,
     """
     defmodule #{module} do
       case System.get_env("FX_BOARD_DEV") do
         "normal" -> def bus, do: :normal
         _ -> def bus, do: :none
       end
       #{lib_extra}
     end
     """}
  end

  defp board(app, lib_extra \\ "") do
    {mix_exs, body} = board_mix_exs(app, lib_extra)
    Map.merge(lib(app, body, %{mix_exs: mix_exs}), %{deps: ["elixir_make"]})
  end

  defp deps do
    %{
      "elixir_make" => @tool,
      "fx_board" => board("fx_board"),
      # Another host read in the package's own compile: no client can check it.
      "fx_board_os" => board("fx_board_os", "@os :os.version()\n  def os, do: @os"),
      # A module named like the tool's, but the package's own: not set apart.
      "fx_board_sneaky" =>
        board(
          "fx_board_sneaky",
          "defmodule ElixirMake.Sneaky, do: def(os, do: :os.version())\n  @os ElixirMake.Sneaky.os()"
        ),
      # The package's own compile reading the host through the tool's code.
      "fx_board_tool_lib" => board("fx_board_tool_lib", "@os ElixirMake.Compiler.os()"),
      "fx_board_tool_alias" => tool_alias_board(),
      "fx_board_make_env" =>
        make_env_board(
          "fx_board_make_env",
          ~s|fn -> System.put_env("FX_MAKE_DEV", "normal") end|,
          "@make System.get_env(\"FX_MAKE_DEV\")\n  def make, do: @make"
        )
    }
  end

  # A package whose `make_env` fun the tool runs: a call the fun tail-calls
  # leaves the tool's frame on top, but it is the package's code.
  defp make_env_board(app, fun, lib_extra \\ "") do
    %{files: files, mix_exs: mix_exs} = board(app, lib_extra)
    mix_exs = String.replace(mix_exs, "compilers: [", "make_env: #{fun},\n          compilers: [")
    %{files: files, mix_exs: mix_exs, deps: ["elixir_make"]}
  end

  # The tool's function as the package's own alias: Mix runs it, but not as
  # its compiler.
  defp tool_alias_board do
    %{files: files, mix_exs: mix_exs} = board("fx_board_tool_alias")

    mix_exs =
      String.replace(
        mix_exs,
        "[&set_make_env/1, \"compile\"]",
        "[&ElixirMake.Compiler.hook/1, \"compile\"]"
      )

    %{files: files, mix_exs: mix_exs, deps: ["elixir_make"]}
  end

  @apps ~w(elixir_make fx_board fx_board_os fx_board_sneaky fx_board_tool_lib fx_board_tool_alias
           fx_board_make_env)

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "ncc-fixtures-target-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    proj = TracerFixtures.project(Path.join(root, "p"), @apps, deps())

    traced =
      TracerFixtures.trace(proj, @apps,
        native: @apps,
        extra_env: [
          {"MIX_TARGET", "rpi4"},
          {"CROSSCOMPILE", @toolchain <> "/bin/aarch64-nerves-linux-gnu"},
          {"NERVES_TOOLCHAIN", @toolchain}
        ]
      )

    %{proj: proj, traced: traced}
  end

  defp rec(term),
    do: term |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)

  defp target_verdict(ctx, app, opts \\ []) do
    opts = Keyword.merge([target: "rpi4", roots: [{"NERVES_TOOLCHAIN", @toolchain}]], opts)
    TracerFixtures.judge(ctx.proj, app, ctx.traced, @apps, opts)
  end

  test "the circuits shape records what a client compares, and nothing of the tool", ctx do
    v = target_verdict(ctx, "fx_board")
    assert %{status: :pass} = v, inspect(v.observations, pretty: true)

    assert Enum.sort_by(v.compile_inputs, &{&1["kind"], &1["name"]}) == [
             %{
               "kind" => "env",
               "name" => "CROSSCOMPILE",
               "set_by" => "nerves",
               "value" => [%{"root" => "NERVES_TOOLCHAIN"}, "/bin/aarch64-nerves-linux-gnu"]
             },
             %{
               "kind" => "env",
               "name" => "FX_BOARD_DEV",
               "set_by" => "build",
               "inputs" => "recorded",
               "value" => rec({:ok, "normal"})
             },
             %{"kind" => "mix_target", "value" => "rpi4"}
           ]

    assert %{app: "fx_board", path: ["default_backend"], value: rec(:error)} in v.compile_env
    assert Compatibility.CompileInputs.validate(v.compile_inputs) == {:ok, v.compile_inputs}
    assert v.observations["native_build"] != []
    refute Enum.any?(v.compile_inputs, &(&1["name"] == "PATH"))
  end

  test "the host judge still refuses the same trace", ctx do
    assert %{status: :skip} = TracerFixtures.judge(ctx.proj, "fx_board", ctx.traced, @apps)
  end

  test "any other host read in the package's compile records nothing", ctx do
    assert %{
             status: :skip,
             compile_inputs: nil,
             reason: "compile-time host read: os:version/0" <> _
           } =
             target_verdict(ctx, "fx_board_os")
  end

  test "a module the package names like the tool's is not the tool's", ctx do
    assert %{status: :skip, compile_inputs: nil} = target_verdict(ctx, "fx_board_sneaky")
  end

  test "the package's own code reading the host through the tool records nothing", ctx do
    for app <- ["fx_board_tool_lib", "fx_board_tool_alias"] do
      assert %{status: :skip, compile_inputs: nil} = v = target_verdict(ctx, app)
      assert v.reason =~ "ElixirMake.Compiler", app
    end
  end

  test "a write the package's fun makes from the tool's frame is the package's, not the tool's",
       ctx do
    assert %{status: :skip, compile_inputs: nil} = v = target_verdict(ctx, "fx_board_make_env")
    assert v.reason == "compile-time write from the native build tool's frame: os:putenv/2"
  end

  # An integrity refusal stands wherever it fell, so this one gets a trace
  # of its own. `Process.info/1` is no BIF: the fun's tail call to it leaves
  # the tool's frame first when it calls `:erlang.process_info/1`.
  describe "the tracer's integrity through the tool's frame" do
    setup do
      root =
        Path.join(
          System.tmp_dir!(),
          "ncc-fixtures-target-integrity-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf(root) end)
      apps = ["elixir_make", "fx_board_probe"]

      deps = %{
        "elixir_make" => @tool,
        "fx_board_probe" => make_env_board("fx_board_probe", "fn -> Process.info(self()) end")
      }

      proj = TracerFixtures.project(Path.join(root, "p"), apps, deps)

      traced =
        TracerFixtures.trace(proj, apps,
          native: apps,
          extra_env: [
            {"MIX_TARGET", "rpi4"},
            {"CROSSCOMPILE", @toolchain <> "/bin/aarch64-nerves-linux-gnu"},
            {"NERVES_TOOLCHAIN", @toolchain}
          ]
        )

      %{proj: proj, traced: traced, apps: apps}
    end

    test "is never the tool's own activity", ctx do
      v =
        TracerFixtures.judge(ctx.proj, "fx_board_probe", ctx.traced, ctx.apps,
          target: "rpi4",
          roots: [{"NERVES_TOOLCHAIN", @toolchain}]
        )

      assert %{status: :skip, compile_inputs: nil} = v
      assert v.reason =~ "process_info"
    end
  end

  test "a tool the tracer did not pattern sets nothing apart", ctx do
    natives = @apps -- ["elixir_make"]

    assert %{status: :skip, compile_inputs: nil} =
             TracerFixtures.judge(ctx.proj, "fx_board", ctx.traced, natives,
               target: "rpi4",
               roots: [{"NERVES_TOOLCHAIN", @toolchain}]
             )
  end

  test "without the Nerves roots the toolchain path is the builder's own", ctx do
    v = target_verdict(ctx, "fx_board", roots: [])
    assert %{status: :pass} = v
    assert %{"set_by" => "host"} = Enum.find(v.compile_inputs, &(&1["name"] == "CROSSCOMPILE"))
  end
end
