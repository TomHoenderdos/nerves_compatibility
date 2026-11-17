defmodule NccWorker.Tracer.FixturesHostNativeTest do
  # A host-native build's verdict on real compiles (`target: "host"`,
  # `host_native: true`, design addendum for #85): the rustler_precompiled
  # shape, with a stand-in for rustler_precompiled whose `__using__/2`,
  # called from the package's module body, reads the target and the NIF
  # version, hashes and writes the NIF into the package's priv and unpacks an
  # archive there, and a stand-in for rustler, the optional dependency whose
  # macro the tool's quote expands (tokenizers 0.5.2, judge revision 25).
  # Starts real `elixir` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.TracerFixtures

  import NccWorker.TracerFixtures, only: [lib: 3]

  @moduletag timeout: 600_000

  # The stand-in's macro has rustler_precompiled 0.10's shape: its quote
  # holds `use Rustler, only_rustler_opts` in the force-build branch whenever
  # Rustler is loaded, so the expander calls Rustler's macro whichever branch
  # the module body takes; its `download_or_reuse_nif_file/2` unpacks a
  # `.tar.gz` held in memory with `:erl_tar.extract({:binary, _}, ...)`, which
  # opens OTP's ram_file driver, as the real one unpacks its download.
  defp tool(tgz) do
    %{
      files: %{
        "lib/rustler_precompiled.ex" => """
        defmodule RustlerPrecompiled do
          @tgz Base.decode64!("#{Base.encode64(tgz)}")

          defmacro __using__(opts) do
            force =
              if Code.ensure_loaded?(Rustler) do
                quote do
                  use Rustler, only_rustler_opts
                end
              else
                quote do
                  raise "Rustler dependency is needed to force the build"
                end
              end

            quote do
              case RustlerPrecompiled.__using__(__MODULE__, unquote(opts)) do
                {:force_build, only_rustler_opts} ->
                  unquote(force)

                {:ok, config} ->
                  @load_from config.load_from
                  def load_from, do: @load_from
              end
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

            if opts[:peek], do: :ok = peek()

            if opts[:force_build] do
              {:force_build, Keyword.drop(opts, [:force_build])}
            else
              name = "lib" <> opts[:crate] <> "-nif-" <> nif <> "-" <> arch
              download_or_reuse_nif_file(opts, name <> variant_suffix(opts) <> ".so")
            end
          end

          # rustler_precompiled 0.10's shape: each variant fun of the
          # package's from a callback that tail-calls it, under Enum.find/2.
          defp variant_suffix(opts) do
            callback = fn {_name, func} ->
              if is_function(func, 1), do: func.(opts), else: func.()
            end

            case Enum.find(opts[:variants] || [], callback) do
              {name, _} -> "--" <> Atom.to_string(name)
              nil -> ""
            end
          end

          def download_or_reuse_nif_file(opts, name) do
            priv = Path.join(Mix.Project.app_path(), "priv/native")
            File.mkdir_p!(priv)
            File.write!(Path.join(priv, name), :crypto.hash(:sha256, name))
            :ok = :erl_tar.extract({:binary, @tgz}, [:compressed, cwd: String.to_charlist(priv)])
            {:ok, %{load_from: {opts[:otp_app], "priv/native/" <> name}}}
          end

          # The same driver from another of the tool's functions.
          def peek do
            {:ok, _names} = :erl_tar.table({:binary, @tgz}, [:compressed])
            :ok
          end
        end
        """
      }
    }
  end

  # rustler's `__using__/2` (0.37, 0.38): a `bind_quoted` quote, whose code
  # compiles the crate and sets `@before_compile Rustler` when it runs.
  @rustler %{
    files: %{
      "lib/rustler.ex" => """
      defmodule Rustler do
        defmacro __using__(opts) do
          quote bind_quoted: [opts: opts] do
            config = Rustler.Compiler.compile_crate(__MODULE__, opts)
            @load_from config
            @before_compile Rustler
          end
        end

        defmacro __before_compile__(_env) do
          quote do
            def rustler_init, do: @load_from
          end
        end
      end

      defmodule Rustler.Compiler do
        def compile_crate(_module, opts), do: {opts[:otp_app], "priv/native/lib.so"}
      end
      """
    }
  }

  @env_force ~S|System.get_env("FX_NIF_BUILD") in ["1", "true"]|

  defp nif(app, extra, after_use \\ "", force \\ @env_force) do
    module = Macro.camelize(app) <> ".Native"

    body = """
    defmodule #{module} do
      use RustlerPrecompiled,
        otp_app: :#{app},
        crate: "#{app}",
        force_build: #{force}#{extra}
    #{after_use}end
    """

    Map.put(lib(app, body, %{}), :deps, ["rustler_precompiled", "rustler"])
  end

  defp deps(tgz) do
    %{
      "rustler_precompiled" => tool(tgz),
      "rustler" => @rustler,
      "fx_nif" => nif("fx_nif", ""),
      # A variant fun the tool runs: the package's own code reading the host.
      "fx_nif_cpu" => nif("fx_nif_cpu", ",\n    variant: fn -> :os.version() end"),
      # Variant funs that tail-call a read: the package's reads.
      "fx_nif_venv" =>
        nif("fx_nif_venv", ",\n    variants: [legacy: fn -> System.get_env(\"FX_LEGACY\") end]"),
      "fx_nif_vfile" =>
        nif(
          "fx_nif_vfile",
          ",\n    variants: [legacy: fn -> File.exists?(\"/fx_legacy_cpu\") end]"
        ),
      # The force-build branch: Rustler's code runs.
      "fx_nif_force" => nif("fx_nif_force", "", "", "true"),
      # The tool's ram_file port outside its download.
      "fx_nif_peek" => nif("fx_nif_peek", ",\n    peek: true"),
      # The package's own `use Rustler` after the tool's.
      "fx_nif_twice" =>
        nif("fx_nif_twice", "", "  use Rustler, otp_app: :fx_nif_twice, crate: \"x\"\n"),
      # rustler on its own, a real cargo build.
      "fx_rustler" =>
        lib(
          "fx_rustler",
          """
          defmodule FxRustler.Native do
            use Rustler, otp_app: :fx_rustler, crate: "fx_rustler", skip_compilation?: true
          end
          """,
          %{deps: ["rustler"]}
        ),
      # The package's own unpack of an archive held in memory.
      "fx_unpack" =>
        lib(
          "fx_unpack",
          """
          defmodule FxUnpack do
            @names :erl_tar.table({:binary, Base.decode64!("#{Base.encode64(tgz)}")}, [:compressed])
            def names, do: @names
          end
          """,
          %{}
        )
    }
  end

  @apps ~w(rustler rustler_precompiled fx_nif fx_nif_cpu fx_nif_venv fx_nif_vfile
           fx_nif_force fx_nif_peek fx_nif_twice fx_rustler fx_unpack)

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "ncc-fixtures-host-native-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    proj = TracerFixtures.project(Path.join(root, "p"), @apps, deps(tgz(root)))
    home = Path.join(root, "hex")
    releases = Map.new(@apps, &release(home, proj, &1))
    traced = TracerFixtures.trace(proj, @apps, native: @apps)
    %{proj: proj, traced: traced, hex: [releases: releases, hex_home: home]}
  end

  # A `.tar.gz` of one member, as a downloaded NIF archive is.
  defp tgz(root) do
    File.mkdir_p!(root)
    path = Path.join(root, "nif.tar.gz")
    member = {~c"libfx_tar.so", "not a library"}
    :ok = :erl_tar.create(String.to_charlist(path), [member], [:compressed])
    File.read!(path)
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

    # Rustler's macro the expander called for the tool's quote, and the
    # ram_file driver its unpack opened, are the tool's.
    built = Enum.map(v.observations["native_build"], & &1["mfa"])
    assert "Rustler.MACRO-__using__/2" in built, inspect(built)
    assert "erlang:open_port/2" in built, inspect(built)
    assert File.regular?(Path.join(ctx.proj, "_build/host/lib/fx_nif/priv/native/libfx_tar.so"))
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

  test "a variant fun's tail-called read is the package's, not the tool's", ctx do
    # The variant fun's frame is gone; the tool's `variant_suffix/2` is first.
    v = verdict(ctx, "fx_nif_venv", target: "host", host_native: true)
    assert %{status: :pass} = v, inspect(v.observations["refusals"])
    assert Enum.any?(v.compile_inputs, &match?(%{"kind" => "env", "name" => "FX_LEGACY"}, &1))

    assert %{status: :skip, compile_inputs: nil, reason: reason} =
             verdict(ctx, "fx_nif_vfile", target: "host", host_native: true)

    assert reason =~ "/fx_legacy_cpu", reason
  end

  @rustler_call "calls natively built dependency at compile time: "

  test "Rustler's code running in the module body keeps its refusal", ctx do
    # The force-build branch, and a use Rustler of the package's own: with
    # skip_compilation? or after the tool's, its code compiles the crate.
    for app <- ["fx_nif_force", "fx_nif_twice", "fx_rustler"] do
      v = verdict(ctx, app, target: "host", host_native: true)
      assert %{status: :skip, compile_inputs: nil} = v, app
      reasons = Enum.map(v.observations["refusals"], & &1["reason"])

      assert (@rustler_call <> "Rustler.Compiler.compile_crate/2") in reasons,
             inspect({app, reasons})
    end

    # The package's own use Rustler is no expansion of the tool's quote.
    for app <- ["fx_nif_twice", "fx_rustler"] do
      v = verdict(ctx, app, target: "host", host_native: true)
      reasons = Enum.map(v.observations["refusals"], & &1["reason"])
      assert (@rustler_call <> "Rustler.MACRO-__using__/2") in reasons, inspect({app, reasons})
    end
  end

  test "the ram_file driver is the tool's only in its download", ctx do
    for app <- ["fx_nif_peek", "fx_unpack"] do
      v = verdict(ctx, app, target: "host", host_native: true)
      assert %{status: :skip, compile_inputs: nil} = v, app
      reasons = Enum.map(v.observations["refusals"], & &1["reason"])

      assert Enum.any?(reasons, &(&1 =~ "erlang:open_port/2 via ram_file:ll_open/3")),
             inspect({app, reasons}, printable_limit: 200)
    end
  end
end
