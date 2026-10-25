defmodule NccWorker.DepsLock do
  @moduledoc """
  The exact dependency tree a package was built against, for `result.json`.

  A BEAM file is not just the package's own code: every macro the package
  calls from a dependency is expanded into it at compile time, and the
  dependency's version decides what that expansion produced. A precompiled
  build is therefore only safe to reuse in a project whose `mix.lock` resolves
  the package's dependencies to the same versions with the same Hex checksums.
  This records that tree so the precompiled manifest can publish it and a
  client can match it.

  The tree is the package's whole transitive closure, not its direct
  dependencies: a macro can come from any module on the code path at compile
  time. It excludes the package itself, whose version is already the manifest
  key, and everything else in the generated Nerves project (nerves, systems,
  toolchains, the template's own dependencies), which the package never sees
  while it compiles.

  The edges come from the lock itself, which names each package's
  dependencies, rather than from `mix deps.tree`: they agree on what is
  resolved, and reading a file cannot fail halfway through a build. An optional
  dependency is an edge only when something resolved it, which is when it is in
  the lock, and that is exactly when it was loadable during the compile.
  """

  alias NccWorker.BuildCache

  @type t :: %{String.t() => %{String.t() => String.t()}}

  @doc """
  Returns `%{name => %{"version" => v, "checksum" => outer}}` for the closure of
  `package`, `%{}` for a package without dependencies, or `nil` when the lock
  is missing, unreadable, does not name the package, or has a closure member
  without an outer checksum. A partial tree would let a client match a build it
  should not, so there is nothing between the whole tree and none.
  """
  @spec read(String.t(), String.t()) :: t() | nil
  def read(project_dir, package) do
    with {:ok, lock} <- read_lock(project_dir),
         {:ok, name} <- lock_name(lock, package) do
      lock
      |> graph()
      |> BuildCache.closure(name)
      |> Enum.reduce_while(%{}, &put_locked(&1, &2, lock))
    else
      _ -> nil
    end
  end

  @doc "The package's own outer Hex checksum from the project's mix.lock, nil when unavailable."
  @spec package_checksum(String.t(), String.t()) :: String.t() | nil
  def package_checksum(project_dir, package) do
    with {:ok, lock} <- read_lock(project_dir),
         {:ok, name} <- lock_name(lock, package),
         {:hex, _pkg, _version, _inner, _managers, _deps, _repo, outer} when is_binary(outer) <-
           lock[name] do
      outer
    else
      _ -> nil
    end
  end

  @doc """
  The package's optional dependencies the lock did not resolve, as
  `%{app, package, requirement}`, for `NccWorker.Project.add_optional_deps/3`
  to add to the generated project. `[]` when the lock is missing or does not
  name the package.

  A generated project holds only the package under test, so an optional
  dependency is never resolved unless the package itself drags it in, while a
  real application almost always has it in its lock (decimal next to jason,
  jason next to ecto). The package compiles differently with the optional
  module loadable, so a build without it matches none of those applications.
  Only Hex packages from the public repo: the generated project cannot
  resolve a private repo.
  """
  @spec unresolved_optional_deps(String.t(), String.t()) ::
          [%{app: String.t(), package: String.t(), requirement: String.t()}]
  def unresolved_optional_deps(project_dir, package) do
    with {:ok, lock} <- read_lock(project_dir),
         {:ok, name} <- lock_name(lock, package) do
      for {app, requirement, opts} <- lock_deps(lock[name]),
          opts[:optional] == true,
          to_string(opts[:repo] || "hexpm") == "hexpm",
          app = to_string(app),
          not Map.has_key?(lock, app),
          do: %{app: app, package: to_string(opts[:hex] || app), requirement: requirement}
    else
      _ -> []
    end
  end

  @doc """
  Every Hex entry's locked version, keyed by lock name, or `:error` when the
  lock is missing or unreadable. `NccWorker.NervesCache` reads the Nerves
  systems and toolchains a run resolved out of it.
  """
  @spec versions(String.t()) :: {:ok, %{String.t() => String.t()}} | :error
  def versions(project_dir) do
    with {:ok, lock} <- read_lock(project_dir) do
      {:ok, lock |> Enum.flat_map(&locked_version/1) |> Map.new()}
    end
  end

  defp locked_version({name, entry})
       when is_tuple(entry) and tuple_size(entry) >= 3 and elem(entry, 0) == :hex and
              is_binary(elem(entry, 2)),
       do: [{name, elem(entry, 2)}]

  defp locked_version(_entry), do: []

  defp lock_deps({:hex, _pkg, _version, _inner, _managers, deps, _repo, _outer})
       when is_list(deps),
       do: deps

  defp lock_deps({:hex, _pkg, _version, _inner, _managers, deps, _repo}) when is_list(deps),
    do: deps

  defp lock_deps(_entry), do: []

  defp put_locked(dep, acc, lock) do
    case Map.get(lock, dep) do
      {:hex, _pkg, version, _inner, _managers, _deps, _repo, outer}
      when is_binary(version) and is_binary(outer) ->
        {:cont, Map.put(acc, dep, %{"version" => version, "checksum" => outer})}

      _ ->
        {:halt, nil}
    end
  end

  # Lock keys are application names; the package arrives as its Hex name. They
  # are almost always the same, and the Hex name in the entry covers the rest.
  defp lock_name(lock, package) do
    if Map.has_key?(lock, package) do
      {:ok, package}
    else
      Enum.find_value(lock, :error, &hex_name_match(&1, package))
    end
  end

  defp hex_name_match({name, entry}, package) when is_tuple(entry) and tuple_size(entry) > 2 do
    if to_string(elem(entry, 1)) == package, do: {:ok, name}
  end

  defp hex_name_match(_entry, _package), do: nil

  # Edges only to dependencies the lock resolved, in the shape
  # `BuildCache.closure/2` walks.
  defp graph(lock) do
    Map.new(lock, fn {name, entry} ->
      {name,
       for(
         {dep, _requirement, _opts} <- lock_deps(entry),
         dep = to_string(dep),
         Map.has_key?(lock, dep),
         do: dep
       )}
    end)
  end

  # Mix writes `mix.lock` with quoted keys, and evaluating it prints a
  # "quotes are not required" warning per dependency into the build log;
  # `with_diagnostics/1` collects them instead. Mirrors `NccWorker.LockPolicy`.
  # Intentional Mix lock evaluation inside the disposable build container, after deps.get
  # has already executed package build code. Never call this on the portal host;
  # container isolation, not this evaluator, is the boundary for package execution.
  # sobelow_skip ["RCE.CodeModule", "Traversal.FileModule"]
  defp read_lock(project_dir) do
    with {:ok, content} <- File.read(Path.join(project_dir, "mix.lock")),
         {{lock, _bindings}, _diagnostics} when is_map(lock) <-
           Code.with_diagnostics(fn -> Code.eval_string(content) end) do
      {:ok, Map.new(lock, fn {name, entry} -> {to_string(name), entry} end)}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
