defmodule Site.Architecture do
  @moduledoc """
  Maps Nerves system package names (`nerves_system_rpi4`, `nerves_system_mangopi_mq_pro`,
  ...) to user-facing CPU-architecture labels (`arm64`, `riscv64`, ...).

  Reasoning: Nerves system names are a project-internal detail. Most readers
  of this site want to know whether the package works on their target's CPU
  architecture, not which specific Nerves system happened to be picked to
  represent that arch in the test matrix. The Nerves system name stays
  available as a tooltip on the rendered chips.

  Currently each architecture is represented by exactly one tested Nerves
  system, so labels collide cleanly. If the matrix ever tests two systems
  for the same arch, the displayed labels will collide too — that's
  arguably what we want, but tooltips still differentiate.
  """

  # Known mappings. Anything outside this set falls through to the
  # nerves_system_-stripped name (e.g., `nerves_system_grisp2` → `grisp2`)
  # so we degrade gracefully when new systems get added.
  @system_to_arch %{
    "nerves_system_rpi" => "arm32",
    "nerves_system_rpi0" => "arm32",
    "nerves_system_rpi0_2" => "arm64",
    "nerves_system_rpi2" => "arm32",
    "nerves_system_rpi3" => "arm32",
    "nerves_system_rpi3a" => "arm32",
    "nerves_system_rpi4" => "arm64",
    "nerves_system_rpi5" => "arm64",
    "nerves_system_qemu_aarch64" => "arm64",
    "nerves_system_mangopi_mq_pro" => "riscv64",
    "nerves_system_grisp2" => "arm32",
    "nerves_system_x86_64" => "x86_64",
    "nerves_system_bbb" => "arm32",
    "nerves_system_osd32mp1" => "arm32",
    "host" => "host"
  }

  @doc """
  Display label for a system. Returns the architecture name when known,
  otherwise the system name with the `nerves_system_` prefix stripped.
  """
  @spec label(String.t() | atom() | nil) :: String.t()
  def label(nil), do: ""

  def label(system) when is_atom(system), do: label(Atom.to_string(system))

  def label(system) when is_binary(system) do
    case Map.fetch(@system_to_arch, system) do
      {:ok, arch} ->
        arch

      :error ->
        cond do
          String.starts_with?(system, "forced") -> "forced"
          true -> String.replace_prefix(system, "nerves_system_", "")
        end
    end
  end
end
