defmodule Portal.BuildCache.StagingTest do
  use ExUnit.Case, async: true

  alias Portal.BuildCache.Staging

  test "name/1 is dest.tmp.<host>.<16 hex>" do
    name = Staging.name("/cache/sha256_x/" <> String.duplicate("a", 64))
    host = Staging.host()
    assert {:ok, %{host: ^host, download?: false}} = Staging.parse(Path.basename(name))
    assert Regex.match?(~r/\.tmp\.#{Regex.escape(host)}\.[0-9a-f]{16}\z/, name)
  end

  test "host/0 only ever contains [A-Za-z0-9-] and is never empty" do
    assert Regex.match?(~r/\A[A-Za-z0-9-]{1,63}\z/, Staging.host())
    assert Staging.sanitize_host("box.home.arpa") == "box-home-arpa"
    assert Staging.sanitize_host("") == "host"
    assert Staging.sanitize_host(String.duplicate("x", 80)) == String.duplicate("x", 63)
  end

  test "parse/1 reads the legacy form, the host form and the download form" do
    assert {:ok, %{host: nil, download?: false}} = Staging.parse("k.tmp.a1b2c3d4e5f60718")

    assert {:ok, %{host: "box-b", download?: false}} =
             Staging.parse("k.tmp.box-b.a1b2c3d4e5f60718")

    assert {:ok, %{host: "box-b", download?: true}} =
             Staging.parse("k.tmp.box-b.a1b2c3d4e5f60718.tar.gz")

    assert :error = Staging.parse("k")
    assert :error = Staging.parse(String.duplicate("a", 64))
  end

  test "ours?/2 is true for the legacy form and our own host only" do
    assert Staging.ours?("k.tmp.a1b2c3d4e5f60718", "box-a")
    assert Staging.ours?("k.tmp.box-a.a1b2c3d4e5f60718", "box-a")
    refute Staging.ours?("k.tmp.box-b.a1b2c3d4e5f60718", "box-a")
    refute Staging.ours?("k", "box-a")
  end
end
