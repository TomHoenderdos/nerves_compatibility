defmodule NccRunner.IntegrationTest do
  @moduledoc """
  End-to-end test that runs the real worker container against a real Hex package.

  Excluded from `mix test` by default. Run explicitly with:

      mix test --only integration

  Requires (the test will fail in setup with a clear message if anything
  is missing):

    * Docker daemon running
    * `ncc-worker:local` image built (`make build` from the repo root)
    * The runner escript built (`mix escript.build` from `runner/`)
    * Network access to Hex.pm and the Nerves system artifact host

  First run is slow (~10 min) while the Nerves x86_64 system artifact
  is downloaded into `~/.ncc-nerves-cache`; subsequent runs are fast.
  """
  use ExUnit.Case

  @moduletag :integration
  @moduletag timeout: :timer.minutes(30)

  @image_name "ncc-worker:local"
  # sha256 of 64 zeros — the runner's Job validator requires a sha256-shaped
  # digest, but image_ref/1 falls back to the tag for local images (name has
  # no slash), so the digest isn't actually used for resolution.
  @placeholder_digest "sha256:" <> String.duplicate("0", 64)

  setup do
    assert docker_running?(), "docker daemon is not running"
    assert image_built?(), "#{@image_name} not built — run: make build"
    assert escript_built?(), "runner escript missing — run: cd runner && mix escript.build"

    tmp = make_tmp_dir()
    on_exit(fn -> File.rm_rf!(tmp) end)

    work_dir = Path.join(tmp, "work")
    output_dir = Path.join(tmp, "out")
    files_dir = Path.join(tmp, "files")
    Enum.each([work_dir, output_dir, files_dir], &File.mkdir_p!/1)

    {:ok, tmp: tmp, work_dir: work_dir, output_dir: output_dir, files_dir: files_dir}
  end

  test "runs jason against nerves_system_x86_64 end-to-end", ctx do
    job = %{
      "run_id" => "integration-jason-#{System.os_time(:second)}",
      "image_name" => @image_name,
      "image_digest" => @placeholder_digest,
      "package" => %{"name" => "jason", "version" => "1.4.4"},
      "systems_filter" => ["nerves_system_x86_64"],
      "files_dir" => ctx.files_dir,
      "cache_dir" => hex_cache_dir()
    }

    job_path = Path.join(ctx.tmp, "job.json")
    File.write!(job_path, JSON.encode_to_iodata!(job))

    {output, exit_code} =
      System.cmd(
        escript_path(),
        [
          "run",
          "--input", job_path,
          "--output-dir", ctx.output_dir,
          "--work-dir", ctx.work_dir
        ],
        stderr_to_stdout: true
      )

    assert exit_code == 0,
           "runner exited #{exit_code}\n--- runner output ---\n#{output}"

    result_path = Path.join(ctx.output_dir, "result.json")

    assert File.exists?(result_path),
           "result.json missing at #{result_path}\n--- runner output ---\n#{output}"

    result = result_path |> File.read!() |> JSON.decode!()

    assert result["package"]["name"] == "jason"
    assert is_map(result["systems"])
    assert Map.has_key?(result["systems"], "nerves_system_x86_64")

    system_result = result["systems"]["nerves_system_x86_64"]
    status = system_result["status"]

    assert status == "pass", """
    expected jason to build on nerves_system_x86_64 but got status=#{inspect(status)}
    error: #{inspect(system_result["error"])}
    log tail:
    #{system_result["log_tail"]}
    """

    # firmware_size_bytes regression guard: this was nil for every passing
    # build across a 9-hour overnight run because Scanner.find_firmware was
    # looking in the wrong directory. Keep this strict so the bug can't come
    # back silently.
    assert is_integer(system_result["firmware_size_bytes"]) and
             system_result["firmware_size_bytes"] > 0,
           "firmware_size_bytes should be a positive integer on a passing build, got " <>
             inspect(system_result["firmware_size_bytes"])

    log_path = Path.join([ctx.output_dir, "logs", "nerves_system_x86_64.log"])
    assert File.exists?(log_path), "per-system log missing at #{log_path}"
  end

  defp docker_running?() do
    case System.cmd("docker", ["version", "--format", "{{.Server.Version}}"],
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp image_built?() do
    case System.cmd("docker", ["image", "inspect", @image_name], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp escript_built?(), do: File.exists?(escript_path())

  defp escript_path() do
    # Tests run with cwd = runner/, escript.build drops the binary there.
    Path.join(File.cwd!(), "ncc_runner")
  end

  defp hex_cache_dir() do
    dir = Path.expand("~/.ncc-hex-cache")
    File.mkdir_p!(dir)
    dir
  end

  defp make_tmp_dir() do
    suffix =
      :crypto.strong_rand_bytes(4)
      |> Base.encode16(case: :lower)

    path = Path.join(System.tmp_dir!(), "ncc_integration_#{suffix}")
    File.mkdir_p!(path)
    path
  end
end
