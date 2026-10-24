defmodule NccWorker.BuildSelectionTest do
  use ExUnit.Case, async: true

  alias NccWorker.BuildSelection

  setup do
    root = Path.join(System.tmp_dir!(), "ncc-selection-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp package(root, name, fixture \\ "circular_buffer-1.0.0") do
    source = Path.join([root, "deps", name])
    File.mkdir_p!(Path.join(source, "lib"))
    File.write!(Path.join(source, "mix.exs"), "defmodule Example.MixProject do end")
    File.write!(Path.join(source, "lib/example.ex"), "defmodule Example do end")
    build = Path.join([root, "_build", "host", "lib", name])
    File.mkdir_p!(Path.dirname(build))
    File.cp_r!(Path.join([__DIR__, "..", "fixture", fixture]), build)
    source
  end

  test "pure Elixir and its pure dependency closure skip firmware", %{root: root} do
    package(root, "wrapper")
    package(root, "leaf")
    graph = %{"root" => ["wrapper", "nerves"], "wrapper" => ["leaf"]}
    assert BuildSelection.classify(root, "wrapper", "A collection", graph) == :pure_elixir
  end

  test "a transitive NIF still requires firmware", %{root: root} do
    package(root, "wrapper")
    package(root, "leaf", "circuits_gpio-2.1.3")
    graph = %{"root" => ["wrapper"], "wrapper" => ["leaf"]}
    assert BuildSelection.classify(root, "wrapper", "", graph) == :firmware
  end

  test "ports are not classified as pure Elixir", %{root: root} do
    package(root, "uart", "circuits_uart-1.5.5")
    assert BuildSelection.classify(root, "uart", "", %{"root" => ["uart"]}) == :firmware
  end

  test "Nerves metadata and target-specific sources require firmware", %{root: root} do
    source = package(root, "sensor")
    graph = %{"root" => ["sensor"]}
    assert BuildSelection.classify(root, "sensor", "A Nerves sensor", graph) == :firmware
    File.write!(Path.join(source, "lib/example.ex"), "Mix.target()")
    assert BuildSelection.classify(root, "sensor", "", graph) == :firmware
  end

  test "native sources are held out even if the host BEAM has no NIF calls", %{root: root} do
    source = package(root, "native")
    File.mkdir_p!(Path.join(source, "c_src"))
    assert BuildSelection.classify(root, "native", "", %{"root" => ["native"]}) == :firmware
  end

  test "missing dependency sources, graph entries or compiled modules fail closed", %{root: root} do
    package(root, "wrapper")
    assert BuildSelection.classify(root, "wrapper", "", %{}) == :firmware
    graph = %{"root" => ["wrapper"], "wrapper" => ["missing"]}
    assert BuildSelection.classify(root, "wrapper", "", graph) == :firmware
    File.rm_rf!(Path.join([root, "_build", "host", "lib", "wrapper", "ebin"]))
    assert BuildSelection.classify(root, "wrapper", "", %{"root" => ["wrapper"]}) == :firmware
  end

  test "dependency cycles terminate and unrelated wrapper dependencies are ignored", %{root: root} do
    package(root, "a")
    package(root, "b")
    graph = %{"root" => ["a", "nerves"], "a" => ["b"], "b" => ["a"]}
    assert BuildSelection.classify(root, "a", "", graph) == :pure_elixir
  end

  test "a failed host compile never implies compatibility", %{root: root} do
    assert BuildSelection.select(root, "sample", "", %{status: :fail}, []) == :firmware
  end

  test "corrupt BEAM evidence keeps firmware enabled", %{root: root} do
    package(root, "sample")
    File.write!(Path.join([root, "_build", "host", "lib", "sample", "ebin", "bad.beam"]), "bad")
    assert BuildSelection.classify(root, "sample", "", %{"root" => ["sample"]}) == :firmware
  end

  test "newly compiled host modules can be classified", %{root: root} do
    package(root, "sample")

    [{module, binary}] =
      Code.compile_quoted(
        quote do
          defmodule NccWorker.TestCompiledPure do
            def size(value), do: byte_size(value)
          end
        end
      )

    path = Path.join([root, "_build", "host", "lib", "sample", "ebin", "#{module}.beam"])
    File.write!(path, binary)
    assert BuildSelection.classify(root, "sample", "", %{"root" => ["sample"]}) == :pure_elixir
  end

  test "looking up an executable on the PATH requires firmware", %{root: root} do
    package(root, "sample")

    [{module, binary}] =
      Code.compile_quoted(
        quote do
          defmodule NccWorker.TestCompiledFindExecutable do
            def ffmpeg, do: System.find_executable("ffmpeg")
          end
        end
      )

    path = Path.join([root, "_build", "host", "lib", "sample", "ebin", "#{module}.beam"])
    File.write!(path, binary)
    assert BuildSelection.classify(root, "sample", "", %{"root" => ["sample"]}) == :firmware
  end

  test "a closure with an Erlang dependency still requires firmware", %{root: root} do
    package(root, "wrapper")
    package(root, "cerlc", "cerlc-0.2.1")
    graph = %{"root" => ["wrapper"], "wrapper" => ["cerlc"]}
    assert BuildSelection.classify(root, "wrapper", "", graph) == :firmware
  end

  describe "portable?/3" do
    defp scan(overrides \\ %{}) do
      Map.merge(
        %{
          beam_count: 2,
          languages: [:elixir, :erlang],
          errors: [],
          nif_calls?: false,
          nif_evidence: [],
          shell_calls?: false,
          shell_evidence: [],
          os_exec_calls?: false,
          os_exec_evidence: [],
          executable_lookup_calls?: false,
          executable_lookup_evidence: [],
          footprint: %{priv: %{file_count: 0, total_bytes: 0}}
        },
        overrides
      )
    end

    defp evidence(mfa), do: [%{beam: Example, file: "Example.beam", mfa: mfa}]

    test "Elixir and Erlang beams with no calls are portable", %{root: root} do
      package(root, "sample")
      assert BuildSelection.portable?(root, "sample", scan()) == :ok
    end

    test "a real scan of an Erlang-only package is portable", %{root: root} do
      package(root, "cerlc", "cerlc-0.2.1")
      built = Path.join([root, "_build", "host", "lib", "cerlc"])
      assert BuildSelection.portable?(root, "cerlc", BeamScanner.analyze(built)) == :ok
    end

    test "another beam language is not portable", %{root: root} do
      package(root, "sample")

      assert BuildSelection.portable?(root, "sample", scan(%{languages: [:elixir, :lfe]})) ==
               {:skip, "beam language lfe is not portable"}
    end

    test "a NIF names the call from the scan's evidence", %{root: root} do
      package(root, "sample")
      nif = scan(%{nif_calls?: true, nif_evidence: evidence({:erlang, :load_nif, 2})})
      assert BuildSelection.portable?(root, "sample", nif) == {:skip, "calls erlang:load_nif/2"}

      bare = scan(%{nif_calls?: true})

      assert BuildSelection.portable?(root, "sample", bare) ==
               {:skip, "calls a NIF or port driver"}
    end

    test "shell, OS command and executable lookups are not portable", %{root: root} do
      package(root, "sample")
      shell = scan(%{shell_calls?: true, shell_evidence: evidence({:os, :cmd, 1})})
      assert BuildSelection.portable?(root, "sample", shell) == {:skip, "calls os:cmd/1"}

      exec = scan(%{os_exec_calls?: true, os_exec_evidence: evidence({System, :cmd, 3})})
      assert BuildSelection.portable?(root, "sample", exec) == {:skip, "calls System.cmd/3"}

      lookup = scan(%{executable_lookup_calls?: true})

      assert {:skip, "calls " <> _} = BuildSelection.portable?(root, "sample", lookup)
    end

    test "priv files are not portable", %{root: root} do
      package(root, "sample")
      priv = scan(%{footprint: %{priv: %{file_count: 1, total_bytes: 10}}})
      assert BuildSelection.portable?(root, "sample", priv) == {:skip, "ships priv files"}
    end

    test "an empty or unreadable scan is not portable", %{root: root} do
      package(root, "sample")
      assert {:skip, _} = BuildSelection.portable?(root, "sample", scan(%{beam_count: 0}))
      assert {:skip, _} = BuildSelection.portable?(root, "sample", scan(%{errors: ["bad"]}))
      assert {:skip, _} = BuildSelection.portable?(root, "sample", %{})
    end

    test "Nerves-specific source is not portable", %{root: root} do
      source = package(root, "sample")
      File.write!(Path.join(source, "lib/example.ex"), "Nerves.Runtime.reboot()")

      assert BuildSelection.portable?(root, "sample", scan()) ==
               {:skip, "nerves-specific source"}
    end

    test "target reads and native sources are not portable", %{root: root} do
      source = package(root, "sample")
      File.write!(Path.join(source, "lib/example.ex"), "Mix.target()")

      assert BuildSelection.portable?(root, "sample", scan()) ==
               {:skip, "reads the target or ships native code"}

      native = package(root, "native")
      File.mkdir_p!(Path.join(native, "c_src"))

      assert BuildSelection.portable?(root, "native", scan()) ==
               {:skip, "reads the target or ships native code"}
    end

    test "rebar platform_define is OS-specific", %{root: root} do
      source = package(root, "sample")

      File.write!(
        Path.join(source, "rebar.config"),
        ~s|{erl_opts, [{platform_define, "win32", 'WIN'}]}.|
      )

      assert BuildSelection.portable?(root, "sample", scan()) ==
               {:skip, "OS-specific (rebar.config: platform_define)"}
    end

    test "OS type and architecture lookups in sources are OS-specific", %{root: root} do
      for {file, body, needle} <- [
            {"lib/example.ex", "def os, do: :os.type()", ":os.type("},
            {"src/example.erl", "os() -> os:type().", "os:type("},
            {"include/example.hrl", "-define(A, erlang:system_info(system_architecture)).",
             "system_architecture"},
            {"src/example.app.src", "{env, [{arch, system_architecture}]}", "system_architecture"}
          ] do
        name = "pkg#{System.unique_integer([:positive])}"
        source = package(root, name)
        File.mkdir_p!(Path.dirname(Path.join(source, file)))
        File.write!(Path.join(source, file), body)

        assert BuildSelection.portable?(root, name, scan()) ==
                 {:skip, "OS-specific (#{file}: #{needle})"}
      end
    end
  end

  describe "BuildCache.os_agnostic?/1" do
    test "a plain package is OS-agnostic and a missing directory fails closed", %{root: root} do
      source = package(root, "sample")
      assert NccWorker.BuildCache.os_agnostic?(source) == :ok

      assert {:error, {_, "grep failed"}} =
               NccWorker.BuildCache.os_agnostic?(Path.join(root, "missing"))
    end

    test "a rebar.config.script fails closed, whatever it says", %{root: root} do
      source = package(root, "scripted")
      File.write!(Path.join(source, "rebar.config.script"), "CONFIG.\n")

      assert NccWorker.BuildCache.os_agnostic?(source) ==
               {:error, {"rebar.config.script", "present"}}
    end
  end
end
