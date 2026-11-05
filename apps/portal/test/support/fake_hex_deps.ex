defmodule Portal.Test.FakeHexDeps do
  @moduledoc """
  Stands in for `Portal.HexDeps.releases/2` where the code under test reads it
  through `config :portal, :hex_deps` (`Portal.Catalog.Coverage`'s default).
  Every package is one `repo.hex.pm` does not list, so nothing in a test asks
  the network; a test about the answers passes its own `:hex_releases`.

  `outer_checksum/3` and `tarball/3` stand in for the host's priv check at
  ingest (`Portal.Catalog.ToolchainPriv`). They answer what the test process
  put under `{#{inspect(__MODULE__)}, :outer_checksum}` and
  `{#{inspect(__MODULE__)}, :tarball}` in its process dictionary, which the
  ingest job reads when it runs inline; Hex is unreachable otherwise.
  """

  def releases(_name, _opts \\ []), do: {:error, :not_found}

  def outer_checksum(_name, _version, _opts \\ []),
    do: Process.get({__MODULE__, :outer_checksum}, {:error, :hex_registry_unavailable})

  def tarball(_name, _version, _opts \\ []),
    do: Process.get({__MODULE__, :tarball}, {:error, :hex_registry_unavailable})
end
