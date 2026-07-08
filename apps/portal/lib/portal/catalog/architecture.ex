defmodule Portal.Catalog.Architecture do
  @moduledoc "Maps Nerves system package names to CPU-architecture labels."

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

  @spec label(String.t() | atom() | nil) :: String.t()
  def label(nil), do: ""
  def label(system) when is_atom(system), do: label(Atom.to_string(system))

  def label(system) when is_binary(system) do
    case Map.fetch(@system_to_arch, system) do
      {:ok, arch} ->
        arch

      :error ->
        if String.starts_with?(system, "forced"),
          do: "forced",
          else: String.replace_prefix(system, "nerves_system_", "")
    end
  end
end
