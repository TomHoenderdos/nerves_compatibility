defmodule Portal.Test.RelocationFixtures do
  @moduledoc """
  A relocation record (`Compatibility.Relocation`) as the worker writes one,
  at the worker's own two roots, so the portal's pins
  (`Compatibility.Relocation.pinned_problem/1`) hold it.
  """

  @doc "The record of `beam` (an `ebin/<beam>` path) with one `LitT` occurrence."
  @spec record(String.t()) :: map()
  def record(beam) do
    second = Compatibility.Relocation.second_layout("/tmp/ncc-relocate-1")

    %{
      "deps" => "/work/proj/deps",
      "build" => "/work/proj/_build/host",
      "second" => Map.take(second, ["deps", "build"]),
      "files" => [
        %{
          "path" => "ebin/#{beam}.beam",
          "occurrences" => [
            %{
              "chunk" => "LitT",
              "index" => 0,
              "term" => [],
              "kind" => "binary",
              "parts" => ["", "deps", "/#{beam}/c_include"]
            }
          ]
        }
      ]
    }
  end
end
