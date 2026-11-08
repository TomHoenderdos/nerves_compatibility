defmodule NccWorker.BuildSelection do
  @moduledoc """
  Selects firmware builds for native or Nerves-specific packages. A successful
  host compile and a fully inspected pure-Elixir dependency closure allow the
  worker to report assumed compatibility without building hardware targets.
  Unavailable or ambiguous evidence always keeps firmware builds enabled.
  """

  alias NccWorker.{BuildCache, DepsLock, StaticPriv}

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

  Priv files are portable when they are static data the package's own Hex
  tarball carries byte for byte (`NccWorker.StaticPriv`), so a package that
  ships them needs `tarball:`, the path of that tarball or `{:binary, bytes}`
  for one already read (`nil` for one the caller could not find or trust). Without the option at all the package is
  skipped as "ships priv files", the verdict from before the files were
  judged one by one.

  Rule 1: kept to record what it would have said (`rule1_reason`); the
  precompiled verdict is `static_rules/4` and the trace.
  """
  @spec portable?(String.t(), String.t(), map(), keyword()) :: :ok | {:skip, String.t()}
  def portable?(project, package, scan, opts \\ []) do
    deps = Path.join(project, "deps")
    source = Path.join(deps, package)

    with :ok <- portable_scan(scan),
         :ok <- portable_priv(project, package, scan, opts),
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

  @doc """
  The static half of the precompiled verdict (precompiled portability spec,
  R0), which the compile-time trace (`NccWorker.Portability`) does not
  cover: compiled beams in portable languages, no NIF or driver load in
  them, static priv data only (`portable?/4`'s priv rule), no mention of
  Nerves in the sources, and no native sources, native build dependencies,
  target reads or `nerves*` name (`BuildCache.dep_target_agnostic?/2`). The
  Nerves and target-read checks also cover every dependency in the
  package's locked closure, as `classify/4` does for a full run; native code
  in a dependency does not refuse.
  Unlike `portable?/4` it does not refuse program calls, executable lookups
  or a look at the OS type in the sources: a runtime call runs the same from
  a precompiled beam, and the trace refuses one made at compile time. Rebar
  `platform_define` and `rebar.config.script` are the trace's to judge, and
  only for a package rebar3 builds.

  The Nerves and target checks stay because the trace does not see a read
  of `Mix.target/0`: it is Mix state, not the host, and a build compiled for
  `:host` would be served to firmware builds. The package's own reasons are
  `portable?/4`'s; a dependency's reason names the dependency.
  Anything missing or unreadable fails closed.
  """
  @spec static_rules(String.t(), String.t(), map(), keyword()) :: :ok | {:skip, String.t()}
  def static_rules(project, package, scan, opts \\ []) do
    deps = Path.join(project, "deps")

    with :ok <- static_scan(scan),
         :ok <- portable_priv(project, package, scan, opts),
         :ok <- check(not nerves_source?(Path.join(deps, package)), "nerves-specific source"),
         :ok <-
           check(
             BuildCache.dep_target_agnostic?(deps, package),
             "reads the target or ships native code"
           ) do
      closure_static(project, package)
    end
  rescue
    _ -> {:skip, "portability could not be judged"}
  end

  # The Nerves word and target reads in every dependency the package compiles
  # against (its locked closure, `NccWorker.DepsLock.read/2`): a dependency's
  # macro that reads `Mix.target/0` expands into the package's own beams.
  # Native code in a dependency is not refused, as the consumer compiles it.
  # A lock that cannot be read or a dependency source that is missing fails
  # closed.
  defp closure_static(project, package) do
    deps = Path.join(project, "deps")

    case DepsLock.read(project, package) do
      nil ->
        {:skip, "portability could not be judged"}

      closure ->
        closure
        |> Map.keys()
        |> Enum.sort()
        |> Enum.find_value(:ok, &dependency_skip(Path.join(deps, &1), &1))
    end
  end

  # `nil` for a dependency that passes, else its `{:skip, reason}`.
  defp dependency_skip(dir, dep) do
    case dependency_static(dir, dep) do
      :ok -> nil
      skip -> skip
    end
  end

  defp dependency_static(dir, dep) do
    cond do
      not File.dir?(dir) -> {:skip, "portability could not be judged"}
      nerves_source?(dir) -> {:skip, "nerves-specific source in dependency #{dep}"}
      BuildCache.reads_target?(dir) -> {:skip, "dependency #{dep} reads the target"}
      true -> :ok
    end
  end

  defp static_scan(%{beam_count: count, errors: [], languages: languages} = scan)
       when is_integer(count) and count > 0 do
    with :ok <- portable_languages(languages) do
      no_calls(scan, :nif_calls?, :nif_evidence, "calls a NIF or port driver")
    end
  end

  defp static_scan(%{beam_count: 0}), do: {:skip, "no compiled beams"}
  defp static_scan(_scan), do: {:skip, "beam scan incomplete"}

  defp portable_scan(scan) do
    with :ok <- static_scan(scan),
         :ok <- no_calls(scan, :shell_calls?, :shell_evidence, "calls a shell"),
         :ok <- no_calls(scan, :os_exec_calls?, :os_exec_evidence, "runs an OS command") do
      no_calls(
        scan,
        :executable_lookup_calls?,
        :executable_lookup_evidence,
        "calls an executable lookup"
      )
    end
  end

  defp portable_priv(_project, _package, %{footprint: %{priv: %{file_count: 0}}}, _opts), do: :ok

  defp portable_priv(project, package, _scan, opts) do
    case Keyword.fetch(opts, :tarball) do
      {:ok, tarball} ->
        StaticPriv.check(
          Path.join([project, "_build", "host", "lib", package, "priv"]),
          Path.join([project, "deps", package, "priv"]),
          tarball
        )

      :error ->
        {:skip, "ships priv files"}
    end
  end

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
