defmodule NccWorker.CLITest do
  use ExUnit.Case, async: true

  alias NccWorker.CLI

  test "parse_input/1 keeps egress_probe targets as string-keyed maps" do
    json = ~s({"run_id":"r1","egress_probe":[{"address":"192.0.2.11","port":5432}]})

    assert {:ok,
            %{
              run_id: "r1",
              egress_probe: [%{"address" => "192.0.2.11", "port" => 5432}]
            }} = CLI.parse_input(json)
  end

  test "parse_input/1 reports malformed JSON" do
    assert {:error, {:invalid_json, _}} = CLI.parse_input("{")
  end
end
