defmodule Portal.Test.RelocationFixtures do
  @moduledoc """
  A relocation record (`Compatibility.Relocation`) as the worker writes one,
  at the worker's own three roots, so the portal's pins
  (`Compatibility.Relocation.pinned_problem/1`) hold it.
  """

  @doc "The record of `beam` (an `ebin/<beam>` path) with one `LitT` occurrence."
  @spec record(String.t()) :: map()
  def record(beam) do
    Map.put(Compatibility.Relocation.pinned_record(1), "files", [
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
    ])
  end
end
