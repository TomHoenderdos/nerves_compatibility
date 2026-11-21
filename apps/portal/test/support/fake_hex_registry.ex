defmodule Portal.Test.FakeHexRegistry do
  @moduledoc """
  Stands in for `Portal.HexRegistry` where a test config names it: answers
  what the test put under `{__MODULE__, :answer}` in its own process, else
  an empty registry. Jobs a test performs run in its process.
  """

  def snapshot(_opts \\ []), do: Process.get({__MODULE__, :answer}, {:ok, []})
end
