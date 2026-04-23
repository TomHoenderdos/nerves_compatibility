defmodule NccRunner.DockerTest do
  use ExUnit.Case, async: true

  alias NccRunner.{Docker, Job}

  describe "build_docker_args/2" do
    test "includes base security flags" do
      job = create_test_job()
      opts = create_test_opts()

      {args, _skipped} = Docker.build_docker_args(job, opts)

      assert "run" in args
      assert "--rm" in args
      assert "--cap-drop=ALL" in args
      assert "--security-opt=no-new-privileges" in args
    end

    test "runs as the host user" do
      job = create_test_job()
      opts = create_test_opts()

      {args, _skipped} = Docker.build_docker_args(job, opts)

      user_idx = Enum.find_index(args, &(&1 == "--user"))
      assert user_idx, "expected --user flag"

      {uid, 0} = System.cmd("id", ["-u"])
      {gid, 0} = System.cmd("id", ["-g"])
      expected = "#{String.trim(uid)}:#{String.trim(gid)}"
      assert Enum.at(args, user_idx + 1) == expected
    end

    test "sets HOME so Mix archives are found regardless of uid" do
      job = create_test_job()
      opts = create_test_opts()

      {args, _skipped} = Docker.build_docker_args(job, opts)

      assert "HOME=/home/nerves" in args
    end

    test "passes --name derived from run_id so timeouts can target the container" do
      job = create_test_job(%{run_id: "jason-1.4.4-1776425470"})
      opts = create_test_opts()

      {args, _skipped} = Docker.build_docker_args(job, opts)

      name_idx = Enum.find_index(args, &(&1 == "--name"))
      assert name_idx, "expected --name flag"
      assert Enum.at(args, name_idx + 1) == "ncc-jason-1.4.4-1776425470"
    end

    test "sanitizes run_ids with chars docker names don't allow" do
      # '+' shows up in SemVer build metadata, e.g. "1.0.0+abc". Docker container
      # names only allow [a-zA-Z0-9_.-] after the first char, so '+' must get
      # replaced or docker run will reject the name.
      job = create_test_job(%{run_id: "pkg-1.0.0+build/weird 2"})
      opts = create_test_opts()

      {args, _skipped} = Docker.build_docker_args(job, opts)

      name_idx = Enum.find_index(args, &(&1 == "--name"))
      name = Enum.at(args, name_idx + 1)

      assert name == "ncc-pkg-1.0.0_build_weird_2"
      assert Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9_.\-]*$/, name)
    end

    test "includes mounts" do
      job = create_test_job()
      opts = create_test_opts()

      {args, _skipped} = Docker.build_docker_args(job, opts)

      # Check for mount arguments
      mount_args = Enum.filter(args, &String.contains?(&1, "type=bind"))
      assert length(mount_args) >= 2
      assert Enum.any?(mount_args, &String.contains?(&1, "target=/work"))
      assert Enum.any?(mount_args, &String.contains?(&1, "target=/out"))
    end

    test "includes environment variables" do
      job = create_test_job()
      opts = create_test_opts()

      {args, _skipped} = Docker.build_docker_args(job, opts)

      assert "NCC_INPUT=/work/input.json" in args
      assert "LANG=C.UTF-8" in args
    end

    test "includes image reference at end" do
      job = create_test_job()
      opts = create_test_opts()

      {args, _skipped} = Docker.build_docker_args(job, opts)

      assert List.last(args) == Job.image_ref(job)
    end

    test "adds platform flag when specified" do
      job = create_test_job(%{docker: %{platform: "linux/arm64"}})
      opts = create_test_opts()

      {args, _skipped} = Docker.build_docker_args(job, opts)

      platform_idx = Enum.find_index(args, &(&1 == "--platform"))
      assert platform_idx
      assert Enum.at(args, platform_idx + 1) == "linux/arm64"
    end

    test "adds resource limits when specified" do
      job =
        create_test_job(%{
          docker: %{
            memory: "4g",
            cpus: "2"
          }
        })

      opts = create_test_opts()

      {args, _skipped} = Docker.build_docker_args(job, opts)

      memory_idx = Enum.find_index(args, &(&1 == "--memory"))
      assert memory_idx
      assert Enum.at(args, memory_idx + 1) == "4g"

      cpus_idx = Enum.find_index(args, &(&1 == "--cpus"))
      assert cpus_idx
      assert Enum.at(args, cpus_idx + 1) == "2"
    end

    test "includes cache mount when cache_dir provided" do
      job = create_test_job()
      opts = create_test_opts(%{cache_dir: "/tmp/hex-cache"})

      {args, _skipped} = Docker.build_docker_args(job, opts)

      mount_args = Enum.filter(args, &String.contains?(&1, "type=bind"))
      assert Enum.any?(mount_args, &String.contains?(&1, "target=/hex-cache"))
    end
  end

  # Test helpers

  defp create_test_job(overrides \\ %{}) do
    defaults = %{
      run_id: "test-1",
      image_digest: "sha256:" <> String.duplicate("a", 64),
      image_name: "ghcr.io/org/ncc-worker",
      package: %{"name" => "test_pkg", "version" => "1.0.0"},
      systems_override: nil,
      limits: nil,
      docker: nil,
      cache_dir: nil
    }

    struct(Job, Map.merge(defaults, overrides))
  end

  defp create_test_opts(overrides \\ %{}) do
    defaults = %{
      work_dir: "/tmp/work",
      output_dir: "/tmp/out",
      files_dir: "/tmp/files",
      cache_dir: nil,
      log_file: "/tmp/out/runner.log"
    }

    Map.merge(defaults, overrides)
  end
end
