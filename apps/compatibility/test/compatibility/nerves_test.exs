defmodule Compatibility.NervesTest do
  use ExUnit.Case, async: true

  alias Compatibility.Nerves

  test "a Nerves 2 system release's requirement accepts the firmware Nerves" do
    assert Nerves.buildable?("~> 1.11 or ~> 2.0 or ~> 2.0.0-dev")
    assert Nerves.buildable?("~> 2.0.0-dev")
  end

  test "a Nerves 1 era requirement, a 2.0 final one, nonsense and none do not" do
    refute Nerves.buildable?("~> 1.11")
    refute Nerves.buildable?("~> 2.0")
    refute Nerves.buildable?("not a requirement")
    refute Nerves.buildable?(nil)
  end

  test "the firmware version is a prerelease of 2.0.0" do
    assert {:ok, %Version{major: 2, minor: 0, patch: 0, pre: [_ | _]}} =
             Version.parse(Nerves.firmware_version())
  end
end
