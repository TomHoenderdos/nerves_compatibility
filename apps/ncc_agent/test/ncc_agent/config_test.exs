defmodule NccAgent.ConfigTest do
  use ExUnit.Case, async: false
  alias NccAgent.Config

  setup do
    saved = System.get_env()

    on_exit(fn ->
      for {k, _} <- System.get_env(), String.starts_with?(k, "NCC_"), do: System.delete_env(k)
      for {k, v} <- saved, String.starts_with?(k, "NCC_"), do: System.put_env(k, v)
    end)

    for {k, _} <- System.get_env(), String.starts_with?(k, "NCC_"), do: System.delete_env(k)
    # Required, like the portal URL; the tests below that are not about it
    # start from a valid one.
    System.put_env("NCC_MEMORY", "8g")
    :ok
  end

  test "requires the portal url and the memory limit, and defaults the rest" do
    System.delete_env("NCC_MEMORY")
    assert {:error, [url, memory]} = Config.load()
    assert url =~ "NCC_PORTAL_URL"
    assert memory =~ "NCC_MEMORY"
    System.put_env("NCC_MEMORY", "8g")
    assert {:error, [msg]} = Config.load()
    assert msg =~ "NCC_PORTAL_URL"
    System.put_env("NCC_PORTAL_URL", "https://portal.test:8443")
    System.put_env("NCC_DATA_DIR", "/tmp/ncc-x")
    assert {:ok, config} = Config.load()

    assert config.portal_url == "https://portal.test:8443" and config.slots == 1 and
             config.docker_bin == "docker"

    assert config.build_user =~ ~r/^\d+:\d+$/
    assert config.memory == "8g"
    assert Config.path(config, :cert) == "/tmp/ncc-x/client.pem"
    assert Config.path(config, :nerves_cache) == "/tmp/ncc-x/nerves-cache"
    assert String.ends_with?(config.egress_script, "egress.sh")
  end

  test "NCC_HEX_CACHE_RW=1, and only 1, turns the Hex cache rollback on" do
    System.put_env("NCC_PORTAL_URL", "https://portal.test:8443")
    assert {:ok, %{hex_cache_rw: false}} = Config.load()

    System.put_env("NCC_HEX_CACHE_RW", "true")
    assert {:ok, %{hex_cache_rw: false}} = Config.load()

    System.put_env("NCC_HEX_CACHE_RW", "1")
    assert {:ok, %{hex_cache_rw: true}} = Config.load()
  end

  test "slots must be 1..16 and the url https" do
    System.put_env("NCC_PORTAL_URL", "http://portal.test")
    System.put_env("NCC_SLOTS", "40")
    assert {:error, errors} = Config.load()
    assert Enum.any?(errors, &(&1 =~ "NCC_SLOTS")) and Enum.any?(errors, &(&1 =~ "https"))
  end

  # The agent runs as root; a build as uid 0 on the bind mounts is refused.
  test "a root or malformed build user is refused" do
    System.put_env("NCC_PORTAL_URL", "https://portal.test:8443")
    System.put_env("NCC_BUILD_USER", "0:0")
    assert {:error, [msg]} = Config.load()
    assert msg =~ "non-root"

    System.put_env("NCC_BUILD_USER", "00:1000")
    assert {:error, [msg]} = Config.load()
    assert msg =~ "non-root"

    System.put_env("NCC_BUILD_USER", "ncc-build")
    assert {:error, [msg]} = Config.load()
    assert msg =~ "uid:gid"

    System.put_env("NCC_BUILD_USER", "999:999")
    assert {:ok, %{build_user: "999:999"}} = Config.load()
  end

  # docker-ncc's authz policy denies a build container without a memory
  # limit, and under gVisor's kvm platform, which enforces no pids limit, it
  # is the only bound on a fork bomb: the agent refuses to start without one.
  test "a missing, zero or malformed memory limit is refused" do
    System.put_env("NCC_PORTAL_URL", "https://portal.test:8443")

    for memory <- [nil, "", "0", "8 GB please"] do
      if memory, do: System.put_env("NCC_MEMORY", memory), else: System.delete_env("NCC_MEMORY")
      assert {:error, [msg]} = Config.load(), inspect(memory)
      assert msg =~ "NCC_MEMORY"
      assert msg =~ "runsc" or msg =~ "memory limit"
    end

    System.put_env("NCC_MEMORY", "12g")
    assert {:ok, %{memory: "12g"}} = Config.load()
  end

  test "an https URL without a host is an error" do
    System.put_env("NCC_PORTAL_URL", "https://")
    assert {:error, [msg]} = Config.load()
    assert msg =~ "NCC_PORTAL_URL"
  end
end
