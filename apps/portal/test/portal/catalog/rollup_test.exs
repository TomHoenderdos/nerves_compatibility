defmodule Portal.Catalog.RollupTest do
  use ExUnit.Case, async: true

  alias Portal.Catalog.{Architecture, Rollup}

  test "architecture label maps known systems and strips prefix otherwise" do
    assert Architecture.label("nerves_system_rpi4") == "arm64"
    assert Architecture.label("nerves_system_x86_64") == "x86_64"
    assert Architecture.label("host") == "host"
    assert Architecture.label("nerves_system_grisp2") == "arm32"
    assert Architecture.label("nerves_system_newthing") == "newthing"
    assert Architecture.label("forced@x") == "forced"
    assert Architecture.label(nil) == ""
  end

  test "overall_status rolls per-system statuses to a package bucket" do
    assert Rollup.overall_status(["pass", "pass"]) == :pass
    assert Rollup.overall_status(["pass", "fail"]) == :fail
    assert Rollup.overall_status(["pass", "error"]) == :fail
    assert Rollup.overall_status(["pass", "skipped"]) == :partial
    assert Rollup.overall_status(["skipped", "skipped"]) == :skipped
    assert Rollup.overall_status([]) == :unknown
    assert Rollup.overall_status([:pass, :fail]) == :fail
  end

  test "native_bucket classifies language / none / not scanned" do
    assert Rollup.native_bucket("rust", [], true) == "rust"
    assert Rollup.native_bucket(nil, ["c"], true) == "c"
    assert Rollup.native_bucket(nil, [], true) == "none"
    assert Rollup.native_bucket(nil, [], false) == "not scanned"
  end
end
