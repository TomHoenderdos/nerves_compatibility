defmodule Portal.BuilderFirmwareJudgeTest do
  # Not async: swaps the `Portal.Builder` application env.
  use ExUnit.Case, async: false

  alias Portal.Builder

  setup do
    previous = Application.get_env(:portal, Builder, [])
    on_exit(fn -> Application.put_env(:portal, Builder, previous) end)
    %{previous: previous}
  end

  @job %{
    run_id: "r1",
    image_name: "ncc-worker",
    image_digest: "sha256:x",
    package: %{"name" => "yamerl", "version" => "0.10.0", "source" => "hex"},
    systems_filter: nil,
    mode: nil
  }

  test "on by default: no firmware_judge key, which the worker reads as on",
       %{previous: previous} do
    Application.put_env(:portal, Builder, Keyword.delete(previous, :firmware_judge))

    for mode <- [nil, "toolchain", "argus_only", "warm_nerves"],
        do: assert(Builder.firmware_judge_input(mode) == nil, inspect(mode))

    refute Map.has_key?(Builder.worker_input(@job), "firmware_judge")
  end

  test "NCC_FIRMWARE_JUDGE=0: a firmware build's input says false", %{previous: previous} do
    Application.put_env(:portal, Builder, Keyword.put(previous, :firmware_judge, false))
    assert Builder.firmware_judge_input(nil) == false

    for mode <- ["toolchain", "argus_only", "warm_nerves"],
        do: assert(Builder.firmware_judge_input(mode) == nil, inspect(mode))

    input =
      Builder.worker_input(Map.put(@job, :firmware_judge, Builder.firmware_judge_input(nil)))

    assert input["firmware_judge"] == false
  end
end
