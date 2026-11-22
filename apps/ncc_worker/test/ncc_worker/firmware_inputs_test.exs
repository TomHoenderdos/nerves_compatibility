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

    test "the portal's rollback (NCC_INPUT firmware_inputs: false) traces nothing",
         %{tmp_dir: tmp_dir} do
      proj = project(tmp_dir, @module_read)
      systems = %{"rpi4" => pass()}
      record = recorder(self(), {:ok, %{compile_inputs: @inputs, compile_env: @env}})
      off = Map.put(ctx(proj, ["rpi4"]), :enabled, false)

      assert FirmwareInputs.put(systems, off, record: record) == {systems, []}
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

  describe "put/3 with the firmware judge" do
    @plain "defmodule Pkg do\n  def x, do: System.get_env(\"X\")\nend\n"
    @probe "compile-time probe of whether a module is loaded: Jason"

    defp judging(ctx, extra \\ %{}), do: ctx |> Map.put(:judge, true) |> Map.merge(extra)

    defp withheld?(result), do: not Map.has_key?(result.beam_scan["footprint"], "file_manifest")

    test "traces a package that reads no env; a pass records the judge, not inputs",
         %{tmp_dir: tmp_dir} do
      proj = project(tmp_dir, @plain)
      record = recorder(self(), {:ok, %{compile_inputs: @inputs, compile_env: @env}})

      {systems, lines} =
        FirmwareInputs.put(%{"rpi4" => pass()}, judging(ctx(proj, ["rpi4"])), record: record)

      assert_received {:recorded, "rpi4", _}
      result = systems["rpi4"]
      assert result.firmware_judge == %{status: "pass", reason: nil, classes: []}
      refute Map.has_key?(result, :compile_inputs)
      refute withheld?(result)
      assert lines == ["Firmware judge of rpi4: pass"]
    end

    test "an env-reading package gets its inputs and the judge", %{tmp_dir: tmp_dir} do
      proj = project(tmp_dir, @module_read)
      record = recorder(self(), {:ok, %{compile_inputs: @inputs, compile_env: @env}})

      {systems, lines} =
        FirmwareInputs.put(%{"rpi4" => pass()}, judging(ctx(proj, ["rpi4"])), record: record)

      assert %{compile_inputs: @inputs, firmware_judge: %{status: "pass"}} = systems["rpi4"]

      assert lines == [
               "Compile inputs of rpi4 recorded",
               "Firmware judge of rpi4: pass"
             ]
    end

    test "a probe, plugin or hook refusal withholds the target's files, its status kept",
         %{tmp_dir: tmp_dir} do
      proj = project(tmp_dir, @module_read)

      for {texts, classes} <- [
            {["portability could not be judged", "pkg: " <> @probe], ["probe"]},
            {["rebar3 build runs plugins"], ["plugins_hooks"]},
            {["closure dependency observed the host: crc32cer (rebar3 build runs pre_hooks)"],
             ["taint"]}
          ] do
        record = recorder(self(), {:skip, hd(texts), texts})

        {systems, lines} =
          FirmwareInputs.put(%{"rpi4" => pass()}, judging(ctx(proj, ["rpi4"])), record: record)

        result = systems["rpi4"]
        assert result.status == :pass
        assert withheld?(result), inspect(texts)
        refute Map.has_key?(result, :compile_inputs)
        assert result.firmware_judge == %{status: "skipped", reason: hd(texts), classes: classes}

        assert lines == [
                 "Compile inputs of rpi4 not recorded: #{hd(texts)}",
                 "Files of rpi4 not published: firmware judge (#{Enum.join(classes, ", ")}): " <>
                   hd(texts)
               ]
      end
    end

    test "any other refusal, or no verdict, leaves the files and records unjudged",
         %{tmp_dir: tmp_dir} do
      proj = project(tmp_dir, @plain)

      for {outcome, reason} <- [
            {{:skip, "compile-time host read: os:getenv/1 (HOME)",
              ["compile-time host read: os:getenv/1 (HOME)"]},
             "compile-time host read: os:getenv/1 (HOME)"},
            {{:error, "the traced compile's beams differ from the published ones"},
             "the traced compile's beams differ from the published ones"}
          ] do
        record = recorder(self(), outcome)

        {systems, lines} =
          FirmwareInputs.put(%{"rpi4" => pass()}, judging(ctx(proj, ["rpi4"])), record: record)

        refute withheld?(systems["rpi4"])

        assert systems["rpi4"].firmware_judge == %{
                 status: "unjudged",
                 reason: reason,
                 classes: []
               }

        assert lines == ["Firmware judge of rpi4: unjudged (#{reason})"]
      end
    end

    test "a target built against another closure than the run's is unjudged and not traced",
         %{tmp_dir: tmp_dir} do
      proj = project(tmp_dir, @plain)

      systems = %{
        "optional" => pass(%{deps_lock: %{"x" => %{}}}),
        "variants" => pass(%{published_variants: [%{variant: "without"}]}),
        "failed" => %{status: :fail, beam_scan: @manifest},
        "withheld" => %{status: :pass, beam_scan: %{"footprint" => %{}}}
      }

      record = recorder(self(), {:ok, %{compile_inputs: @inputs, compile_env: @env}})

      {out, lines} =
        FirmwareInputs.put(systems, judging(ctx(proj, Map.keys(systems))), record: record)

      refute_received {:recorded, _, _}

      for name <- ["optional", "variants"] do
        assert out[name].firmware_judge ==
                 %{status: "unjudged", reason: "closure differs from the run's", classes: []}
      end

      assert out["failed"] == systems["failed"]
      assert out["withheld"] == systems["withheld"]
      assert length(lines) == 2
    end

    test "the judge's own budget leaves the rest unjudged; an env reader's inputs are still tried",
         %{tmp_dir: tmp_dir} do
      record = recorder(self(), {:ok, %{compile_inputs: @inputs, compile_env: @env}})
      spent = %{judge_budget_sec: 0}

      plain = project(Path.join(tmp_dir, "plain"), @plain)

      {systems, lines} =
        FirmwareInputs.put(%{"rpi4" => pass()}, judging(ctx(plain, ["rpi4"]), spent),
          record: record
        )

      refute_received {:recorded, _, _}

      assert systems["rpi4"].firmware_judge ==
               %{status: "unjudged", reason: "firmware judge budget spent", classes: []}

      assert lines == ["Firmware judge of rpi4: unjudged (firmware judge budget spent)"]

      reader = project(Path.join(tmp_dir, "reader"), @module_read)

      {systems, _lines} =
        FirmwareInputs.put(%{"rpi4" => pass()}, judging(ctx(reader, ["rpi4"]), spent),
          record: record
        )

      assert_received {:recorded, "rpi4", _}
      assert %{compile_inputs: @inputs, firmware_judge: %{status: "pass"}} = systems["rpi4"]
    end

    test "with the inputs pass off, an env reader is judged but records no inputs",
         %{tmp_dir: tmp_dir} do
      proj = project(tmp_dir, @module_read)
      record = recorder(self(), {:ok, %{compile_inputs: @inputs, compile_env: @env}})
      ctx = judging(ctx(proj, ["rpi4"]), %{enabled: false})

      {systems, lines} = FirmwareInputs.put(%{"rpi4" => pass()}, ctx, record: record)

      refute Map.has_key?(systems["rpi4"], :compile_inputs)
      assert systems["rpi4"].firmware_judge.status == "pass"
      assert lines == ["Firmware judge of rpi4: pass"]
    end

    test "the judge off leaves a package that reads no env untraced", %{tmp_dir: tmp_dir} do
      proj = project(tmp_dir, @plain)
      record = recorder(self(), {:ok, %{compile_inputs: @inputs, compile_env: @env}})
      ctx = Map.put(ctx(proj, ["rpi4"]), :judge, false)

      assert FirmwareInputs.put(%{"rpi4" => pass()}, ctx, record: record) ==
               {%{"rpi4" => pass()}, []}

      refute_received {:recorded, _, _}
    end
  end

  # The judge ships off (review S7): only a portal node with
  # NCC_FIRMWARE_JUDGE=1 sends `NCC_INPUT.firmware_judge: true`. The
  # worker's own env cannot reach the container (review N1), so nothing else
  # turns it on.
  test "judge_enabled?/1 is on only when the input says true" do
    assert FirmwareInputs.judge_enabled?(%{firmware_judge: true})
    refute FirmwareInputs.judge_enabled?(%{})
    refute FirmwareInputs.judge_enabled?(%{firmware_judge: false})
    refute FirmwareInputs.judge_enabled?(%{firmware_judge: "true"})
  end

  test "judge_budget/1 is the input's, else 1800 s" do
    assert FirmwareInputs.judge_budget(%{firmware_judge_budget_sec: 600}) == 600
    assert FirmwareInputs.judge_budget(%{firmware_judge_budget_sec: 0}) == 0
    assert FirmwareInputs.judge_budget(%{}) == 1800
    assert FirmwareInputs.judge_budget(%{firmware_judge_budget_sec: -1}) == 1800
    assert FirmwareInputs.judge_budget(%{firmware_judge_budget_sec: "600"}) == 1800
  end

  test "a target whose dirs could not be put back fails the run", %{tmp_dir: tmp_dir} do
    proj = project(tmp_dir, @module_read)
    systems = %{"rpi3" => pass(), "rpi4" => pass()}

    record = fn name, _target_env, _ctx, _result ->
      send(self(), {:recorded, name})
      raise FirmwareInputs.LayoutNotRestored, "stash -> deps: :eacces"
    end

    assert FirmwareInputs.put(systems, ctx(proj, ["rpi3", "rpi4"]), record: record) ==
             {:error, {:firmware_inputs_layout_not_restored, "stash -> deps: :eacces"}}

    assert_received {:recorded, "rpi3"}
    refute_received {:recorded, "rpi4"}

    assert NccWorker.CLI.exit_code(
             {:error, {:firmware_inputs_layout_not_restored, "stash -> deps: :eacces"}}
           ) == 10
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

  describe "the build's layout" do
    # A project after a target's firmware build: the run's own `deps/`, and
    # the target's deps and build dirs, each with a file naming it.
    setup %{tmp_dir: tmp_dir} do
      proj = Path.join(tmp_dir, "proj")

      for {rel, name} <- [
            {"deps/pkg", "run"},
            {"deps_rpi4/pkg", "target"},
            {"_build/rpi4", "build"}
          ] do
        File.mkdir_p!(Path.join(proj, rel))
        File.write!(Path.join([proj, rel, "which"]), name)
      end

      env = [
        {"MIX_TARGET", "rpi4"},
        {"MIX_BUILD_PATH", Path.join(proj, "_build/rpi4")},
        {"MIX_DEPS_PATH", Path.join(proj, "deps_rpi4")},
        {"MIX_ENV", "prod"}
      ]

      dir = Path.join(tmp_dir, "fw-inputs-rpi4")
      %{proj: proj, env: env, dir: dir, kept: Path.join(dir, "_build")}
    end

    defp which(proj, rel), do: File.read(Path.join([proj, rel, "which"]))

    test "is the target's own build and deps dirs, and the run's deps/", c do
      assert {:ok, layout} = FirmwareInputs.layout(c.proj, "rpi4", c.env)

      assert layout == %{
               build: Path.join(c.proj, "_build/rpi4"),
               deps: Path.join(c.proj, "deps_rpi4"),
               host_deps: Path.join(c.proj, "deps")
             }

      relative = List.keyreplace(c.env, "MIX_DEPS_PATH", 0, {"MIX_DEPS_PATH", "deps_rpi4"})
      assert {:ok, ^layout} = FirmwareInputs.layout(c.proj, "rpi4", relative)
    end

    test "anything else is no layout to trace in", c do
      put = fn name, value -> List.keystore(c.env, name, 0, {name, value}) end
      outside = Path.join(Path.dirname(c.proj), "elsewhere")

      for env <- [
            put.("MIX_TARGET", "rpi3"),
            List.keydelete(c.env, "MIX_BUILD_PATH", 0),
            put.("MIX_BUILD_PATH", outside),
            put.("MIX_DEPS_PATH", outside),
            put.("MIX_BUILD_PATH", Path.join(c.proj, "deps_rpi4/_build")),
            put.("MIX_DEPS_PATH", Path.join(c.proj, "deps/rpi4")),
            put.("MIX_BUILD_PATH", Path.join(c.proj, "_build/none"))
          ] do
        assert {:error, _why} = FirmwareInputs.layout(c.proj, "rpi4", env), inspect(env)
      end
    end

    test "the trace sees the run's deps at the target's paths, and the project is put back",
         c do
      {:ok, layout} = FirmwareInputs.layout(c.proj, "rpi4", c.env)

      seen =
        FirmwareInputs.in_build_layout(layout, c.dir, c.kept, fn ->
          # The trace builds where the build did, and leaves a deps/ behind.
          File.mkdir_p!(Path.join(c.proj, "_build/rpi4/lib"))
          File.write!(Path.join(c.proj, "_build/rpi4/which"), "trace")
          File.mkdir_p!(Path.join(c.proj, "deps"))

          {:seen, which(c.proj, "deps_rpi4/pkg"),
           File.exists?(Path.join(c.proj, "_build/rpi4/lib")) and
             not File.exists?(Path.join(c.proj, "deps/pkg"))}
        end)

      assert seen == {:seen, {:ok, "run"}, true}
      assert which(c.proj, "deps/pkg") == {:ok, "run"}
      assert which(c.proj, "deps_rpi4/pkg") == {:ok, "target"}
      assert which(c.proj, "_build/rpi4") == {:ok, "build"}
      assert which(c.dir, "_build") == {:ok, "trace"}
      refute File.exists?(Path.join(c.dir, "published"))
    end

    test "a trace that raises leaves the project as it was", c do
      {:ok, layout} = FirmwareInputs.layout(c.proj, "rpi4", c.env)

      assert_raise RuntimeError, fn ->
        FirmwareInputs.in_build_layout(layout, c.dir, c.kept, fn -> raise "boom" end)
      end

      assert which(c.proj, "deps/pkg") == {:ok, "run"}
      assert which(c.proj, "deps_rpi4/pkg") == {:ok, "target"}
      assert which(c.proj, "_build/rpi4") == {:ok, "build"}
    end

    # A target whose build read the run's own `deps/` has its published
    # `priv` there (Mix links `_build/<target>/lib/<p>/priv` to the source
    # tree's), and the trace compiles in that very tree: what its compile
    # writes in source (a NIF made into `$(MIX_APP_PATH)/priv`) would be the
    # published file once the build is back. The worker gives every target
    # its own deps dir, so such a target is not traced.
    test "a target that used the run's deps/ itself is no layout to trace in", c do
      priv = Path.join(c.proj, "deps/pkg/priv")
      File.mkdir_p!(priv)
      File.write!(Path.join(priv, "pkg.so"), "build")
      File.mkdir_p!(Path.join(c.proj, "_build/rpi4/lib/pkg"))
      File.ln_s!(priv, Path.join(c.proj, "_build/rpi4/lib/pkg/priv"))

      for env <- [
            List.keydelete(c.env, "MIX_DEPS_PATH", 0),
            List.keystore(c.env, "MIX_DEPS_PATH", 0, {"MIX_DEPS_PATH", "deps"})
          ] do
        result =
          with {:ok, layout} <- FirmwareInputs.layout(c.proj, "rpi4", env) do
            FirmwareInputs.in_build_layout(layout, c.dir, c.kept, fn ->
              File.write!(Path.join(c.proj, "deps/pkg/priv/pkg.so"), "trace")
            end)
          end

        assert {:error, _why} = result, inspect(env)

        assert File.read(Path.join(c.proj, "_build/rpi4/lib/pkg/priv/pkg.so")) ==
                 {:ok, "build"}
      end
    end

    # The binding reads the trace's build where `in_build_layout` moved it.
    # A native build in the trace (a Makefile, which the tracer does not see
    # write) could put the published beams, which it can read where they
    # are moved aside, at that path itself: had the path been fixed, they
    # would bind in place of whatever the trace compiled.
    test "nothing the trace put where its build is kept is taken for its build", c do
      toolchain = Path.join([c.tmp_dir, "artifacts", "nerves_toolchain_fx-1.0.0"])
      File.mkdir_p!(toolchain)
      nerves_env = fn _proj, _env, _dir -> {:ok, [{"NERVES_TOOLCHAIN", toolchain}]} end
      ctx = %{ctx(c.proj, []) | work_dir: c.tmp_dir, log_dir: c.tmp_dir}

      ebin = Path.join(c.proj, "_build/rpi4/lib/pkg/ebin")
      File.mkdir_p!(ebin)
      [{module, beam}] = Code.compile_string("defmodule FirmwareInputsPlanted, do: nil")
      File.write!(Path.join(ebin, "#{module}.beam"), beam)
      File.write!(Path.join(ebin, "pkg.app"), "{application, pkg, []}.\n")

      # The trace compiles nothing and copies the published build to every
      # path under its dir it might be read from.
      plant = fn _proj, _package, opts ->
        dir = opts |> Keyword.fetch!(:trace_dir) |> Path.dirname()
        published = Path.join([dir, "published", "build"])

        for kept <- ["_build", "build", "trace_build", "traced"] do
          File.cp_r!(published, Path.join(dir, kept))
        end

        %{status: :pass, compile_inputs: [], compile_env: []}
      end

      assert {:error, _why} =
               FirmwareInputs.record("rpi4", {"rpi4", c.env}, ctx, pass(),
                 nerves_env: nerves_env,
                 target_inputs: plant
               )

      assert which(c.proj, "_build/rpi4") == {:ok, "build"}
    end

    # A refusal is evidence whether or not the beams bind: the judge's
    # texts come back for `put/3` to class.
    test "a refused trace returns its reason and texts, the project put back", c do
      toolchain = Path.join([c.tmp_dir, "artifacts", "nerves_toolchain_fx-1.0.0"])
      File.mkdir_p!(toolchain)
      nerves_env = fn _proj, _env, _dir -> {:ok, [{"NERVES_TOOLCHAIN", toolchain}]} end
      ctx = %{ctx(c.proj, []) | work_dir: c.tmp_dir, log_dir: c.tmp_dir}

      refused = fn _proj, _package, _opts ->
        %{
          status: :skip,
          reason: "rebar3 build runs plugins",
          observations: %{
            "problems" => ["pkg: compile-time probe of whether a module is loaded: X"]
          }
        }
      end

      assert FirmwareInputs.record("rpi4", {"rpi4", c.env}, ctx, pass(),
               nerves_env: nerves_env,
               target_inputs: refused
             ) ==
               {:skip, "rebar3 build runs plugins",
                [
                  "rebar3 build runs plugins",
                  "pkg: compile-time probe of whether a module is loaded: X"
                ]}

      assert which(c.proj, "deps/pkg") == {:ok, "run"}
      assert which(c.proj, "_build/rpi4") == {:ok, "build"}
    end

    # S8 pilot (F382): the trace compiles the run's `deps/` renamed to the
    # target's deps dir, so it names the dir it was moved from, as Mix and
    # rebar3 wrote it, for the plugin check (`RebarPlugins`).
    test "the trace is told the dir its deps were moved from", c do
      toolchain = Path.join([c.tmp_dir, "artifacts", "nerves_toolchain_fx-1.0.0"])
      File.mkdir_p!(toolchain)
      nerves_env = fn _proj, _env, _dir -> {:ok, [{"NERVES_TOOLCHAIN", toolchain}]} end
      ctx = %{ctx(c.proj, []) | work_dir: c.tmp_dir, log_dir: c.tmp_dir}
      test_pid = self()

      seen = fn _proj, _package, opts ->
        send(test_pid, {:moved_deps, opts[:moved_deps]})
        %{status: :skip, reason: "not traced", observations: %{}}
      end

      _ =
        FirmwareInputs.record("rpi4", {"rpi4", c.env}, ctx, pass(),
          nerves_env: nerves_env,
          target_inputs: seen
        )

      assert_received {:moved_deps, moved}
      assert Path.join(c.proj, "deps") in moved
      assert NccWorker.Portability.Context.realpath(Path.join(c.proj, "deps")) in moved
    end

    # The trace builds into the published build's own paths, so a process it
    # left running that the tracer could not kill (a writer on
    # `_build/<target>` or `deps_<target>`) would write into the published
    # files once they are back. Such a trace fails the run, as a traced host
    # compile that leaves one does (`NccWorker.HostTrace`).
    test "a trace that leaves processes running stops the run", c do
      toolchain = Path.join([c.tmp_dir, "artifacts", "nerves_toolchain_fx-1.0.0"])
      File.mkdir_p!(toolchain)
      nerves_env = fn _proj, _env, _dir -> {:ok, [{"NERVES_TOOLCHAIN", toolchain}]} end
      ctx = %{ctx(c.proj, []) | work_dir: c.tmp_dir, log_dir: c.tmp_dir}

      for {error, left_running?} <- [
            {{:writers_survived, ["4242"]}, true},
            {{:group_survived, ["4242"]}, true},
            {:cleanup_unverified, true},
            {:timeout, false}
          ] do
        # The real judge, with a compile that ends and a reap that reports.
        target_inputs = fn proj, package, opts ->
          NccWorker.Portability.target_inputs(
            proj,
            package,
            opts ++
              [
                cmd: fn _caller, _ref, _timeout, _argv, _log -> {:ok, 0} end,
                reap: fn _build -> {:error, error} end
              ]
          )
        end

        record = fn ->
          FirmwareInputs.record("rpi4", {"rpi4", c.env}, ctx, pass(),
            nerves_env: nerves_env,
            target_inputs: target_inputs
          )
        end

        if left_running? do
          assert_raise FirmwareInputs.LayoutNotRestored, ~r/left processes running/, record
        else
          assert {:skip, _reason, _texts} = record.()
        end

        assert which(c.proj, "deps/pkg") == {:ok, "run"}, inspect(error)
        assert which(c.proj, "deps_rpi4/pkg") == {:ok, "target"}
        assert which(c.proj, "_build/rpi4") == {:ok, "build"}
      end
    end

    # What `mix firmware` or Nerves's env left running is swept before the
    # trace, and the container again after it (`NccWorker.Tracer.sweep/2`):
    # a survivor of either may write the target's dirs once they are back.
    test "processes the sweeps around the trace could not kill stop the run", c do
      toolchain = Path.join([c.tmp_dir, "artifacts", "nerves_toolchain_fx-1.0.0"])
      File.mkdir_p!(toolchain)
      nerves_env = fn _proj, _env, _dir -> {:ok, [{"NERVES_TOOLCHAIN", toolchain}]} end
      ctx = %{ctx(c.proj, []) | work_dir: c.tmp_dir, log_dir: c.tmp_dir}
      survivors = {:error, {:survivors, [%{pid: 40, comm: "sh"}]}}

      for {answers, message} <- [
            {[survivors], ~r/processes left running before the trace of rpi4/},
            {[:ok, survivors], ~r/the trace of rpi4 left processes running \(sweep_survived\)/}
          ] do
        calls = :counters.new(1, [])

        sweep = fn ->
          :counters.add(calls, 1, 1)
          Enum.at(answers, :counters.get(calls, 1) - 1, List.last(answers))
        end

        target_inputs = fn proj, package, opts ->
          NccWorker.Portability.target_inputs(
            proj,
            package,
            opts ++ [cmd: fn _caller, _ref, _timeout, _argv, _log -> {:ok, 0} end, sweep: sweep]
          )
        end

        assert_raise FirmwareInputs.LayoutNotRestored, message, fn ->
          FirmwareInputs.record("rpi4", {"rpi4", c.env}, ctx, pass(),
            nerves_env: nerves_env,
            target_inputs: target_inputs
          )
        end

        assert which(c.proj, "deps/pkg") == {:ok, "run"}
        assert which(c.proj, "deps_rpi4/pkg") == {:ok, "target"}
        assert which(c.proj, "_build/rpi4") == {:ok, "build"}
      end
    end

    test "a dir that cannot be put back stops the run", c do
      {:ok, layout} = FirmwareInputs.layout(c.proj, "rpi4", c.env)

      try do
        assert_raise FirmwareInputs.LayoutNotRestored, fn ->
          FirmwareInputs.in_build_layout(layout, c.dir, c.kept, fn ->
            File.chmod!(c.proj, 0o555)
          end)
        end
      after
        File.chmod!(c.proj, 0o755)
      end
    end
  end
end
