defmodule NccWorker.CLITest do
  use ExUnit.Case, async: false

  alias NccWorker.CLI

  test "parse_input/1 keeps egress_probe targets as string-keyed maps" do
    json = ~s({"run_id":"r1","egress_probe":[{"address":"100.64.0.1","port":5432}]})

    assert {:ok,
            %{
              run_id: "r1",
              egress_probe: [%{"address" => "100.64.0.1", "port" => 5432}]
            }} = CLI.parse_input(json)
  end

  # A toolchain build is queued per optional-deps variant: "include" runs the
  # optional dependencies pass, "exclude" builds without it.
  test "parse_input/1 keeps the optional_deps variant" do
    for variant <- ["include", "exclude"] do
      json = ~s({"run_id":"r1","mode":"toolchain","optional_deps":"#{variant}"})
      assert {:ok, %{mode: "toolchain", optional_deps: ^variant}} = CLI.parse_input(json)
    end
  end

  # Anything else would run as the default and record the wrong variant.
  test "parse_input/1 refuses an optional_deps value that is no variant" do
    for value <- [~s("maybe"), ~s(""), ~s("INCLUDE"), "1", "true", "[]"] do
      json = ~s({"run_id":"r1","mode":"toolchain","optional_deps":#{value}})
      assert {:error, _} = CLI.parse_input(json), value
    end
  end

  test "parse_input/1 takes a run without optional_deps as before" do
    assert {:ok, input} = CLI.parse_input(~s({"run_id":"r1","mode":"toolchain"}))
    refute Map.has_key?(input, :optional_deps)
  end

  test "parse_input/1 reports malformed JSON" do
    assert {:error, {:invalid_json, _}} = CLI.parse_input("{")
  end

  describe "exit_code/1" do
    test "0 for :ok" do
      assert CLI.exit_code(:ok) == 0
    end

    test "11 for a policy violation" do
      assert CLI.exit_code({:error, :policy_violation}) == 11
    end

    test "10 for any other internal failure" do
      assert CLI.exit_code({:error, {:deps_get_failed, "boom"}}) == 10
      assert CLI.exit_code({:error, :missing_work_dir}) == 10
    end
  end

  # Spec R1 "Other OS processes": Mix must compile dependencies one at a time
  # in one VM, or the trace sees neither the other partitions nor the order.
  test "scrub_env/0 removes the deps partition count" do
    System.put_env("MIX_OS_DEPS_COMPILE_PARTITION_COUNT", "2")
    on_exit(fn -> System.delete_env("MIX_OS_DEPS_COMPILE_PARTITION_COUNT") end)

    assert :ok = CLI.scrub_env()
    assert System.get_env("MIX_OS_DEPS_COMPILE_PARTITION_COUNT") == nil
  end

  test "parse_input/1 keeps a known config_variant and refuses an unknown one" do
    assert {:ok, %{config_variant: "phx_dev"}} =
             CLI.parse_input(~s({"mode": "toolchain", "config_variant": "phx_dev"}))

    assert {:ok, input} = CLI.parse_input(~s({"mode": "toolchain"}))
    refute Map.has_key?(input, :config_variant)

    assert {:error, {:invalid_config_variant, "phx_staging"}} =
             CLI.parse_input(~s({"mode": "toolchain", "config_variant": "phx_staging"}))
  end

  test "parse_input/1 reads the judge options" do
    assert {:ok, %{judge: %{makefile_rule2: true}}} =
             CLI.parse_input(~s({"mode": "toolchain", "judge": {"makefile_rule2": true}}))
  end
end
