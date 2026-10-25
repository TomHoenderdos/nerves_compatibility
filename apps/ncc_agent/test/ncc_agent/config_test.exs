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
    :ok
  end

  test "requires the portal url and defaults the rest" do
    assert {:error, [msg]} = Config.load()
    assert msg =~ "NCC_PORTAL_URL"
    System.put_env("NCC_PORTAL_URL", "https://portal.test:8443")
    System.put_env("NCC_DATA_DIR", "/tmp/ncc-x")
    assert {:ok, config} = Config.load()

    assert config.portal_url == "https://portal.test:8443" and config.slots == 1 and
             config.docker_bin == "docker"

    assert config.build_user =~ ~r/^\d+:\d+$/
    assert Config.path(config, :cert) == "/tmp/ncc-x/client.pem"
    assert Config.path(config, :nerves_cache) == "/tmp/ncc-x/nerves-cache"
    assert String.ends_with?(config.egress_script, "egress.sh")
  end

  test "slots must be 1..16 and the url https" do
    System.put_env("NCC_PORTAL_URL", "http://portal.test")
    System.put_env("NCC_SLOTS", "40")
    assert {:error, errors} = Config.load()
    assert Enum.any?(errors, &(&1 =~ "NCC_SLOTS")) and Enum.any?(errors, &(&1 =~ "https"))
  end

  test "an https URL without a host is an error" do
    System.put_env("NCC_PORTAL_URL", "https://")
    assert {:error, [msg]} = Config.load()
    assert msg =~ "NCC_PORTAL_URL"
  end
end
