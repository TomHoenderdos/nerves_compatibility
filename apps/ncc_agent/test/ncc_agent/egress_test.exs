defmodule NccAgent.EgressTest do
  use ExUnit.Case, async: false

  alias NccAgent.{Config, Egress}

  @script Path.expand("../../priv/egress.sh", __DIR__)
  @fake Path.expand("../support/fake_iptables.sh", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "egress-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "state"))
    System.put_env("IPTABLES", @fake)
    System.put_env("IP6TABLES", "/bin/false")
    System.put_env("FAKE_IPTABLES_LOG", Path.join(dir, "log"))
    System.put_env("FAKE_IPTABLES_STATE", Path.join(dir, "state"))

    File.write!(
      Path.join([dir, "state", "DOCKER-USER"]),
      "-N DOCKER-USER\n-A DOCKER-USER -j RETURN\n"
    )

    Config.put(%{
      Config.defaults()
      | portal_url: "https://x",
        egress_script: @script,
        data_dir: dir
    })

    on_exit(fn ->
      File.rm_rf(dir)

      for k <- ~w(IPTABLES IP6TABLES FAKE_IPTABLES_LOG FAKE_IPTABLES_STATE),
          do: System.delete_env(k)
    end)

    %{dir: dir}
  end

  test "verify fails before install and passes after; install is idempotent", %{dir: dir} do
    assert {:error, why} = Egress.verify()
    assert why =~ "NCC-EGRESS"
    assert :ok = Egress.install()
    assert :ok = Egress.verify()
    rules = File.read!(Path.join([dir, "state", "NCC-EGRESS"]))
    assert rules =~ "-d 169.254.0.0/16 -j DROP"
    assert rules =~ "-d 100.64.0.0/10 -j DROP"
    assert rules =~ "-p tcp --dport 443 -j ACCEPT"
    assert String.ends_with?(String.trim(rules), "-j DROP")
    lines = String.split(rules, "\n")
    dns_index = Enum.find_index(lines, &(&1 =~ "--dport 53"))
    drop_index = Enum.find_index(lines, &(&1 =~ "10.0.0.0/8"))
    assert is_integer(dns_index) and is_integer(drop_index)
    assert dns_index < drop_index
    assert :ok = Egress.install()
    docker_user = File.read!(Path.join([dir, "state", "DOCKER-USER"]))
    assert length(Regex.scan(~r/-j NCC-EGRESS/, docker_user)) == 1
    assert Egress.status() == "ok"
  end

  test "the ruleset is exactly the policy, in order, and jumps first from DOCKER-USER", %{
    dir: dir
  } do
    :ok = Egress.install()

    assert File.read!(Path.join([dir, "state", "NCC-EGRESS"])) == """
           -N NCC-EGRESS
           -A NCC-EGRESS -p udp --dport 53 -j ACCEPT
           -A NCC-EGRESS -p tcp --dport 53 -j ACCEPT
           -A NCC-EGRESS -d 10.0.0.0/8 -j DROP
           -A NCC-EGRESS -d 172.16.0.0/12 -j DROP
           -A NCC-EGRESS -d 192.168.0.0/16 -j DROP
           -A NCC-EGRESS -d 100.64.0.0/10 -j DROP
           -A NCC-EGRESS -d 169.254.0.0/16 -j DROP
           -A NCC-EGRESS -d 127.0.0.0/8 -j DROP
           -A NCC-EGRESS -p tcp --dport 443 -j ACCEPT
           -A NCC-EGRESS -p tcp --dport 80 -j ACCEPT
           -A NCC-EGRESS -j DROP
           """

    assert File.read!(Path.join([dir, "state", "DOCKER-USER"])) ==
             "-N DOCKER-USER\n-A DOCKER-USER -j NCC-EGRESS\n-A DOCKER-USER -j RETURN\n"
  end

  test "a rule removed after install fails verify again", %{dir: dir} do
    :ok = Egress.install()
    File.write!(Path.join([dir, "state", "NCC-EGRESS"]), "-N NCC-EGRESS\n")
    assert {:error, _} = Egress.verify()
    assert Egress.status() == "missing"
  end

  test "install fails without a DOCKER-USER chain", %{dir: dir} do
    File.rm!(Path.join([dir, "state", "DOCKER-USER"]))
    assert {:error, why} = Egress.install()
    assert why =~ "DOCKER-USER"
    assert {:error, _} = Egress.verify()
  end

  test "with ip6tables present the IPv6 chain is installed and verified too", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "state6"))
    wrapper = Path.join(dir, "ip6tables")

    File.write!(wrapper, """
    #!/usr/bin/env bash
    FAKE_IPTABLES_STATE=#{Path.join(dir, "state6")} FAKE_IPTABLES_DOCKER_USER=1 exec #{@fake} "$@"
    """)

    File.chmod!(wrapper, 0o755)
    System.put_env("IP6TABLES", wrapper)

    assert :ok = Egress.install()
    assert :ok = Egress.verify()
    rules = File.read!(Path.join([dir, "state6", "NCC-EGRESS"]))
    assert rules =~ "-d fc00::/7 -j DROP"
    assert rules =~ "-d fe80::/10 -j DROP"
    assert rules =~ "-d ::1/128 -j DROP"
    assert String.ends_with?(String.trim(rules), "-j DROP")
    assert File.read!(Path.join([dir, "state6", "DOCKER-USER"])) =~ "-j NCC-EGRESS"

    File.write!(Path.join([dir, "state6", "NCC-EGRESS"]), "-N NCC-EGRESS\n")
    assert {:error, why} = Egress.verify()
    assert why =~ "ip6tables"
  end

  test "a missing script is an error, not a crash", %{dir: dir} do
    Config.put(%{Config.get() | egress_script: Path.join(dir, "nope.sh")})
    assert {:error, _} = Egress.verify()
    assert {:error, _} = Egress.install()
    assert Egress.status() == "missing"
  end
end
