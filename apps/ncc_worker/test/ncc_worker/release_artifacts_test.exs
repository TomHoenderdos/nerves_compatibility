defmodule NccWorker.ReleaseArtifactsTest do
  use ExUnit.Case, async: true

  alias NccWorker.{AppFile, BeamScan, FileArchiver, Footprint, SourceScanner}

  @moduletag :tmp_dir

  # The same application twice, as a firmware build leaves it: compiled into
  # `_build/<target>/lib/<app>` with debug_info, and copied into the release
  # with its BEAMs stripped. Only the `.app` and priv files are byte-identical.
  @app_file "{application, sample, [{applications, [kernel, stdlib]}]}."
  @build_files %{
    "ebin/sample.app" => @app_file,
    "ebin/sample.beam" => "beam with debug_info",
    "priv/data.txt" => "release data"
  }
  @release_files %{
    "ebin/sample.app" => @app_file,
    "ebin/sample.beam" => "stripped beam",
    "priv/data.txt" => "release data"
  }

  setup %{tmp_dir: dir} do
    project = Path.join(dir, "proj")
    library = Path.join(project, "_build/rpi4/rel/firmware/lib/sample-1.0.0")
    build_lib = Path.join(project, "_build/rpi4/lib/sample")

    write_tree(library, @release_files)
    write_tree(build_lib, @build_files)

    images = Path.join(project, "_build/rpi4/nerves/images")
    File.mkdir_p!(images)
    File.write!(Path.join(images, "firmware.fw"), "firmware")

    %{
      project: project,
      library: library,
      build_lib: build_lib,
      archive: Path.join(dir, "archive")
    }
  end

  defp write_tree(root, files) do
    for {name, content} <- files do
      path = Path.join(root, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end
  end

  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  # A client installs these files into its own `_build`, where Mix expects
  # what it would have compiled itself: BEAMs with debug_info, so protocols
  # consolidate and Dialyzer has types. The release copy has neither.
  test "manifests describe the target's _build copy, not the stripped release copy", %{
    project: project,
    archive: archive,
    tmp_dir: work_dir
  } do
    systems = [%{target: "rpi4", name: "nerves_system_rpi4"}]
    assert {:ok, footprint} = Footprint.calculate(project, "sample", systems)
    assert %{file_count: 3, firmware_bytes: 8} = footprint.per_system["nerves_system_rpi4"]

    assert footprint.per_system["nerves_system_rpi4"].total_bytes ==
             Enum.sum(Enum.map(@build_files, fn {_path, body} -> byte_size(body) end))

    beam = Enum.find(footprint.file_manifest.ebin, &(&1.path == "ebin/sample.beam"))
    assert beam.sha256 == sha256(@build_files["ebin/sample.beam"])

    result = %{
      package: %{name: "sample"},
      systems: %{
        "nerves_system_rpi4" => %{beam_scan: %{footprint: footprint}},
        "host" => %{beam_scan: %{footprint: footprint}}
      }
    }

    assert {:ok, %{files_archived: 3, files_skipped: 0}} =
             FileArchiver.archive_manifest_files(archive, result, work_dir)

    for {_path, body} <- @build_files do
      assert File.read!(Path.join(archive, sha256(body))) == body
    end

    refute File.exists?(Path.join(archive, sha256(@release_files["ebin/sample.beam"])))

    assert {:ok, %{files_archived: 0, files_skipped: 3}} =
             FileArchiver.archive_manifest_files(archive, result, work_dir)
  end

  test "the package beam scan reads the target's _build copy", %{
    project: project,
    build_lib: build_lib
  } do
    assert {:ok, scan} = BeamScan.analyze(Path.join(project, "_build/rpi4"), "sample")

    assert %{"path" => "ebin/sample.beam", "sha256" => sha} =
             Enum.find(
               scan["footprint"]["file_manifest"]["ebin"],
               &(&1["path"] == "ebin/sample.beam")
             )

    assert sha == sha256(File.read!(Path.join(build_lib, "ebin/sample.beam")))
  end

  # Dependencies' files are archived but never published, and their manifests
  # come from the release scan, so they are still copied from the release.
  test "dependency files are still archived from the release", %{
    project: project,
    archive: archive,
    tmp_dir: work_dir
  } do
    dep_beam = "dep beam"

    write_tree(Path.join(project, "_build/rpi4/rel/firmware/lib/dep-1.0.0"), %{
      "ebin/dep.beam" => dep_beam
    })

    result = %{
      package: %{name: "sample"},
      systems: %{
        "nerves_system_rpi4" => %{
          beam_scan: nil,
          dependency_scans: %{
            "dep@1.0.0" => %{
              "footprint" => %{
                "file_manifest" => %{
                  "ebin" => [%{"path" => "ebin/dep.beam", "sha256" => sha256(dep_beam)}],
                  "priv" => []
                }
              }
            }
          }
        }
      }
    }

    assert {:ok, %{files_archived: 1}} =
             FileArchiver.archive_manifest_files(archive, result, work_dir)

    assert File.read!(Path.join(archive, sha256(dep_beam))) == dep_beam
  end

  # The one case the release copy is still used for the package itself: an
  # application whose `_build/<target>/lib` directory is not named after the
  # package, so the build copy cannot be found.
  test "falls back to the release copy when the target has no _build lib for the package", %{
    project: project,
    archive: archive,
    tmp_dir: work_dir
  } do
    File.rm_rf!(Path.join(project, "_build/rpi4/lib"))
    systems = [%{target: "rpi4", name: "nerves_system_rpi4"}]

    assert {:ok, footprint} = Footprint.calculate(project, "sample", systems)
    beam = Enum.find(footprint.file_manifest.ebin, &(&1.path == "ebin/sample.beam"))
    assert beam.sha256 == sha256(@release_files["ebin/sample.beam"])

    result = %{
      package: %{name: "sample"},
      systems: %{"nerves_system_rpi4" => %{beam_scan: %{footprint: footprint}}}
    }

    assert {:ok, %{files_archived: 3}} =
             FileArchiver.archive_manifest_files(archive, result, work_dir)

    assert File.read!(Path.join(archive, beam.sha256)) == @release_files["ebin/sample.beam"]
  end

  # With a real BEAM: the published file keeps its Dbgi chunk, which is what
  # `mix compile.protocols` and Dialyzer read on the client, and the release
  # copy does not, so this test can tell the two apart.
  test "the archived package beam keeps debug_info where the release copy has none", %{
    project: project,
    archive: archive,
    tmp_dir: work_dir
  } do
    source = :code.which(NccWorker.Footprint) |> List.to_string()
    {:ok, {_, [debug_info: _]}} = :beam_lib.chunks(String.to_charlist(source), [:debug_info])
    {:ok, {_, stripped}} = :beam_lib.strip(File.read!(source))

    write_tree(Path.join(project, "_build/rpi4/lib/real"), %{
      "ebin/real.beam" => File.read!(source)
    })

    write_tree(Path.join(project, "_build/rpi4/rel/firmware/lib/real-0.1.0"), %{
      "ebin/real.beam" => stripped
    })

    assert {:ok, scan} = BeamScan.analyze(Path.join(project, "_build/rpi4"), "real")
    assert scan["errors"] == []
    [%{"sha256" => sha}] = scan["footprint"]["file_manifest"]["ebin"]

    result = %{package: %{name: "real"}, systems: %{"nerves_system_rpi4" => %{beam_scan: scan}}}

    assert {:ok, %{files_archived: 1}} =
             FileArchiver.archive_manifest_files(archive, result, work_dir)

    # By bytes: given a path without an extension, beam_lib appends ".beam".
    archived = File.read!(Path.join(archive, sha))

    assert {:ok, {_, [debug_info: {:debug_info_v1, _, _}]}} =
             :beam_lib.chunks(archived, [:debug_info])

    release_copy = Path.join(project, "_build/rpi4/rel/firmware/lib/real-0.1.0/ebin/real.beam")

    assert {:error, :beam_lib, {:missing_chunk, _, ~c"Dbgi"}} =
             :beam_lib.chunks(String.to_charlist(release_copy), [:debug_info])
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

  test "the host compile records compile_env the same way a pure Elixir result does", %{
    project: project
  } do
    build_path = Path.join([project, "_build", "host"])
    ebin = Path.join([build_path, "lib", "plain", "ebin"])
    File.mkdir_p!(ebin)

    File.write!(
      Path.join(ebin, "plain.app"),
      "{application, plain, [{compile_env, [{plain, [mode], {ok, fast}}]}]}.\n"
    )

    assert [%{app: "plain", path: ["mode"], value: _}] =
             NccWorker.Worker.host_compile_env(build_path, "plain")
  end

  test "finds runtime applications and handles a missing package", %{project: project} do
    assert {:ok, path} = AppFile.find_app_file(project, "sample")
    assert {:ok, [:kernel, :stdlib]} = AppFile.read_applications(path)
    assert {:error, :not_found} = AppFile.find_app_file(project, "missing")
    assert {:error, :package_not_in_release} = Footprint.calculate(project, "missing")
    assert {:ok, _} = Footprint.calculate(project, "sample")
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
