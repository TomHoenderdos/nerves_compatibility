defmodule Portal.Catalog.WarmupTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog.Warmup

  @web [server?: true, queues: [intake: 5, maintenance: 1], ttl_ms: 60_000]

  describe "enabled?/1" do
    test "a node serving the site warms" do
      assert Warmup.enabled?(@web)
    end

    test "a single node with every queue warms" do
      assert Warmup.enabled?(Keyword.put(@web, :queues, builds: 1, ingest: 2, intake: 5))
    end

    test "the build node does not" do
      refute Warmup.enabled?(Keyword.put(@web, :queues, builds: 3, ingest: 3))
    end

    test "a node without the endpoint does not" do
      refute Warmup.enabled?(Keyword.put(@web, :server?, false))
    end

    test "nothing warms when the cache keeps nothing" do
      refute Warmup.enabled?(Keyword.put(@web, :ttl_ms, 0))
    end

    test "the test environment does not" do
      refute Warmup.enabled?()
    end
  end

  test "warm/0 computes every key without raising" do
    assert Warmup.warm() == :ok
  end
end
