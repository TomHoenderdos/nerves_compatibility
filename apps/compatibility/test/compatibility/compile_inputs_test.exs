defmodule Compatibility.CompileInputsTest do
  use ExUnit.Case, async: true

  alias Compatibility.CompileInputs

  defp rec(term),
    do: term |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)

  @host %{
    "kind" => "env",
    "name" => "GITHUB_ACTIONS",
    "value" => "g3cFZXJyb3I",
    "set_by" => "host"
  }

  test "every item kind is accepted in its exact shape" do
    items = [
      @host,
      %{@host | "value" => "unrecordable"},
      Map.merge(@host, %{"set_by" => "build", "inputs" => "recorded"}),
      Map.merge(@host, %{"set_by" => "build", "inputs" => "unknown"}),
      %{"kind" => "env_all"},
      %{"kind" => "config_unrecorded"}
    ]

    assert CompileInputs.validate(items) == {:ok, items}
    assert CompileInputs.validate(nil) == {:ok, nil}
    assert CompileInputs.validate([]) == {:ok, []}
  end

  test "anything else is malformed, all or nothing" do
    for bad <- [
          [Map.put(@host, "extra", 1)],
          [%{@host | "set_by" => "elsewhere"}],
          [Map.merge(@host, %{"set_by" => "build", "inputs" => "maybe"})],
          [%{@host | "name" => "A=B"}],
          [%{@host | "name" => ""}],
          [%{@host | "value" => rec(fn -> :ok end)}],
          [%{"kind" => "env_all", "name" => "X"}],
          [%{"kind" => "teleport"}],
          [@host, :not_a_map],
          List.duplicate(%{"kind" => "env_all"}, 257),
          %{"kind" => "env_all"}
        ] do
      assert CompileInputs.validate(bad) == :error, inspect(bad, limit: 3)
    end
  end

  test "only build-set items with recorded inputs need no check" do
    refute CompileInputs.needs_check?(nil)
    refute CompileInputs.needs_check?([])

    refute CompileInputs.needs_check?([
             Map.merge(@host, %{"set_by" => "build", "inputs" => "recorded"})
           ])

    assert CompileInputs.needs_check?([@host])

    assert CompileInputs.needs_check?([
             Map.merge(@host, %{"set_by" => "build", "inputs" => "unknown"})
           ])

    assert CompileInputs.needs_check?([%{"kind" => "env_all"}])
    assert CompileInputs.needs_check?([%{"kind" => "config_unrecorded"}])
  end
end
