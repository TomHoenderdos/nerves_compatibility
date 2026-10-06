defmodule Portal.Test.FakeHexLookup do
  @moduledoc """
  Stands in for `Portal.HexPm.package_exists?/1`. Controller tests run in the
  test process, so a test scripts the answer for a name with
  `Process.put({:fake_hex_package, name}, answer)`. Unscripted names exist,
  which keeps every test that is not about the check unaware of it.
  """

  def package_exists?(name), do: Process.get({:fake_hex_package, name}, {:ok, true})
end
