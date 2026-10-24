defmodule NccWorker.ToolchainModeTest do
  use ExUnit.Case, async: true

  alias NccWorker.{CLI, FileArchiver, JsonWriter, Worker}

  @moduletag :tmp_dir

  @toolchain %{elixir: "1.19.1", erlang: "28", mix: "1.19.1", nerves_bootstrap: "absent"}

  @lock """
  %{
    "sample": {:hex, :sample, "1.0.0", "i-sample", [:mix], [{:dep, "~> 1.0", [hex: :dep, repo: "hexpm", optional: false]}], "hexpm", "o-sample"},
    "dep": {:hex, :dep, "1.2.0", "i-dep", [:mix], [], "hexpm", "o-dep"},
  }
  """

  # The project a toolchain run leaves behind: the package's sources under
  # `deps/<pkg>`, its host build under `_build/host/lib/<pkg>`, and the lock.
  defp project(work_dir, fixture) do
    project = Path.join(work_dir, "proj")
    source = Path.join([project, "deps", "sample"])
    File.mkdir_p!(Path.join(source, "lib"))
    File.write!(Path.join(source, "mix.exs"), "defmodule Sample.MixProject do end")
    File.write!(Path.join(source, "lib/sample.ex"), "defmodule Sample do end")

    built = Path.join([project, "_build", "host", "lib", "sample"])
    File.mkdir_p!(Path.dirname(built))
    File.cp_r!(Path.join([__DIR__, "..", "fixture", fixture]), built)

    # The fixture's `.app` is named after the fixture's own application.
    [app] = Path.wildcard(Path.join(built, "ebin/*.app"))
    File.rename!(app, Path.join(built, "ebin/sample.app"))
    File.write!(Path.join(project, "mix.lock"), @lock)
    {project, built}
  end

  defp sha256(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp passing_host, do: %{status: :pass, error: nil}

  describe "toolchain_build/4" do
    test "a portable package passes with its own beams' manifest", %{tmp_dir: work_dir} do
      {project, built} = project(work_dir, "circular_buffer-1.0.0")

      build = Worker.toolchain_build(project, "sample", passing_host(), @toolchain)

      assert %{status: "pass", reason: nil, elixir: "1.19.1", otp: "28"} = build
      assert build.deps_lock == %{"dep" => %{"version" => "1.2.0", "checksum" => "o-dep"}}
      assert build.package_checksum == "o-sample"
      assert is_list(build.compile_env)

      assert %{"ebin" => ebin, "priv" => []} = build.file_manifest
      beam = Enum.find(ebin, &(&1["path"] == "ebin/Elixir.CircularBuffer.beam"))
      assert beam["sha256"] == sha256(Path.join(built, "ebin/Elixir.CircularBuffer.beam"))
      assert %{"size" => size, "mode" => _} = beam
      assert is_integer(size) and size > 0
    end

    test "a package that is not portable is skipped with the reason", %{tmp_dir: work_dir} do
      {project, _built} = project(work_dir, "circuits_gpio-2.1.3")

      build = Worker.toolchain_build(project, "sample", passing_host(), @toolchain)

      assert %{status: "skipped", file_manifest: nil} = build
      assert is_binary(build.reason) and build.reason != ""
    end

    test "a failed host compile is an error naming the failure", %{tmp_dir: work_dir} do
      {project, _built} = project(work_dir, "circular_buffer-1.0.0")
      host = %{status: :fail, error: "mix command exited with code 1"}

      build = Worker.toolchain_build(project, "sample", host, @toolchain)

      assert %{status: "error", file_manifest: nil, deps_lock: nil} = build
      assert build.reason =~ "host compile failed"
      assert build.reason =~ "exited with code 1"
    end

    test "a missing host build is skipped, not a crash", %{tmp_dir: work_dir} do
      {project, built} = project(work_dir, "circular_buffer-1.0.0")
      File.rm_rf!(built)

      assert %{status: "skipped"} =
               Worker.toolchain_build(project, "sample", passing_host(), @toolchain)
    end
  end

  test "the toolchain probe does not need nerves_bootstrap" do
    assert {:ok, %{nerves_bootstrap: "absent", elixir: elixir}} =
             Worker.detect_toolchain(:toolchain)

    assert elixir == System.version()
  end

  defp result(build) do
    %{
      run_id: "run-1",
      package: %{name: "sample", version: "1.0.0"},
      image: %{name: "ncc-worker:1.19-28", digest: "sha256:abc"},
      toolchain: @toolchain,
      systems: %{},
      finished_at: "2026-10-24T00:00:00Z",
      scope: "toolchain",
      toolchain_build: build,
      requested_toolchain: %{elixir: "1.19", otp: "28"}
    }
  end

  test "the archiver copies a toolchain build's files from the host build", %{tmp_dir: work_dir} do
    {project, built} = project(work_dir, "circular_buffer-1.0.0")
    build = Worker.toolchain_build(project, "sample", passing_host(), @toolchain)
    archive = Path.join(work_dir, "files")

    assert {:ok, %{files_archived: 5, files_skipped: 0}} =
             FileArchiver.archive_manifest_files(archive, result(build), work_dir)

    for file <- File.ls!(Path.join(built, "ebin")) do
      path = Path.join([built, "ebin", file])
      assert File.read!(Path.join(archive, sha256(path))) == File.read!(path)
    end
  end

  test "the archiver ignores a toolchain_build outside a toolchain run", %{tmp_dir: work_dir} do
    {project, _built} = project(work_dir, "circular_buffer-1.0.0")
    build = Worker.toolchain_build(project, "sample", passing_host(), @toolchain)
    archive = Path.join(work_dir, "files")

    assert {:ok, %{files_archived: 0}} =
             FileArchiver.archive_manifest_files(
               archive,
               %{result(build) | scope: "full"},
               work_dir
             )
  end

  test "result.json carries the toolchain build and the requested toolchain", %{
    tmp_dir: work_dir
  } do
    {project, _built} = project(work_dir, "circular_buffer-1.0.0")
    build = Worker.toolchain_build(project, "sample", passing_host(), @toolchain)
    out = Path.join(work_dir, "out")
    File.mkdir_p!(out)

    assert :ok = JsonWriter.write_result(out, result(build))
    decoded = out |> Path.join("result.json") |> File.read!() |> JSON.decode!()

    assert %{"scope" => "toolchain", "systems" => systems} = decoded
    assert systems == %{}
    assert decoded["requested_toolchain"] == %{"elixir" => "1.19", "otp" => "28"}

    assert %{
             "status" => "pass",
             "reason" => nil,
             "elixir" => "1.19.1",
             "otp" => "28",
             "package_checksum" => "o-sample",
             "deps_lock" => %{"dep" => _},
             "compile_env" => _,
             "file_manifest" => %{"ebin" => [_ | _], "priv" => []}
           } = decoded["toolchain_build"]
  end

  describe "CLI outcome" do
    test "a written result exits 0 for pass, skipped and a failed compile" do
      assert CLI.result_outcome(result(%{status: "pass"})) == :ok
      assert CLI.result_outcome(result(%{status: "skipped"})) == :ok
      assert CLI.result_outcome(%{systems: %{}}) == :ok

      # Deterministic: the portal records it as a fail verdict, not a retry.
      assert CLI.result_outcome(result(%{status: "error", reason: "host compile failed"})) ==
               :ok
    end
  end
end
