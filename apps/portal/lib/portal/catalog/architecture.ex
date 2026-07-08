defmodule Portal.Catalog.Architecture do
  @moduledoc """
  Maps Nerves system names to architecture labels.
  """

  @system_to_arch %{
    "nerves_system_bbb" => "arm32",
    "nerves_system_osd32mp1" => "arm32",
    "nerves_system_rpi0" => "arm32",
    "nerves_system_rpi2" => "arm32",
    "nerves_system_rpi3" => "arm32",
    "nerves_system_rpi3a" => "arm32",
    "nerves_system_grisp2" => "arm32",
    "nerves_system_rpi4" => "arm64",
    "nerves_system_rpi5" => "arm64",
    "nerves_system_qemu_aarch64" => "arm64",
    "nerves_system_mangopi_mq_pro" => "riscv64",
    "nerves_system_x86_64" => "x86_64",
    "host" => "host"
  }

  @doc """
  Maps a Nerves system name to its architecture label.

  If the system is in the known map, returns the mapped label.
  Otherwise, strips the "nerves_system_" prefix and returns the suffix,
  or the original string if the prefix is not present.
  Returns "" for nil input.
  """
  def label(nil), do: ""

  def label(system) when is_atom(system) do
    label(Atom.to_string(system))
  end

  def label(system) when is_binary(system) do
    case Map.get(@system_to_arch, system) do
      arch when is_binary(arch) ->
        arch

      nil ->
        case String.split(system, "nerves_system_") do
          [_prefix, suffix] -> suffix
          [_] -> String.split(system, "@") |> hd()
        end
    end
  end
end
