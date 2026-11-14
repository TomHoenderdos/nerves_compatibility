defmodule Portal.Catalog.Coverage do
  @moduledoc """
  How much of what people actually install the precompiled manifest serves:
  per configured toolchain (`Portal.Toolchains.images/0`), how many of the
  most downloaded packages have a served build of their latest stable
  version, and why each of the others does not.

  A package is ranked by its hex.pm recent downloads; one without a count is
  not ranked at all. Its latest version is the highest stable version any
  run of it has seen, by version order, since that is what a fresh
  `mix deps.get` resolves to; a package that has only ever been seen at
  pre-releases falls back to the highest of those.

  A version is covered on a toolchain by a passing, non-revoked
  `Portal.Catalog.ToolchainBuild`, whichever `builder_version` made it:
  coverage counts what a client gets, and the manifest serves every such
  build. A revoked build is not served and counts for nothing, not even as
  a build of the version.

  A covered version also counts in the second column when a covering build
  other than a world build (`Compatibility.Worlds`) carries the package's
  optional dependencies, since a fresh lock that adds
  one misses a build made without it. Carrying them means the build's
  `deps_lock` holds every optional Hex dependency the version declares,
  each at the newest stable release its requirement allows: what a fresh
  `mix deps.get` next to the package resolves. The worker's never-added
  tooling and alternatives (`Compatibility.OptionalDeps.never_added/0`) are
  not expected, and a version that declares no other optional dependency
  counts as carrying them, as does a package `repo.hex.pm` does not list,
  which declares nothing a fresh lock could add. The declarations come from
  `repo.hex.pm` (`Portal.HexDeps`); a version whose declarations cannot be
  read is not counted, since nothing shows its build has them.

  Each uncovered package is a gap with the first reason that applies:

    * `:no_host_build` - no build of any version on the toolchain, or only
      skipped builds of the version: a skip is the toolchain build judging
      the package not portable, so by design there is no host build
    * `:no_build_for_version` - builds of other versions only
    * `:failed` - the version was built and nothing is served for it:
      `fail` or `error`, by any recipe
    * `:no_optional_deps_build` - covered, but without its optional
      dependencies; a gap only in the second column

  Computing it asks the registry about every ranked package, so the admin
  page shows a stored copy (`store/1`, `latest/0`) that
  `Portal.Workers.CoverageRefresh` recomputes hourly.
  """

  require Ash.Query

  alias Portal.Catalog.{CoverageReport, Package, Run, ToolchainBuild, UnrecordedOptionalDeps}
  alias Portal.HexDeps

  @default_top_n 100

  @reasons Map.new(
             [:no_host_build, :no_build_for_version, :failed, :no_optional_deps_build],
             &{Atom.to_string(&1), &1}
           )

  @type reason :: :no_host_build | :no_build_for_version | :failed | :no_optional_deps_build
  @type gap :: %{
          package: String.t(),
          version: String.t() | nil,
          downloads: non_neg_integer(),
          reason: reason()
        }
  @type row :: %{
          toolchain: String.t(),
          total: non_neg_integer(),
          covered: non_neg_integer(),
          percent: float(),
          covered_with_optional: non_neg_integer(),
          percent_with_optional: float(),
          gaps: [gap()]
        }
  @type t :: %{top_n: pos_integer(), toolchains: [row()]}

  @doc """
  The report, toolchains in configured order and each row's gaps most
  downloaded first.

  Options:

    * `:top_n` - how many packages to rank (default `config :portal,
      :coverage_top_n`, else 100)
    * `:hex_releases` - `(String.t() -> {:ok, [Portal.HexDeps.release()]} |
      {:error, term()})`, a package's releases and their dependencies
      (default `releases/2` of `config :portal, :hex_deps`, else
      `Portal.HexDeps`, with its default options)
    * `:optional_deps_complete?` - `(ToolchainBuild.t() -> boolean())`,
      whether a covering build carries its package's optional dependencies
      (default: the check described in the moduledoc, through
      `:hex_releases`)
  """
  @spec report(keyword()) :: t()
  def report(opts \\ []) do
    top_n =
      Keyword.get_lazy(opts, :top_n, fn ->
        Application.get_env(:portal, :coverage_top_n, @default_top_n)
      end)

    packages = top_packages(top_n)
    ids = Enum.map(packages, & &1.id)
    latest = latest_versions(ids)
    builds = builds(ids)

    complete? =
      Keyword.get_lazy(opts, :optional_deps_complete?, fn ->
        hex_releases = Keyword.get_lazy(opts, :hex_releases, &default_hex_releases/0)
        optional_deps_check(packages, latest, builds, hex_releases)
      end)

    toolchains =
      for %{toolchain: toolchain} <- Portal.Toolchains.images() do
        row(toolchain, packages, latest, Map.get(builds, toolchain, %{}), complete?)
      end

    %{top_n: top_n, toolchains: toolchains}
  end

  @doc """
  Stores `report` as the latest (`Portal.Catalog.CoverageReport`), computed
  now. `Portal.Workers.CoverageRefresh` calls it.
  """
  @spec store(t()) :: {:ok, CoverageReport.t()} | {:error, term()}
  def store(report) do
    CoverageReport
    |> Ash.Changeset.for_create(:upsert, %{
      key: "latest",
      report: report,
      computed_at: DateTime.utc_now()
    })
    |> Ash.create(domain: Portal.Catalog)
  end

  @doc """
  The latest stored report, in the shape `report/1` returns, with the time it
  was computed; nil before the first refresh. Reads one row and asks Hex
  nothing.
  """
  @spec latest() :: %{report: t(), computed_at: DateTime.t()} | nil
  def latest do
    CoverageReport
    |> Ash.Query.filter(key == "latest")
    |> Ash.read_one!(domain: Portal.Catalog)
    |> case do
      nil -> nil
      stored -> %{report: from_stored(stored.report), computed_at: stored.computed_at}
    end
  end

  # The row holds the report as JSON: string keys, and a gap's reason as its
  # name. Only the names `report/1` writes are read back.
  defp from_stored(stored) do
    %{
      top_n: stored["top_n"],
      toolchains: Enum.map(stored["toolchains"] || [], &row_from_stored/1)
    }
  end

  defp row_from_stored(row) do
    %{
      toolchain: row["toolchain"],
      total: row["total"],
      covered: row["covered"],
      percent: as_float(row["percent"]),
      covered_with_optional: row["covered_with_optional"],
      percent_with_optional: as_float(row["percent_with_optional"]),
      gaps: Enum.map(row["gaps"] || [], &gap_from_stored/1)
    }
  end

  defp gap_from_stored(gap) do
    %{
      package: gap["package"],
      version: gap["version"],
      downloads: gap["downloads"],
      reason: Map.get(@reasons, gap["reason"])
    }
  end

  defp as_float(number) when is_number(number), do: number * 1.0
  defp as_float(_other), do: 0.0

  # Tests that render the report without asking about optional dependencies
  # configure a stand-in, as for `Portal.HexPackageLookup`.
  defp default_hex_releases do
    hex_deps = Application.get_env(:portal, :hex_deps, HexDeps)
    &hex_deps.releases/1
  end

  defp top_packages(top_n) do
    Package
    |> Ash.Query.filter(not is_nil(hex_downloads_recent))
    |> Ash.Query.sort(hex_downloads_recent: :desc, name: :asc)
    |> Ash.Query.select([:id, :name, :hex_downloads_recent])
    |> Ash.Query.limit(top_n)
    |> Ash.read!(domain: Portal.Catalog)
  end

  # `package_id => latest version`, from every run of the packages.
  defp latest_versions([]), do: %{}

  defp latest_versions(ids) do
    Run
    |> Ash.Query.filter(package_id in ^ids)
    |> Ash.Query.select([:package_id, :version_tested])
    |> Ash.read!(domain: Portal.Catalog)
    |> Enum.group_by(& &1.package_id, & &1.version_tested)
    |> Map.new(fn {id, versions} -> {id, latest_version(versions)} end)
  end

  defp latest_version(versions) do
    parsed =
      for version <- Enum.uniq(versions),
          is_binary(version),
          {:ok, parsed} <- [Version.parse(version)],
          do: parsed

    case Enum.filter(parsed, &(&1.pre == [])) do
      [] -> highest(parsed)
      stable -> highest(stable)
    end
  end

  defp highest([]), do: nil
  defp highest(versions), do: versions |> Enum.max(Version) |> to_string()

  # `toolchain => package_id => [build]`, passing or not, of every builder
  # version, of the default config variant only: a named variant's build
  # covers nothing its default does not.
  defp builds([]), do: %{}

  defp builds(ids) do
    ToolchainBuild
    |> Ash.Query.filter(package_id in ^ids and is_nil(revoked_at) and config_variant == "default")
    # Not `file_manifest`: a build's file list is the largest thing on the
    # row and nothing here reads it.
    |> Ash.Query.select([:id, :package_id, :version, :toolchain, :status, :variant, :deps_lock])
    |> Ash.read!(domain: Portal.Catalog)
    |> Enum.group_by(& &1.toolchain)
    |> Map.new(fn {toolchain, builds} -> {toolchain, Enum.group_by(builds, & &1.package_id)} end)
  end

  defp row(toolchain, packages, latest, builds, complete?) do
    verdicts =
      Enum.map(packages, fn package ->
        version = Map.get(latest, package.id)
        {package, version, verdict(Map.get(builds, package.id, []), version, complete?)}
      end)

    total = length(packages)
    covered = Enum.count(verdicts, fn {_, _, verdict} -> verdict in [:covered, :without] end)
    with_optional = Enum.count(verdicts, fn {_, _, verdict} -> verdict == :covered end)

    gaps =
      for {package, version, verdict} <- verdicts, verdict != :covered do
        %{
          package: package.name,
          version: version,
          downloads: package.hex_downloads_recent,
          reason: if(verdict == :without, do: :no_optional_deps_build, else: verdict)
        }
      end

    %{
      toolchain: toolchain,
      total: total,
      covered: covered,
      percent: percent(covered, total),
      covered_with_optional: with_optional,
      percent_with_optional: percent(with_optional, total),
      gaps: gaps
    }
  end

  # `:covered` counts in both columns, `:without` in the first only. A pass
  # from any recipe covers, so a newer recipe's failure does not take away a
  # build already served.
  defp verdict([], _version, _complete?), do: :no_host_build

  defp verdict(builds, version, complete?) do
    of_version = Enum.filter(builds, &(&1.version == version))

    cond do
      of_version == [] -> :no_build_for_version
      Enum.all?(of_version, &(&1.status == :skipped)) -> :no_host_build
      true -> passing_verdict(Enum.filter(of_version, &(&1.status == :pass)), complete?)
    end
  end

  defp passing_verdict([], _complete?), do: :failed

  # A world build carries a world's members, not the package's own optional
  # dependencies, so it never counts in the second column.
  defp passing_verdict(passing, complete?) do
    if Enum.any?(passing, &(not ToolchainBuild.world?(&1.variant) and complete?.(&1))),
      do: :covered,
      else: :without
  end

  # The default `optional_deps_complete?`: per package whose latest version
  # has a passing build on some toolchain, the optional dependencies that
  # version's build must hold (`dep => version`), read once here so a
  # dependency many packages declare is looked up once; `:unknown` when the
  # registry could not say.
  defp optional_deps_check(packages, latest, builds, hex_releases) do
    passing =
      for {_toolchain, by_package} <- builds,
          {package_id, package_builds} <- by_package,
          Enum.any?(package_builds, &(&1.status == :pass and &1.version == latest[package_id])),
          into: MapSet.new(),
          do: package_id

    {expected, _releases} =
      packages
      |> Enum.filter(&MapSet.member?(passing, &1.id))
      |> Enum.reduce({%{}, %{}}, fn package, {expected, releases} ->
        {wanted, releases} =
          expected_optional_deps(package.name, latest[package.id], hex_releases, releases)

        {Map.put(expected, package.id, wanted), releases}
      end)

    fn build -> holds?(build.deps_lock, Map.get(expected, build.package_id, :unknown)) end
  end

  defp expected_optional_deps(name, version, hex_releases, releases) do
    {answer, releases} = lookup(name, hex_releases, releases)

    with {:ok, found} <- answer,
         %{deps: deps} <- Enum.find(found, &(&1.version == version)) do
      deps
      |> Enum.filter(&expected_optional?/1)
      |> Enum.reduce({%{}, releases}, fn dep, {wanted, releases} ->
        newest_match(dep, hex_releases, releases, wanted)
      end)
    else
      {:error, :not_found} -> {%{}, releases}
      _ -> {:unknown, releases}
    end
  end

  defp expected_optional?(dep), do: UnrecordedOptionalDeps.addable?(dep)

  # A dependency with no stable release its requirement allows is one no
  # fresh lock can add, so it is not expected. One the registry cannot answer
  # for leaves the whole version unknown.
  defp newest_match(_dep, _hex_releases, releases, :unknown), do: {:unknown, releases}

  defp newest_match(dep, hex_releases, releases, wanted) do
    case lookup(dep.package, hex_releases, releases) do
      {{:ok, found}, releases} ->
        case newest_stable(found, dep.requirement) do
          nil -> {wanted, releases}
          version -> {Map.put(wanted, dep.package, version), releases}
        end

      {_error, releases} ->
        {:unknown, releases}
    end
  end

  defp lookup(name, hex_releases, releases) do
    case Map.fetch(releases, name) do
      {:ok, answer} ->
        {answer, releases}

      :error ->
        answer = hex_releases.(name)
        {answer, Map.put(releases, name, answer)}
    end
  end

  defp newest_stable(releases, requirement) do
    case Version.parse_requirement(requirement) do
      {:ok, requirement} ->
        releases
        |> Enum.flat_map(&stable_version/1)
        |> Enum.filter(&Version.match?(&1, requirement))
        |> highest()

      :error ->
        nil
    end
  end

  defp stable_version(%{version: version}) do
    case Version.parse(version) do
      {:ok, %Version{pre: []} = parsed} -> [parsed]
      _ -> []
    end
  end

  defp holds?(_deps_lock, :unknown), do: false

  defp holds?(deps_lock, wanted) do
    Enum.all?(wanted, fn {package, version} ->
      match?(%{^package => %{"version" => ^version}}, deps_lock || %{})
    end)
  end

  defp percent(_count, 0), do: 0.0
  defp percent(count, total), do: Float.round(count * 100 / total, 1)
end
