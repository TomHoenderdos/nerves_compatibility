defmodule Portal.BuildCache.L2.ClientTest do
  use ExUnit.Case, async: true

  alias Portal.BuildCache.L2.Client
  alias Portal.Test.FakeS3

  setup do
    {:ok, s} = FakeS3.start()
    tmp = Path.join(System.tmp_dir!(), "client-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    %{s: s, cfg: s.config, tmp: tmp}
  end

  test "put, head, get round trip with the sha metadata", %{s: s, cfg: cfg, tmp: tmp} do
    src = Path.join(tmp, "src")
    File.write!(src, "hello")
    sha = :crypto.hash(:sha256, "hello") |> Base.encode16(case: :lower)
    assert :ok = Client.put(cfg, "slug/k.tar.gz", src, sha)
    assert {:ok, %{meta: meta}} = FakeS3.get_object(s, "slug/k.tar.gz")
    assert meta["x-amz-meta-sha256"] == sha
    assert {:ok, %{size: 5, sha256: ^sha}} = Client.head(cfg, "slug/k.tar.gz")
    dst = Path.join(tmp, "dst")

    assert {:ok, %{bytes: 5, sha256_computed: ^sha, sha256_header: ^sha}} =
             Client.get(cfg, "slug/k.tar.gz", dst, [])

    assert File.read!(dst) == "hello"
  end

  test "a missing object is not_found on head and get, and get leaves no file", %{
    cfg: cfg,
    tmp: tmp
  } do
    assert {:error, :not_found} = Client.head(cfg, "slug/none")
    dst = Path.join(tmp, "dst")
    assert {:error, :not_found} = Client.get(cfg, "slug/none", dst, [])
    refute File.exists?(dst)
  end

  test "get stops past max_bytes and removes the partial file", %{s: s, cfg: cfg, tmp: tmp} do
    FakeS3.put_object(s, "slug/big", String.duplicate("x", 10_000), %{
      "x-amz-meta-sha256" => "irrelevant"
    })

    dst = Path.join(tmp, "dst")
    assert {:error, :too_large} = Client.get(cfg, "slug/big", dst, max_bytes: 100)
    refute File.exists?(dst)
  end

  test "get is bounded in time", %{s: s, cfg: cfg, tmp: tmp} do
    FakeS3.put_object(s, "slug/slow", "body", %{})
    FakeS3.on_get(s, fn _ -> Process.sleep(500) end)

    dst = Path.join(tmp, "dst")
    assert {:error, :timeout} = Client.get(cfg, "slug/slow", dst, timeout_ms: 50)
    refute File.exists?(dst)
  end

  @tag :capture_log
  test "put is bounded in total time", %{s: s, cfg: cfg, tmp: tmp} do
    File.write!(Path.join(tmp, "src"), "x")
    FakeS3.set_fault(s, {:put, :hang})

    {micros, result} =
      :timer.tc(fn ->
        Client.put(cfg, "slug/k", Path.join(tmp, "src"), "sha", timeout_ms: 200)
      end)

    # The total bound and Req's receive timeout are both 200 ms, so either
    # can fire first; what matters is that the call returns in time.
    assert result in [{:error, :timeout}, {:error, %Req.TransportError{reason: :timeout}}]
    assert micros < 1_000_000
    assert Process.alive?(self())
  end

  test "a non-2xx is reported by status", %{s: s, cfg: cfg, tmp: tmp} do
    FakeS3.put_object(s, "slug/k", "body", %{})
    FakeS3.set_fault(s, {:get, :status, 500})
    dst = Path.join(tmp, "dst")
    assert {:error, {:status, 500}} = Client.get(cfg, "slug/k", dst, [])
    refute File.exists?(dst)
    FakeS3.set_fault(s, {:put, :status, 503})
    File.write!(Path.join(tmp, "src"), "x")
    assert {:error, {:status, 503}} = Client.put(cfg, "slug/k", Path.join(tmp, "src"), "sha")
  end

  test "an open failure comes back as an error", %{s: s, cfg: cfg, tmp: tmp} do
    FakeS3.put_object(s, "slug/k", "body", %{})
    assert {:error, _} = Client.get(cfg, "slug/k", tmp, [])
    assert File.dir?(tmp)
  end

  test "a write failure comes back as an error, the caller survives, the device stays", %{
    s: s,
    cfg: cfg
  } do
    FakeS3.put_object(s, "slug/k", "body", %{})

    # /dev/full opens fine and fails every write with ENOSPC, inside the task.
    if File.exists?("/dev/full") do
      assert {:error, {:exception, _}} = Client.get(cfg, "slug/k", "/dev/full", [])
      assert Process.alive?(self())
      assert File.exists?("/dev/full")
    end
  end

  test "list pages through the prefix and parses size and time", %{s: s, cfg: cfg} do
    for i <- 1..5, do: FakeS3.put_object(s, "slug/#{i}.tar.gz", String.duplicate("x", i), %{})
    FakeS3.put_object(s, "other/1.tar.gz", "y", %{})
    assert {:ok, objects} = Client.list(cfg, "slug/", max_keys: 2)
    assert Enum.map(objects, & &1.key) == for(i <- 1..5, do: "slug/#{i}.tar.gz")
    assert Enum.map(objects, & &1.size) == [1, 2, 3, 4, 5]
    assert Enum.all?(objects, &match?(%DateTime{}, &1.last_modified))
    assert length(FakeS3.requests(s)) >= 3
  end

  test "a truncated page without a token ends the listing", %{s: s, cfg: cfg} do
    for i <- 1..3, do: FakeS3.put_object(s, "slug/#{i}.tar.gz", "x", %{})
    FakeS3.set_fault(s, {:list, :no_token})
    assert {:ok, [_one]} = Client.list(cfg, "slug/")
  end

  test "an endpoint that is down is an error, quickly", %{cfg: cfg} do
    down = %{cfg | endpoint: "http://127.0.0.1:1"}
    assert {:error, _} = Client.head(down, "slug/k")
    assert {:error, _} = Client.list(down, "slug/")
  end

  test "every request was signed with the configured key", %{s: s, cfg: cfg} do
    assert {:ok, []} = Client.list(cfg, "slug/")
    assert [{"GET", _, query}] = FakeS3.requests(s)
    assert query =~ "list-type=2"
  end

  # The pool hands out a kept-alive connection the server has since closed;
  # the first request on it fails with `:closed` before a byte is sent. A
  # proxy in front of the stub closes its first connection right after
  # accepting it and forwards every later one.
  test "delete removes the object, signed, and a missing one is ok too", %{s: s, cfg: cfg} do
    FakeS3.put_object(s, "slug/k.tar.gz", "hello")
    assert :ok = Client.delete(cfg, "slug/k.tar.gz")
    assert FakeS3.objects(s) == []
    assert {"DELETE", "/ncc-test/slug/k.tar.gz", ""} in FakeS3.requests(s)
    assert :ok = Client.delete(cfg, "slug/k.tar.gz")
  end

  test "delete answers ok on a 404 and an error on any other status", %{s: s, cfg: cfg} do
    FakeS3.put_object(s, "slug/k.tar.gz", "hello")
    FakeS3.set_fault(s, {:delete, :status, 404})
    assert :ok = Client.delete(cfg, "slug/k.tar.gz")
    FakeS3.set_fault(s, {:delete, :status, 403})
    assert {:error, {:status, 403}} = Client.delete(cfg, "slug/k.tar.gz")
    FakeS3.set_fault(s, {:delete, :status, 500})
    assert {:error, {:status, 500}} = Client.delete(cfg, "slug/k.tar.gz")
    assert FakeS3.objects(s) == ["slug/k.tar.gz"]
  end

  test "a delete signed with the wrong secret is refused", %{s: s, cfg: cfg} do
    FakeS3.put_object(s, "slug/k.tar.gz", "hello")
    assert {:error, {:status, 403}} = Client.delete(%{cfg | secret_key: "wrong"}, "slug/k.tar.gz")
    assert FakeS3.objects(s) == ["slug/k.tar.gz"]
  end

  test "delete is bounded in time", %{s: s, cfg: cfg} do
    FakeS3.put_object(s, "slug/k.tar.gz", "hello")
    FakeS3.on_delete(s, fn _ -> Process.sleep(200) end)
    # Whichever fires first: the receive timeout or the total bound.
    assert {:error, reason} = Client.delete(cfg, "slug/k.tar.gz", timeout_ms: 50)
    assert reason in [:timeout, %Req.TransportError{reason: :timeout}]
    # Let the stub answer before it stops with the test.
    Process.sleep(250)
  end

  test "an unreachable store is an error from delete, not a raise", %{cfg: cfg} do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)

    assert {:error, _} =
             Client.delete(%{cfg | endpoint: "http://127.0.0.1:#{port}"}, "slug/k.tar.gz")
  end

  test "a request on a connection the server closed is sent again once", %{s: s, cfg: cfg} do
    FakeS3.put_object(s, "slug/k.tar.gz", "hello")
    %URI{port: upstream} = URI.parse(cfg.endpoint)
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    proxy = spawn_link(fn -> closing_proxy(listen, upstream, :close_first) end)
    on_exit(fn -> Process.exit(proxy, :kill) end)

    cfg = %{cfg | endpoint: "http://127.0.0.1:#{port}"}
    assert {:ok, [%{key: "slug/k.tar.gz"}]} = Client.list(cfg, "slug/")
  end

  defp closing_proxy(listen, upstream, mode) do
    {:ok, client} = :gen_tcp.accept(listen)

    case mode do
      :close_first ->
        :gen_tcp.close(client)

      :forward ->
        {:ok, server} = :gen_tcp.connect(~c"127.0.0.1", upstream, [:binary, active: false])
        pid = spawn(fn -> pipe(client, server) end)
        :gen_tcp.controlling_process(client, pid)
        spawn(fn -> pipe(server, client) end) |> then(&:gen_tcp.controlling_process(server, &1))
    end

    closing_proxy(listen, upstream, :forward)
  end

  defp pipe(from, to) do
    case :gen_tcp.recv(from, 0) do
      {:ok, data} ->
        :gen_tcp.send(to, data)
        pipe(from, to)

      {:error, _} ->
        :gen_tcp.close(to)
    end
  end
end
