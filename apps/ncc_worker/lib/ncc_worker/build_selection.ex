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

  @doc """
  Judges whether a package's own beams are portable: identical on every OS and
  architecture for the same Elixir minor and OTP major. Unlike `classify/4` it
  looks only at the package itself, not its dependency closure, and allows
  Erlang beams, because a portable build's consumer compiles native or
  OS-specific dependencies locally. `scan` is the `BeamScanner.analyze/1`
  result for `_build/host/lib/<package>`. Checks run in order and the first
  failure is the reason; anything missing or unreadable fails closed.
  """
  @spec portable?(String.t(), String.t(), map()) :: :ok | {:skip, String.t()}
  def portable?(project, package, scan) do
    deps = Path.join(project, "deps")
    source = Path.join(deps, package)

    with :ok <- portable_scan(scan),
         :ok <- check(not nerves_source?(source), "nerves-specific source"),
         :ok <-
           check(
             BuildCache.dep_target_agnostic?(deps, package),
             "reads the target or ships native code"
           ) do
      case BuildCache.os_agnostic?(source) do
        :ok -> :ok
        {:error, {file, needle}} -> {:skip, "OS-specific (#{file}: #{needle})"}
      end
    end
  rescue
    _ -> {:skip, "portability could not be judged"}
  end

  @portable_languages [:elixir, :erlang]

  defp portable_scan(%{beam_count: count, errors: [], languages: languages} = scan)
       when is_integer(count) and count > 0 do
    with :ok <- portable_languages(languages),
         :ok <- no_calls(scan, :nif_calls?, :nif_evidence, "calls a NIF or port driver"),
         :ok <- no_calls(scan, :shell_calls?, :shell_evidence, "calls a shell"),
         :ok <- no_calls(scan, :os_exec_calls?, :os_exec_evidence, "runs an OS command"),
         :ok <-
           no_calls(
             scan,
             :executable_lookup_calls?,
             :executable_lookup_evidence,
             "calls an executable lookup"
           ) do
      check(match?(%{footprint: %{priv: %{file_count: 0}}}, scan), "ships priv files")
    end
  end

  defp portable_scan(%{beam_count: 0}), do: {:skip, "no compiled beams"}
  defp portable_scan(_scan), do: {:skip, "beam scan incomplete"}

  defp portable_languages(languages) do
    case Enum.reject(languages, &(&1 in @portable_languages)) do
      [] -> :ok
      [language | _] -> {:skip, "beam language #{language} is not portable"}
    end
  end

  defp no_calls(scan, flag, evidence_key, generic) do
    case {Map.get(scan, flag), Map.get(scan, evidence_key)} do
      {false, _} -> :ok
      {_, [%{mfa: mfa} | _]} -> {:skip, "calls " <> format_mfa(mfa)}
      _ -> {:skip, generic}
    end
  end

  defp format_mfa({module, function, arity}) do
    case Atom.to_string(module) do
      "Elixir." <> name -> "#{name}.#{function}/#{arity}"
      name -> "#{name}:#{function}/#{arity}"
    end
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:skip, reason}

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
         executable_lookup_calls?: false,
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
