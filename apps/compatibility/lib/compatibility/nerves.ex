defmodule Compatibility.Nerves do
  @moduledoc """
  The Nerves release every firmware build is made on: the worker pins its
  project's `:nerves` dependency to it (`NccWorker.Project`), and the portal
  builds a system release only when that release's own `nerves`
  requirement accepts it (`Portal.Pins`, `Portal.SystemFollowUp`). One
  place, so the two never drift.

  `mix nerves.new --prerelease` writes a floating `~> 2.0.0-pre.N`
  requirement, which would let Hex move the Nerves version under an
  unchanged worker image, and the portal deduplicates runs on that image.
  Pinned exactly, so a new Nerves prerelease only arrives with a new image.
  """

  @firmware_version "2.0.0-pre.3"

  @doc "The Nerves version every firmware build is made on."
  @spec firmware_version() :: String.t()
  def firmware_version, do: @firmware_version

  @doc """
  Whether a system release whose `nerves` dependency has `requirement`
  can be built on `firmware_version/0`: a Nerves 2 release declares
  `~> 1.11 or ~> 2.0 or ~> 2.0.0-dev`, a Nerves 1 era one `~> 1.11`. A
  requirement that does not parse, or none, is not.
  """
  @spec buildable?(term()) :: boolean()
  def buildable?(requirement) when is_binary(requirement) do
    case Version.parse_requirement(requirement) do
      {:ok, parsed} -> Version.match?(@firmware_version, parsed)
      :error -> false
    end
  end

  def buildable?(_requirement), do: false
end
