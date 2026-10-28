defmodule NccWorker.CLITest do
  use ExUnit.Case, async: true

  alias NccWorker.CLI

  test "parse_input/1 keeps egress_probe targets as string-keyed maps" do
    json = ~s({"run_id":"r1","egress_probe":[{"address":"100.64.0.1","port":5432}]})

    assert {:ok,
            %{
              run_id: "r1",
              egress_probe: [%{"address" => "100.64.0.1", "port" => 5432}]
            }} = CLI.parse_input(json)
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
end
