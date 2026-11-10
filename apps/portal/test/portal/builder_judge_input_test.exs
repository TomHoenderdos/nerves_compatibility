defmodule Portal.BuilderJudgeInputTest do
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
    package: %{"name" => "jason", "version" => "1.4.4", "source" => "hex"},
    systems_filter: nil,
    mode: "toolchain"
  }

  test "off by default: no judge options for any build", %{previous: previous} do
    Application.put_env(:portal, Builder, Keyword.delete(previous, :judge_makefile_rule2))

    for mode <- ["toolchain", nil, "argus_only", "warm_nerves"],
        do: assert(Builder.judge_input(mode) == nil, inspect(mode))
  end

  test "on: toolchain builds only", %{previous: previous} do
    Application.put_env(:portal, Builder, Keyword.put(previous, :judge_makefile_rule2, true))
    assert Builder.judge_input("toolchain") == %{"makefile_rule2" => true}

    for mode <- [nil, "argus_only", "warm_nerves"],
        do: assert(Builder.judge_input(mode) == nil, inspect(mode))
  end

  test "worker_input carries judge only when set" do
    input = Builder.worker_input(Map.put(@job, :judge, %{"makefile_rule2" => true}))
    assert input["judge"] == %{"makefile_rule2" => true}
    refute Map.has_key?(Builder.worker_input(@job), "judge")
  end
end
