defmodule NccWorker.RunScope do
  @moduledoc """
  What a run rebuilds: every target (`:full`), the targets in
  `systems_filter` (`:targets`), nothing but the host compile and argus
  (`:argus_only`), or one host build in a plain, non-Nerves project on a
  toolchain image, judged for portability (`:toolchain`).

  The scope travels into `result.json` because ingestion has to know what a
  run left out: a partial run's missing systems are copied from the package's
  previous run (`Portal.Catalog.Ingestion`), where a full run's missing
  systems simply were not built.
  """

  @type t :: :full | :targets | :argus_only | :toolchain

  @spec from_input(map()) :: t()
  def from_input(%{mode: "argus_only"}), do: :argus_only
  def from_input(%{mode: "toolchain"}), do: :toolchain
  def from_input(%{systems_filter: [_ | _]}), do: :targets
  def from_input(_input), do: :full

  @doc """
  The argus config for a run of `scope`. An argus-only run exists to produce
  findings, so it covers the package even when the configured scope
  (`"firmware"`) would skip a pure-Elixir one.
  """
  @spec argus_config(map() | nil, t()) :: map() | nil
  def argus_config(nil, _scope), do: nil
  def argus_config(config, :argus_only), do: Map.put(config, :scope, "all")
  def argus_config(config, _scope), do: config

  @spec to_string(t()) :: String.t()
  def to_string(scope), do: Atom.to_string(scope)
end
