defmodule Portal.NativeClosure do
  @moduledoc """
  Decides from registry data alone whether a package could need a Nerves build.

  Cross-compilation is the one thing a firmware build does that a plain
  `mix compile` does not, so a package can only fail on Nerves in an interesting
  way if native code appears somewhere in its transitive dependency closure.
  Registry v2 carries every release's dependency list, so the closure is
  computable from `repo.hex.pm` (via `Portal.HexDeps`) without fetching a
  tarball or running `mix deps.get`.

  Native code is recognised by the build tooling it depends on -- the marker
  list below -- and by `nerves*` names. The known blind spot: a package that
  ships its own `c_src/` with a hand-rolled compiler and no marker dependency,
  or pure Elixir that shells out to a program a Nerves image lacks, looks pure
  here. `NccWorker.BuildSelection` catches both, but only inside a real build.

  ## Fails closed

  Anything this cannot answer with confidence is `{:native, reason}`, which
  sends the package down the normal build path: a version or requirement it
  cannot resolve, a dependency from another repository, a registry resource
  that is missing or does not verify, or a closure larger than 500 packages. The cost of a wrong "native" is one build; the cost of a
  wrong "pure" is a green badge nobody checked.

  The single exception is `:hex_registry_unavailable`. An outage is not a fact
  about the package, and treating it as native would turn a CDN hiccup during a
  seed into thousands of Docker builds, so it comes back as an error for the
  caller to retry.
  """

  require Logger

  alias Portal.HexDeps

  @progress_every 500
  @markers ~w(elixir_make rustler rustler_precompiled zigler cc_precompiler unifex bundlex)
  @max_closure 500

  @type reason ::
          {:nerves, String.t()}
          | {:marker, String.t()}
          | {:repository, String.t(), String.t()}
          | {:unknown_version, String.t(), String.t()}
          | {:unsatisfiable, String.t(), String.t()}
          | {:bad_requirement, String.t(), String.t()}
          | {:registry, String.t(), :hex_registry_undecodable | :not_found}
          | :closure_too_large

  @doc """
  Classifies `name` at `version` from its registry dependency closure.

  The root package's releases are always fetched fresh (`cache: false`),
  whatever `opts` say: `Portal.Workers.UpdateCheck` hands over a release it has
  only just seen, and a copy of the resource cached up to an hour earlier would
  not list it, turning a pure package into `{:unknown_version, ...}` and a
  needless build. Dependencies use the cache as `opts` direct.
  """
  @spec classify(String.t(), String.t(), keyword()) ::
          :pure | {:native, reason()} | {:error, :hex_registry_unavailable}
  def classify(name, version, opts \\ []) do
    if nerves?(name) do
      {:native, {:nerves, name}}
    else
      with {:ok, releases} <- releases(name, Keyword.put(opts, :cache, false)) do
        classify_release(name, version, releases, opts)
      end
    end
  end

  defp classify_release(name, version, releases, opts) do
    with {:ok, release} <- exact(name, version, releases) do
      walk(release.deps, %{name => version}, opts)
    end
  end

  @doc """
  Classifies each name at its newest live release and writes nothing.

  For a remote console on production (`bin/portal remote`), to size a sweep
  before switching the filter on. Not `bin/portal eval`: `eval` starts no
  applications, so the `Portal.HexDeps` table and the HTTP client this needs
  are not running and the call crashes. A full run over ~18.5k names takes
  roughly 20-40 minutes, longer than a `bin/portal rpc` call is comfortable
  holding open, so prefer the remote console. Progress is logged every 500
  names.

  `reasons` counts native verdicts by the reason's first element. "Latest"
  here is the newest stable non-retired release in the registry, whereas
  `Portal.Workers.Backfill` asks `Portal.HexPm.latest_version/1`, so the
  counts can differ slightly from what a seed would do.
  """
  @spec dry_run([String.t()], keyword()) :: %{
          pure: non_neg_integer(),
          native: non_neg_integer(),
          errors: non_neg_integer(),
          reasons: %{atom() => non_neg_integer()}
        }
  def dry_run(names, opts \\ []) do
    names
    |> Enum.with_index(1)
    |> Enum.reduce(%{pure: 0, native: 0, errors: 0, reasons: %{}}, fn {name, n}, acc ->
      acc = tally(acc, dry_classify(name, opts))
      if rem(n, @progress_every) == 0, do: log_progress(n, acc)
      acc
    end)
  end

  # The root resource is fetched once, fresh, and reused for both the
  # latest-version pick and the classification.
  defp dry_classify(name, opts) do
    if nerves?(name) do
      {:native, {:nerves, name}}
    else
      with {:ok, releases} <- releases(name, Keyword.put(opts, :cache, false)),
           {:ok, version} <- latest(name, releases) do
        classify_release(name, version, releases, opts)
      end
    end
  end

  defp log_progress(n, acc) do
    Logger.info(
      "NativeClosure.dry_run: #{n} classified " <>
        "(pure #{acc.pure}, native #{acc.native}, errors #{acc.errors})"
    )
  end

  defp tally(acc, :pure), do: Map.update!(acc, :pure, &(&1 + 1))
  defp tally(acc, {:error, _}), do: Map.update!(acc, :errors, &(&1 + 1))

  defp tally(acc, {:native, reason}) do
    kind = if is_tuple(reason), do: elem(reason, 0), else: reason

    acc
    |> Map.update!(:native, &(&1 + 1))
    |> Map.update!(:reasons, &Map.update(&1, kind, 1, fn n -> n + 1 end))
  end

  defp latest(name, releases) do
    stable = Enum.filter(releases, &(not &1.retired? and stable?(&1.version)))

    case newest(stable) || newest(releases) do
      nil -> {:native, {:unknown_version, name, "latest"}}
      release -> {:ok, release.version}
    end
  end

  # Breadth-first: `rest ++ deps` keeps a shallow marker from waiting behind a
  # deep pure subtree. `seen` maps each visited package to the version it was
  # resolved to, so cycles terminate and each package is resolved once, as Mix
  # resolves one version per package -- but a later edge to an already-resolved
  # package still has its requirement checked against that version, instead of
  # being skipped outright, so a dependency Mix would have pinned to a
  # different (native) release cannot be waved through as pure.
  defp walk([], _seen, _opts), do: :pure

  defp walk([dep | rest], seen, opts) do
    cond do
      dep.optional -> walk(rest, seen, opts)
      dep.repository != "hexpm" -> {:native, {:repository, dep.package, dep.repository}}
      Map.has_key?(seen, dep.package) -> recheck(dep, rest, seen, opts)
      dep.package in @markers -> {:native, {:marker, dep.package}}
      nerves?(dep.package) -> {:native, {:nerves, dep.package}}
      map_size(seen) >= @max_closure -> {:native, :closure_too_large}
      true -> descend(dep, rest, seen, opts)
    end
  end

  # A second edge to an already-resolved package doesn't get a second
  # resolution -- Mix picks one version per package -- but its requirement
  # must still hold against the version already chosen, or the closure that
  # picked it is not the one Mix would actually build.
  defp recheck(dep, rest, seen, opts) do
    version = Map.fetch!(seen, dep.package)

    case Version.parse_requirement(dep.requirement) do
      {:ok, requirement} ->
        if matches?(version, requirement) do
          walk(rest, seen, opts)
        else
          {:native, {:unsatisfiable, dep.package, dep.requirement}}
        end

      :error ->
        {:native, {:bad_requirement, dep.package, dep.requirement}}
    end
  end

  defp descend(dep, rest, seen, opts) do
    with {:ok, releases} <- releases(dep.package, opts),
         {:ok, release} <- resolve(dep, releases) do
      walk(rest ++ release.deps, Map.put(seen, dep.package, release.version), opts)
    end
  end

  defp releases(name, opts) do
    case HexDeps.releases(name, opts) do
      {:ok, releases} -> {:ok, releases}
      {:error, :hex_registry_unavailable} = error -> error
      {:error, reason} -> {:native, {:registry, name, reason}}
    end
  end

  defp exact(name, version, releases) do
    case Enum.find(releases, &(&1.version == version)) do
      nil -> {:native, {:unknown_version, name, version}}
      release -> {:ok, release}
    end
  end

  # Newest release satisfying the requirement, preferring live releases and
  # falling back to retired ones -- which is what `mix deps.get` does.
  # `allow_pre: false` keeps `~> 1.0` off `1.1.0-rc.0` while still letting a
  # requirement that names a prerelease (`~> 2.0.0-rc.0`) match one.
  defp resolve(dep, releases) do
    case Version.parse_requirement(dep.requirement) do
      {:ok, requirement} ->
        matching = Enum.filter(releases, &matches?(&1.version, requirement))
        live = Enum.reject(matching, & &1.retired?)

        case newest(live) || newest(matching) do
          nil -> {:native, {:unsatisfiable, dep.package, dep.requirement}}
          release -> {:ok, release}
        end

      :error ->
        {:native, {:bad_requirement, dep.package, dep.requirement}}
    end
  end

  defp matches?(version, requirement) do
    case Version.parse(version) do
      {:ok, parsed} -> Version.match?(parsed, requirement, allow_pre: false)
      :error -> false
    end
  end

  defp stable?(version) do
    match?({:ok, %Version{pre: []}}, Version.parse(version))
  end

  defp newest([]), do: nil

  defp newest(releases) do
    releases
    |> Enum.filter(&match?({:ok, _}, Version.parse(&1.version)))
    |> case do
      [] -> nil
      parsable -> Enum.max_by(parsable, &Version.parse!(&1.version), Version)
    end
  end

  defp nerves?(name), do: String.starts_with?(name, "nerves")
end
