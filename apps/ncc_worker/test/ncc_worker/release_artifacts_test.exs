defmodule NccWorker.ReleaseArtifactsTest do
  use ExUnit.Case, async: true

  alias NccWorker.{AppFile, BeamScan, FileArchiver, Footprint, SourceScanner}

  @moduletag :tmp_dir
  @files %{
    "ebin/sample.app" => "{application, sample, [{applications, [kernel, stdlib]}]}.",
    "priv/data.txt" => "release data"
  }

  setup %{tmp_dir: dir} do
    project = Path.join(dir, "proj")
    library = Path.join(project, "_build/rpi4/rel/firmware/lib/sample-1.0.0")

    for {name, content} <- @files do
      path = Path.join(library, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    images = Path.join(project, "_build/rpi4/nerves/images")
    File.mkdir_p!(images)
    File.write!(Path.join(images, "firmware.fw"), "firmware")
    %{project: project, library: library, archive: Path.join(dir, "archive")}
  end

  test "release manifests retain system names, sizes, and content hashes", %{
    project: project,
    archive: archive,
    tmp_dir: work_dir
  } do
    systems = [%{target: "rpi4", name: "nerves_system_rpi4"}]
    assert {:ok, footprint} = Footprint.calculate(project, "sample", systems)
    assert %{file_count: 2, firmware_bytes: 8} = footprint.per_system["nerves_system_rpi4"]

    assert footprint.per_system["nerves_system_rpi4"].total_bytes ==
             Enum.sum(Enum.map(@files, fn {_path, body} -> byte_size(body) end))

    result = %{
      systems: %{
        "nerves_system_rpi4" => %{beam_scan: %{footprint: footprint}},
        "host" => %{beam_scan: %{footprint: footprint}}
      }
    }

    assert {:ok, %{files_archived: 2, files_skipped: 0}} =
             FileArchiver.archive_manifest_files(archive, result, work_dir)

    for {_path, body} <- @files do
      digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      assert File.read!(Path.join(archive, digest)) == body
    end

    assert {:ok, %{files_archived: 0, files_skipped: 2}} =
             FileArchiver.archive_manifest_files(archive, result, work_dir)
  end

  test "a pure Elixir result archives the package's files from the host build", %{
    project: project,
    archive: archive,
    tmp_dir: work_dir
  } do
    host_lib = Path.join([project, "_build", "host", "lib"])
    beam = "pure beam"

    for {path, body} <- [{"plain/ebin/plain.beam", beam}, {"other/ebin/other.beam", "other"}] do
      File.mkdir_p!(Path.dirname(Path.join(host_lib, path)))
      File.write!(Path.join(host_lib, path), body)
    end

    assert {:ok, scan} = BeamScan.analyze_app_dir(Path.join(host_lib, "plain"))
    assert [%{"path" => "ebin/plain.beam"}] = scan["footprint"]["file_manifest"]["ebin"]

    result = %{
      package: %{name: "plain"},
      systems: %{"pure_elixir" => %{beam_scan: scan}, "host" => %{beam_scan: nil}}
    }

    assert {:ok, %{files_archived: 1}} =
             FileArchiver.archive_manifest_files(archive, result, work_dir)

    digest = :crypto.hash(:sha256, beam) |> Base.encode16(case: :lower)
    assert File.ls!(archive) == [digest]
    assert File.read!(Path.join(archive, digest)) == beam
  end

  test "a pure Elixir result carries the host build's file manifest", %{project: project} do
    beam = Path.join([project, "_build", "host", "lib", "plain", "ebin", "plain.beam"])
    File.mkdir_p!(Path.dirname(beam))
    File.write!(beam, "pure beam")

    assert %{status: :pass, beam_scan: scan} =
             NccWorker.Worker.pure_elixir_result(project, "plain")

    assert [%{"path" => "ebin/plain.beam", "size" => 9}] =
             scan["footprint"]["file_manifest"]["ebin"]

    assert %{beam_scan: %{"errors" => [_]}} =
             NccWorker.Worker.pure_elixir_result(project, "missing")
  end

  test "a pure Elixir result records the host build's compile_env", %{project: project} do
    ebin = Path.join([project, "_build", "host", "lib", "plain", "ebin"])
    File.mkdir_p!(ebin)
    File.write!(Path.join(ebin, "plain.beam"), "pure beam")

    File.write!(
      Path.join(ebin, "plain.app"),
      "{application, plain, [{compile_env, [{plain, [mode], {ok, fast}}]}]}.\n"
    )

    assert %{compile_env: [%{app: "plain", path: ["mode"], value: _}]} =
             NccWorker.Worker.pure_elixir_result(project, "plain")
  end

  test "finds runtime applications and handles a missing package", %{project: project} do
    assert {:ok, path} = AppFile.find_app_file(project, "sample")
    assert {:ok, [:kernel, :stdlib]} = AppFile.read_applications(path)
    assert {:error, :not_found} = AppFile.find_app_file(project, "missing")
    assert {:error, :package_not_in_release} = Footprint.calculate(project, "missing")
  end

  test "host-only assessments retain runtime dependency metadata", %{project: project} do
    path = Path.join([project, "_build", "host", "lib", "plain", "ebin", "plain.app"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{application, plain, [{applications, [kernel, stdlib, jason]}]}.")
    assert {:ok, ^path} = AppFile.find_app_file(project, "plain")
    assert {:ok, [:kernel, :stdlib, :jason]} = AppFile.read_applications(path)
  end

  test "source snapshots exclude build scratch and accept missing directories", %{tmp_dir: dir} do
    source = Path.join(dir, "source")
    File.mkdir_p!(Path.join(source, "_build"))
    File.write!(Path.join(source, "mix.exs"), "source")
    File.write!(Path.join(source, "_build/generated"), "scratch")

    assert {:ok, snapshot} = SourceScanner.snapshot(source)
    assert Map.keys(snapshot) == ["mix.exs"]
    assert {:ok, %{}} = SourceScanner.snapshot(Path.join(dir, "missing"))
  end
end
