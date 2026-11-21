defmodule Portal.BuilderJudgeInputTest do
  # Not async: swaps the `Portal.Builder` application env. A data case: the
  # judge options read the `foreign_priv_enabled` setting.
  use Portal.DataCase, async: false

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
    Application.put_env(
      :portal,
      Builder,
      Keyword.drop(previous, [:judge_makefile_rule2, :judge_native_side])
    )

    for mode <- ["toolchain", nil, "argus_only", "warm_nerves"],
        do: assert(Builder.judge_input(mode) == nil, inspect(mode))
  end

  test "on: toolchain builds only", %{previous: previous} do
    Application.put_env(:portal, Builder, Keyword.put(previous, :judge_makefile_rule2, true))
    assert Builder.judge_input("toolchain") == %{"makefile_rule2" => true}

    for mode <- [nil, "argus_only", "warm_nerves"],
        do: assert(Builder.judge_input(mode) == nil, inspect(mode))
  end

  # Foreign priv spec 3.1, gate 1: the flag goes to toolchain builds (pinned
  # toolchain builds are `mode: "toolchain"` too) while the setting is on,
  # never from a host env var.
  test "foreign_priv: toolchain builds only, and only with the setting on", %{previous: previous} do
    Application.put_env(:portal, Builder, Keyword.delete(previous, :judge_makefile_rule2))
    {:ok, _} = Portal.Settings.save(%{foreign_priv_enabled: false})
    assert Builder.judge_input("toolchain") == nil

    {:ok, _} = Portal.Settings.save(%{foreign_priv_enabled: true})
    assert Builder.judge_input("toolchain") == %{"foreign_priv" => true}

    for mode <- [nil, "argus_only", "warm_nerves", "host_native"],
        do: assert(Builder.judge_input(mode) == nil, inspect(mode))

    Application.put_env(:portal, Builder, Keyword.put(previous, :judge_makefile_rule2, true))

    assert Builder.judge_input("toolchain") == %{
             "foreign_priv" => true,
             "makefile_rule2" => true
           }
  end

  # S3 native side: `NCC_JUDGE_NATIVE_SIDE=1` (`:judge_native_side`) puts
  # the flag into toolchain builds only, next to the others.
  test "native_side: toolchain builds only, while the config says so", %{previous: previous} do
    base = Keyword.drop(previous, [:judge_makefile_rule2, :judge_native_side])
    Application.put_env(:portal, Builder, base)
    {:ok, _} = Portal.Settings.save(%{foreign_priv_enabled: false})
    assert Builder.judge_input("toolchain") == nil

    Application.put_env(:portal, Builder, Keyword.put(base, :judge_native_side, true))
    assert Builder.judge_input("toolchain") == %{"native_side" => true}

    for mode <- [nil, "argus_only", "warm_nerves", "host_native"],
        do: assert(Builder.judge_input(mode) == nil, inspect(mode))

    for value <- [false, nil, "1"] do
      Application.put_env(:portal, Builder, Keyword.put(base, :judge_native_side, value))
      assert Builder.judge_input("toolchain") == nil, inspect(value)
    end

    Application.put_env(
      :portal,
      Builder,
      base |> Keyword.put(:judge_native_side, true) |> Keyword.put(:judge_makefile_rule2, true)
    )

    assert Builder.judge_input("toolchain") == %{"makefile_rule2" => true, "native_side" => true}
  end

  test "worker_input carries judge only when set" do
    input = Builder.worker_input(Map.put(@job, :judge, %{"makefile_rule2" => true}))
    assert input["judge"] == %{"makefile_rule2" => true}
    refute Map.has_key?(Builder.worker_input(@job), "judge")
  end
end
