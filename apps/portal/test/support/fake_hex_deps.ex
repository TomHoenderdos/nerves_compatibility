defmodule Portal.Test.FakeHexDeps do
  @moduledoc """
  Stands in for `Portal.HexDeps.releases/2` where the code under test reads it
  through `config :portal, :hex_deps` (`Portal.Catalog.Coverage`'s default).
  Every package is one `repo.hex.pm` does not list, so nothing in a test asks
  the network; a test about the answers passes its own `:hex_releases`.
  """

  def releases(_name, _opts \\ []), do: {:error, :not_found}
end
