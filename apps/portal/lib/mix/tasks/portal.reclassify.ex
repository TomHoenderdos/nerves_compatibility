defmodule Mix.Tasks.Portal.Reclassify do
  @shortdoc "Re-derive failure_category for stored system results from their log_tail"
  @moduledoc @shortdoc
  use Mix.Task

  alias Portal.Catalog
  alias Portal.Catalog.{FailureClassifier, SystemResult}

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    results = Ash.read!(SystemResult, domain: Catalog)

    counts =
      Enum.reduce(results, %{}, fn sr, acc ->
        category =
          FailureClassifier.classify(%{
            "status" => to_string(sr.status),
            "log_tail" => sr.log_tail
          })

        if category != sr.failure_category do
          sr
          |> Ash.Changeset.for_update(:update, %{failure_category: category})
          |> Ash.update!(domain: Catalog)
        end

        Map.update(acc, category || "pass/skipped", 1, &(&1 + 1))
      end)

    Mix.shell().info("Reclassified #{length(results)} system results:")
    Enum.each(counts, fn {cat, n} -> Mix.shell().info("  #{cat}: #{n}") end)
  end
end
