defmodule NccWorker.ScannerTest do
  use ExUnit.Case, async: true

  alias NccWorker.Scanner

  setup do
    tmp = Path.join(System.tmp_dir!(), "scanner_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, build_path: tmp}
  end

  describe "find_firmware/1" do
    test "locates a .fw file at <build_path>/nerves/images/", %{build_path: build_path} do
      images = Path.join([build_path, "nerves", "images"])
      File.mkdir_p!(images)
      fw_path = Path.join(images, "project.fw")
      File.write!(fw_path, "fake firmware content")

      assert %{size: size, path: ^fw_path} = Scanner.find_firmware(build_path)
      assert size == byte_size("fake firmware content")
    end

    test "returns an empty map when the images dir doesn't exist", %{build_path: build_path} do
      assert Scanner.find_firmware(build_path) == %{}
    end

    test "returns an empty map when the dir exists but has no .fw file", %{build_path: build_path} do
      images = Path.join([build_path, "nerves", "images"])
      File.mkdir_p!(images)
      File.write!(Path.join(images, "not_firmware.txt"), "x")

      assert Scanner.find_firmware(build_path) == %{}
    end

    # Regression guard: the worker sets MIX_BUILD_PATH=_build/<target>, so
    # Nerves does NOT nest images under a dev/ env subdir. If someone adds
    # dev/ back to the path, this test will catch it — the previous
    # firmware_size_bytes=nil-on-every-pass bug came from that mismatch.
    test "does NOT match the old buggy <build_path>/dev/nerves/images/ layout",
         %{build_path: build_path} do
      old_layout = Path.join([build_path, "dev", "nerves", "images"])
      File.mkdir_p!(old_layout)
      File.write!(Path.join(old_layout, "project.fw"), "x")

      assert Scanner.find_firmware(build_path) == %{}
    end
  end
end
