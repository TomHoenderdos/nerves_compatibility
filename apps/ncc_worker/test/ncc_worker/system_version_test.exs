defmodule NccWorker.SystemVersionTest do
  use ExUnit.Case, async: true

  alias NccWorker.Worker

  setup do
    dir = Path.join(System.tmp_dir!(), "ncc-system-version-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir, log: Path.join(dir, "nerves_system_rpi4.log")}
  end

  @lock """
  %{
    "nerves": {:hex, :nerves, "2.0.0-pre.3", "i-nerves", [:mix], [], "hexpm", "o-nerves"},
    "nerves_system_rpi4": {:hex, :nerves_system_rpi4, "2.2.1", "i-rpi4", [:mix], [{:nerves, "~> 2.0-pre", [hex: :nerves, repo: "hexpm", optional: false]}], "hexpm", "o-rpi4"},
    "nerves_system_x86_64": {:hex, :nerves_system_x86_64, "1.35.1", "i-x86", [:mix], [], "hexpm", "o-x86"},
  }
  """

  # What a per-target `mix deps.get` writes with Hex 2.6.0, which stopped
  # listing unchanged dependencies after resolution: nothing names the
  # system's version any more.
  @hex_2_6_log """
  Resolving Hex dependencies...
  Resolution completed in 0.399s
  * Getting nerves (Hex package)
  * Getting nerves_system_rpi4 (Hex package)
  * Getting nerves_system_x86_64 (Hex package)
  """

  # The same output from Hex 2.5 and earlier.
  @hex_2_5_log """
  Resolving Hex dependencies...
  Resolution completed in 0.116s
  Unchanged:
    nerves 2.0.0-pre.3
    nerves_system_rpi4 2.2.1
    nerves_system_x86_64 1.35.1
  * Getting nerves (Hex package)
  """

  test "reads the system's version from the project's mix.lock", %{dir: dir, log: log} do
    File.write!(Path.join(dir, "mix.lock"), @lock)
    File.write!(log, @hex_2_6_log)

    assert Worker.system_version(dir, log, "nerves_system_rpi4") == "2.2.1"
    assert Worker.system_version(dir, log, "nerves_system_x86_64") == "1.35.1"
  end

  test "keeps a prerelease version whole", %{dir: dir, log: log} do
    File.write!(
      Path.join(dir, "mix.lock"),
      String.replace(@lock, ~s("2.2.1"), ~s("2.3.0-rc.1"))
    )

    File.write!(log, @hex_2_6_log)

    assert Worker.system_version(dir, log, "nerves_system_rpi4") == "2.3.0-rc.1"
  end

  test "falls back to the deps.get listing when the lock does not name the system",
       %{dir: dir, log: log} do
    File.write!(log, @hex_2_5_log)

    assert Worker.system_version(dir, log, "nerves_system_rpi4") == "2.2.1"
  end

  test "is nil when neither the lock nor the log names the system", %{dir: dir, log: log} do
    File.write!(log, @hex_2_6_log)

    assert Worker.system_version(dir, log, "nerves_system_rpi4") == nil
    assert Worker.system_version(dir, Path.join(dir, "missing.log"), "nerves_system_bbb") == nil
  end
end
