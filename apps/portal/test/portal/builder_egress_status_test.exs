defmodule Portal.BuilderEgressStatusTest do
  # D8b (#40): the portal reads the live filter through a root helper on
  # /run/ncc-egress/status.sock that takes no input, lists `inet ncc_egress`
  # and the bridge icc table with `nft -s` and closes. A listing whose normalised
  # sha256 is not one this release expects refuses builds, however complete
  # it looks: an extra accept rule leaves the forward hook and the marker in
  # place. Beside the helper tests in Portal.BuilderTest ("egress preflight").
  use ExUnit.Case, async: false

  alias Portal.Builder
  import ExUnit.CaptureLog

  @build_args %{package: "jason", version: "1.4.1", run_id: "run-1", image_digest: "sha256:x"}

  @listing """
  table inet ncc_egress {
  	chain build_forward {
  		type filter hook forward priority filter - 10; policy accept;
  		iifname != "ncc0" accept
  		ip daddr { 10.0.0.0/8, 100.64.0.0/10, 172.16.0.0/12, 192.168.0.0/16 } drop
  		tcp dport { 80, 443 } accept
  		drop comment "ncc_egress_v1"
  	}
  }
  table bridge ncc_egress_icc {
  	chain build_icc {
  		type filter hook forward priority filter - 10; policy accept;
  		meta ibrname "ncc0" drop comment "ncc_egress_icc_v1"
  	}
  }
  """

  # The normalisation the release's expected set is computed with: each line
  # without a trailing `# handle N` and right-trimmed, leading and trailing
  # blank lines dropped, lines joined with "\n"; lowercase hex sha256 of that.
  defp normalised_sha256(listing) do
    listing
    |> String.split("\n")
    |> Enum.map(&(&1 |> String.replace(~r/\s*# handle \d+$/, "") |> String.trim_trailing()))
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  setup do
    previous = Application.get_env(:portal, Portal.Builder, [])
    on_exit(fn -> Application.put_env(:portal, Portal.Builder, previous) end)
    {:ok, previous: previous, expected: [normalised_sha256(@listing)]}
  end

  # A stand-in for the root helper: answers each connection with `reply`
  # (a binary, or {:partial_then_hang, binary}, or :hang) and closes. It
  # records whatever the portal wrote to it.
  defp helper(reply) do
    path = "/tmp/ncc-egress-st-#{System.unique_integer([:positive])}.sock"
    File.rm(path)
    test = self()

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false, reuseaddr: true])

    server = spawn(fn -> serve(listen, reply, test) end)
    :ok = :gen_tcp.controlling_process(listen, server)

    on_exit(fn ->
      Process.exit(server, :kill)
      File.rm(path)
    end)

    path
  end

  defp serve(listen, reply, test) do
    with {:ok, conn} <- :gen_tcp.accept(listen) do
      answer(conn, reply)

      case :gen_tcp.recv(conn, 0, 50) do
        {:ok, data} -> send(test, {:helper_received, data})
        _ -> :ok
      end

      :gen_tcp.close(conn)
      serve(listen, reply, test)
    end
  end

  defp answer(_conn, :hang), do: Process.sleep(5_000)

  defp answer(conn, {:partial_then_hang, part}) do
    :ok = :gen_tcp.send(conn, part)
    Process.sleep(5_000)
  end

  defp answer(conn, reply), do: :ok = :gen_tcp.send(conn, reply)

  defp probe(socket, expected, opts \\ []) do
    Builder.probe_egress(
      Keyword.merge([socket: socket, expected_hashes: expected, timeout_ms: 200], opts)
    )
  end

  # Every refusal first shows the genuine listing passing under the same
  # expected set, so a probe that refuses everything cannot pass it.
  defp baseline!(expected) do
    assert :ok = probe(helper(@listing), expected), "the genuine listing itself does not pass"
  end

  test "the genuine listing passes", %{expected: expected} do
    assert :ok = probe(helper(@listing), expected)
  end

  test "the hash ignores trailing whitespace and the final newline", %{expected: expected} do
    cosmetic = @listing |> String.replace("accept\n", "accept  \n") |> String.trim_trailing()
    assert :ok = probe(helper(cosmetic <> "\n\n"), expected)
  end

  # Complete by every other measure: the forward hook, the table and the
  # marker are all still there.
  test "a listing with an extra accept rule is refused", %{expected: expected} do
    baseline!(expected)

    tampered =
      String.replace(
        @listing,
        "\t\tiifname != \"ncc0\" accept\n",
        "\t\tiifname != \"ncc0\" accept\n\t\tip daddr 192.168.0.4 accept\n"
      )

    assert tampered != @listing
    assert {:error, _} = probe(helper(tampered), expected)
  end

  test "a listing outside the expected set is refused, any in it passes", %{expected: expected} do
    older = String.replace(@listing, "tcp dport { 80, 443 } accept", "tcp dport 443 accept")
    baseline!(expected)
    assert {:error, _} = probe(helper(older), expected)
    assert :ok = probe(helper(older), expected ++ [normalised_sha256(older)])
  end

  # A reload re-creates the tables with new handles; the rules are the same.
  test "a reloaded table with new handles passes", %{expected: expected} do
    {handled, _} =
      @listing
      |> String.split("\n")
      |> Enum.map_reduce(40, fn line, n ->
        if String.ends_with?(line, ["accept", "drop", "{", "\""]),
          do: {line <> " # handle #{n}", n + 1},
          else: {line, n}
      end)

    handled = Enum.join(handled, "\n")
    assert handled =~ "# handle 4"
    assert :ok = probe(helper(handled), expected)
  end

  test "a table with one drop removed is refused", %{expected: expected} do
    baseline!(expected)

    weakened =
      String.replace(
        @listing,
        "\t\tip daddr { 10.0.0.0/8, 100.64.0.0/10, 172.16.0.0/12, 192.168.0.0/16 } drop\n",
        ""
      )

    assert weakened != @listing
    assert {:error, _} = probe(helper(weakened), expected)
  end

  # Without it containers on ncc0 reach each other. Refused even when the
  # release were to list that listing's hash as expected.
  test "a listing without the bridge icc table is refused", %{expected: expected} do
    baseline!(expected)
    [inet_only, _] = String.split(@listing, "table bridge ", parts: 2)
    assert {:error, _} = probe(helper(inet_only), expected ++ [normalised_sha256(inet_only)])
  end

  test "an icc table without its drop is refused", %{expected: expected} do
    baseline!(expected)
    open = String.replace(@listing, ~s(meta ibrname "ncc0" drop comment "ncc_egress_icc_v1"), "")
    assert {:error, _} = probe(helper(open), expected ++ [normalised_sha256(open)])
  end

  # The read is capped: a helper that streams without end neither passes nor
  # fills the portal's memory.
  test "an oversized answer is refused", %{expected: expected} do
    baseline!(expected)
    padding = String.duplicate("# " <> String.duplicate("x", 1022) <> "\n", 2048)
    started = System.monotonic_time(:millisecond)
    assert {:error, _} = probe(helper(@listing <> padding), expected, timeout_ms: 2_000)
    assert System.monotonic_time(:millisecond) - started < 2_500
  end

  test "an empty expected set refuses every listing", %{expected: expected} do
    baseline!(expected)
    assert {:error, _} = probe(helper(@listing), [])
  end

  # The expected set comes from the release's config when the caller passes
  # none, and there is no default that accepts.
  test "without configured hashes the genuine listing is refused", %{
    previous: previous,
    expected: expected
  } do
    baseline!(expected)
    Application.put_env(:portal, Portal.Builder, Keyword.delete(previous, :egress_table_hashes))
    assert {:error, _} = Builder.probe_egress(socket: helper(@listing), timeout_ms: 200)
  end

  test "a listing cut off before its end is refused", %{expected: expected} do
    baseline!(expected)
    [head, _] = String.split(@listing, "\t}\n", parts: 2)
    assert {:error, _} = probe(helper(head), expected)
  end

  test "a helper that sends part of the listing and hangs is refused within the bound",
       %{expected: expected} do
    baseline!(expected)
    started = System.monotonic_time(:millisecond)

    assert {:error, _} =
             probe(helper({:partial_then_hang, String.slice(@listing, 0, 40)}), expected)

    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  test "a helper that answers nothing is refused", %{expected: expected} do
    baseline!(expected)
    assert {:error, _} = probe(helper(""), expected)
  end

  # nft's error first and the old table after it is not a table.
  test "an nft error is refused even when a listing follows it", %{expected: expected} do
    baseline!(expected)
    assert {:error, _} = probe(helper("Error: Could not process rule\n" <> @listing), expected)
  end

  test "a socket file nobody listens on is refused", %{expected: expected} do
    baseline!(expected)
    path = "/tmp/ncc-egress-stale-#{System.unique_integer([:positive])}.sock"

    {:ok, listen} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false])
    :gen_tcp.close(listen)
    on_exit(fn -> File.rm(path) end)

    assert {:error, _} = probe(path, expected)
  end

  # The helper takes no input; the portal gives it none.
  test "the portal writes nothing to the helper", %{expected: expected} do
    assert :ok = probe(helper(@listing), expected)
    refute_receive {:helper_received, _}, 200
  end

  describe "check_egress/0 and build/2 through the configured socket and hashes" do
    setup %{previous: previous, expected: expected} do
      socket = helper(@listing)

      Application.put_env(
        :portal,
        Portal.Builder,
        previous
        |> Keyword.delete(:egress_filter_probe)
        |> Keyword.merge(
          egress_check: true,
          egress_status_socket: socket,
          egress_table_hashes: expected
        )
      )

      {:ok, socket: socket}
    end

    test "the genuine listing lets builds through" do
      assert :ok = Builder.check_egress()
    end

    test "a tampered table refuses the build before anything is written", %{
      previous: previous,
      expected: expected
    } do
      assert :ok = Builder.check_egress()

      root = Path.join(System.tmp_dir!(), "egress-root-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(root) end)

      tampered = String.replace(@listing, "drop comment", "accept\n\t\tdrop comment")

      Application.put_env(
        :portal,
        Portal.Builder,
        previous
        |> Keyword.delete(:egress_filter_probe)
        |> Keyword.merge(
          egress_check: true,
          egress_status_socket: helper(tampered),
          egress_table_hashes: expected,
          scratch_root: root,
          min_free_disk_gb: 0,
          exec_probe: fn _path -> :ok end
        )
      )

      log =
        capture_log(fn ->
          assert {:error, :egress_filter_missing} = Builder.build(@build_args)
        end)

      assert log =~ "Build egress filter missing"
      refute File.exists?(Path.join(root, "run-1"))
    end
  end
end
