defmodule NccAgent.DockerTest do
  use ExUnit.Case, async: false

  alias NccAgent.{Config, Docker}

  @fake Path.expand("../support/fake_docker.sh", __DIR__)
  @env ~w(FAKE_DOCKER_EXIT FAKE_DOCKER_SLEEP FAKE_DOCKER_IMAGE_PRESENT)

  setup do
    dir = Path.join(System.tmp_dir!(), "agent-docker-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Enum.each(@env, &System.delete_env/1)
      File.rm_rf(dir)
    end)

    %{dir: dir, config: %{Config.defaults() | docker_bin: @fake, data_dir: dir}}
  end

  test "run/4 appends the output to the log and returns the exit code", %{
    dir: dir,
    config: config
  } do
    log = Path.join(dir, "runner.log")
    File.write!(log, "before\n")
    assert {:ok, 0} = Docker.run(config, ["run", "--name", "ncc-r1", "img"], log, 5_000)
    assert File.read!(log) =~ "before\n"
    assert File.read!(log) =~ "fake build output"
    assert Docker.log_tail(log) =~ "fake build output"
    assert Docker.log_tail(log, 6) |> byte_size() <= 6

    System.put_env("FAKE_DOCKER_EXIT", "10")
    assert {:ok, 10} = Docker.run(config, ["run", "--name", "ncc-r1", "img"], log, 5_000)
  end

  test "present?/2 follows image inspect", %{config: config} do
    refute Docker.present?(config, "ghcr.io/x/ncc-worker@sha256:aa")
    System.put_env("FAKE_DOCKER_IMAGE_PRESENT", "1")
    assert Docker.present?(config, "ghcr.io/x/ncc-worker@sha256:aa")
    assert :ok = Docker.pull(config, "ghcr.io/x/ncc-worker@sha256:aa")
  end

  test "run/4 kills the container and returns :timeout past the deadline", %{
    dir: dir,
    config: config
  } do
    System.put_env("FAKE_DOCKER_SLEEP", "1")
    log = Path.join(dir, "runner.log")

    assert {:error, :timeout} =
             Docker.run(config, ["run", "--name", "ncc-r2", "img"], log, 200)

    assert File.read!(log) =~ "killed container ncc-r2"
  end

  test "log_tail/2 of a missing log is empty", %{dir: dir} do
    assert Docker.log_tail(Path.join(dir, "nope.log")) == ""
  end
end
