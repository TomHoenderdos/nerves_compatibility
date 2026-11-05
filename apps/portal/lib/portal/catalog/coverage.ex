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
  a build of the version. A covered version also counts in the second
  column when a covering build carries the package's optional dependencies
  (`optional_deps_complete?`), since a fresh lock that adds one misses a
  build made without it.

  Each uncovered package is a gap with the first reason that applies:

    * `:no_host_build` - no build of any version on the toolchain
    * `:no_build_for_version` - builds of other versions only
    * `:failed` - the version was built and nothing is served for it:
      `fail`, `error`, or `skipped`, by any recipe
    * `:no_optional_deps_build` - covered, but without its optional
      dependencies; a gap only in the second column
  """

  require Ash.Query

  alias Portal.Catalog.{Package, Run, ToolchainBuild}

  @default_top_n 100

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
    * `:optional_deps_complete?` - `(ToolchainBuild.t() -> boolean())`,
      whether a covering build carries the package's optional dependencies.
      The default counts every build as carrying them: the worker resolves a
      package's optional dependencies into the build it makes, and nothing
      stored here yet records which ones the package declares.
  """
  @spec report(keyword()) :: t()
  def report(opts \\ []) do
    top_n =
      Keyword.get_lazy(opts, :top_n, fn ->
        Application.get_env(:portal, :coverage_top_n, @default_top_n)
      end)

    complete? = Keyword.get(opts, :optional_deps_complete?, fn _build -> true end)

    packages = top_packages(top_n)
    ids = Enum.map(packages, & &1.id)
    latest = latest_versions(ids)
    builds = builds(ids)

    toolchains =
      for %{toolchain: toolchain} <- Portal.Toolchains.images() do
        row(toolchain, packages, latest, Map.get(builds, toolchain, %{}), complete?)
      end

    %{top_n: top_n, toolchains: toolchains}
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
  # version.
  defp builds([]), do: %{}

  defp builds(ids) do
    ToolchainBuild
    |> Ash.Query.filter(package_id in ^ids and is_nil(revoked_at))
    # Not `file_manifest`: a build's file list is the largest thing on the
    # row and nothing here reads it.
    |> Ash.Query.select([:id, :package_id, :version, :toolchain, :status, :deps_lock])
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

    case Enum.filter(of_version, &(&1.status == :pass)) do
      [] when of_version == [] -> :no_build_for_version
      [] -> :failed
      passing -> if Enum.any?(passing, complete?), do: :covered, else: :without
    end
  end

  defp percent(_count, 0), do: 0.0
  defp percent(count, total), do: Float.round(count * 100 / total, 1)
end
