defmodule Portal.Builders.RateLimitTest do
  use ExUnit.Case, async: false
  alias Portal.Builders.RateLimit

  test "allows limit calls per window, then refuses, then resets" do
    key = {:test, System.unique_integer()}
    now = System.system_time(:millisecond)
    assert Enum.all?(1..3, fn _ -> RateLimit.allow?(key, 3, 60_000, now_ms: now) end)
    refute RateLimit.allow?(key, 3, 60_000, now_ms: now)
    assert RateLimit.allow?(key, 3, 60_000, now_ms: now + 60_000)
  end

  test "keys are counted separately" do
    a = {:test, System.unique_integer()}
    b = {:test, System.unique_integer()}
    assert RateLimit.allow?(a, 1, 60_000)
    refute RateLimit.allow?(a, 1, 60_000)
    assert RateLimit.allow?(b, 1, 60_000)
  end
end
