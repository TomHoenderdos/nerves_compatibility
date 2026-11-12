defmodule PortalWeb.MemoryFormat do
  @moduledoc """
  Container memory as people read it, for the admin Memory tab and the
  package page: `1.4 GiB` from 1 GiB up (`3 GiB` when whole), `650 MiB`
  under it, `—` when there is no figure.
  """

  @gib 1024 * 1024 * 1024
  @mib 1024 * 1024

  @spec size(non_neg_integer() | nil) :: String.t()
  def size(nil), do: "—"

  def size(bytes) when is_integer(bytes) and bytes >= @gib do
    case Float.round(bytes / @gib, 1) do
      whole when whole == trunc(whole) -> "#{trunc(whole)} GiB"
      gib -> "#{gib} GiB"
    end
  end

  def size(bytes) when is_integer(bytes), do: "#{round(bytes / @mib)} MiB"

  @doc """
  The package page line for `Portal.Catalog.RunMemoryStats.latest_for_package/1`'s
  rows, or nil when neither says anything.
  """
  @spec package_line(map() | nil) :: String.t() | nil
  def package_line(nil), do: nil

  def package_line(%{firmware: firmware, toolchain: toolchain}) do
    case {phrase(firmware), phrase(toolchain)} do
      {nil, nil} -> nil
      {fw, nil} -> "Memory: last firmware build #{fw}"
      {nil, tc} -> "Memory: last toolchain build #{tc}"
      {fw, tc} -> "Memory: last firmware build #{fw}, toolchain #{strip(tc)}"
    end
  end

  defp phrase(nil), do: nil

  defp phrase(%{oom_killed: true, memory_limit_bytes: limit}) when is_integer(limit),
    do: "was OOM-killed at #{size(limit)}"

  defp phrase(%{peak_used_bytes: peak, memory_limit_bytes: limit}) when is_integer(peak),
    do: "peaked at #{size(peak)} of #{size(limit)}"

  defp phrase(_row), do: nil

  # "toolchain 650 MiB of 2 GiB" after a firmware part, not "toolchain peaked at ...".
  defp strip("peaked at " <> rest), do: rest
  defp strip(other), do: other
end
