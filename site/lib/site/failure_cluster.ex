defmodule Site.FailureCluster do
  @moduledoc """
  Groups failed system-results by a normalized signature extracted from the
  worker's log_tail, so a single page can answer "which root causes account
  for the most failures, and which packages are blocked by each."

  Input: a directory of raw worker result.json files (compat_test_results/).
  Output: an ordered list of clusters, each with title, count, affected
  packages+systems, and a representative log snippet.
  """

  # Ordered: the first pattern a failure matches wins. More specific ones
  # must come before generic catch-alls. Each entry is {title, regex, hint}.
  # The regex runs against the entire log_tail (multiline).
  @patterns [
    {"Precompiled NIF missing for this target",
     ~r/precompiled NIF is not available for this target: "([^"]+)"/,
     "Package ships a Rustler/Zigler precompiled NIF but no build exists for the Nerves target triple. The package vendor would need to add the triple to their release."},
    {"NIF built for wrong architecture (scrub-otp)",
     ~r/scrub-otp-release\.sh: ERROR: Unexpected executable format/,
     "A dependency's NIF .so was compiled against the host architecture, not the Nerves target — Nerves' scrub-otp step rejects it at firmware-build time. Usually fixable by forcing a clean rebuild of the dep for the target."},
    {"Failed to load NIF library at runtime",
     ~r/Failed to load NIF library/,
     "Application loaded on target but the NIF .so couldn't be dlopened — usually means the NIF was compiled but for the wrong libc/ABI."},
    {"UndefinedFunctionError",
     ~r/\*\* \(UndefinedFunctionError\) function ([^\s]+) is undefined/,
     "Package calls into an API that's missing. Often a version skew: the package expects a newer version of a dep than what resolved."},
    {"CompileError in package source",
     ~r/\*\* \(CompileError\) ([^\n]+)/,
     "The package's own Elixir source fails to compile. Could be a syntax issue triggered by a newer Elixir, or a missing macro dep."},
    {"Could not compile dependency",
     ~r/could not compile dependency :(\w+)/,
     "Catch-all for build failures where a dep's `mix compile` returned nonzero. See the representative log for the specific dep and cause."}
  ]

  @type cluster :: %{
          title: String.t(),
          count: non_neg_integer(),
          unique_packages: non_neg_integer(),
          affected_systems: [String.t()],
          hint: String.t(),
          entries: [%{package: String.t(), system: String.t(), detail: String.t() | nil}],
          sample_log: String.t() | nil
        }

  @doc """
  Scan a compat_test_results directory and return clusters in descending
  count order, plus an "Other" bucket for unclassified failures.
  """
  @spec compute(Path.t()) :: [cluster()]
  def compute(results_dir) do
    results_dir
    |> list_fail_entries()
    |> Enum.reduce(init_acc(), &classify/2)
    |> finalize()
  end

  defp list_fail_entries(results_dir) do
    results_dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, content} ->
          case JSON.decode(content) do
            {:ok, data} -> fail_entries(data)
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  defp fail_entries(%{"systems" => systems} = data) when is_map(systems) do
    pkg = get_in(data, ["package", "name"]) || "unknown"
    version = get_in(data, ["package", "version"])
    nif_lang = get_in(data, ["package", "native_components", "nif_language"])

    for {system, sys_result} <- systems,
        is_map(sys_result),
        sys_result["status"] == "fail" do
      %{
        package: pkg,
        version: version,
        system: system,
        log: sys_result["log_tail"] || "",
        nif_language: nif_lang
      }
    end
  end

  defp fail_entries(_), do: []

  defp init_acc() do
    named = Map.new(@patterns, fn {title, _rx, _hint} -> {title, []} end)
    Map.put(named, :__other__, [])
  end

  defp classify(%{package: pkg, system: system, log: log} = input, acc) do
    nif_lang = input[:nif_language]
    version = input[:version]

    entry_base = %{
      package: pkg,
      version: version,
      system: system,
      log: log,
      nif_language: nif_lang
    }

    case Enum.find_value(@patterns, fn {title, rx, _hint} ->
           case Regex.run(rx, log) do
             nil -> nil
             [_full | captures] -> {title, List.first(captures)}
           end
         end) do
      {title, detail} ->
        Map.update!(acc, title, fn entries ->
          [Map.put(entry_base, :detail, detail) | entries]
        end)

      nil ->
        Map.update!(acc, :__other__, fn entries ->
          [Map.put(entry_base, :detail, nil) | entries]
        end)
    end
  end

  defp finalize(acc) do
    ordered =
      @patterns
      |> Enum.map(fn {title, _rx, hint} -> build_cluster(title, hint, acc[title]) end)

    other = build_cluster("Other / unclassified", "Failures whose logs didn't match any known signature — worth eyeballing to propose a new pattern.", acc[:__other__])

    (ordered ++ [other])
    |> Enum.reject(&(&1.count == 0))
    |> Enum.sort_by(& &1.count, :desc)
  end

  defp build_cluster(title, hint, entries) do
    entries = entries || []

    %{
      title: title,
      count: length(entries),
      unique_packages: entries |> Enum.map(& &1.package) |> Enum.uniq() |> length(),
      affected_systems: entries |> Enum.map(& &1.system) |> Enum.uniq() |> Enum.sort(),
      hint: hint,
      entries:
        entries
        |> Enum.map(&Map.take(&1, [:package, :version, :system, :detail, :nif_language]))
        |> Enum.sort_by(&{&1.package, &1.system}),
      sample_log: sample_log(entries)
    }
  end

  # Pick the last ~40 lines of a representative failure's log_tail — usually
  # the bit with the actual error. Prefer the shortest log because shorter
  # = denser in signal, less prelude.
  defp sample_log([]), do: nil

  defp sample_log(entries) do
    entries
    |> Enum.min_by(&byte_size(&1.log))
    |> Map.get(:log)
    |> String.split("\n")
    |> Enum.take(-40)
    |> Enum.join("\n")
  end
end
