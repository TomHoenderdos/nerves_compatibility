defmodule PortalWeb.MemoryFormatTest do
  use ExUnit.Case, async: true

  alias Portal.Catalog.RunMemory
  alias PortalWeb.MemoryFormat

  @gib 1024 * 1024 * 1024
  @mib 1024 * 1024

  test "size/1: GiB with one decimal from 1 GiB, MiB under it, a dash for nil" do
    assert MemoryFormat.size(round(1.4 * @gib)) == "1.4 GiB"
    assert MemoryFormat.size(3 * @gib) == "3 GiB"
    assert MemoryFormat.size(@gib) == "1 GiB"
    assert MemoryFormat.size(650 * @mib) == "650 MiB"
    assert MemoryFormat.size(0) == "0 MiB"
    assert MemoryFormat.size(nil) == "—"
  end

  test "package_line/1" do
    fw = %RunMemory{peak_used_bytes: round(2.9 * @gib), memory_limit_bytes: 3 * @gib}
    tc = %RunMemory{peak_used_bytes: 650 * @mib, memory_limit_bytes: 2 * @gib}

    assert MemoryFormat.package_line(nil) == nil

    assert MemoryFormat.package_line(%{firmware: fw, toolchain: tc}) ==
             "Memory: last firmware build peaked at 2.9 GiB of 3 GiB, toolchain 650 MiB of 2 GiB"

    assert MemoryFormat.package_line(%{firmware: nil, toolchain: tc}) ==
             "Memory: last toolchain build peaked at 650 MiB of 2 GiB"

    oom = %RunMemory{oom_killed: true, peak_used_bytes: nil, memory_limit_bytes: 3 * @gib}

    assert MemoryFormat.package_line(%{firmware: oom, toolchain: nil}) ==
             "Memory: last firmware build was OOM-killed at 3 GiB"

    # No side file and not killed: nothing worth a line.
    assert MemoryFormat.package_line(%{firmware: %RunMemory{}, toolchain: nil}) == nil
  end
end
