defmodule NccAgent.DockerTest do
  use ExUnit.Case, async: false

  alias NccAgent.{Config, Docker}

  @fake Path.expand("../support/fake_docker.sh", __DIR__)
  @env ~w(FAKE_DOCKER_EXIT FAKE_DOCKER_SLEEP FAKE_DOCKER_IMAGE_PRESENT FAKE_DOCKER_KILL_LOG
          FAKE_DOCKER_PS FAKE_DOCKER_PS_LOG FAKE_DOCKER_PS_IMAGES FAKE_DOCKER_IMAGES
          FAKE_DOCKER_IMAGES_LOG FAKE_DOCKER_IMAGES_FAIL FAKE_DOCKER_RMI_LOG FAKE_DOCKER_RMI_FAIL)

  setup do
    dir = Path.join(System.tmp_dir!(), "agent-docker-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Enum.each(@env, &System.delete_env/1)
      Application.delete_env(:ncc_agent, :caps)
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
    kills = Path.join(dir, "kills.log")
    System.put_env("FAKE_DOCKER_KILL_LOG", kills)
    log = Path.join(dir, "runner.log")

    assert {:error, :timeout} =
             Docker.run(config, ["run", "--name", "ncc-r2", "img"], log, 200)

    assert File.read!(log) =~ "killed container ncc-r2"
    assert File.read!(kills) == "ncc-r2\n"
  end

  test "run/4 stops appending to the log at the cap", %{dir: dir, config: config} do
    Application.put_env(:ncc_agent, :caps, runner_log_bytes: 20)
    log = Path.join(dir, "runner.log")
    File.write!(log, "[agent] header\n")

    assert {:ok, 0} = Docker.run(config, ["run", "--name", "ncc-r3", "img"], log, 5_000)
    contents = File.read!(log)
    assert contents =~ "runner.log truncated at 20 bytes"
    refute contents =~ "fake build output"
    assert String.starts_with?(contents, "[agent] header\nfake ")
  end

  test "kill/2 reports the container it killed", %{dir: dir, config: config} do
    kills = Path.join(dir, "kills.log")
    System.put_env("FAKE_DOCKER_KILL_LOG", kills)
    assert :ok = Docker.kill(config, "ncc-r4")
    assert File.read!(kills) == "ncc-r4\n"
  end

  test "log_tail/2 of a missing log is empty", %{dir: dir} do
    assert Docker.log_tail(Path.join(dir, "nope.log")) == ""
  end

  # A boot after a VM stopped mid-job: the worker containers it left running
  # are killed before the scratch dir under their binds is removed.
  @tag :capture_log
  test "kill_leftovers/1 kills every running ncc- container", %{dir: dir, config: config} do
    kills = Path.join(dir, "kills.log")
    ps = Path.join(dir, "ps.log")
    System.put_env("FAKE_DOCKER_KILL_LOG", kills)
    System.put_env("FAKE_DOCKER_PS_LOG", ps)
    System.put_env("FAKE_DOCKER_PS", "abc123\ndef456")

    assert ["abc123", "def456"] = Docker.kill_leftovers(config)
    assert File.read!(ps) == "ps -q --filter name=ncc-\n"
    assert File.read!(kills) == "abc123\ndef456\n"

    System.delete_env("FAKE_DOCKER_PS")
    assert [] = Docker.kill_leftovers(config)
  end

  describe "prune_old_images/2" do
    @current "ghcr.io/x/ncc-worker@sha256:" <> String.duplicate("a", 64)
    @old "ghcr.io/x/ncc-worker@sha256:" <> String.duplicate("b", 64)
    @other_old "ghcr.io/x/ncc-worker@sha256:" <> String.duplicate("c", 64)

    test "removes every other local digest of the repository", %{dir: dir, config: config} do
      rmi = Path.join(dir, "rmi.log")
      images_log = Path.join(dir, "images.log")
      System.put_env("FAKE_DOCKER_RMI_LOG", rmi)
      System.put_env("FAKE_DOCKER_IMAGES_LOG", images_log)
      System.put_env("FAKE_DOCKER_IMAGES", Enum.join([@current, @old, @other_old], "\n"))

      assert :ok = Docker.prune_old_images(config, @current)

      assert File.read!(images_log) =~
               "images --no-trunc --format {{.Repository}}@{{.Digest}} ghcr.io/x/ncc-worker"

      removed = rmi |> File.read!() |> String.split("\n", trim: true)
      assert Enum.sort(removed) == Enum.sort([@old, @other_old])
    end

    test "keeps the image a currently present container uses", %{dir: dir, config: config} do
      rmi = Path.join(dir, "rmi.log")
      System.put_env("FAKE_DOCKER_RMI_LOG", rmi)
      System.put_env("FAKE_DOCKER_IMAGES", Enum.join([@current, @old], "\n"))
      System.put_env("FAKE_DOCKER_PS_IMAGES", @old)

      assert :ok = Docker.prune_old_images(config, @current)

      refute File.exists?(rmi)
    end

    @tag :capture_log
    test "a removal failure is logged, not raised", %{dir: dir, config: config} do
      rmi = Path.join(dir, "rmi.log")
      System.put_env("FAKE_DOCKER_RMI_LOG", rmi)
      System.put_env("FAKE_DOCKER_RMI_FAIL", "1")
      System.put_env("FAKE_DOCKER_IMAGES", Enum.join([@current, @old], "\n"))

      assert :ok = Docker.prune_old_images(config, @current)
      assert File.read!(rmi) == "#{@old}\n"
    end

    @tag :capture_log
    test "a listing failure is logged, not raised, and nothing is removed", %{
      dir: dir,
      config: config
    } do
      rmi = Path.join(dir, "rmi.log")
      System.put_env("FAKE_DOCKER_RMI_LOG", rmi)
      System.put_env("FAKE_DOCKER_IMAGES_FAIL", "1")

      assert :ok = Docker.prune_old_images(config, @current)
      refute File.exists?(rmi)
    end

    test "a bare local tag has no repository and is never listed or touched", %{
      dir: dir,
      config: config
    } do
      images_log = Path.join(dir, "images.log")
      rmi = Path.join(dir, "rmi.log")
      System.put_env("FAKE_DOCKER_IMAGES_LOG", images_log)
      System.put_env("FAKE_DOCKER_RMI_LOG", rmi)
      System.put_env("FAKE_DOCKER_IMAGES", @old)

      assert :ok = Docker.prune_old_images(config, "ncc-worker:local")

      refute File.exists?(images_log)
      refute File.exists?(rmi)
    end

    test "a digest kept only by a floating tag (<none>) is left alone", %{
      dir: dir,
      config: config
    } do
      rmi = Path.join(dir, "rmi.log")
      System.put_env("FAKE_DOCKER_RMI_LOG", rmi)
      System.put_env("FAKE_DOCKER_IMAGES", "ghcr.io/x/ncc-worker@<none>")

      assert :ok = Docker.prune_old_images(config, @current)
      refute File.exists?(rmi)
    end
  end
end
