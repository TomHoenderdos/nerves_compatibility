defmodule Compatibility.ElfSourceHashTest do
  use ExUnit.Case, async: true

  # The precompiled client carries a verbatim copy of this reader under its
  # own module name, and the same test with the same constant. Changing the
  # reader means changing both.
  @hash "595c45615d5ef194f4887184cc197910e90d7fb53d636eeb1c5037526bd5e140"

  @source Path.expand("../../lib/compatibility/elf.ex", __DIR__)

  test "the reader's source matches the client's copy" do
    lines = @source |> File.read!() |> String.split("\n")
    [defmodule_line | body] = Enum.drop_while(lines, &String.starts_with?(&1, "#"))
    assert String.starts_with?(defmodule_line, "defmodule ")

    normalised = body |> Enum.join("\n") |> String.replace("Compatibility.Elf", "ELF")
    assert :crypto.hash(:sha256, normalised) |> Base.encode16(case: :lower) == @hash
  end
end
