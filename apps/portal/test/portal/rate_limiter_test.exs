defmodule Portal.RateLimiterTest do
  # Not async: the sweep test drops every ended window in the shared table,
  # whoever counted it.
  use ExUnit.Case, async: false

  alias Portal.RateLimiter

  # A unique bucket per test keeps tests off each other's counters.
  defp bucket, do: {:test, make_ref()}

  test "allows `limit` hits per window, then refuses with the time left in it" do
    bucket = bucket()
    now = 1_800_000_000_020_000

    assert :ok = RateLimiter.hit(bucket, :a, 2, 60_000, now_ms: now)
    assert :ok = RateLimiter.hit(bucket, :a, 2, 60_000, now_ms: now)
    assert {:error, retry_after_ms} = RateLimiter.hit(bucket, :a, 2, 60_000, now_ms: now)

    # `now` is 20 s into its minute.
    assert retry_after_ms == 40_000
  end

  test "keys and buckets are counted separately" do
    bucket = bucket()

    assert :ok = RateLimiter.hit(bucket, :a, 1, 60_000)
    assert {:error, _} = RateLimiter.hit(bucket, :a, 1, 60_000)
    assert :ok = RateLimiter.hit(bucket, :b, 1, 60_000)
    assert :ok = RateLimiter.hit(bucket(), :a, 1, 60_000)
  end

  test "the next window starts from zero" do
    bucket = bucket()
    now = System.system_time(:millisecond)

    assert :ok = RateLimiter.hit(bucket, :a, 1, 60_000, now_ms: now)
    assert {:error, _} = RateLimiter.hit(bucket, :a, 1, 60_000, now_ms: now)
    assert :ok = RateLimiter.hit(bucket, :a, 1, 60_000, now_ms: now + 60_000)
  end

  test "a limit of zero refuses the first hit" do
    assert {:error, _} = RateLimiter.hit(bucket(), :a, 0, 60_000)
  end

  test "the sweep drops windows that have ended and keeps the current one" do
    bucket = bucket()
    now = System.system_time(:millisecond)

    assert :ok = RateLimiter.hit(bucket, :a, 1, 60_000, now_ms: now)

    RateLimiter.sweep(now)
    assert {:error, _} = RateLimiter.hit(bucket, :a, 1, 60_000, now_ms: now)

    RateLimiter.sweep(now + 60_001)
    assert :ok = RateLimiter.hit(bucket, :a, 1, 60_000, now_ms: now)
  end

  describe "limit/1" do
    test "every bucket the portal uses has a default" do
      for bucket <- [:auth, :provider_auth, :scan_request, :hex_search, :hex_search_global] do
        assert {limit, window_ms} = RateLimiter.limit(bucket)
        assert is_integer(limit) and limit > 0
        assert is_integer(window_ms) and window_ms > 0
      end
    end

    test "an unknown bucket raises rather than going unlimited" do
      assert_raise KeyError, fn -> RateLimiter.limit(:no_such_bucket) end
    end
  end
end
