defmodule Portal.Builders.WarmAllowlist do
  @moduledoc """
  The Nerves systems and toolchains a remote builder may warm into its
  shared Nerves cache after a build: the official ones the `nerves` Hex
  account publishes. A cache miss outside this list is never warmed, so a
  package cannot get an arbitrary artifact into the cache every later build
  reads.

  `Portal.Catalog.ToolingSkip` recognises the same families by prefix but
  exports no names, so the list is the tracked targets
  (`Portal.BulkRebuild.targets/0`) plus the toolchains they build with and
  the kiosk systems. `Portal.HexPm.owners/1` from the build-sandbox
  isolation branch replaces this hard-coded list with an ownership check
  once it lands.
  """

  @toolchains ~w(
    nerves_toolchain_aarch64_nerves_linux_gnu
    nerves_toolchain_armv6_nerves_linux_gnueabihf
    nerves_toolchain_armv7_nerves_linux_gnueabihf
    nerves_toolchain_riscv64_nerves_linux_gnu
    nerves_toolchain_x86_64_nerves_linux_musl
  )

  @kiosk_systems ~w(kiosk_system_rpi4 kiosk_system_rpi5 kiosk_system_x86_64)

  @doc "The allowlisted package names, sorted."
  @spec names() :: [String.t()]
  def names, do: Enum.sort(Portal.BulkRebuild.targets() ++ @toolchains ++ @kiosk_systems)
end
