defmodule NccWorker.BuildSelection do
  @moduledoc """
  Selects firmware builds for native or Nerves-specific packages. A successful
  host compile and a fully inspected pure-Elixir dependency closure allow the
  worker to report assumed compatibility without building hardware targets.
  Unavailable or ambiguous evidence always keeps firmware builds enabled.
  """

  alias NccWorker.BuildCache

  @spec select(String.t(), String.t(), String.t(), map(), [{String.t(), String.t()}]) ::
          :pure_elixir | :firmware
  def select(project, package, description, %{status: :pass}, env) do
    case BuildCache.dep_graph(project, env) do
      {:ok, graph} -> classify(project, package, description, graph)
      _ -> :firmware
    end
  end

  def select(_project, _package, _description, _host, _env), do: :firmware

  @doc "Classifies a resolved package and its transitive dependencies inside the worker."
  @spec classify(String.t(), String.t(), String.t(), map()) :: :pure_elixir | :firmware
  def classify(project, package, description, graph) do
    names = graph |> Enum.flat_map(fn {name, deps} -> [name | deps] end) |> MapSet.new()
    closure = graph |> BuildCache.closure(package) |> MapSet.put(package)

    if MapSet.member?(names, package) and not nerves_description?(description) and
         Enum.all?(closure, &pure_dependency?(project, &1)) do
      :pure_elixir
    else
      :firmware
    end
  rescue
    _ -> :firmware
  end

  defp nerves_description?(description), do: Regex.match?(~r/\bnerves\b/i, description)

  defp pure_dependency?(project, name) do
    deps = Path.join(project, "deps")
    built = Path.join([project, "_build", "host", "lib", name])

    BuildCache.dep_target_agnostic?(deps, name) and
      not nerves_source?(Path.join(deps, name)) and pure_beams?(BeamScanner.analyze(built))
  end

  defp pure_beams?(%{
         beam_count: count,
         languages: [:elixir],
         errors: [],
         nif_calls?: false,
         shell_calls?: false,
         os_exec_calls?: false,
         footprint: %{priv: %{file_count: 0}}
       })
       when count > 0,
       do: true

  defp pure_beams?(_), do: false

  defp nerves_source?(dir) do
    args = [
      "-r",
      "-q",
      "-i",
      "--include=*.ex",
      "--include=*.exs",
      "--include=*.erl",
      "-e",
      "nerves",
      "--",
      dir
    ]

    case System.cmd("grep", args, stderr_to_stdout: true) do
      {_, 1} -> false
      _ -> true
    end
  end
end
