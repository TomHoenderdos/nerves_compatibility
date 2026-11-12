defmodule Portal.Precompiled.SystemAbi do
  @moduledoc """
  How the releases of one Nerves system are grouped for precompiled target
  builds: by the series of the toolchain each release builds with.

  A release the portal has built on knows its toolchain version from the
  lock (`Compatibility.Elf.series_from_version/1`); one it only knows from
  the system's Hex metadata has a requirement instead, read here.
  """

  @doc """
  The `major.minor` series a toolchain requirement pins: `"~> 15.3.0"` is
  `"15.3"`. Any other shape (`"~> 15.3"`, `">= 15.3.0"`, an exact version,
  an `or`) does not pin one series and is `nil`, as is a non-string.
  """
  @spec series_from_requirement(term()) :: String.t() | nil
  def series_from_requirement(requirement) when is_binary(requirement) do
    case Regex.run(~r/^\s*~>\s*(\d+)\.(\d+)\.\d+\s*$/, requirement) do
      [_, major, minor] -> major <> "." <> minor
      nil -> nil
    end
  end

  def series_from_requirement(_requirement), do: nil
end
