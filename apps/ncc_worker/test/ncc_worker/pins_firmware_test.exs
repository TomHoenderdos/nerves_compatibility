defmodule NccWorker.PinsFirmwareTest do
  # A pinned firmware build (lock-driven builds spec, phase 2): the result a
  # refused set writes, and the targets of a reproduced one, which get no
  # optional pass.
  use ExUnit.Case, async: true

  alias NccWorker.{JsonWriter, Systems, Worker}

  @moduletag :tmp_dir

  @a String.duplicate("a", 64)
  @b String.duplicate("b", 64)

  @toolchain %{elixir: "1.20.5", erlang: "29", mix: "1.20.5", nerves_bootstrap: "1.17.3"}

  defp outcome(status, reason, extra) do
    %{
      "hash" => @a,
      "status" => status,
      "reason" => reason,
      "extra" => extra,
      "missing" => [],
      "differing" => []
    }
  end

  defp context(outcome) do
    %{
      input: %{
        run_id: "r1",
        image: %{name: "ncc-worker:local", digest: "sha256:x"},
        package: %{name: "sample", version: "1.0.0"},
        systems_filter: ["nerves_system_rpi4"],
        systems_override: %{"nerves_system_rpi4" => "== 2.1.2"},
        optional_deps: "pinned",
        pins: %{"hash" => @a},
        pins_outcome: outcome
      },
      toolchain: @toolchain,
      description: "Sample",
      github_url: nil,
      package_version_hint: "1.0.0"
    }
  end

  defp written(result, dir) do
    File.mkdir_p!(dir)
    :ok = JsonWriter.write_result(dir, result)
    dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()
  end

  @lock """
  %{
    "sample": {:hex, :sample, "1.0.0", "i", [:mix], [{:ring_logger, "~> 0.11", [hex: :ring_logger, repo: "hexpm", optional: false]}], "hexpm", "#{@a}"},
    "ring_logger": {:hex, :ring_logger, "0.11.3", "i", [:mix], [{:logger_backends, "~> 1.0", [hex: :logger_backends, repo: "hexpm", optional: true]}], "hexpm", "#{@b}"},
  }
  """

  # A pinned firmware project after its target built `sample` for rpi4:
  # the lock, the package's source (reading the env at module level) and
  # its target build.
  defp pinned_project(dir) do
    proj = Path.join(dir, "proj")
    File.mkdir_p!(Path.join([proj, "deps", "sample", "lib"]))
    File.mkdir_p!(Path.join([proj, "_build", "rpi4", "lib", "sample", "ebin"]))
    File.write!(Path.join(proj, "mix.lock"), @lock)

    File.write!(
      Path.join([proj, "deps", "sample", "lib", "sample.ex"]),
      ~s|defmodule Sample do\n  @mode System.get_env("SAMPLE_MODE")\n  def mode, do: @mode\nend\n|
    )

    out = Path.join(dir, "out")
    File.mkdir_p!(Path.join(out, "logs"))

    %{
      project_dir: proj,
      package: "sample",
      systems: Systems.select(["nerves_system_rpi4"]),
      paths: %{work_dir: dir, output_dir: out, logs_dir: Path.join(out, "logs")},
      timeout: 60,
      started_at: System.monotonic_time(:second),
      known_system_abi: [],
      firmware_world: nil,
      firmware_inputs: true,
      releases: nil,
      trees: nil
    }
  end

  @manifest %{
    "ebin" => [
      %{"path" => "ebin/Elixir.Sample.beam", "sha256" => @a, "size" => 1, "mode" => 33_188}
    ],
    "priv" => []
  }

  defp passed do
    %{
      status: :pass,
      duration_sec: 1.0,
      firmware_size_bytes: 1000,
      log_tail: "ok",
      system_version: "2.1.2",
      beam_scan: %{"footprint" => %{"file_manifest" => @manifest}},
      dependency_scans: nil,
      error: nil
    }
  end

  @envs %{"nerves_system_rpi4" => [{"MIX_TARGET", "rpi4"}]}
  @info %{added: [], dropped: [], reason: "pinned", skipped: []}

  defp manifest(systems),
    do: get_in(systems, ["nerves_system_rpi4", :beam_scan, "footprint", "file_manifest"])

  # Review M3: R2 runs on a pinned target's own build, and withholds it.
  test "a passing pinned target goes through R2, which can withhold its files", %{tmp_dir: dir} do
    pass = pinned_project(dir)
    build = fn -> {%{"nerves_system_rpi4" => passed()}, @envs} end
    refuse = fn _app_dir, _project, "rpi4", _opts -> {:refuse, "bakes the build path"} end
    record = fn _name, _target_env, _ctx, _result -> {:error, "not traced"} end

    assert {:ok, systems, @info, _lock} =
             Worker.pinned_targets(build, pass, @info,
               build_root_judge: refuse,
               record_inputs: record
             )

    assert systems["nerves_system_rpi4"].status == :pass
    assert manifest(systems) == nil

    assert %{status: "skipped", reason: "bakes the build path"} =
             systems["nerves_system_rpi4"].build_root
  end

  # Review M3: and its compile inputs are recorded, as any firmware target's.
  test "a passing pinned target that R2 passes records its compile inputs", %{tmp_dir: dir} do
    pass = pinned_project(dir)
    build = fn -> {%{"nerves_system_rpi4" => passed()}, @envs} end
    publish = fn _app_dir, _project, "rpi4", _opts -> :ok end
    inputs = [%{"kind" => "env", "name" => "SAMPLE_MODE", "value" => nil}]

    record = fn "nerves_system_rpi4", {"rpi4", _env}, _ctx, _result ->
      {:ok, %{compile_inputs: inputs, compile_env: []}}
    end

    assert {:ok, systems, @info, _lock} =
             Worker.pinned_targets(build, pass, @info,
               build_root_judge: publish,
               record_inputs: record
             )

    assert manifest(systems) == @manifest
    assert systems["nerves_system_rpi4"].compile_inputs == inputs
    assert %{status: "pass"} = systems["nerves_system_rpi4"].build_root
  end

  # Review M2: the lock is read after the build, as on the regular path; a
  # build that changed it is no build of the set.
  test "a target build that rewrote the lock is an error, never served", %{tmp_dir: dir} do
    pass = pinned_project(dir)
    lock_path = Path.join(pass.project_dir, "mix.lock")

    build = fn ->
      File.write!(lock_path, String.replace(@lock, "0.11.3", "0.11.4"))
      {%{"nerves_system_rpi4" => passed()}, @envs}
    end

    assert {:ok, systems, @info, run_lock} =
             Worker.pinned_targets(build, pass, @info,
               build_root_judge: fn _, _, _, _ -> :ok end,
               record_inputs: fn _, _, _, _ -> {:error, "not traced"} end
             )

    assert %{status: :error, error: "deps_lock_changed"} = systems["nerves_system_rpi4"]
    assert manifest(systems) == nil
    assert run_lock.deps_lock["ring_logger"]["version"] == "0.11.4"
  end

  # Review M3: the result a reproduced set writes is the one ingest takes:
  # the echo, the set's outcome, the lock its target built against.
  test "a reproduced set's result echoes it and carries its lock", %{tmp_dir: dir} do
    pass = pinned_project(dir)
    outcome = outcome("reproduced", nil, [])
    source = Path.join([pass.project_dir, "deps", "sample"])
    {:ok, snapshot} = NccWorker.SourceScanner.snapshot(source)

    run_lock = %{
      deps_lock: %{"ring_logger" => %{"version" => "0.11.3", "checksum" => @b}},
      package_checksum: @a,
      declared: []
    }

    context =
      context(outcome)
      |> Map.merge(%{
        project_dir: pass.project_dir,
        systems: pass.systems,
        release_info: nil,
        host_result: %{status: :pass, duration_sec: 1.0},
        scope: :targets,
        selection: :firmware,
        runtime_apps: [],
        source_before: snapshot,
        pkg_source_dir: source,
        optional_deps: @info,
        run_lock: run_lock
      })

    systems = %{"nerves_system_rpi4" => passed(), "host" => %{passed() | system_version: nil}}
    assert {:ok, result} = Worker.finish_result(systems, context)
    json = written(Map.put(result, :finished_at, "2026-11-19T00:00:00Z"), Path.join(dir, "json"))

    assert json["pins"] == outcome
    assert json["requested_optional_deps"] == "pinned"
    assert json["scope"] == "targets"
    assert json["deps_lock"] == %{"ring_logger" => %{"version" => "0.11.3", "checksum" => @b}}
    assert json["package_checksum"] == @a
    assert json["optional_deps"]["reason"] == "pinned"
    assert json["systems"]["nerves_system_rpi4"]["system_version"] == "2.1.2"
    refute Map.has_key?(json, "firmware_world")
  end

  test "a refused set skips its target, builds nothing and says why", %{tmp_dir: dir} do
    outcome = outcome("refused", "pins_closure_mismatch", ["logger_backends"])
    systems = Systems.select(["nerves_system_rpi4"])

    json = written(Worker.pinned_refused_result(context(outcome), systems, outcome), dir)

    assert %{
             "status" => "skipped",
             "error" => "pins_not_reproduced",
             "log_tail" => "pins not reproduced: pins_closure_mismatch (+logger_backends)",
             "beam_scan" => nil,
             "system_version" => nil
           } = json["systems"]["nerves_system_rpi4"]

    assert Map.keys(json["systems"]) == ["nerves_system_rpi4"]
    assert json["pins"] == outcome
    assert json["requested_optional_deps"] == "pinned"
    assert json["optional_deps"]["reason"] == "pinned"
    assert json["scope"] == "targets"
    refute Map.has_key?(json, "deps_lock")
    refute Map.has_key?(json, "package_checksum")
  end

  # A pinned build's targets keep their own build: no optional pass adds to
  # it, and the published `deps` is the lock the status build saw.
  test "a reproduced set's targets get no optional pass and publish the run lock", %{
    tmp_dir: dir
  } do
    proj = Path.join(dir, "proj")
    File.mkdir_p!(proj)

    File.write!(Path.join(proj, "mix.lock"), """
    %{
      "sample": {:hex, :sample, "1.0.0", "i", [:mix], [{:ring_logger, "~> 0.11", [hex: :ring_logger, repo: "hexpm", optional: false]}], "hexpm", "#{@a}"},
      "ring_logger": {:hex, :ring_logger, "0.11.3", "i", [:mix], [{:logger_backends, "~> 1.0", [hex: :logger_backends, repo: "hexpm", optional: true]}], "hexpm", "#{@b}"},
    }
    """)

    out = Path.join(dir, "out")
    File.mkdir_p!(Path.join(out, "logs"))

    pass = %{
      project_dir: proj,
      package: "sample",
      systems: Systems.select(["nerves_system_rpi4"]),
      paths: %{work_dir: dir, output_dir: out, logs_dir: Path.join(out, "logs")},
      timeout: 60,
      started_at: System.monotonic_time(:second),
      known_system_abi: [],
      firmware_world: nil,
      firmware_inputs: true,
      releases: nil,
      trees: nil
    }

    failed = %{
      status: :fail,
      duration_sec: 1.0,
      firmware_size_bytes: nil,
      log_tail: "boom",
      system_version: "2.1.2",
      beam_scan: nil,
      dependency_scans: nil,
      error: "build_failed"
    }

    build = fn -> {%{"nerves_system_rpi4" => failed}, %{}} end
    info = %{added: [], dropped: [], reason: "pinned", skipped: []}

    assert {:ok, systems, ^info, run_lock} = Worker.pinned_targets(build, pass, info)
    assert systems == %{"nerves_system_rpi4" => failed}
    refute Map.has_key?(systems["nerves_system_rpi4"], :optional_deps)
    assert run_lock.deps_lock == %{"ring_logger" => %{"version" => "0.11.3", "checksum" => @b}}
    assert run_lock.package_checksum == @a
  end

  # Spec section 6, item 4: pins change only which `mix.exs` lines exist
  # before `deps.get`. No module that judges a build or decides a status
  # reads them.
  test "no judge or status module reads the pins" do
    lib = Path.expand("../../lib/ncc_worker", __DIR__)

    judges =
      ~w(portability.ex build_selection.ex firmware_build_root.ex firmware_inputs.ex beam_scan.ex
         static_priv.ex host_trace.ex tracer.ex native_build.ex system_abi.ex footprint.ex)
      |> Enum.map(&Path.join(lib, &1))
      |> Kernel.++(Path.wildcard(Path.join(lib, "portability/*.ex")))
      |> Kernel.++(Path.wildcard(Path.join(lib, "tracer/*.ex")))

    reads = ~r/pins_outcome|NccWorker\.Pins|Compatibility\.Pins|:pins\b|"pins"|"pinned"/

    for file <- judges do
      refute File.read!(file) =~ reads, file
    end
  end
end
