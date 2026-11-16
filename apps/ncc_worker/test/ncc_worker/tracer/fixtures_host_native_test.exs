defmodule NccWorker.Tracer.FixturesHostNativeTest do
  # A host-native build's verdict on real compiles (`target: "host"`,
  # `host_native: true`, design addendum for #85): the rustler_precompiled
  # shape, with a stand-in for rustler_precompiled whose `__using__/2`,
  # called from the package's module body, reads the target and the NIF
  # version, hashes and writes the NIF into the package's priv. Starts real
  # `elixir` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.TracerFixtures

  import NccWorker.TracerFixtures, only: [lib: 3]

  @moduletag timeout: 600_000

  @tool %{
    files: %{
      "lib/rustler_precompiled.ex" => """
      defmodule RustlerPrecompiled do
        defmacro __using__(opts) do
          quote do
            {:ok, config} = RustlerPrecompiled.__using__(__MODULE__, unquote(opts))
            @load_from config.load_from
            def load_from, do: @load_from
          end
        end

        def __using__(_module, opts) do
          _ = System.get_env("RUSTLER_PRECOMPILED_FORCE_BUILD_ALL")
          arch = List.to_string(:erlang.system_info(:system_architecture))
          nif = List.to_string(:erlang.system_info(:nif_version))

          case opts[:variant] do
            fun when is_function(fun, 0) -> _ = fun.()
            _ -> :ok
          end

          name = "lib" <> opts[:crate] <> "-nif-" <> nif <> "-" <> arch <> ".so"
          priv = Path.join(Mix.Project.app_path(), "priv/native")
          File.mkdir_p!(priv)
          File.write!(Path.join(priv, name), :crypto.hash(:sha256, name))
          {:ok, %{load_from: {opts[:otp_app], "priv/native/" <> name}}}
        end
      end
      """
    }
  }

  defp nif(app, extra) do
    module = Macro.camelize(app) <> ".Native"

    body = """
    defmodule #{module} do
      use RustlerPrecompiled,
        otp_app: :#{app},
        crate: "#{app}",
        force_build: System.get_env("FX_NIF_BUILD") in ["1", "true"]#{extra}
    end
    """

    Map.put(lib(app, body, %{}), :deps, ["rustler_precompiled"])
  end

  defp deps do
    %{
      "rustler_precompiled" => @tool,
      "fx_nif" => nif("fx_nif", ""),
      # A variant fun the tool runs: the package's own code reading the host.
      "fx_nif_cpu" => nif("fx_nif_cpu", ",\n    variant: fn -> :os.version() end")
    }
  end

  @apps ~w(rustler_precompiled fx_nif fx_nif_cpu)

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "ncc-fixtures-host-native-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    proj = TracerFixtures.project(Path.join(root, "p"), @apps, deps())
    home = Path.join(root, "hex")
    releases = Map.new(@apps, &release(home, proj, &1))
    traced = TracerFixtures.trace(proj, @apps, native: @apps)
    %{proj: proj, traced: traced, hex: [releases: releases, hex_home: home]}
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

  defp verdict(ctx, app, opts),
    do: TracerFixtures.judge(ctx.proj, app, ctx.traced, @apps, opts ++ ctx.hex)

  test "the tool's own reads and writes are set apart; the package's env read is an input",
       ctx do
    assert {:ok, 0} = ctx.traced.result, ctx.traced.log
    v = verdict(ctx, "fx_nif", target: "host", host_native: true)
    assert %{status: :pass} = v, inspect(v.observations, pretty: true)

    assert Enum.any?(v.compile_inputs, &match?(%{"kind" => "env", "name" => "FX_NIF_BUILD"}, &1))
    refute Enum.any?(v.compile_inputs, &(&1["name"] == "RUSTLER_PRECOMPILED_FORCE_BUILD_ALL"))
    assert Compatibility.CompileInputs.validate(v.compile_inputs) == {:ok, v.compile_inputs}
    assert v.observations["native_build"] != []
  end

  test "a firmware target's verdict and the toolchain judge refuse the same trace", ctx do
    assert %{status: :skip, compile_inputs: nil} = verdict(ctx, "fx_nif", target: "host")
    assert %{status: :skip, compile_inputs: nil} = verdict(ctx, "fx_nif", [])
  end

  test "a package fun the tool runs is the package's: its host read refuses", ctx do
    assert %{status: :skip, compile_inputs: nil, reason: reason} =
             verdict(ctx, "fx_nif_cpu", target: "host", host_native: true)

    assert reason =~ "os:version/0"
  end
end
