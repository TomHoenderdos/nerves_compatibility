defmodule Portal.Catalog.VersionBackfill do
  @max_failures 3
  @concurrency 8
  @budget_ms 120_000
  # A request's own receive and connect timeouts (`default_hex_releases/0`).
  @request_ms 15_000

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
  API (`releases/2` of `config :portal, :hex_deps`, else `Portal.HexDeps`).
  `Portal.Workers.ToolchainSweep` calls `wanted/0` once per run for every
  toolchain. Only the packages in scope are asked about (at most `packages`,
  500 by default), #{@concurrency} at a time, each request with a short
  timeout and no retry. `Portal.HexDeps` keeps every answer for an hour,
  errors and unknown packages included (`negative_cache: true`), so a second
  call within the hour asks nothing again. After #{@max_failures} answers
  that are not a package's (the CDN down or slow) it asks no more, and after
  #{div(@budget_ms, 1000)} s in all it starts no new request and logs one
  line; either way it backfills only what it has, and the next daily sweep
  asks again.
  """

  require Logger

  alias Portal.Catalog

  @doc """
  The `{package, version}` pairs to backfill, most downloaded package first,
  newest release first within a package.

  Options: `:hex_releases` (`(String.t() -> {:ok, [release]} | {:error, term()})`,
  default `releases/2` of `config :portal, :hex_deps` with a short timeout),
  `:tiers` (default `Portal.Toolchains.version_backfill/0`), `:budget_ms`
  (default #{@budget_ms}).
  """
  @spec wanted(keyword()) :: [{String.t(), String.t()}]
  def wanted(opts \\ []) do
    tiers = Keyword.get_lazy(opts, :tiers, &Portal.Toolchains.version_backfill/0)
    hex_releases = Keyword.get_lazy(opts, :hex_releases, &default_hex_releases/0)
    budget = Keyword.get(opts, :budget_ms, @budget_ms)
    deadline = System.monotonic_time(:millisecond) + budget

    tiers
    |> scope()
    |> Catalog.version_backfill_packages()
    |> Enum.map(fn {name, rank} -> {name, versions_for(rank, tiers)} end)
    |> Enum.reject(fn {_name, count} -> count == 0 end)
    |> Task.async_stream(
      fn {name, count} -> {name, count, ask(hex_releases, name, deadline)} end,
      max_concurrency: @concurrency,
      ordered: true,
      timeout: budget + @request_ms,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({[], 0}, &collect(&1, &2, deadline))
    |> elem(0)
    |> Enum.reverse()
    |> List.flatten()
  end

  # No request starts past the deadline.
  defp ask(hex_releases, name, deadline) do
    if System.monotonic_time(:millisecond) < deadline, do: hex_releases.(name), else: :late
  end

  # Past the deadline, every answer still to come is dropped.
  defp collect(result, state, deadline) do
    if late?(result) or System.monotonic_time(:millisecond) >= deadline do
      Logger.warning(
        "Version backfill ran out of its hex.pm time budget; using the releases it has"
      )

      {:halt, state}
    else
      answer(result, state)
    end
  end

  defp late?({:ok, {_name, _count, :late}}), do: true
  defp late?(_result), do: false

  defp answer({:ok, {name, count, {:ok, releases}}}, {acc, failures}),
    do: {:cont, {[Enum.map(last(releases, count), &{name, &1}) | acc], failures}}

  defp answer({:ok, {_name, _count, {:error, :not_found}}}, state), do: {:cont, state}

  defp answer(_unavailable, {acc, failures}) when failures + 1 >= @max_failures,
    do: {:halt, {acc, failures + 1}}

  defp answer(_unavailable, {acc, failures}), do: {:cont, {acc, failures + 1}}

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

    opts = [
      retry: false,
      receive_timeout: 10_000,
      connect_options: [timeout: 5_000],
      negative_cache: true
    ]

    &hex_deps.releases(&1, opts)
  end
end
