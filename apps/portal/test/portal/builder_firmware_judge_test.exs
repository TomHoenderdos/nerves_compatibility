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

  # The judge ships off (review S7): a node turns it on with
  # NCC_FIRMWARE_JUDGE=1, so its verdict rate and cost are measured on one
  # node before the fleet. An input without the key is off in the worker.
  test "off by default: no firmware_judge key", %{previous: previous} do
    Application.put_env(
      :portal,
      Builder,
      previous |> Keyword.delete(:firmware_judge) |> Keyword.delete(:firmware_judge_budget_sec)
    )

    for mode <- [nil, "toolchain", "argus_only", "warm_nerves"] do
      assert Builder.firmware_judge_input(mode) == nil, inspect(mode)
      assert Builder.firmware_judge_budget_input(mode) == nil, inspect(mode)
    end

    input = Builder.worker_input(@job)
    refute Map.has_key?(input, "firmware_judge")
    refute Map.has_key?(input, "firmware_judge_budget_sec")
  end

  test "NCC_FIRMWARE_JUDGE=1: a firmware build's input turns it on, with the node's budget",
       %{previous: previous} do
    Application.put_env(
      :portal,
      Builder,
      Keyword.merge(previous, firmware_judge: true, firmware_judge_budget_sec: 900)
    )

    assert Builder.firmware_judge_input(nil) == true
    assert Builder.firmware_judge_budget_input(nil) == 900

    for mode <- ["toolchain", "argus_only", "warm_nerves"] do
      assert Builder.firmware_judge_input(mode) == nil, inspect(mode)
      assert Builder.firmware_judge_budget_input(mode) == nil, inspect(mode)
    end

    input =
      @job
      |> Map.put(:firmware_judge, Builder.firmware_judge_input(nil))
      |> Map.put(:firmware_judge_budget_sec, Builder.firmware_judge_budget_input(nil))
      |> Builder.worker_input()

    assert input["firmware_judge"] == true
    assert input["firmware_judge_budget_sec"] == 900
  end

  test "on without a budget sends no budget, which the worker reads as its default",
       %{previous: previous} do
    Application.put_env(
      :portal,
      Builder,
      previous |> Keyword.put(:firmware_judge, true) |> Keyword.delete(:firmware_judge_budget_sec)
    )

    assert Builder.firmware_judge_input(nil) == true
    assert Builder.firmware_judge_budget_input(nil) == nil
  end
end
