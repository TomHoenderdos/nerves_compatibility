defmodule NccAgent.VersionTest do
  use ExUnit.Case, async: true
  alias NccAgent.Version

  test "compares the leading integer and never updates a dev build" do
    assert Version.newer?("1761400001.abc", "1761400000.def")
    refute Version.newer?("1761400000.abc", "1761400000.def")
    refute Version.newer?("1761400001.abc", "0.dev")
    refute Version.newer?(nil, "1761400000.def")
    refute Version.newer?("garbage", "1.a")
  end

  test "current is a string" do
    assert is_binary(Version.current())
  end
end
