defmodule Portal.Catalog.VersionBackfill do
  @max_failures 3

  @moduledoc """
  Older Hex releases of popular pure packages, for
  `Portal.Catalog.toolchain_backlog/3`: real projects lock older versions,
  and the catalog's own runs are almost always of the newest one.

  Of the packages ranked by hex.pm recent downloads
  (`Portal.Catalog.version_backfill_packages/1`), the top `top_packages` get
  their last `top_versions` releases and the top `packages` their last
  `versions` (`Portal.Toolchains.version_backfill/0`, by default 100 x 10 and
  500 x 4). Only packages already known to be pure qualify: one of their runs,
  any version, has a `host` or `registry_deps` pass, and they record no native
  components. The last releases are the newest by `Version`, counted after
  leaving out retired releases and pre-releases. The newest is usually one
  the catalog already has a run of, and the backlog lists it once.

  This only nominates versions. Each is built on the host by
  `Portal.Workers.ToolchainBuild` and judged on its own compile; the backlog
  leaves out a version with a live build like any other, and the build never
  touches a package's runs, badge or page, only the precompiled manifests.

  The release lists are read from `repo.hex.pm`, the registry's CDN, not the
  API (`releases/2` of `config :portal, :hex_deps`, else `Portal.HexDeps`,
  which caches each answer for an hour), one request per package in scope
  and one at a time, so at most `packages` requests per sweep and none for a
  package asked about within the hour. After #{@max_failures} answers that
  are not a package's (the CDN down or slow) it asks no more in that call and
  backfills only what it has: the sweep runs daily and asks again.
  """

  alias Portal.Catalog

  @doc """
  The `{package, version}` pairs to backfill, most downloaded package first,
  newest release first within a package.

  Options: `:hex_releases` (`(String.t() -> {:ok, [release]} | {:error, term()})`,
  default `releases/2` of `config :portal, :hex_deps` with a short timeout),
  `:tiers` (default `Portal.Toolchains.version_backfill/0`).
  """
  @spec wanted(keyword()) :: [{String.t(), String.t()}]
  def wanted(opts \\ []) do
    tiers = Keyword.get_lazy(opts, :tiers, &Portal.Toolchains.version_backfill/0)
    hex_releases = Keyword.get_lazy(opts, :hex_releases, &default_hex_releases/0)

    tiers
    |> scope()
    |> Catalog.version_backfill_packages()
    |> Enum.map(fn {name, rank} -> {name, versions_for(rank, tiers)} end)
    |> Enum.reject(fn {_name, count} -> count == 0 end)
    |> Enum.reduce_while({[], 0}, fn {name, count}, {acc, failures} ->
      case hex_releases.(name) do
        {:ok, releases} ->
          {:cont, {[Enum.map(last(releases, count), &{name, &1}) | acc], failures}}

        {:error, :not_found} ->
          {:cont, {acc, failures}}

        _unavailable when failures + 1 >= @max_failures ->
          {:halt, {acc, failures + 1}}

        _unavailable ->
          {:cont, {acc, failures + 1}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> List.flatten()
  end

  # The deepest rank any tier reaches.
  defp scope(tiers) do
    max(
      tier_scope(tiers.top_packages, tiers.top_versions),
      tier_scope(tiers.packages, tiers.versions)
    )
  end

  defp tier_scope(_packages, 0), do: 0
  defp tier_scope(packages, _versions), do: packages

  # How many releases the package at `rank` gets: the most of every tier it
  # is in.
  defp versions_for(rank, tiers) do
    [
      {tiers.top_packages, tiers.top_versions},
      {tiers.packages, tiers.versions}
    ]
    |> Enum.filter(fn {packages, _versions} -> rank <= packages end)
    |> Enum.map(fn {_packages, versions} -> versions end)
    |> Enum.max(fn -> 0 end)
  end

  # The newest `count` releases that are neither retired nor pre-releases.
  defp last(releases, count) do
    releases
    |> Enum.reject(& &1.retired?)
    |> Enum.flat_map(fn release ->
      case Version.parse(release.version) do
        {:ok, %Version{pre: []} = version} -> [{version, release.version}]
        _ -> []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0), {:desc, Version})
    |> Enum.take(count)
    |> Enum.map(&elem(&1, 1))
  end

  defp default_hex_releases do
    hex_deps = Application.get_env(:portal, :hex_deps, Portal.HexDeps)
    opts = [retry: false, receive_timeout: 10_000, connect_options: [timeout: 5_000]]
    &hex_deps.releases(&1, opts)
  end
end
