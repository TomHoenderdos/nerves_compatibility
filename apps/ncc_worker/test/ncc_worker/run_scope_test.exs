defmodule NccWorker.RunScopeTest do
  use ExUnit.Case, async: true

  alias NccWorker.RunScope

  describe "from_input/1" do
    test "a plain input is a full run" do
      assert RunScope.from_input(%{}) == :full
    end

    test "a systems filter makes it a targets run" do
      assert RunScope.from_input(%{systems_filter: ["nerves_system_rpi4"]}) == :targets
    end

    test "argus_only mode wins over a filter" do
      assert RunScope.from_input(%{mode: "argus_only", systems_filter: ["x"]}) == :argus_only
    end

    test "toolchain mode wins over a filter" do
      assert RunScope.from_input(%{mode: "toolchain"}) == :toolchain
      assert RunScope.from_input(%{mode: "toolchain", systems_filter: ["x"]}) == :toolchain
    end

    test "an unknown mode is a full run, not a crash" do
      assert RunScope.from_input(%{mode: "bogus"}) == :full
    end
  end

  describe "argus_config/2" do
    # An argus-only run exists to produce findings. The admin's default scope
    # "firmware" skips pure-Elixir packages, which would make the run empty.
    test "an argus-only run covers the package whatever the configured scope" do
      assert RunScope.argus_config(%{scope: "firmware", analyses: ["default"]}, :argus_only) ==
               %{scope: "all", analyses: ["default"]}
    end

    test "other runs keep the configured scope" do
      config = %{scope: "firmware"}
      assert RunScope.argus_config(config, :full) == config
      assert RunScope.argus_config(config, :targets) == config
    end

    test "argus switched off stays off" do
      assert RunScope.argus_config(nil, :argus_only) == nil
    end
  end

  test "to_string/1 is the result.json value" do
    assert Enum.map([:full, :targets, :argus_only, :toolchain], &RunScope.to_string/1) ==
             ["full", "targets", "argus_only", "toolchain"]
  end
end
