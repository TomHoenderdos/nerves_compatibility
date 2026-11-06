defmodule NccAgent.HostCheckTest do
  use ExUnit.Case, async: false

  alias NccAgent.{Config, HostCheck}

  @fake Path.expand("../support/fake_docker.sh", __DIR__)
  @env ~w(FAKE_DOCKER_RUNTIMES FAKE_DOCKER_INFO_FAIL)

  setup do
    dir = Path.join(System.tmp_dir!(), "agent-hostcheck-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    daemon_json = Path.join(dir, "daemon.json")

    on_exit(fn ->
      Enum.each(@env, &System.delete_env/1)
      File.rm_rf(dir)
    end)

    config = %{Config.defaults() | docker_bin: @fake, data_dir: dir, daemon_json: daemon_json}
    %{config: config, daemon_json: daemon_json}
  end

  defp nofile(path, soft, hard) do
    File.write!(
      path,
      Jason.encode!(%{
        "runtimes" => %{"runsc" => %{"path" => "/usr/local/bin/runsc"}},
        "default-ulimits" => %{"nofile" => %{"Name" => "nofile", "Soft" => soft, "Hard" => hard}}
      })
    )
  end

  test "a daemon with runsc and nofile 65536 passes", %{config: config, daemon_json: path} do
    nofile(path, 65_536, 65_536)
    assert HostCheck.check(config) == :ok
  end

  test "a daemon without the runsc runtime fails", %{config: config, daemon_json: path} do
    nofile(path, 65_536, 65_536)
    System.put_env("FAKE_DOCKER_RUNTIMES", ~s({"runc":{"path":"runc"}}))
    assert {:error, why} = HostCheck.check(config)
    assert why =~ "no runsc runtime"
  end

  test "a daemon that does not answer fails", %{config: config, daemon_json: path} do
    nofile(path, 65_536, 65_536)
    System.put_env("FAKE_DOCKER_INFO_FAIL", "1")
    assert {:error, why} = HostCheck.check(config)
    assert why =~ "docker info"
  end

  test "a missing daemon.json fails and names it", %{config: config, daemon_json: path} do
    assert {:error, why} = HostCheck.check(config)
    assert why =~ path
    assert why =~ "nofile"
  end

  test "default-ulimits without nofile fails", %{config: config, daemon_json: path} do
    File.write!(path, ~s({"default-runtime": "runsc"}))
    assert {:error, why} = HostCheck.check(config)
    assert why =~ "default-ulimits nofile"
  end

  test "a soft or hard limit below 65536 fails", %{config: config, daemon_json: path} do
    nofile(path, 1024, 65_536)
    assert {:error, why} = HostCheck.check(config)
    assert why =~ "65536"

    nofile(path, 65_536, 4096)
    assert {:error, _} = HostCheck.check(config)
  end

  test "a limit up to 1048576 passes", %{config: config, daemon_json: path} do
    nofile(path, 65_536, 1_048_576)
    assert HostCheck.check(config) == :ok
  end

  test "an unlimited or very large limit fails like a small one", %{
    config: config,
    daemon_json: path
  } do
    # The point of the limit is the BEAM's port table: 2^31 is what an unset
    # limit becomes, and it is what gets every build OOM-killed under runsc.
    nofile(path, 2_147_483_584, 2_147_483_584)
    assert {:error, why} = HostCheck.check(config)
    assert why =~ "65536"
  end

  test "malformed JSON fails", %{config: config, daemon_json: path} do
    File.write!(path, "{not json")
    assert {:error, why} = HostCheck.check(config)
    assert why =~ "not valid JSON"
  end
end
