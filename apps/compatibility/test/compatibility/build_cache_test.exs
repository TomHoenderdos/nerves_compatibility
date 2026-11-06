defmodule Compatibility.BuildCacheTest do
  use ExUnit.Case, async: true

  alias Compatibility.BuildCache

  @hex String.duplicate("ab", 32)
  @slug "sha256_" <> String.duplicate("cd", 32)

  test "shareable_slug? takes a full, non-zero sha256 digest only" do
    assert BuildCache.shareable_slug?(@slug)
    refute BuildCache.shareable_slug?("sha256_" <> String.duplicate("0", 64))
    refute BuildCache.shareable_slug?("sha256_abc")
    refute BuildCache.shareable_slug?("unknown")
    refute BuildCache.shareable_slug?(@slug <> "\n")
    refute BuildCache.shareable_slug?(nil)
  end

  test "key? and sha256? take 64 lowercase hex only" do
    assert BuildCache.key?(@hex)
    assert BuildCache.sha256?(@hex)

    for bad <- [String.upcase(@hex), "../" <> @hex, @hex <> "/x", "", nil, 1, @hex <> "\n"] do
      refute BuildCache.key?(bad), inspect(bad)
      refute BuildCache.sha256?(bad), inspect(bad)
    end
  end

  test "object_hex takes back exactly what object_key wrote" do
    prefix = @slug <> "/"
    assert BuildCache.object_hex(BuildCache.object_key(@slug, @hex), prefix) == @hex

    for bad <- [
          prefix <> @hex <> ".tar.gz.x",
          prefix <> "../" <> @hex <> ".tar.gz",
          prefix <> "x/" <> @hex <> ".tar.gz",
          "other/" <> @hex <> ".tar.gz",
          prefix <> String.upcase(@hex) <> ".tar.gz",
          nil
        ] do
      assert BuildCache.object_hex(bad, prefix) == nil, inspect(bad)
    end
  end
end
