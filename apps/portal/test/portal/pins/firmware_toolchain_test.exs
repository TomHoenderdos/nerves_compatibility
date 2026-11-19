defmodule Portal.Pins.FirmwareToolchainTest do
  # Review I1: every firmware pinned build is keyed on
  # `Portal.Pins.firmware_toolchain/0`, and ingest refuses a result built on
  # another one. Its default must be what the worker image installs, or every
  # build after an image bump is wasted.
  use ExUnit.Case, async: true

  @dockerfile Path.expand("../../../../ncc_worker/Dockerfile", __DIR__)

  test "the default firmware toolchain is the Elixir and OTP the worker image installs" do
    [_, major, minor, otp] =
      Regex.run(
        ~r{repo\.hex\.pm/builds/elixir/v(\d+)\.(\d+)\.\d+-otp-(\d+)\.zip},
        File.read!(@dockerfile)
      )

    assert Application.get_env(:portal, Portal.Pins) == nil
    assert Portal.Pins.firmware_toolchain() == "#{major}.#{minor}/#{otp}"
  end
end
