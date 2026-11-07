defmodule NccWorker.ReleaseArtifactsTest do
  # Starts real `elixir` VMs: one such module at a time (the :real_vm
  # group), alongside the unit suites, so their compiles do not contend.
  use ExUnit.Case, async: true, group: :real_vm

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

  # The package's own source, as `mix deps.get` leaves it under deps/.
  defp write_source(project, package, body) do
    lib = Path.join([project, "deps", package, "lib"])
    File.mkdir_p!(lib)
    File.write!(Path.join(lib, "#{package}.ex"), body)
  end

  # The compile-time trace's verdicts (`NccWorker.Portability.run/3`), as the
  # full run's `pure_elixir_result/3` takes them.
  # A pass always carries the config reads it observed, `[]` for none.
  defp traced_pass do
    fn _package ->
      %{status: :pass, reason: nil, observations: %{"trace_stats" => %{}}, compile_env: []}
    end
  end

  defp killed_tracer do
    fn _package ->
      %{
        status: :skip,
        reason: "portability could not be judged",
        observations: %{"problems" => ["tracer: :killed"]}
      }
    end
  end

  # A host build of `plain` and its OS-agnostic source.
  defp pure_build(project) do
    beam = Path.join([project, "_build", "host", "lib", "plain", "ebin", "plain.beam"])
    File.mkdir_p!(Path.dirname(beam))
    File.write!(beam, "pure beam")
    write_plain_app(Path.dirname(beam))
    write_source(project, "plain", "defmodule Plain do\n  def hi, do: :hi\nend\n")
  end

  # A published result needs a readable `.app`: its `compile_env` is what a
  # client matches on.
  defp write_plain_app(ebin),
    do: File.write!(Path.join(ebin, "plain.app"), "{application, plain, []}.\n")

  describe "the compile-time trace (P1)" do
    setup %{project: project} do
      pure_build(project)
      :ok
    end

    test "a pure Elixir result whose trace passes publishes and says so", %{project: project} do
      result = NccWorker.Worker.pure_elixir_result(project, "plain", traced_pass())

      assert %{
               status: :pass,
               host_portability: %{status: "pass", reason: nil, portability_rule: 1}
             } =
               result

      assert %{"footprint" => %{"file_manifest" => %{"ebin" => [_ | _]}}} = result.beam_scan
    end

    test "a killed tracer changes nothing but publication and host_portability", %{
      project: project
    } do
      published = NccWorker.Worker.pure_elixir_result(project, "plain", traced_pass())
      killed = NccWorker.Worker.pure_elixir_result(project, "plain", killed_tracer())

      assert %{
               status: :pass,
               host_portability: %{
                 status: "skipped",
                 reason: "portability could not be judged",
                 compile_observations: %{"problems" => ["tracer: :killed"]}
               }
             } = killed

      refute Map.has_key?(killed.beam_scan["footprint"], "file_manifest")
      assert killed.log_tail =~ "Files not published: portability could not be judged."
      assert String.starts_with?(killed.log_tail, "Assumed compatible: host compilation passed")

      assert strip_publication(killed) == strip_publication(published)
    end

    test "a trace refusal publishes nothing and names the refusal", %{project: project} do
      reason = "compile-time host read: os:type/0 in Plain.f/0 (lib/plain.ex:2)"

      result =
        NccWorker.Worker.pure_elixir_result(project, "plain", fn _ ->
          %{status: :skip, reason: reason, observations: %{"refusals" => [reason]}}
        end)

      assert %{status: :pass, host_portability: %{status: "skipped", reason: ^reason}} = result
      refute Map.has_key?(result.beam_scan["footprint"], "file_manifest")
      assert result.log_tail =~ "Files not published: #{reason}."
    end

    test "an OS-specific source never starts the traced compile", %{project: project} do
      write_source(project, "plain", "defmodule Plain do\n  def os, do: :os.type()\nend\n")
      test_pid = self()

      result =
        NccWorker.Worker.pure_elixir_result(project, "plain", fn _ ->
          send(test_pid, :traced)
          %{status: :pass, reason: nil, observations: %{}}
        end)

      refute_received :traced

      assert %{status: "skipped", reason: "OS-specific" <> _, compile_observations: nil} =
               result.host_portability

      refute Map.has_key?(result.beam_scan["footprint"], "file_manifest")
    end

    test "only a pure_elixir run carries host_portability" do
      hp = %{status: "pass", reason: nil, portability_rule: 1, compile_observations: %{}}
      pure = %{"pure_elixir" => %{status: :pass, host_portability: hp}, "host" => %{}}
      firmware = %{"nerves_system_rpi4" => %{status: :pass}, "host" => %{}}

      assert %{host_portability: ^hp} = NccWorker.Worker.put_host_portability(%{}, pure)
      assert NccWorker.Worker.put_host_portability(%{}, firmware) == %{}
      assert NccWorker.Worker.put_host_portability(%{}, %{}) == %{}
    end
  end

  # `Worker.full_run_portability/3` with its trace and its rebuild compile
  # injected: whatever they raise or however long they would take, the
  # result equals an untraced run's except for `host_portability` and
  # publication. Short names: the tmp_dir path the beam scan reads becomes an
  # atom, which is at most 255 characters.
  describe "guarded portability" do
    setup %{project: project, tmp_dir: dir} do
      pure_build(project)
      out = Path.join(dir, "out")
      File.mkdir_p!(Path.join(out, "logs"))
      %{paths: %{work_dir: dir, output_dir: out, logs_dir: Path.join(out, "logs")}}
    end

    defp unfinished do
      fn _project, _package, _paths, _opts ->
        %{
          status: :skip,
          reason: "portability could not be judged",
          observations: %{"trace_stats" => %{"judge_compile" => "not_finished"}}
        }
      end
    end

    defp recording_compile(test_pid) do
      fn project_dir, env, log_file, timeout_sec ->
        send(test_pid, {:compiled, project_dir, env, log_file, timeout_sec})
        :ok
      end
    end

    defp run_guarded(project, paths, opts) do
      portability = NccWorker.Worker.full_run_portability(project, paths, opts)

      ExUnit.CaptureIO.with_io(:stderr, fn ->
        NccWorker.Worker.pure_elixir_result(project, "plain", portability)
      end)
    end

    defp assert_unpublished(result, untraced) do
      assert %{status: "skipped", reason: "portability could not be judged"} =
               result.host_portability

      refute Map.has_key?(result.beam_scan["footprint"], "file_manifest")
      assert strip_publication(result) == strip_publication(untraced)
    end

    test "a raising trace is could-not-judge",
         %{project: project, paths: paths} do
      untraced = NccWorker.Worker.pure_elixir_result(project, "plain", traced_pass())

      for failure <- [
            fn -> raise File.Error, reason: :eacces, action: "make directory", path: "/x" end,
            fn -> throw(:boom) end,
            fn -> exit(:boom) end
          ] do
        {result, stderr} =
          run_guarded(project, paths,
            releases: {:ok, %{}},
            trace: fn _, _, _, _ -> failure.() end,
            compile: recording_compile(self())
          )

        assert_unpublished(result, untraced)

        assert ["portability failed: " <> _] =
                 result.host_portability.compile_observations["problems"]

        assert %{"judge_compile" => "not_finished", "transient" => true} =
                 result.host_portability.compile_observations["trace_stats"]

        assert_received {:compiled, ^project, _env, _log, _timeout}
        assert stderr =~ "rebuilding without the trace"
      end
    end

    test "the host compile's time is recorded next to the trace's, as in a toolchain build",
         %{project: project, paths: paths} do
      pass = fn _, _, _, _ ->
        %{status: :pass, reason: nil, observations: %{"trace_stats" => %{"wall_ms" => 5}}}
      end

      {result, _stderr} =
        run_guarded(project, paths, releases: {:ok, %{}}, trace: pass, host_compile_sec: 12.5)

      assert %{"wall_ms" => 5, "host_compile_sec" => 12.5} =
               result.host_portability.compile_observations["trace_stats"]

      {result, _stderr} =
        run_guarded(project, paths,
          releases: {:ok, %{}},
          trace: fn _, _, _, _ -> raise "boom" end,
          compile: recording_compile(self()),
          host_compile_sec: 3.0
        )

      assert %{"host_compile_sec" => 3.0, "transient" => true} =
               result.host_portability.compile_observations["trace_stats"]
    end

    test "a raising rebuild", %{
      project: project,
      paths: paths
    } do
      untraced = NccWorker.Worker.pure_elixir_result(project, "plain", traced_pass())

      {result, stderr} =
        run_guarded(project, paths,
          releases: {:ok, %{}},
          trace: unfinished(),
          compile: fn _, _, _, _ ->
            raise File.Error, reason: :enospc, action: "write", path: "/x"
          end
        )

      assert_unpublished(result, untraced)
      assert stderr =~ "the rebuild failed"
    end

    test "the rebuild is bounded by the run", %{
      project: project,
      paths: paths
    } do
      untraced = NccWorker.Worker.pure_elixir_result(project, "plain", traced_pass())

      {result, _stderr} =
        run_guarded(project, paths,
          releases: {:ok, %{}},
          run_started_at: System.monotonic_time(:second),
          rebuild_timeout_sec: 7,
          trace: unfinished(),
          compile: recording_compile(self())
        )

      assert_unpublished(result, untraced)
      assert_received {:compiled, ^project, _env, _log, 7}

      {result, stderr} =
        run_guarded(project, paths,
          releases: {:ok, %{}},
          run_started_at: System.monotonic_time(:second) - 105 * 60,
          rebuild_timeout_sec: 7,
          trace: unfinished(),
          compile: recording_compile(self())
        )

      assert_unpublished(result, untraced)
      refute_received {:compiled, _, _, _, _}
      assert stderr =~ "no time left"
    end

    # The first compile's build-cache candidates (`host_result.cache_candidates`)
    # describe dirs under `<out>/build-cache`; the rebuild only runs
    # `mix compile` into `_build/host`, never `deps.get` or a cache store.
    test "the rebuild only compiles", %{
      project: project,
      paths: paths
    } do
      candidate = Path.join([paths.output_dir, "build-cache", "k1", "ebin", "dep.beam"])
      File.mkdir_p!(Path.dirname(candidate))
      File.write!(candidate, "first compile")
      before = File.ls!(Path.join(paths.output_dir, "build-cache"))

      run_guarded(project, paths,
        releases: {:ok, %{}},
        trace: unfinished(),
        compile: recording_compile(self())
      )

      assert_received {:compiled, ^project, env, log, _timeout}
      assert {"MIX_BUILD_PATH", Path.join([project, "_build", "host"])} in env
      assert log == Path.join([paths.output_dir, "logs", "host.log"])
      assert File.read!(candidate) == "first compile"
      assert File.ls!(Path.join(paths.output_dir, "build-cache")) == before
    end
  end

  # The full run's own traced compile (`Worker.full_run_portability/3`, the
  # real tracer) killed by its timeout in the middle of the package's
  # compile: the half-written build is rebuilt untraced, so the result equals
  # an untraced run's except for `host_portability` and publication.
  describe "the full run's traced compile killed mid-compile" do
    @describetag timeout: 300_000

    # The judge compile's own process killed outright: unlinked, so the
    # worker survives it, and the run equals an untraced one's.
    test "a killed judge compile process", %{tmp_dir: dir} do
      proj =
        NccWorker.TracerFixtures.project(dir, ["fx_pure"], %{
          "fx_pure" => NccWorker.TracerFixtures.lib("fx_pure", "defmodule FxPure do\nend\n")
        })

      env = NccWorker.TracerFixtures.env(proj)

      for args <- [["deps.get"], ["compile"]] do
        assert {_out, 0} = System.cmd("mix", args, cd: proj, env: env, stderr_to_stdout: true)
      end

      beam = Path.join([proj, "_build", "host", "lib", "fx_pure", "ebin", "Elixir.FxPure.beam"])
      untraced_beam = File.read!(beam)
      untraced = NccWorker.Worker.pure_elixir_result(proj, "fx_pure", traced_pass())

      out = Path.join(dir, "out")
      File.mkdir_p!(Path.join(out, "logs"))
      paths = %{work_dir: dir, output_dir: out, logs_dir: Path.join(out, "logs")}

      portability =
        NccWorker.Worker.full_run_portability(proj, paths,
          releases: {:ok, %{}},
          cmd: fn _caller, _ref, _command, _argv, _log -> Process.exit(self(), :kill) end
        )

      {killed, _stderr} =
        ExUnit.CaptureIO.with_io(:stderr, fn ->
          NccWorker.Worker.pure_elixir_result(proj, "fx_pure", portability)
        end)

      assert %{status: "skipped", reason: "portability could not be judged"} =
               killed.host_portability

      assert killed.host_portability.compile_observations["problems"] |> Enum.join() =~
               "killed"

      refute Map.has_key?(killed.beam_scan["footprint"], "file_manifest")
      assert strip_publication(killed) == strip_publication(untraced)
      assert File.read!(beam) == untraced_beam
    end

    test "changes nothing but host_portability and publication", %{tmp_dir: dir} do
      # Sleeps only under the trace, until the judge compile's timeout kills it.
      body = """
      defmodule FxPure do
        if System.get_env("NCC_TRACE_DIR"), do: Process.sleep(120_000)
        def hi, do: :hi
      end
      """

      proj =
        NccWorker.TracerFixtures.project(dir, ["fx_pure"], %{
          "fx_pure" => NccWorker.TracerFixtures.lib("fx_pure", body)
        })

      env = NccWorker.TracerFixtures.env(proj)

      for args <- [["deps.get"], ["compile"]] do
        assert {out, 0} = System.cmd("mix", args, cd: proj, env: env, stderr_to_stdout: true)
        assert is_binary(out)
      end

      beam = Path.join([proj, "_build", "host", "lib", "fx_pure", "ebin", "Elixir.FxPure.beam"])
      untraced_beam = File.read!(beam)
      untraced = NccWorker.Worker.pure_elixir_result(proj, "fx_pure", traced_pass())

      out = Path.join(dir, "out")
      File.mkdir_p!(Path.join(out, "logs"))
      paths = %{work_dir: dir, output_dir: out, logs_dir: Path.join(out, "logs")}

      portability =
        NccWorker.Worker.full_run_portability(proj, paths,
          releases: {:ok, %{}},
          run_started_at: nil,
          timeout_ms: 4_000
        )

      {killed, stderr} =
        ExUnit.CaptureIO.with_io(:stderr, fn ->
          NccWorker.Worker.pure_elixir_result(proj, "fx_pure", portability)
        end)

      assert stderr =~ "rebuilding without the trace"

      assert %{status: "skipped", reason: "portability could not be judged"} =
               killed.host_portability

      assert %{"trace_stats" => %{"judge_compile" => "not_finished"}} =
               killed.host_portability.compile_observations

      assert killed.host_portability.compile_observations["problems"] |> Enum.join() =~
               "timeout"

      refute Map.has_key?(killed.beam_scan["footprint"], "file_manifest")
      assert String.starts_with?(killed.log_tail, untraced.log_tail)
      assert strip_publication(killed) == strip_publication(untraced)
      assert File.read!(beam) == untraced_beam
      assert File.read!(Path.join([out, "logs", "host-trace.log"])) != ""
    end
  end

  # Everything a withheld result may differ in from a published one.
  defp strip_publication(result) do
    result
    |> Map.drop([:host_portability, :log_tail, :compile_env_rule])
    |> update_in([:beam_scan, "footprint"], &Map.delete(&1, "file_manifest"))
  end

  test "a pure Elixir result carries the host build's file manifest", %{project: project} do
    beam = Path.join([project, "_build", "host", "lib", "plain", "ebin", "plain.beam"])
    File.mkdir_p!(Path.dirname(beam))
    File.write!(beam, "pure beam")
    write_plain_app(Path.dirname(beam))
    write_source(project, "plain", "defmodule Plain do\n  def hi, do: :hi\nend\n")

    assert %{status: :pass, beam_scan: scan} =
             NccWorker.Worker.pure_elixir_result(project, "plain", traced_pass())

    assert [
             %{"path" => "ebin/plain.app", "size" => 26},
             %{"path" => "ebin/plain.beam", "size" => 9}
           ] ==
             scan["footprint"]["file_manifest"]["ebin"]
             |> Enum.map(&Map.take(&1, ["path", "size"]))
             |> Enum.sort_by(& &1["path"])

    assert %{beam_scan: %{"errors" => [_]}} =
             NccWorker.Worker.pure_elixir_result(project, "missing", traced_pass())
  end

  # A module body that reads the OS bakes the build host into the beams, so a
  # Linux build must not be served to a macOS project. The status stands; only
  # the files are not published: no manifest, so nothing is archived.
  test "a pure Elixir result of OS-specific source publishes no files", %{
    project: project,
    archive: archive,
    tmp_dir: work_dir
  } do
    beam = Path.join([project, "_build", "host", "lib", "plain", "ebin", "plain.beam"])
    File.mkdir_p!(Path.dirname(beam))
    File.write!(beam, "pure beam")

    write_source(project, "plain", """
    defmodule Plain do
      @os :os.type()
      def os, do: @os
    end
    """)

    assert %{status: :pass, beam_scan: scan, log_tail: log_tail} =
             NccWorker.Worker.pure_elixir_result(project, "plain", traced_pass())

    refute Map.has_key?(scan["footprint"], "file_manifest")
    assert log_tail =~ "OS-specific"

    result = %{
      package: %{name: "plain"},
      systems: %{"pure_elixir" => %{beam_scan: scan}, "host" => %{beam_scan: nil}}
    }

    assert {:ok, %{files_archived: 0}} =
             FileArchiver.archive_manifest_files(archive, result, work_dir)

    assert File.ls!(archive) == []
  end

  # No source to judge fails closed, as `BuildCache.os_agnostic?/1` does.
  test "a pure Elixir result without the package source publishes no files", %{
    project: project
  } do
    beam = Path.join([project, "_build", "host", "lib", "plain", "ebin", "plain.beam"])
    File.mkdir_p!(Path.dirname(beam))
    File.write!(beam, "pure beam")

    assert %{status: :pass, beam_scan: scan} =
             NccWorker.Worker.pure_elixir_result(project, "plain", traced_pass())

    refute Map.has_key?(scan["footprint"], "file_manifest")
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
             NccWorker.Worker.pure_elixir_result(project, "plain", traced_pass())
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
