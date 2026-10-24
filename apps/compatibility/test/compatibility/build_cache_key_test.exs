defmodule Compatibility.BuildCacheKeyTest do
  use ExUnit.Case, async: true

  alias Compatibility.BuildCacheKey

  @inputs %{
    elixir: "1.20.3",
    otp: "29",
    target: "rpi4",
    dep: "a",
    dep_lock: "1.0.0 aaa bbb",
    closure: [{"c", "3.0.0 ccc"}, {"b", "2.0.0 bbb"}]
  }

  test "hashes the documented line format" do
    text = "v2\nelixir=1.20.3\notp=29\ntarget=rpi4\ndep=a 1.0.0 aaa bbb\nb 2.0.0 bbb\nc 3.0.0 ccc"
    expected = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

    assert {:ok, ^expected} = BuildCacheKey.key(@inputs)
  end

  test "closure order does not matter" do
    assert BuildCacheKey.key(@inputs) ==
             BuildCacheKey.key(%{@inputs | closure: Enum.reverse(@inputs.closure)})
  end

  test "the dependency name is part of the key" do
    refute BuildCacheKey.key(@inputs) == BuildCacheKey.key(%{@inputs | dep: "z"})
  end

  # A newline in any field would let one field's text stand in for the next
  # line of the hashed document. The host recomputes keys from inputs a
  # container reported, so it must refuse rather than hash them.
  test "refuses a line break in any input" do
    for field <- [:elixir, :otp, :target, :dep, :dep_lock] do
      assert :error = BuildCacheKey.key(Map.put(@inputs, field, "x\ny"))
      assert :error = BuildCacheKey.key(Map.put(@inputs, field, "x\ry"))
    end

    assert :error = BuildCacheKey.key(%{@inputs | closure: [{"b\nc", "1"}]})
    assert :error = BuildCacheKey.key(%{@inputs | closure: [{"b", "1\n2"}]})
  end
end
