defmodule NccWorker.FirmwareDeterministicTest do
  # The compile is a stub that writes what a real `mix compile` with the
  # option writes: a real Erlang beam compiled with `deterministic`, the
  # `.app`, and Mix's `priv` link into the target's deps dir. Everything
  # the pass moves, checks and puts back is real files.
  use ExUnit.Case, async: true

  alias NccWorker.{BeamScan, FirmwareDeterministic}

  @moduletag :tmp_dir

  @lock "%{\"sample\": {:hex, :sample, \"1.0.0\", \"i\", [:mix], [], \"hexpm\", \"o\"}}\n"
  @nif "\x7FELF the target's nif"

  setup %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf(dir) end)
    proj = Path.join(dir, "proj")
    source = Path.join([proj, "deps_rpi4", "sample"])
    module = "m#{System.unique_integer([:positive])}"
    erl = Path.join([source, "src", module <> ".erl"])
    File.mkdir_p!(Path.dirname(erl))
    File.write!(erl, "-module(#{module}).\n-export([f/0]).\nf() -> ?FILE.\n")
    File.mkdir_p!(Path.join(source, "priv"))
    File.write!(Path.join([source, "priv", "nif.so"]), @nif)
    File.write!(Path.join(proj, "mix.lock"), @lock)

    lib = Path.join([proj, "_build", "rpi4", "lib", "sample"])
    normal = erl(erl, [])
    det = erl(erl, [:deterministic])
    write_build(lib, module, normal)

    {:ok, scan} = BeamScan.analyze_app_dir(lib)
    log = Path.join([dir, "logs", "nerves_system_rpi4.log"])

    env = [
      {"MIX_TARGET", "rpi4"},
      {"MIX_BUILD_PATH", Path.join([proj, "_build", "rpi4"])},
      {"MIX_DEPS_PATH", Path.join(proj, "deps_rpi4")},
      {"MIX_ENV", "prod"}
    ]

    %{
      proj: proj,
      lib: lib,
      module: module,
      normal: normal,
      det: det,
      systems: %{"nerves_system_rpi4" => passed(scan)},
      ctx: %{
        enabled: true,
        project_dir: proj,
        package: "sample",
        targets: [{"nerves_system_rpi4", %{target: "rpi4", env: env, log_file: log}}],
        timeout_sec: 60,
        concurrency: 2
      }
    }
  end

  defp erl(path, opts) do
    {:ok, _, beam} = :compile.file(String.to_charlist(path), [:binary, :debug_info | opts])
    beam
  end

  # The package's compiled app as Mix leaves it: its beam, its `.app`, and
  # `priv` a link into the target's deps dir.
  defp write_build(lib, module, beam) do
    File.mkdir_p!(Path.join(lib, "ebin"))
    File.write!(Path.join([lib, "ebin", module <> ".beam"]), beam)
    File.write!(Path.join([lib, "ebin", "sample.app"]), "{application,sample,[]}.\n")
    :ok = File.ln_s("../../../../deps_rpi4/sample/priv", Path.join(lib, "priv"))
  end

  defp passed(scan) do
    %{
      status: :pass,
      duration_sec: 1.0,
      firmware_size_bytes: 1000,
      log_tail: "ok",
      system_version: "2.2.2",
      compile_env: [],
      beam_scan: scan,
      dependency_scans: nil,
      error: nil
    }
  end

  # `mix compile` with the option, into the build path its env names.
  defp compile(parent, beam_of) do
    fn project_dir, env, _log, timeout_sec ->
      send(parent, {:compiled, project_dir, Map.new(env), timeout_sec})
      lib = Path.join([Map.new(env)["MIX_BUILD_PATH"], "lib", "sample"])
      %{module: module} = beam_of
      write_build(lib, module, beam_of.beam)
      :ok
    end
  end

  defp runners(parent, beam_of, extra \\ %{}) do
    Map.merge(
      %{
        compile: compile(parent, beam_of),
        judge: fn _dir, _proj, "rpi4", _opts -> :ok end,
        reap: fn _build_path -> :ok end
      },
      extra
    )
  end

  defp sha(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp sibling_dir(c), do: Path.join(Path.dirname(c.lib), ".sample.deterministic")

  defp put(c, runners, systems \\ nil, ctx \\ %{}),
    do: FirmwareDeterministic.put(systems || c.systems, Map.merge(c.ctx, ctx), runners)

  # The published build is back where it was, its files the bytes its scan
  # recorded.
  defp published_intact(c) do
    manifest = c.systems["nerves_system_rpi4"].beam_scan["footprint"]["file_manifest"]
    assert :ok = NccWorker.OptionalDepsTargets.verify_files(c.lib, manifest)
    refute File.exists?(Path.join(Path.dirname(c.lib), ".sample.det-build"))
  end

  test "a run that does not ask for it compiles nothing and records nothing", c do
    never = %{compile: fn _, _, _, _ -> flunk("compiled") end}
    assert {:ok, systems, []} = put(c, never, nil, %{enabled: false})
    assert systems == c.systems
  end

  test "a passing target gets a sibling compiled with the option in its own build tree", c do
    assert {:ok, systems, [line]} = put(c, runners(self(), %{module: c.module, beam: c.det}))
    assert line == "Deterministic sibling of nerves_system_rpi4: pass"

    assert_received {:compiled, proj, env, 60}
    assert proj == c.proj
    assert env["ERL_COMPILER_OPTIONS"] == "deterministic"
    assert env["MIX_BUILD_PATH"] == Path.join([c.proj, "_build", "rpi4"])
    assert env["MIX_TARGET"] == "rpi4"

    sibling = systems["nerves_system_rpi4"].deterministic_build

    assert %{status: "pass", reason: nil, erl_compiler_options: ["deterministic"]} = sibling
    assert %{status: "pass"} = sibling.build_root
    assert is_integer(sibling.judge_revision)

    [beam] = sibling.file_manifest["ebin"] |> Enum.filter(&(&1["path"] =~ ".beam"))
    assert beam["sha256"] == :crypto.hash(:sha256, c.det) |> Base.encode16(case: :lower)
    assert sha(Path.join(sibling_dir(c), beam["path"])) == beam["sha256"]

    # Its priv is its own files, the build's bytes; no link into deps.
    assert {:ok, %File.Stat{type: :directory}} = File.lstat(Path.join(sibling_dir(c), "priv"))

    assert sibling.file_manifest["priv"] ==
             systems["nerves_system_rpi4"].beam_scan["footprint"]["file_manifest"]["priv"]

    published_intact(c)
    # Nothing else about the target changed.
    assert Map.delete(systems["nerves_system_rpi4"], :deterministic_build) ==
             c.systems["nerves_system_rpi4"]
  end

  # Review focus 1: a target that kept its optional dependencies was built
  # against a closure the project no longer holds.
  test "a target that kept its optional dependencies gets a skipped sibling, never compiled", c do
    systems = put_in(c.systems, ["nerves_system_rpi4", :deps_lock], %{"jason" => %{}})
    never = %{compile: fn _, _, _, _ -> flunk("compiled") end}

    assert {:ok, systems, _} = put(c, never, systems)

    assert %{status: "skipped", file_manifest: nil} =
             sibling = systems["nerves_system_rpi4"].deterministic_build

    assert sibling.reason == "the target's build was made with its optional dependencies"
  end

  test "a build whose compile reads the option or the whole env gets none", c do
    never = %{compile: fn _, _, _, _ -> flunk("compiled") end}

    for input <- [
          %{"kind" => "env", "name" => "ERL_COMPILER_OPTIONS", "value" => "x"},
          %{"kind" => "env_all"}
        ] do
      systems = put_in(c.systems, ["nerves_system_rpi4", :compile_inputs], [input])
      assert {:ok, systems, _} = put(c, never, systems)

      assert %{status: "skipped", reason: "the build's compile reads ERL_COMPILER_OPTIONS"} =
               systems["nerves_system_rpi4"].deterministic_build
    end
  end

  test "a target that failed or publishes nothing gets no sibling key", c do
    never = %{compile: fn _, _, _, _ -> flunk("compiled") end}
    failed = %{c.systems["nerves_system_rpi4"] | status: :fail}

    withheld =
      update_in(
        c.systems["nerves_system_rpi4"].beam_scan["footprint"],
        &Map.delete(&1, "file_manifest")
      )

    for result <- [failed, withheld] do
      assert {:ok, systems, []} = put(c, never, %{"nerves_system_rpi4" => result})
      refute Map.has_key?(systems["nerves_system_rpi4"], :deterministic_build)
    end
  end

  # Review focus 3: bytes the option does not explain.
  test "a sibling that is not the build but for the option is skipped", c do
    other = erl_other(c)

    cases = [
      {"never compiled with the option", c.normal, "not compiled with the option"},
      {"other code", other, "chunks"}
    ]

    for {label, beam, why} <- cases do
      assert {:ok, systems, _} = put(c, runners(self(), %{module: c.module, beam: beam}))
      sibling = systems["nerves_system_rpi4"].deterministic_build
      assert %{status: "skipped", file_manifest: nil} = sibling, label
      assert sibling.reason =~ "differs from the build", label
      assert sibling.reason =~ why, label
      published_intact(c)
    end
  end

  defp erl_other(c) do
    path = Path.join([c.proj, "deps_rpi4", "sample", "src", c.module <> ".erl"])
    File.write!(path, "-module(#{c.module}).\n-export([f/0]).\nf() -> other.\n")
    beam = erl(path, [:deterministic])
    File.write!(path, "-module(#{c.module}).\n-export([f/0]).\nf() -> ?FILE.\n")
    beam
  end

  test "a sibling whose priv differs from the build's is skipped", c do
    compile = fn _proj, env, _log, _timeout ->
      lib = Path.join([Map.new(env)["MIX_BUILD_PATH"], "lib", "sample"])
      write_build(lib, c.module, c.det)
      # Through Mix's link, into the target's deps dir, as elixir_make writes.
      File.write!(Path.join([lib, "priv", "nif.so"]), "another nif")
      :ok
    end

    assert {:ok, systems, _} = put(c, runners(self(), nil, %{compile: compile}))

    assert %{status: "skipped", reason: "differs from the build: its priv differs"} =
             systems["nerves_system_rpi4"].deterministic_build

    # The build's own priv was made its own before the compile wrote there.
    published_intact(c)
    assert File.read!(Path.join([c.lib, "priv", "nif.so"])) == @nif
  end

  test "a sibling R2 refuses is skipped with the reason and its R2 outcome", c do
    refuse = fn dir, _proj, "rpi4", _opts ->
      assert dir == sibling_dir(c)
      {:refuse, "bakes the build path: m string table"}
    end

    assert {:ok, systems, _} =
             put(c, runners(self(), %{module: c.module, beam: c.det}, %{judge: refuse}))

    assert %{status: "skipped", reason: "R2: bakes the build path: m string table"} =
             sibling = systems["nerves_system_rpi4"].deterministic_build

    assert %{status: "skipped"} = sibling.build_root
  end

  test "a compile that fails or runs out of time is skipped and the build put back", c do
    for {compile, reason} <- [
          {fn _, _, _, _ -> {:error, "mix compile exited with code 1"} end, "compile failed"},
          {fn _, _, _, _ -> {:error, :timeout} end, "timeout"},
          {fn _, _, _, _ -> raise "boom" end, "compile failed"}
        ] do
      assert {:ok, systems, _} = put(c, runners(self(), nil, %{compile: compile}))

      assert %{status: "skipped", reason: ^reason} =
               systems["nerves_system_rpi4"].deterministic_build

      published_intact(c)
      refute File.exists?(sibling_dir(c))
    end
  end

  test "past the pass's budget a target is not compiled", c do
    # The pass starts at 0; every later reading is an hour on.
    calls = :counters.new(1, [:atomics])

    late = %{
      now: fn ->
        :counters.add(calls, 1, 1)
        if :counters.get(calls, 1) == 1, do: 0, else: 3600
      end
    }

    never = Map.merge(%{compile: fn _, _, _, _ -> flunk("compiled") end}, late)

    {:ok, systems, _} = put(c, Map.merge(runners(self(), nil), never), nil, %{budget_sec: 60})

    assert %{status: "skipped", reason: "timeout"} =
             systems["nerves_system_rpi4"].deterministic_build

    published_intact(c)
  end

  test "past 75 minutes of the run nothing is moved or compiled", c do
    never = %{compile: fn _, _, _, _ -> flunk("compiled") end}
    assert {:ok, systems, _} = put(c, never, nil, %{run_elapsed_sec: 75 * 60 + 1})

    assert %{status: "skipped", reason: "run budget exhausted"} =
             systems["nerves_system_rpi4"].deterministic_build
  end

  test "a compile that writes into the published build fails the run", c do
    compile = fn _proj, env, _log, _timeout ->
      lib = Path.join([Map.new(env)["MIX_BUILD_PATH"], "lib", "sample"])
      write_build(lib, c.module, c.det)
      aside = Path.join(Path.dirname(lib), ".sample.det-build")
      File.write!(Path.join([aside, "ebin", c.module <> ".beam"]), "tampered")
      :ok
    end

    assert {:error, {:deterministic_changed_build, "nerves_system_rpi4"}} =
             put(c, runners(self(), nil, %{compile: compile}))
  end

  test "writers that survive the reap fail the run", c do
    reap = fn _ -> {:error, {:writers_survived, ["123"]}} end

    assert {:error, {:deterministic_revert_failed, {:writers_survived, ["123"]}}} =
             put(c, runners(self(), %{module: c.module, beam: c.det}, %{reap: reap}))
  end

  test "a compile that changes mix.lock has it put back and keeps no sibling", c do
    compile = fn proj, env, log, timeout ->
      File.write!(Path.join(proj, "mix.lock"), "%{}\n")
      compile(self(), %{module: c.module, beam: c.det}).(proj, env, log, timeout)
    end

    assert {:ok, systems, _} = put(c, runners(self(), nil, %{compile: compile}))

    assert %{status: "skipped", reason: "the sibling compile changed mix.lock"} =
             systems["nerves_system_rpi4"].deterministic_build

    assert File.read!(Path.join(c.proj, "mix.lock")) == @lock
  end

  test "same_build/4 holds the sibling to the build's paths and modes" do
    build = %{"ebin" => [%{"path" => "ebin/a.beam", "mode" => 33_188}], "priv" => []}
    other_mode = %{"ebin" => [%{"path" => "ebin/a.beam", "mode" => 33_261}], "priv" => []}
    other_path = %{"ebin" => [%{"path" => "ebin/b.beam", "mode" => 33_188}], "priv" => []}

    for sibling <- [other_mode, other_path] do
      assert {:error, "its files are not its build's"} =
               FirmwareDeterministic.same_build(build, sibling, "/nonexistent", "/nonexistent")
    end
  end
end
