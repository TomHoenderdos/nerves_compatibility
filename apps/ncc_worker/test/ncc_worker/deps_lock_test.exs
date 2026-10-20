defmodule NccWorker.DepsLockTest do
  use ExUnit.Case, async: true

  alias NccWorker.DepsLock

  setup do
    dir = Path.join(System.tmp_dir!(), "ncc-deps-lock-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  # The shape of a generated Nerves project's lock after `mix deps.get`: the
  # package under test (`ash_thing`) sits beside nerves, a system, a toolchain
  # and the template's own dependencies, none of which it depends on.
  # `ash_thing` reaches `sourceror` only through `spark`, `jason` and `decimal`
  # point at each other, and `spark`'s optional `igniter` was never resolved.
  @lock """
  %{
    "ash_thing": {:hex, :ash_thing, "0.3.0", "i-ash", [:mix], [{:spark, "~> 2.0", [hex: :spark, repo: "hexpm", optional: false]}, {:jason, "~> 1.0", [hex: :jason, repo: "hexpm", optional: false]}], "hexpm", "o-ash"},
    "spark": {:hex, :spark, "2.7.8", "i-spark", [:mix], [{:sourceror, "~> 1.0", [hex: :sourceror, repo: "hexpm", optional: false]}, {:igniter, "~> 0.5", [hex: :igniter, repo: "hexpm", optional: true]}], "hexpm", "o-spark"},
    "sourceror": {:hex, :sourceror, "1.10.0", "i-sourceror", [:mix], [], "hexpm", "o-sourceror"},
    "jason": {:hex, :jason, "1.4.4", "i-jason", [:mix], [{:decimal, "~> 1.0 or ~> 2.0", [hex: :decimal, repo: "hexpm", optional: true]}], "hexpm", "o-jason"},
    "decimal": {:hex, :decimal, "2.3.0", "i-decimal", [:mix], [{:jason, "~> 1.0", [hex: :jason, repo: "hexpm", optional: true]}], "hexpm", "o-decimal"},
    "nerves": {:hex, :nerves, "1.11.3", "i-nerves", [:mix], [{:castore, "~> 1.0", [hex: :castore, repo: "hexpm", optional: false]}], "hexpm", "o-nerves"},
    "castore": {:hex, :castore, "1.0.15", "i-castore", [:mix], [], "hexpm", "o-castore"},
    "nerves_system_rpi4": {:hex, :nerves_system_rpi4, "1.31.0", "i-rpi4", [:mix], [{:nerves, "~> 1.11", [hex: :nerves, repo: "hexpm", optional: false]}, {:nerves_toolchain_aarch64_nerves_linux_gnu, "~> 13.2.0", [hex: :nerves_toolchain_aarch64_nerves_linux_gnu, repo: "hexpm", optional: false]}], "hexpm", "o-rpi4"},
    "nerves_toolchain_aarch64_nerves_linux_gnu": {:hex, :nerves_toolchain_aarch64_nerves_linux_gnu, "13.2.0", "i-tc", [:mix], [], "hexpm", "o-tc"},
    "shoehorn": {:hex, :shoehorn, "0.9.2", "i-shoehorn", [:mix], [], "hexpm", "o-shoehorn"},
  }
  """

  test "records the package's whole transitive closure with version and outer checksum",
       %{dir: dir} do
    File.write!(Path.join(dir, "mix.lock"), @lock)

    assert DepsLock.read(dir, "ash_thing") == %{
             "spark" => %{"version" => "2.7.8", "checksum" => "o-spark"},
             "sourceror" => %{"version" => "1.10.0", "checksum" => "o-sourceror"},
             "jason" => %{"version" => "1.4.4", "checksum" => "o-jason"},
             "decimal" => %{"version" => "2.3.0", "checksum" => "o-decimal"}
           }
  end

  test "a package with no dependencies records an empty lock, not none", %{dir: dir} do
    File.write!(Path.join(dir, "mix.lock"), @lock)

    assert DepsLock.read(dir, "sourceror") == %{}
  end

  # A dependency the package reaches back to through a cycle is still not part
  # of its own closure.
  test "never lists the package itself", %{dir: dir} do
    File.write!(Path.join(dir, "mix.lock"), @lock)

    assert DepsLock.read(dir, "jason") == %{
             "decimal" => %{"version" => "2.3.0", "checksum" => "o-decimal"}
           }
  end

  test "a missing or unreadable lock, or a package not in it, records nothing", %{dir: dir} do
    assert DepsLock.read(dir, "ash_thing") == nil

    File.write!(Path.join(dir, "mix.lock"), "%{not valid elixir")
    assert DepsLock.read(dir, "ash_thing") == nil

    File.write!(Path.join(dir, "mix.lock"), @lock)
    assert DepsLock.read(dir, "not_there") == nil
  end

  # Without an outer checksum the entry cannot be matched against a client's
  # lock, and publishing the closure minus that dependency would let a client
  # match a build it should not.
  test "a closure member without an outer checksum records nothing", %{dir: dir} do
    File.write!(Path.join(dir, "mix.lock"), """
    %{
      "pkg": {:hex, :pkg, "1.0.0", "i-pkg", [:mix], [{:old, "~> 1.0", [hex: :old, repo: "hexpm", optional: false]}], "hexpm", "o-pkg"},
      "old": {:hex, :old, "1.0.0", "i-old", [:mix], [], "hexpm"},
    }
    """)

    assert DepsLock.read(dir, "pkg") == nil
  end
end
