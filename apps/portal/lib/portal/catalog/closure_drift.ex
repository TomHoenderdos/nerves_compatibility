defmodule Portal.Catalog.ClosureDrift do
  @moduledoc """
  Whether a fresh `mix deps.get` of a package version would now lock a
  dependency of its closure at a newer release than one of its builds did.

  A toolchain build records the lock it was made with (`deps_lock`), and a
  client takes it only when its own lock agrees. A build of `fledex_scheduler
  0.4.0` made against `certifi 2.18.0` stops hitting for every new project
  the day `certifi 2.19.0` comes out, though nothing about the package
  changed: the build drifted. `Portal.Workers.ClosureDrift` finds those builds
  with `candidates/2` and `drift/3` and queues their rebuilds.

  ## What counts as drift

  A fresh resolve picks, for each dependency, the newest release every
  requirement on it in the closure allows. `drift/3` asks exactly that of each
  dependency the build locked, and is conservative everywhere it cannot know:

    * the requirements are those the package and every closure member
      declare at their locked versions (`Portal.HexDeps`); a closure whose
      requirements cannot all be read is not judged (`{:error, _}`);
    * a target is a stable, unretired release, never a prerelease;
    * a dependency the registry last changed before the build finished is
      not drift: that build's own resolve saw the release and did not pick
      it, so something this check does not model (a constraint of another
      release in the new closure, say) still holds, and a rebuild would only
      lock the same version again. This is also what keeps a rebuild that
      came back with the same lock from being queued again the next day.

  A newer release of a member can change the requirements too; that is the
  rebuild's to find out, since it resolves the whole closure afresh.
  """

  alias Portal.Catalog.ToolchainBuild
  alias Portal.Repo

  @typedoc "A registry package as `index/1` keeps it."
  @type package :: %{
          newest: String.t() | nil,
          versions: [Version.t()],
          updated_at: DateTime.t() | nil
        }

  @typedoc "One dependency of a build that a fresh resolve now locks newer."
  @type change :: %{String.t() => String.t()}

  @doc """
  The registry (`Portal.HexRegistry.snapshot/1` with `all_versions: true`)
  by package name: every stable, unretired release, parsed and ascending, the
  newest of them (`newest`, nil when there is none) and `updated_at`.
  """
  @spec index([map()]) :: %{String.t() => package()}
  def index(entries) do
    Map.new(entries, fn entry ->
      retired = MapSet.new(Map.get(entry, :retired, []))

      versions =
        entry
        |> Map.get(:versions, [entry.latest_version])
        |> Enum.reject(&MapSet.member?(retired, &1))
        |> Enum.flat_map(&stable/1)
        |> Enum.sort(Version)

      newest = if versions == [], do: nil, else: versions |> List.last() |> to_string()
      {entry.name, %{newest: newest, versions: versions, updated_at: entry.updated_at}}
    end)
  end

  defp stable(version) do
    case Version.parse(version) do
      {:ok, %Version{pre: []} = parsed} -> [parsed]
      _ -> []
    end
  end

  @doc """
  Whether `build` (`package`, `version`, `deps_lock`, and `built_at`, when
  it last resolved) drifted against `index`: `{:drift, changes}` with one
  `%{"dep", "from", "to"}` per dependency a fresh resolve would lock newer,
  sorted by name; `:current`; or `{:error, reason}` when the closure's
  requirements could not be read. `releases` answers like
  `Portal.HexDeps.releases/1`, and is only asked when some dependency has a
  newer release at all.
  """
  @spec drift(map(), %{String.t() => package()}, (String.t() -> {:ok, [map()]} | {:error, term()})) ::
          {:drift, [change()]} | :current | {:error, term()}
  def drift(%{deps_lock: %{} = lock} = build, index, releases) do
    case newer(lock, index, build[:built_at]) do
      none when none == %{} -> :current
      newer -> judge(build, lock, newer, releases)
    end
  end

  def drift(_build, _index, _releases), do: :current

  # Each locked dependency with a stable, unretired release newer than its
  # lock, that changed after the build: `%{name => {locked, [newer]}}`.
  defp newer(lock, index, built_at) do
    for {name, %{"version" => locked}} <- lock,
        {:ok, locked_version} <- [Version.parse(locked)],
        %{versions: versions, updated_at: updated_at} <- [Map.get(index, name)],
        changed_since?(updated_at, built_at),
        newer = Enum.filter(versions, &(Version.compare(&1, locked_version) == :gt)),
        newer != [],
        into: %{},
        do: {name, {locked, newer}}
  end

  defp changed_since?(nil, _built_at), do: true
  defp changed_since?(_updated_at, nil), do: true
  defp changed_since?(updated_at, built_at), do: DateTime.compare(updated_at, built_at) == :gt

  defp judge(build, lock, newer, releases) do
    members = [
      {build.package, build.version} | for({name, %{"version" => v}} <- lock, do: {name, v})
    ]

    with {:ok, requirements} <- requirements(members, Map.keys(newer), releases) do
      changes =
        for {name, {locked, candidates}} <- Enum.sort(newer),
            allowed = Enum.filter(candidates, &allowed?(&1, Map.get(requirements, name, []))),
            allowed != [],
            do: %{"dep" => name, "from" => locked, "to" => allowed |> List.last() |> to_string()}

      if changes == [], do: :current, else: {:drift, changes}
    end
  end

  # Every requirement a member declares, at its locked version, on one of
  # `names`: `%{name => [requirement]}`.
  defp requirements(members, names, releases) do
    wanted = MapSet.new(names)

    Enum.reduce_while(members, {:ok, %{}}, fn {member, version}, {:ok, acc} ->
      case release_deps(member, version, releases) do
        {:ok, deps} -> {:cont, {:ok, add_requirements(acc, deps, wanted)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp add_requirements(acc, deps, wanted) do
    for %{package: package, requirement: requirement} = dep <- deps,
        Map.get(dep, :repository, "hexpm") == "hexpm",
        MapSet.member?(wanted, package),
        reduce: acc do
      acc -> Map.update(acc, package, [requirement], &[requirement | &1])
    end
  end

  defp release_deps(member, version, releases) do
    with {:ok, list} <- releases.(member),
         %{deps: deps} <- Enum.find(list, &(&1.version == version)) do
      {:ok, deps}
    else
      {:error, reason} -> {:error, {:releases, member, reason}}
      _ -> {:error, {:unknown_release, member, version}}
    end
  end

  defp allowed?(version, requirements) do
    Enum.all?(requirements, fn requirement ->
      case Version.parse_requirement(requirement) do
        {:ok, parsed} -> Version.match?(version, parsed)
        :error -> false
      end
    end)
  end

  @candidates_sql """
  WITH newest AS (
    SELECT * FROM unnest($1::text[], $2::text[]) AS n(name, version)
  ), served AS (
    SELECT t.id, p.name, t.version, t.toolchain, t.variant, t.config_variant, t.deps_lock,
           greatest(t.finished_at, t.attempted_at) AS built_at,
           coalesce(p.hex_downloads_recent, 0) AS downloads
    FROM catalog_toolchain_builds t
    JOIN catalog_packages p ON p.id = t.package_id
    JOIN newest l ON l.name = p.name AND l.version = t.version
    WHERE t.status = 'pass' AND t.revoked_at IS NULL AND t.builder_version = $3
      AND t.toolchain = ANY($4::text[]) AND t.variant = ANY($5::text[])
      AND t.variant IN #{ToolchainBuild.variants_sql()}
      AND jsonb_typeof(t.deps_lock) = 'object'
      AND ($7::text IS NULL OR t.deps_lock ? $7::text)
  ), behind AS (
    SELECT DISTINCT s.id
    FROM served s
    CROSS JOIN LATERAL jsonb_each(s.deps_lock) d
    JOIN newest n ON n.name = d.key
    WHERE d.value->>'version' IS DISTINCT FROM n.version
      AND ($7::text IS NULL OR d.key = $7::text)
  )
  SELECT s.id, s.name, s.version, s.toolchain, s.variant, s.config_variant, s.deps_lock,
         s.built_at
  FROM served s
  JOIN behind b ON b.id = s.id
  ORDER BY s.downloads DESC, s.name, s.toolchain, s.variant, s.config_variant
  LIMIT $6
  """

  @doc """
  The passing, unrevoked toolchain builds at `:builder_version` on one of
  `:toolchains`, of one of `:variants` (names), of each package's newest
  stable release in `index`, that lock some dependency at anything but its
  newest release: the builds `drift/3` may find drifted, most downloaded
  package first, at most `:limit`. With `:dep`, only the builds that lock
  that package at anything but its newest release.
  """
  @spec candidates(%{String.t() => package()}, keyword()) :: [map()]
  def candidates(index, opts) do
    {names, versions} =
      index
      |> Enum.flat_map(fn {name, %{newest: newest}} ->
        if newest, do: [{name, newest}], else: []
      end)
      |> Enum.unzip()

    %{rows: rows} =
      Repo.query!(
        @candidates_sql,
        [
          names,
          versions,
          Keyword.fetch!(opts, :builder_version),
          Keyword.fetch!(opts, :toolchains),
          Enum.map(Keyword.fetch!(opts, :variants), &to_string/1),
          Keyword.fetch!(opts, :limit),
          Keyword.get(opts, :dep)
        ],
        timeout: :timer.minutes(2)
      )

    for [id, name, version, toolchain, variant, config_variant, lock, built_at] <- rows do
      %{
        id: Ecto.UUID.cast!(id),
        package: name,
        version: version,
        toolchain: toolchain,
        variant: variant,
        config_variant: config_variant,
        deps_lock: lock,
        built_at: built_at && DateTime.from_naive!(built_at, "Etc/UTC")
      }
    end
  end
end
