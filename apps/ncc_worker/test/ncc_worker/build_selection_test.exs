defmodule NccWorker.BuildSelectionTest do
  use ExUnit.Case, async: true

  alias NccWorker.BuildSelection

  setup do
    root = Path.join(System.tmp_dir!(), "ncc-selection-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

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

  defp package(root, name, fixture \\ "circular_buffer-1.0.0") do
    source = Path.join([root, "deps", name])
    File.mkdir_p!(Path.join(source, "lib"))
    File.write!(Path.join(source, "mix.exs"), "defmodule Example.MixProject do end")
    File.write!(Path.join(source, "lib/example.ex"), "defmodule Example do end")
    build = Path.join([root, "_build", "host", "lib", name])
    File.mkdir_p!(Path.dirname(build))
    File.cp_r!(Path.join([__DIR__, "..", "fixture", fixture]), build)
    lock(root, name, [])
    source
  end

  # Puts `name` in the project's mix.lock with `deps` as its dependencies.
  defp lock(root, name, deps) do
    path = Path.join(root, "mix.lock")
    {entries, _} = if File.exists?(path), do: Code.eval_file(path), else: {%{}, []}
    locked = for dep <- deps, do: {String.to_atom(dep), "~> 1.0", [hex: String.to_atom(dep)]}
    entry = {:hex, String.to_atom(name), "1.0.0", "inner", [:mix], locked, "hexpm", "outer"}
    File.write!(path, inspect(Map.put(entries, name, entry), limit: :infinity))
  end

  # Rewrites `name`'s lock entry with `managers` (Hex's `build_tools`) and
  # returns a `tarball:` whose `metadata.config` lists the same, the only
  # place item 1 reads them from.
  defp lock_managers(root, name, managers) do
    path = Path.join(root, "mix.lock")
    {entries, _} = Code.eval_file(path)
    entry = {:hex, String.to_atom(name), "1.0.0", "inner", managers, [], "hexpm", "outer"}
    File.write!(path, inspect(Map.put(entries, name, entry), limit: :infinity))
    tools_tarball(Enum.map(managers, &Atom.to_string/1))
  end

  defp tools_tarball(build_tools) do
    meta = ~s({<<"build_tools">>,[#{Enum.map_join(build_tools, ",", &~s(<<"#{&1}">>))}]}.\n)
    path = Path.join(System.tmp_dir!(), "ncc-tools-#{System.unique_integer([:positive])}.tar")
    :ok = :erl_tar.create(String.to_charlist(path), [{~c"metadata.config", meta}])
    bytes = File.read!(path)
    File.rm!(path)
    {:binary, bytes}
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

  describe "static_rules/4 (R0)" do
    test "item 1: a Makefile Mix never runs passes only with the flag and a matching manager",
         %{root: root} do
      source = package(root, "sample")
      File.write!(Path.join(source, "Makefile"), "all:\n\tcc -o x x.c\n")
      tarball = lock_managers(root, "sample", [:make, :rebar3])
      native = {:skip, "reads the target or ships native code"}
      on = [makefile_rule2: true, tarball: tarball]

      assert BuildSelection.static_rules(root, "sample", scan(), on ++ [manager: "rebar3"]) == :ok

      # Off, or no manager from the trace: today's verdict.
      assert BuildSelection.static_rules(root, "sample", scan(),
               manager: "rebar3",
               tarball: tarball
             ) == native

      assert BuildSelection.static_rules(root, "sample", scan(), on) == native
      # The trace says make, or disagrees with the tarball (rebar3 vs mix).
      for trace <- ["make", "mix", nil] do
        assert BuildSelection.static_rules(root, "sample", scan(), on ++ [manager: trace]) ==
                 native,
               inspect(trace)
      end

      # No tarball: the lock alone never declassifies.
      assert BuildSelection.static_rules(root, "sample", scan(),
               makefile_rule2: true,
               manager: "rebar3"
             ) == native

      # A lock saying rebar3 over a tarball saying make stays native.
      assert BuildSelection.static_rules(root, "sample", scan(),
               makefile_rule2: true,
               manager: "rebar3",
               tarball: tools_tarball(["make"])
             ) == native

      # [:make] only: Mix falls to the files (mix.exs here, so "mix"), never
      # the trace's rebar3.
      tarball = lock_managers(root, "sample", [:make])

      assert BuildSelection.static_rules(root, "sample", scan(),
               makefile_rule2: true,
               manager: "rebar3",
               tarball: tarball
             ) == native
    end

    test "item 1 keeps every other rule-2 refusal: port_env, a target read, a nerves* name, c_src under mix",
         %{root: root} do
      native = {:skip, "reads the target or ships native code"}

      with_makefile = fn name, managers ->
        source = package(root, name)
        File.write!(Path.join(source, "Makefile"), "all:\n")
        tarball = lock_managers(root, name, managers)
        {source, [makefile_rule2: true, manager: "rebar3", tarball: tarball]}
      end

      {port, opts} = with_makefile.("portenv", [:make, :rebar3])
      File.write!(Path.join(port, "rebar.config"), "{port_env, []}.\n")
      assert BuildSelection.static_rules(root, "portenv", scan(), opts) == native

      {target, opts} = with_makefile.("target", [:make, :rebar3])
      File.write!(Path.join(target, "lib/example.ex"), "Mix.target()")
      assert BuildSelection.static_rules(root, "target", scan(), opts) == native

      {_source, opts} = with_makefile.("nerves_foo", [:make, :rebar3])
      assert BuildSelection.static_rules(root, "nerves_foo", scan(), opts) == native

      refute NccWorker.BuildCache.dep_target_agnostic_rule2?(
               Path.join(root, "deps"),
               "nerves_foo",
               "rebar3"
             )

      {csrc, opts} = with_makefile.("csrcmix", [:make, :mix])
      File.mkdir_p!(Path.join(csrc, "c_src"))

      assert BuildSelection.static_rules(
               root,
               "csrcmix",
               scan(),
               Keyword.put(opts, :manager, "mix")
             ) == native

      # The same package without the extra refusal passes, so each case above
      # is held by its own rule, not by the Makefile.
      {_source, opts} = with_makefile.("control", [:make, :rebar3])
      assert BuildSelection.static_rules(root, "control", scan(), opts) == :ok
    end

    test "item 1 never lets c_src, elixir_make or a missing lock entry through", %{root: root} do
      native = {:skip, "reads the target or ships native code"}
      opts = [makefile_rule2: true, manager: "rebar3"]

      csrc = package(root, "csrc")
      File.mkdir_p!(Path.join(csrc, "c_src"))
      tarball = lock_managers(root, "csrc", [:rebar3])

      assert BuildSelection.static_rules(root, "csrc", scan(), opts ++ [tarball: tarball]) ==
               native

      emake = package(root, "emake")
      File.write!(Path.join(emake, "Makefile"), "all:\n")
      File.write!(Path.join(emake, "mix.exs"), "def project, do: [compilers: [:elixir_make]]")
      tarball = lock_managers(root, "emake", [:mix])

      assert BuildSelection.static_rules(root, "emake", scan(),
               makefile_rule2: true,
               manager: "mix",
               tarball: tarball
             ) ==
               native

      unlocked = package(root, "unlocked")
      File.write!(Path.join(unlocked, "Makefile"), "all:\n")
      {entries, _} = Code.eval_file(Path.join(root, "mix.lock"))

      File.write!(
        Path.join(root, "mix.lock"),
        inspect(Map.delete(entries, "unlocked"), limit: :infinity)
      )

      assert BuildSelection.static_rules(root, "unlocked", scan(), opts) == native
    end

    test "runtime program calls and the OS grep do not refuse", %{root: root} do
      source = package(root, "sample")
      File.write!(Path.join(source, "lib/example.ex"), "def os, do: :os.type()\n")

      File.write!(
        Path.join(source, "rebar.config"),
        ~s|{erl_opts, [{platform_define, "win32", 'WIN'}]}.|
      )

      calls =
        scan(%{
          shell_calls?: true,
          shell_evidence: evidence({:os, :cmd, 1}),
          os_exec_calls?: true,
          os_exec_evidence: evidence({System, :cmd, 3}),
          executable_lookup_calls?: true,
          executable_lookup_evidence: evidence({System, :find_executable, 1})
        })

      assert BuildSelection.static_rules(root, "sample", calls) == :ok
      assert {:skip, "calls os:cmd/1"} = BuildSelection.portable?(root, "sample", calls)
    end

    test "a mention of nerves in the sources still refuses", %{root: root} do
      source = package(root, "sample")
      File.write!(Path.join(source, "lib/example.ex"), "# runs on Nerves.Runtime too\n")

      assert BuildSelection.static_rules(root, "sample", scan()) ==
               {:skip, "nerves-specific source"}
    end

    test "NIF loads keep rule 1's reason", %{root: root} do
      package(root, "sample")
      nif = scan(%{nif_calls?: true, nif_evidence: evidence({:erlang, :load_nif, 2})})

      assert BuildSelection.static_rules(root, "sample", nif) ==
               {:skip, "calls erlang:load_nif/2"}

      assert BuildSelection.static_rules(root, "sample", scan(%{nif_calls?: true})) ==
               {:skip, "calls a NIF or port driver"}
    end

    test "beams, languages and scan errors keep rule 1's reasons", %{root: root} do
      package(root, "sample")

      assert BuildSelection.static_rules(root, "sample", scan(%{beam_count: 0})) ==
               {:skip, "no compiled beams"}

      assert BuildSelection.static_rules(root, "sample", scan(%{errors: ["bad"]})) ==
               {:skip, "beam scan incomplete"}

      assert BuildSelection.static_rules(root, "sample", %{}) == {:skip, "beam scan incomplete"}

      assert BuildSelection.static_rules(root, "sample", scan(%{languages: [:elixir, :lfe]})) ==
               {:skip, "beam language lfe is not portable"}
    end

    test "priv files without a tarball keep rule 1's reason", %{root: root} do
      package(root, "sample")
      priv = scan(%{footprint: %{priv: %{file_count: 1, total_bytes: 10}}})
      assert BuildSelection.static_rules(root, "sample", priv) == {:skip, "ships priv files"}
    end

    test "target reads, native sources, a nerves name and a missing source refuse",
         %{root: root} do
      source = package(root, "sample")
      File.write!(Path.join(source, "lib/example.ex"), "Mix.target()")

      assert BuildSelection.static_rules(root, "sample", scan()) ==
               {:skip, "reads the target or ships native code"}

      native = package(root, "native")
      File.mkdir_p!(Path.join(native, "c_src"))

      assert BuildSelection.static_rules(root, "native", scan()) ==
               {:skip, "reads the target or ships native code"}

      package(root, "nerves_thing")

      assert BuildSelection.static_rules(root, "nerves_thing", scan()) ==
               {:skip, "reads the target or ships native code"}

      assert BuildSelection.static_rules(root, "absent", scan()) ==
               {:skip, "reads the target or ships native code"}
    end

    test "every spelling of a target read refuses", %{root: root} do
      for {file, body} <- [
            {"lib/example.ex", "defmodule E do\n  @t Mix.target\nend\n"},
            {"lib/example.ex", "if Mix.target == :host, do: :a, else: :b"},
            {"lib/example.ex", "f = &Mix.target/0"},
            {"lib/example.ex", "Mix . target()"},
            {"lib/example.ex", "Mix.\n  target()"},
            {"mix.exs", "def project, do: [t: Mix.target]"},
            {"lib/example.ex", ~s|System.get_env("MIX_TARGET")|},
            {"src/example.erl", "t() -> 'Elixir.Mix':target()."},
            {"src/example.erl", "t() -> 'Elixir.Mix' : target()."},
            {"include/example.hrl", "-define(T, 'Elixir.Mix':target())."}
          ] do
        name = "pkg#{System.unique_integer([:positive])}"
        source = package(root, name)
        File.mkdir_p!(Path.dirname(Path.join(source, file)))
        File.write!(Path.join(source, file), body)

        assert BuildSelection.static_rules(root, name, scan()) ==
                 {:skip, "reads the target or ships native code"},
               "not refused: #{inspect(body)}"

        assert BuildSelection.portable?(root, name, scan()) ==
                 {:skip, "reads the target or ships native code"}
      end
    end

    test "MIX_TARGET read in config refuses", %{root: root} do
      source = package(root, "sample")
      File.mkdir_p!(Path.join(source, "config"))

      File.write!(
        Path.join(source, "config/config.exs"),
        ~s|import Config\nconfig :sample, target: System.get_env("MIX_TARGET")|
      )

      assert BuildSelection.static_rules(root, "sample", scan()) ==
               {:skip, "reads the target or ships native code"}
    end

    test "a name that only starts like Mix.target does not refuse", %{root: root} do
      source = package(root, "sample")
      File.write!(Path.join(source, "lib/example.ex"), "Mix.targets_of(x)\nMyMix.target_dir()")
      assert BuildSelection.static_rules(root, "sample", scan()) == :ok
    end

    # The target and Nerves checks cover the package only. A dependency's
    # compile-time `Mix.target/0` call, such as a macro expanded into the
    # package's beams, is meant to be judged by the compile-time trace
    # (`NccWorker.Portability`) instead.
    test "a dependency's macro that reads the target passes", %{root: root} do
      package(root, "sample")
      helper = package(root, "helper")
      lock(root, "sample", ["helper"])

      File.write!(
        Path.join(helper, "lib/example.ex"),
        "defmodule Helper do\n  defmacro target, do: Mix.target()\nend\n"
      )

      assert BuildSelection.static_rules(root, "sample", scan()) == :ok
    end

    test "a transitive dependency that mentions nerves passes", %{root: root} do
      package(root, "sample")
      package(root, "middle")
      leaf = package(root, "leaf")
      lock(root, "sample", ["middle"])
      lock(root, "middle", ["leaf"])
      File.write!(Path.join(leaf, "lib/example.ex"), "# works with Nerves.Runtime\n")

      assert BuildSelection.static_rules(root, "sample", scan()) == :ok
    end

    test "ordinary dependencies pass, native ones included", %{root: root} do
      package(root, "sample")
      package(root, "helper")
      native = package(root, "native")
      File.mkdir_p!(Path.join(native, "c_src"))
      lock(root, "sample", ["helper", "native"])

      assert BuildSelection.static_rules(root, "sample", scan()) == :ok
    end

    test "a project under a path that says nerves is judged by its contents", %{root: root} do
      root = Path.join([root, "nerves_x", "nerves_compatibility"])
      package(root, "sample")
      package(root, "helper")
      lock(root, "sample", ["helper"])

      assert BuildSelection.static_rules(root, "sample", scan()) == :ok
      assert BuildSelection.portable?(root, "sample", scan()) == :ok

      graph = %{"root" => ["sample"], "sample" => ["helper"]}
      assert BuildSelection.classify(root, "sample", "A collection", graph) == :pure_elixir

      assert BuildSelection.static_rules(root, "absent", scan()) ==
               {:skip, "reads the target or ships native code"}

      assert BuildSelection.portable?(root, "absent", scan()) ==
               {:skip, "reads the target or ships native code"}
    end

    test "a real scan of an Erlang-only package passes", %{root: root} do
      package(root, "cerlc", "cerlc-0.2.1")
      built = Path.join([root, "_build", "host", "lib", "cerlc"])
      assert BuildSelection.static_rules(root, "cerlc", BeamScanner.analyze(built)) == :ok
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
