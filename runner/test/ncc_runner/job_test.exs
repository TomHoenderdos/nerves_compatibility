defmodule NccRunner.JobTest do
  use ExUnit.Case, async: true

  alias NccRunner.Job

  describe "from_map/1" do
    test "parses valid minimal job" do
      data = %{
        "run_id" => "test-1",
        "image_digest" => "sha256:" <> String.duplicate("a", 64),
        "image_name" => "ghcr.io/org/ncc-worker",
        "package" => %{
          "name" => "phoenix",
          "version" => "1.7.0"
        }
      }

      assert {:ok, job} = Job.from_map(data)
      assert job.run_id == "test-1"
      assert job.image_name == "ghcr.io/org/ncc-worker"
      assert job.package["name"] == "phoenix"
    end

    test "validates required fields" do
      assert {:error, msg} = Job.from_map(%{})
      assert msg =~ "missing required field"
    end

    test "validates digest format" do
      data = %{
        "run_id" => "test-1",
        "image_digest" => "invalid",
        "image_name" => "ghcr.io/org/ncc-worker",
        "package" => %{"name" => "phoenix"}
      }

      assert {:error, msg} = Job.from_map(data)
      assert msg =~ "image_digest must be in format"
    end

    test "parses optional fields" do
      data = %{
        "run_id" => "test-1",
        "image_digest" => "sha256:" <> String.duplicate("a", 64),
        "image_name" => "ghcr.io/org/ncc-worker",
        "package" => %{"name" => "phoenix"},
        "systems_override" => ["rpi4", "rpi0"],
        "limits" => %{"timeout_seconds" => 300},
        "docker" => %{"platform" => "linux/amd64", "memory" => "4g"},
        "cache_dir" => "/tmp/cache"
      }

      assert {:ok, job} = Job.from_map(data)
      assert job.systems_override == ["rpi4", "rpi0"]
      assert job.limits.timeout_seconds == 300
      assert job.docker.platform == "linux/amd64"
      assert job.cache_dir == "/tmp/cache"
    end
  end

  describe "image_ref/1" do
    test "combines name and digest" do
      job = %Job{
        image_name: "ghcr.io/org/ncc-worker",
        image_digest: "sha256:abc123"
      }

      assert Job.image_ref(job) == "ghcr.io/org/ncc-worker@sha256:abc123"
    end
  end

  describe "worker_input/1" do
    test "generates input for worker" do
      job = %Job{
        package: %{"name" => "phoenix", "version" => "1.7.0"},
        systems_override: ["rpi4"],
        limits: %{timeout_seconds: 300}
      }

      input = Job.worker_input(job)

      assert input["package"] == %{"name" => "phoenix", "version" => "1.7.0"}
      assert input["systems_override"] == ["rpi4"]
      assert input["limits"] == %{timeout_seconds: 300}
    end

    test "omits nil optional fields" do
      job = %Job{
        package: %{"name" => "phoenix"}
      }

      input = Job.worker_input(job)

      assert input["package"] == %{"name" => "phoenix"}
      refute Map.has_key?(input, "systems_override")
      refute Map.has_key?(input, "limits")
    end
  end
end
