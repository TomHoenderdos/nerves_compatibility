defmodule Portal.Catalog.FailureClassifier do
  @moduledoc """
  Maps a failed system build to a coarse failure category by matching its
  `log_tail`/`error` text against an ordered ruleset. Portal-side; pure.
  """

  @fallback "Other / unclassified"

  # Ordered — first match wins.
  @rules [
    {"NIF built for wrong architecture",
     ~r/wrong ELF class|cannot execute binary|invalid ELF header|Exec format error|incompatible architecture/i},
    {"Precompiled NIF missing for target",
     ~r/could not find.*(\.so|nif|precompiled)|no precompiled|precompiled.*(not found|not available|missing)|error loading NIF/i},
    {"Dependency resolution failed",
     ~r/failed to use|unable to resolve|dependency resolution|no matching version|could not fetch|mix deps\.get.*fail/i},
    {"Compilation error",
     ~r/\(CompileError\)|== Compilation error|undefined function|\berror:\s/i}
  ]

  def classify(sys) when is_map(sys) do
    status = Map.get(sys, "status")

    case status do
      "pass" -> nil
      "skipped" -> nil
      _ -> classify_failure(sys)
    end
  end

  defp classify_failure(sys) do
    log_tail = Map.get(sys, "log_tail", "")
    error = Map.get(sys, "error", "")
    combined_text = "#{log_tail} #{error}"

    Enum.find_value(@rules, @fallback, fn {category, pattern} ->
      if String.match?(combined_text, pattern), do: category
    end)
  end
end
