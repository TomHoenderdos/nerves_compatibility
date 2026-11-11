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

  # `{#{inspect(__MODULE__)}, :releases}` holds `%{name => [release]}` for a
  # test that needs a package's declared dependencies; any other name is one
  # the registry does not list.
  # A caller may ask from a task it started (`Portal.Catalog.VersionBackfill`
  # asks several at once), so the test process's dictionary is read through
  # `$callers` when the asking process has no answers of its own.
  def releases(name, _opts \\ []) do
    case lookup({__MODULE__, :releases}) do
      %{^name => releases} -> {:ok, releases}
      _ -> {:error, :not_found}
    end
  end

  defp lookup(key) do
    Enum.find_value([self() | Process.get(:"$callers", [])], fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} -> List.keyfind(dictionary, key, 0) |> value()
        nil -> nil
      end
    end)
  end

  defp value({_key, value}), do: value
  defp value(nil), do: nil

  def outer_checksum(_name, _version, _opts \\ []),
    do: Process.get({__MODULE__, :outer_checksum}, {:error, :hex_registry_unavailable})

  def tarball(_name, _version, _opts \\ []),
    do: Process.get({__MODULE__, :tarball}, {:error, :hex_registry_unavailable})
end
