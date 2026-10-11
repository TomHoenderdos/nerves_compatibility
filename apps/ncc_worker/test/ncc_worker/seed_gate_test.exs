defmodule NccWorker.SeedGateTest do
  use ExUnit.Case, async: true

  alias NccWorker.SeedGate

  describe "gate?/1" do
    test "a package that compiles on the host builds every target as before" do
      refute SeedGate.gate?(%{status: :pass})
    end

    # Most host failures fail on every target too, and those runs were a fifth
    # of all target CPU. One target decides whether the rest are worth building.
    test "a host failure gates the remaining targets on one seed target" do
      assert SeedGate.gate?(%{status: :fail})
      assert SeedGate.gate?(%{status: :error})
    end

    test "no host result means no gate" do
      refute SeedGate.gate?(nil)
    end
  end

  describe "split/1" do
    defp system(name), do: %{name: name, target: String.replace(name, "nerves_system_", "")}

    # Picked from prod: of the packages that fail on the host but pass some
    # target, rpi4 fails the fewest (4 of 46). bbb, first in result order,
    # would have wrongly skipped 9.
    test "seeds on rpi4 when it is among the systems" do
      systems = Enum.map(~w(nerves_system_bbb nerves_system_rpi4 nerves_system_x86_64), &system/1)

      assert {%{name: "nerves_system_rpi4"}, rest} = SeedGate.split(systems)
      assert Enum.map(rest, & &1.name) == ~w(nerves_system_bbb nerves_system_x86_64)
    end

    test "falls back to the first system without rpi4" do
      systems = Enum.map(~w(nerves_system_bbb nerves_system_x86_64), &system/1)

      assert {%{name: "nerves_system_bbb"}, [%{name: "nerves_system_x86_64"}]} =
               SeedGate.split(systems)
    end
  end

  describe "skip_rest?/1" do
    # Nerves-only packages (nerves_network, kiosk_system_*) cannot compile on the
    # host but build firmware fine: the seed passing is what keeps them whole.
    test "a passing seed builds the remaining targets" do
      refute SeedGate.skip_rest?(%{status: :pass})
    end

    test "a failing seed skips the remaining targets" do
      assert SeedGate.skip_rest?(%{status: :fail})
    end
  end

  describe "skipped_result/1" do
    test "says which builds failed, so a skip is not read as a failure" do
      result = SeedGate.skipped_result("nerves_system_bbb")

      assert result.status == :skipped
      assert result.error == "host and nerves_system_bbb failed to compile"
      assert result.log_tail =~ "host and nerves_system_bbb failed to compile"
      assert result.duration_sec == 0.0
      assert result.firmware_size_bytes == nil
    end
  end
end
