defmodule Portal.RuntimeQueuesTest do
  # Reads `config/runtime.exs` with `OBAN_QUEUES` set, so it changes the
  # process environment and cannot run alongside other tests.
  use ExUnit.Case, async: false

  @runtime Path.expand("../../../../config/runtime.exs", __DIR__)

  defp queues(value) do
    previous = System.get_env("OBAN_QUEUES")

    try do
      if value, do: System.put_env("OBAN_QUEUES", value), else: System.delete_env("OBAN_QUEUES")
      @runtime |> Config.Reader.read!(env: :test) |> get_in([:portal, Oban, :queues])
    after
      if previous,
        do: System.put_env("OBAN_QUEUES", previous),
        else: System.delete_env("OBAN_QUEUES")
    end
  end

  test "the default queue list runs reports" do
    assert queues(nil)[:reports] == 1
  end

  # Each build node's own queue, `Portal.NodeQueue`, is sized by `node`; no
  # node runs a shared ingest queue.
  test "the default queue list sizes the node queue and names no shared ingest queue" do
    assert queues(nil)[:node] == 2
    refute Keyword.has_key?(queues(nil), :ingest)
  end

  test "a node that runs maintenance also runs reports" do
    assert queues("intake:5,maintenance:1") == [intake: 5, maintenance: 1, reports: 1]
  end

  test "a node without maintenance does not run reports" do
    assert queues("builds:1,node:2") == [builds: 1, node: 2]
  end

  test "an explicit reports limit is kept" do
    assert queues("maintenance:1,reports:3") == [maintenance: 1, reports: 3]
  end
end
