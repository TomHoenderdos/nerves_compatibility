defmodule NccWorker.SeedGate do
  @moduledoc """
  Whether a package that failed to compile on the host is worth building for
  every target.

  Most are not. In two weeks of prod runs, 688 packages failed on the host and
  on every target, about a fifth of all target CPU, against 45 that failed on
  the host and still built firmware. Those 45 are Nerves-only packages
  (nerves_network, kiosk_system_*) that need a target to compile at all.

  So after a host failure one target builds first, alone. If it passes, the
  rest build as usual. If it fails too, the rest are recorded as `skipped`, not
  `fail`: nothing was built for them, and the result says why.
  """

  @seed "nerves_system_rpi4"

  @doc "Whether the targets wait on a seed target, given the host result."
  @spec gate?(map() | nil) :: boolean()
  def gate?(%{status: :pass}), do: false
  def gate?(%{status: _}), do: true
  def gate?(_host_result), do: false

  @doc """
  The seed and the rest of `systems`. Any target can fail where another
  passes, so the seed is the one that fails least often on these packages:
  on prod, rpi4 failed 4 of the 46 that failed on the host but passed some
  target, against 9 for bbb, the first in result order.
  """
  @spec split([map(), ...]) :: {map(), [map()]}
  def split(systems) do
    case Enum.split_with(systems, &(&1.name == @seed)) do
      {[seed], rest} -> {seed, rest}
      {[], [seed | rest]} -> {seed, rest}
    end
  end

  @doc "Whether the remaining targets are skipped, given the seed's result."
  @spec skip_rest?(map()) :: boolean()
  def skip_rest?(%{status: :pass}), do: false
  def skip_rest?(_seed_result), do: true

  @doc "The result recorded for a target skipped after `seed` failed."
  @spec skipped_result(String.t()) :: map()
  def skipped_result(seed) do
    reason = "host and #{seed} failed to compile"

    %{
      status: :skipped,
      duration_sec: 0.0,
      firmware_size_bytes: nil,
      log_tail: "Not built: #{reason}, so this target was skipped.\n",
      system_version: nil,
      beam_scan: nil,
      dependency_scans: nil,
      error: reason
    }
  end
end
