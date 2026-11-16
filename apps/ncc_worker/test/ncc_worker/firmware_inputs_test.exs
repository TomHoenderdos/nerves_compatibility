defmodule NccWorker.FirmwareInputsTest do
  use ExUnit.Case, async: true

  alias NccWorker.FirmwareInputs

  @moduletag :tmp_dir

  @manifest %{"footprint" => %{"file_manifest" => %{"ebin" => []}}}
  @inputs [%{"kind" => "mix_target", "value" => "rpi4"}]
  @env [%{app: "pkg", path: ["default_backend"], value: "g3cFZXJyb3I"}]

  defp pass(extra \\ %{}), do: Map.merge(%{status: :pass, beam_scan: @manifest}, extra)

  defp project(tmp_dir, lib) do
    dir = Path.join([tmp_dir, "deps", "pkg", "lib"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "pkg.ex"), lib)
    tmp_dir
  end

  @module_read """
  defmodule Pkg do
    case System.get_env("PKG_DEV") do
      "normal" -> def dev, do: :normal
      _ -> def dev, do: :none
    end
  end
  """

  defp ctx(project_dir, names) do
    %{
      project_dir: project_dir,
      package: "pkg",
      targets: Map.new(names, &{&1, {"rpi4", [{"MIX_TARGET", "rpi4"}]}}),
      releases: %{},
      trees: %{},
      started_at: nil,
      work_dir: project_dir,
      log_dir: project_dir
    }
  end

  defp recorder(test_pid, outcome) do
    fn name, target_env, _ctx, _result ->
      send(test_pid, {:recorded, name, target_env})
      outcome
    end
  end

  describe "env_reads?/1" do
    test "a module-level env read in lib/ is one", %{tmp_dir: tmp_dir} do
      assert FirmwareInputs.env_reads?(Path.join([project(tmp_dir, @module_read), "deps", "pkg"]))
    end

    test "a read in a function body runs at runtime and is not", %{tmp_dir: tmp_dir} do
      lib = "defmodule Pkg do\n  def dev, do: System.get_env(\"PKG_DEV\")\nend\n"
      refute FirmwareInputs.env_reads?(Path.join([project(tmp_dir, lib), "deps", "pkg"]))
    end

    test "every spelling the client scans for", %{tmp_dir: tmp_dir} do
      for call <- ~w[System.fetch_env("X") System.fetch_env!("X") :os.getenv(~c"X")] do
        lib = "defmodule Pkg do\n  @x #{call}\n  def x, do: @x\nend\n"
        dir = Path.join(tmp_dir, Base.encode16(call))
        assert FirmwareInputs.env_reads?(Path.join([project(dir, lib), "deps", "pkg"])), call
      end
    end

    test "no lib/ reads nothing", %{tmp_dir: tmp_dir} do
      refute FirmwareInputs.env_reads?(Path.join(tmp_dir, "nothing"))
    end
  end

  describe "put/3" do
    test "records a passing target that publishes its own first build", %{tmp_dir: tmp_dir} do
      proj = project(tmp_dir, @module_read)
      record = recorder(self(), {:ok, %{compile_inputs: @inputs, compile_env: @env}})

      {systems, lines} =
        FirmwareInputs.put(%{"nerves_system_rpi4" => pass()}, ctx(proj, ["nerves_system_rpi4"]),
          record: record
        )

      assert %{compile_inputs: @inputs, compile_env: @env, status: :pass} =
               systems["nerves_system_rpi4"]

      assert_received {:recorded, "nerves_system_rpi4", {"rpi4", [{"MIX_TARGET", "rpi4"}]}}
      assert lines == ["Compile inputs of nerves_system_rpi4 recorded"]
    end

    test "a target that fails, publishes nothing, or was built against another closure is left",
         %{tmp_dir: tmp_dir} do
      proj = project(tmp_dir, @module_read)

      systems = %{
        "failed" => %{status: :fail, beam_scan: @manifest},
        "withheld" => %{status: :pass, beam_scan: %{"footprint" => %{}}},
        "optional" => pass(%{deps_lock: %{"x" => %{}}}),
        "variants" => pass(%{published_variants: [%{variant: "without"}]}),
        "no_env" => pass()
      }

      names = Map.keys(systems) -- ["no_env"]
      record = recorder(self(), {:ok, %{compile_inputs: @inputs, compile_env: @env}})

      assert FirmwareInputs.put(systems, ctx(proj, names), record: record) == {systems, []}
      refute_received {:recorded, _, _}
    end

    test "a package that reads no env at module level is never traced", %{tmp_dir: tmp_dir} do
      proj = project(tmp_dir, "defmodule Pkg do\n  def x, do: System.get_env(\"X\")\nend\n")
      systems = %{"rpi4" => pass()}
      record = recorder(self(), {:ok, %{compile_inputs: @inputs, compile_env: @env}})

      assert FirmwareInputs.put(systems, ctx(proj, ["rpi4"]), record: record) == {systems, []}
      refute_received {:recorded, _, _}
    end

    # `Portal.Builder` kills the container at 2 h and the whole run is lost:
    # past the tracer's ceiling no target starts its Nerves env or trace.
    test "no target is tried once the run's budget is spent", %{tmp_dir: tmp_dir} do
      proj = project(tmp_dir, @module_read)
      systems = %{"rpi4" => pass(), "rpi5" => pass()}
      record = recorder(self(), {:ok, %{compile_inputs: @inputs, compile_env: @env}})

      late = %{
        ctx(proj, ["rpi4", "rpi5"])
        | started_at: System.monotonic_time(:second) - 105 * 60
      }

      assert FirmwareInputs.put(systems, late, record: record) ==
               {systems,
                [
                  "Compile inputs of rpi4 not recorded: run budget exhausted",
                  "Compile inputs of rpi5 not recorded: run budget exhausted"
                ]}

      refute_received {:recorded, _, _}
    end

    test "a target whose inputs could not be recorded keeps none, and says why",
         %{tmp_dir: tmp_dir} do
      proj = project(tmp_dir, @module_read)
      systems = %{"rpi4" => pass()}
      record = recorder(self(), {:error, "the traced compile's beams differ"})

      assert FirmwareInputs.put(systems, ctx(proj, ["rpi4"]), record: record) ==
               {systems,
                ["Compile inputs of rpi4 not recorded: the traced compile's beams differ"]}
    end
  end

  test "pairs/1 reads name NUL value NUL, and nothing else" do
    assert FirmwareInputs.pairs("") == {:ok, []}
    assert FirmwareInputs.pairs("A\0one\0B\0\0") == {:ok, [{"A", "one"}, {"B", ""}]}

    for bad <- ["A\0one", "A\0one\0B\0", "\0x\0", "A\0" <> <<0xFF>> <> "\0"] do
      assert {:error, _} = FirmwareInputs.pairs(bad), inspect(bad)
    end
  end

  describe "roots/2" do
    setup %{tmp_dir: tmp_dir} do
      artifacts = Path.join(tmp_dir, "artifacts")
      tc = Path.join(artifacts, "nerves_toolchain_aarch64_nerves_linux_gnu-15.3.1")
      sys = Path.join(artifacts, "nerves_system_rpi4-2.2.2")
      File.mkdir_p!(tc)
      File.mkdir_p!(sys)
      %{artifacts: artifacts, tc: tc, sys: sys}
    end

    test "the two Nerves paths, artifact dirs of one artifacts dir", c do
      nerves = [
        {"CROSSCOMPILE", c.tc <> "/bin/x"},
        {"NERVES_TOOLCHAIN", c.tc},
        {"NERVES_SYSTEM", c.sys}
      ]

      roots = [{"NERVES_TOOLCHAIN", c.tc}, {"NERVES_SYSTEM", c.sys}]

      assert FirmwareInputs.roots(nerves, c.artifacts) == {:ok, c.artifacts, roots}
      assert FirmwareInputs.roots(nerves, nil) == {:ok, c.artifacts, roots}
    end

    test "anything else is no root", c do
      other = Path.join(c.tmp_dir, "elsewhere/nerves_system_rpi4-2.2.2")
      File.mkdir_p!(other)

      for nerves <- [
            [{"CROSSCOMPILE", c.tc}],
            [{"NERVES_TOOLCHAIN", c.tc}, {"NERVES_SYSTEM", other}],
            [{"NERVES_TOOLCHAIN", c.artifacts}],
            [{"NERVES_TOOLCHAIN", Path.join(c.artifacts, "missing-1.0")}],
            [{"NERVES_TOOLCHAIN", "relative/nerves_toolchain_x-1.0"}]
          ] do
        assert {:error, _} = FirmwareInputs.roots(nerves, nil), inspect(nerves)
      end

      assert {:error, _} = FirmwareInputs.roots([{"NERVES_TOOLCHAIN", c.tc}], "/other/artifacts")
    end
  end

  describe "move/4" do
    setup %{tmp_dir: tmp_dir} do
      artifacts = Path.join(tmp_dir, "artifacts")
      tc = Path.join(artifacts, "nerves_toolchain_aarch64_nerves_linux_gnu-15.3.1")
      sys = Path.join(artifacts, "nerves_system_rpi4-2.2.2")
      work = Path.join(tmp_dir, "work")
      Enum.each([tc, sys, work], &File.mkdir_p!/1)

      %{
        artifacts: artifacts,
        roots: [{"NERVES_TOOLCHAIN", tc}, {"NERVES_SYSTEM", sys}],
        work: work
      }
    end

    # A client takes a build made on another release of its system (another
    # system version, a toolchain of the same series), whose roots are named
    # for it: the trace must not have them under their builder names, or a
    # beam that keeps a root's name (its version) binds as well.
    test "moves each root whole, its name included, and every variable with it", c do
      [{_, tc}, {_, sys}] = c.roots

      nerves = [
        {"CROSSCOMPILE", tc <> "/bin/aarch64-nerves-linux-gnu"},
        {"NERVES_TOOLCHAIN", tc},
        {"NERVES_SYSTEM", sys},
        {"CFLAGS", "--sysroot=#{sys}/staging -O2"},
        {"OTHER", "plain"}
      ]

      assert {:ok, moved, moved_roots} = FirmwareInputs.move(nerves, c.artifacts, c.roots, c.work)
      assert Enum.map(moved_roots, &elem(&1, 0)) == ["NERVES_TOOLCHAIN", "NERVES_SYSTEM"]

      for {{_name, root}, {_moved_name, link}} <- Enum.zip(c.roots, moved_roots) do
        refute String.contains?(link, Path.basename(root)), link
        refute String.contains?(link, c.artifacts)
        assert File.read_link!(link) == root
      end

      for {{name, value}, {moved_name, moved_value}} <- Enum.zip(nerves, moved) do
        assert moved_name == name
        refute String.contains?(moved_value, c.artifacts)

        assert Compatibility.CompileInputs.split(moved_value, moved_roots) ==
                 Compatibility.CompileInputs.split(value, c.roots)
      end
    end

    test "a variable naming the artifacts dir anywhere but at a root is not moved", c do
      other = Path.join(c.artifacts, "nerves_toolchain_other-1.0")
      nerves = [{"NERVES_TOOLCHAIN", elem(hd(c.roots), 1)}, {"OTHER_TOOLCHAIN", other}]

      assert {:error, _} = FirmwareInputs.move(nerves, c.artifacts, c.roots, c.work)
    end
  end

  # A persisted attribute is in the beam's attributes chunk, which
  # `:beam_lib.md5/1` leaves out, and a running system reads it
  # (`module_info(:attributes)`): a value the compile took from a root's path
  # would bind otherwise.
  test "fingerprints/1 tells apart beams whose code is the same and persisted attributes differ",
       %{tmp_dir: tmp_dir} do
    ebins =
      for value <- ["/a/nerves_system_rpi4-2.2.2", "/b/nerves_system_rpi4-2.3.0"] do
        source = """
        defmodule FirmwareInputsAttrProbe do
          Module.register_attribute(__MODULE__, :system, persist: true)
          @system #{inspect(value)}
          def x, do: 1
        end
        """

        [{mod, bin}] = Code.compile_string(source, "probe.ex")
        :code.purge(mod)
        :code.delete(mod)
        ebin = Path.join([tmp_dir, Base.encode16(value), "ebin"])
        File.mkdir_p!(ebin)
        File.write!(Path.join(ebin, "#{mod}.beam"), bin)
        ebin
      end

    [a, b] = Enum.map(ebins, &FirmwareInputs.fingerprints/1)
    assert map_size(a) == 1
    assert a != b
  end

  test "fingerprints/1 reads each beam's code md5 and attributes, and nothing when one is unreadable",
       %{tmp_dir: tmp_dir} do
    [{mod, bin}] =
      Code.compile_string("defmodule FirmwareInputsMd5Probe, do: def(x, do: 1)", "probe.ex")

    ebin = Path.join(tmp_dir, "ebin")
    File.mkdir_p!(ebin)
    File.write!(Path.join(ebin, "#{mod}.beam"), bin)
    {:ok, {^mod, md5}} = :beam_lib.md5(bin)
    {:ok, {^mod, [{~c"Attr", attrs}]}} = :beam_lib.chunks(bin, [~c"Attr"])

    assert FirmwareInputs.fingerprints(ebin) == %{mod => {md5, attrs}}
    File.write!(Path.join(ebin, "broken.beam"), "not a beam")
    assert FirmwareInputs.fingerprints(ebin) == %{}
    assert FirmwareInputs.fingerprints(Path.join(tmp_dir, "none")) == %{}
  end
end
