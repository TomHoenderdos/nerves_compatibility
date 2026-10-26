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
    # No resolver to find unless a test plants one: the host's own files
    # stay out of it.
    System.put_env("NCC_DOCKER_DAEMON_JSON", Path.join(dir, "daemon.json"))
    System.put_env("NCC_RESOLV_CONF", Path.join(dir, "resolv.conf"))
    System.put_env("RESOLVECTL", Path.join(dir, "resolvectl"))
    # No IPv6 on the default bridge unless a test says otherwise.
    System.put_env("NCC_DOCKER_BRIDGE_IPV6", "false")

    # What a running Docker daemon leaves in the filter table.
    File.write!(
      Path.join([dir, "state", "DOCKER-USER"]),
      "-N DOCKER-USER\n-A DOCKER-USER -j RETURN\n"
    )

    File.write!(Path.join([dir, "state", "FORWARD"]), "-N FORWARD\n-A FORWARD -j DOCKER-USER\n")
    File.write!(Path.join([dir, "state", "INPUT"]), "-N INPUT\n")

    Config.put(%{
      Config.defaults()
      | portal_url: "https://x",
        egress_script: @script,
        data_dir: dir
    })

    on_exit(fn ->
      File.rm_rf(dir)

      for k <- ~w(IPTABLES IP6TABLES FAKE_IPTABLES_LOG FAKE_IPTABLES_STATE NCC_DNS_SERVERS
                  NCC_DOCKER_DAEMON_JSON NCC_RESOLV_CONF RESOLVECTL NCC_DOCKER_BRIDGE_IPV6),
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
           -A NCC-EGRESS -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
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

    # Container-to-host traffic: DNS, then no new connection from a bridge.
    assert File.read!(Path.join([dir, "state", "NCC-INPUT"])) == """
           -N NCC-INPUT
           -A NCC-INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
           -A NCC-INPUT -p udp --dport 53 -j ACCEPT
           -A NCC-INPUT -p tcp --dport 53 -j ACCEPT
           -A NCC-INPUT -i docker0 -m conntrack --ctstate NEW -j DROP
           -A NCC-INPUT -i br-+ -m conntrack --ctstate NEW -j DROP
           -A NCC-INPUT -j DROP
           """

    assert File.read!(Path.join([dir, "state", "INPUT"])) == "-N INPUT\n-A INPUT -j NCC-INPUT\n"
    refute File.exists?(Path.join([dir, "state", "NCC-EGRESS-NEW"]))
  end

  test "verify wants the whole policy: the jump first, FORWARD wired, the rules in order", %{
    dir: dir
  } do
    :ok = Egress.install()
    docker_user = Path.join([dir, "state", "DOCKER-USER"])
    chain = Path.join([dir, "state", "NCC-EGRESS"])
    forward = Path.join([dir, "state", "FORWARD"])

    # A rule inserted ahead of the jump (ufw-docker style) is a bypass.
    File.write!(
      docker_user,
      "-N DOCKER-USER\n-A DOCKER-USER -j ACCEPT\n-A DOCKER-USER -j NCC-EGRESS\n"
    )

    assert {:error, why} = Egress.verify()
    assert why =~ "first rule of DOCKER-USER"
    :ok = Egress.install()
    assert :ok = Egress.verify()

    # The drops must precede the Internet accepts.
    lines = chain |> File.read!() |> String.split("\n", trim: true)
    {accepts, drops} = Enum.split_with(lines, &(&1 =~ "--dport 443" or &1 =~ "--dport 80"))
    [head, conntrack, dns1, dns2 | rest] = drops
    reordered = [head, conntrack, dns1, dns2] ++ accepts ++ rest
    File.write!(chain, Enum.join(reordered, "\n") <> "\n")
    assert {:error, why} = Egress.verify()
    assert why =~ "not the policy"
    :ok = Egress.install()

    # A rule the policy does not name is not tolerated either.
    File.write!(
      chain,
      String.replace(File.read!(chain), "-j DROP\n", "-d 1.2.3.4/32 -j ACCEPT\n-j DROP\n",
        global: false
      )
    )

    assert {:error, _} = Egress.verify()
    :ok = Egress.install()

    # Real iptables prints the implicit match modules; that still verifies.
    File.write!(
      chain,
      String.replace(File.read!(chain), "-p tcp --dport 443", "-p tcp -m tcp --dport 443")
    )

    assert :ok = Egress.verify()

    File.write!(forward, "-N FORWARD\n")
    assert {:error, why} = Egress.verify()
    assert why =~ "FORWARD"
  end

  test "a reinstall swaps the chain in rather than emptying it", %{dir: dir} do
    :ok = Egress.install()
    :ok = Egress.install()
    calls = dir |> Path.join("log") |> File.read!() |> String.split("\n", trim: true)
    # The old chain is only flushed after DOCKER-USER already jumps to the new one.
    jump = Enum.find_index(calls, &(&1 =~ "-I DOCKER-USER 1 -j NCC-EGRESS-NEW"))
    flushes = calls |> Enum.with_index() |> Enum.filter(fn {c, _} -> c =~ ~r/-F NCC-EGRESS$/ end)
    assert [{_, flush}] = flushes
    assert jump < flush
    assert Enum.count(calls, &(&1 =~ "-E NCC-EGRESS-NEW NCC-EGRESS")) == 2
    assert :ok = Egress.verify()
    docker_user = File.read!(Path.join([dir, "state", "DOCKER-USER"]))
    assert length(Regex.scan(~r/-j NCC-EGRESS/, docker_user)) == 1
  end

  test "IPv6 on the bridge with nothing to filter it fails verify" do
    :ok = Egress.install()
    assert :ok = Egress.verify()
    System.put_env("NCC_DOCKER_BRIDGE_IPV6", "true")
    assert {:error, why} = Egress.verify()
    assert why =~ "IPv6"
    System.put_env("NCC_DOCKER_BRIDGE_IPV6", "unknown")
    assert {:error, _} = Egress.verify()
  end

  test "verify requires the conntrack accept as the first rule, in either state order", %{
    dir: dir
  } do
    :ok = Egress.install()
    file = Path.join([dir, "state", "NCC-EGRESS"])
    [head, conntrack | rest] = file |> File.read!() |> String.split("\n", trim: true)

    File.write!(file, Enum.join([head | rest], "\n") <> "\n")
    assert {:error, why} = Egress.verify()
    assert why =~ "ESTABLISHED"

    File.write!(file, Enum.join([head | List.insert_at(rest, 1, conntrack)], "\n") <> "\n")
    assert {:error, _} = Egress.verify()

    nft_order = "-A NCC-EGRESS -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
    File.write!(file, Enum.join([head, nft_order | rest], "\n") <> "\n")
    assert :ok = Egress.verify()
  end

  test "concurrent installs run one after the other", %{dir: dir} do
    System.put_env("FAKE_IPTABLES_DELAY", "0.01")
    on_exit(fn -> System.delete_env("FAKE_IPTABLES_DELAY") end)

    results =
      1..3
      |> Enum.map(fn _ -> Task.async(&Egress.install/0) end)
      |> Enum.map(&Task.await(&1, 30_000))

    assert results == [:ok, :ok, :ok]

    # Each install starts with `-S DOCKER-USER` (its only one); everything
    # up to the next one must be its own calls, in one complete sequence.
    installs =
      dir
      |> Path.join("log")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.chunk_while(
        [],
        fn line, acc ->
          if line =~ "-S DOCKER-USER" and acc != [],
            do: {:cont, Enum.reverse(acc), [line]},
            else: {:cont, [line | acc]}
        end,
        fn acc -> {:cont, Enum.reverse(acc), []} end
      )

    assert length(installs) == 3

    for calls <- installs do
      assert calls |> hd() |> String.ends_with?("-S DOCKER-USER")
      assert Enum.count(calls, &(&1 =~ "-S DOCKER-USER")) == 1
      assert Enum.count(calls, &(&1 =~ "-A NCC-EGRESS-NEW -j DROP")) == 1
      assert Enum.count(calls, &(&1 =~ "-I NCC-EGRESS-NEW")) == 11
      assert Enum.count(calls, &(&1 =~ "-E NCC-EGRESS-NEW NCC-EGRESS")) == 1
    end

    assert File.read!(Path.join([dir, "state", "NCC-EGRESS"]))
           |> String.split("\n", trim: true)
           |> length() == 13

    assert :ok = Egress.verify()
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

    assert rules |> String.split("\n") |> Enum.at(1) ==
             "-A NCC-EGRESS -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"

    assert rules =~ "-d fc00::/7 -j DROP"
    assert rules =~ "-d fe80::/10 -j DROP"
    assert rules =~ "-d ::1/128 -j DROP"
    assert String.ends_with?(String.trim(rules), "-j DROP")
    assert File.read!(Path.join([dir, "state6", "DOCKER-USER"])) =~ "-j NCC-EGRESS"

    File.write!(Path.join([dir, "state6", "NCC-EGRESS"]), "-N NCC-EGRESS\n")
    assert {:error, why} = Egress.verify()
    assert why =~ "ip6tables"
  end

  test "without an ip6tables DOCKER-USER chain both actions say v6 is skipped" do
    skipped = "egress: ip6tables DOCKER-USER chain not present, v6 rules skipped"
    {install, 0} = System.cmd(@script, ["install"], stderr_to_stdout: true)
    assert install =~ skipped
    {verify, 0} = System.cmd(@script, ["verify"], stderr_to_stdout: true)
    assert verify =~ skipped
  end

  test "every iptables call waits at most 10 s for the xtables lock", %{dir: dir} do
    :ok = Egress.install()
    :ok = Egress.verify()
    calls = dir |> Path.join("log") |> File.read!() |> String.split("\n", trim: true)
    assert calls != []
    assert Enum.all?(calls, &String.starts_with?(&1, "-w 10 "))
  end

  test "a missing script is an error, not a crash", %{dir: dir} do
    Config.put(%{Config.get() | egress_script: Path.join(dir, "nope.sh")})
    assert {:error, _} = Egress.verify()
    assert {:error, _} = Egress.install()
    assert Egress.status() == "missing"
  end

  defp chain(dir, state \\ "state"),
    do: dir |> Path.join(state) |> Path.join("NCC-EGRESS") |> File.read!()

  defp bare_dns?(rules),
    do: rules =~ "-A NCC-EGRESS -p udp --dport 53" or rules =~ "-A NCC-EGRESS -p tcp --dport 53"

  defp ip6tables!(dir) do
    File.mkdir_p!(Path.join(dir, "state6"))
    wrapper = Path.join(dir, "ip6tables")

    File.write!(wrapper, """
    #!/usr/bin/env bash
    FAKE_IPTABLES_STATE=#{Path.join(dir, "state6")} FAKE_IPTABLES_DOCKER_USER=1 exec #{@fake} "$@"
    """)

    File.chmod!(wrapper, 0o755)
    System.put_env("IP6TABLES", wrapper)
  end

  test "with NCC_DNS_SERVERS, DNS goes to those resolvers only, before the private drops", %{
    dir: dir
  } do
    System.put_env("NCC_DNS_SERVERS", "10.0.0.2")

    assert :ok = Egress.install()
    assert :ok = Egress.verify()
    rules = chain(dir)
    lines = String.split(rules, "\n", trim: true)

    assert Enum.slice(lines, 1, 3) == [
             "-A NCC-EGRESS -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT",
             "-A NCC-EGRESS -d 10.0.0.2/32 -p udp --dport 53 -j ACCEPT",
             "-A NCC-EGRESS -d 10.0.0.2/32 -p tcp --dport 53 -j ACCEPT"
           ]

    assert Enum.at(lines, 4) == "-A NCC-EGRESS -d 10.0.0.0/8 -j DROP"
    refute bare_dns?(rules)
  end

  test "the dns list of daemon.json is used, v4 in iptables and v6 in ip6tables", %{dir: dir} do
    ip6tables!(dir)

    File.write!(Path.join(dir, "daemon.json"), """
    {"dns-search": ["corp"], "dns": ["10.1.1.1", "fd00::53"], "log-driver": "json-file"}
    """)

    {out, 0} = System.cmd(@script, ["install"], stderr_to_stdout: true)
    refute out =~ "resolver unknown"
    v4 = chain(dir)
    v6 = chain(dir, "state6")
    assert v4 =~ "-A NCC-EGRESS -d 10.1.1.1/32 -p udp --dport 53 -j ACCEPT"
    refute v4 =~ "fd00::53"
    assert v6 =~ "-A NCC-EGRESS -d fd00::53/128 -p tcp --dport 53 -j ACCEPT"
    refute v6 =~ "10.1.1.1"
    refute bare_dns?(v4) or bare_dns?(v6)
    assert :ok = Egress.verify()
  end

  test "resolv.conf's nameservers are used, loopback ones left out", %{dir: dir} do
    File.write!(Path.join(dir, "resolv.conf"), """
    # generated
    nameserver 127.0.0.1
    nameserver 192.168.1.1
    search lan
    """)

    assert :ok = Egress.install()
    rules = chain(dir)
    assert rules =~ "-A NCC-EGRESS -d 192.168.1.1/32 -p udp --dport 53 -j ACCEPT"
    refute rules =~ "127.0.0.1/32"
    refute bare_dns?(rules)
  end

  test "behind systemd-resolved the resolvers come from resolvectl", %{dir: dir} do
    File.write!(Path.join(dir, "resolv.conf"), "nameserver 127.0.0.53\noptions edns0\n")
    resolvectl = Path.join(dir, "resolvectl")

    File.write!(resolvectl, """
    #!/usr/bin/env bash
    cat <<'OUT'
    Global
           Protocols: -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported

    Link 2 (eth0)
    Current DNS Server: 10.0.0.2
           DNS Servers: 10.0.0.2 10.0.0.3#dns.example
    OUT
    """)

    File.chmod!(resolvectl, 0o755)

    assert :ok = Egress.install()
    rules = chain(dir)
    assert rules =~ "-A NCC-EGRESS -d 10.0.0.2/32 -p udp --dport 53 -j ACCEPT"
    assert rules =~ "-A NCC-EGRESS -d 10.0.0.3/32 -p tcp --dport 53 -j ACCEPT"
    assert length(Regex.scan(~r/10\.0\.0\.2/, rules)) == 2
    refute rules =~ "127.0.0.53"
    refute bare_dns?(rules)
  end

  test "with no resolver to be found DNS stays open to any destination, and install says so", %{
    dir: dir
  } do
    File.write!(Path.join(dir, "resolv.conf"), "nameserver 127.0.0.53\n")

    {out, 0} = System.cmd(@script, ["install"], stderr_to_stdout: true)
    assert out =~ "egress: resolver unknown, DNS allowed to any destination"
    assert bare_dns?(chain(dir))
    assert :ok = Egress.verify()
  end
end
