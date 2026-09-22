defmodule NccWorker.ReleaseArtifactsTest do
  use ExUnit.Case, async: true

  alias NccWorker.{AppFile, FileArchiver, Footprint, SourceScanner}

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
