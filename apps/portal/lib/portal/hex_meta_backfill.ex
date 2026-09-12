defmodule Portal.HexMetaBackfill do
  @moduledoc """
  Fills in hex.pm metadata for packages already in the catalog.

  `Portal.Workers.Ingest` enqueues a `Portal.Workers.PackageMeta` job for every
  package it ingests from now on, so this module exists for the packages that
  were ingested before that hook did. Both go through the same worker; this one
  only decides which names to send and how fast.

  Staggered one per second, the same as `Portal.UpstreamBackfill` and for the
  same reason: a catalog-wide sweep is one hex.pm request per package, and
  hex.pm rate-limits. At ~2,500 packages the sweep takes roughly 45 minutes of
  wall clock on the `intake` queue, during which each package is an independent
  job that retries on its own without costing the sweep its progress.

  Meant to be run by hand from a remote console, not on a schedule -- links and
  owners change on the order of years.
  """

  require Ash.Query
  require Logger

  alias Portal.Catalog.Package
  alias Portal.Workers.PackageMeta

  @doc """
  Enqueue a `PackageMeta` job per package.

  Options:

    * `:only_missing` - skip packages whose metadata has already been fetched
      (default `true`); pass `false` to force a full refresh
    * `:stagger_ms` - spacing between jobs (default `1000`)
    * `:limit` - only enqueue the first N packages, for a dry run
  """
  @spec run(keyword()) :: {:ok, %{candidates: non_neg_integer(), enqueued: non_neg_integer()}}
  def run(opts \\ []) do
    names = opts |> candidates() |> maybe_limit(Keyword.get(opts, :limit))
    stagger_ms = Keyword.get(opts, :stagger_ms, 1000)

    enqueued =
      names
      |> Enum.with_index()
      |> Enum.reduce(0, fn {name, index}, acc ->
        job = PackageMeta.new(%{package: name}, schedule_in: div(index * stagger_ms, 1000))

        case Oban.insert(job) do
          {:ok, _job} ->
            acc + 1

          {:error, reason} ->
            Logger.warning("PackageMeta enqueue failed for #{name}: #{inspect(reason)}")
            acc
        end
      end)

    Logger.info("Hex metadata backfill: #{enqueued} of #{length(names)} packages enqueued")
    {:ok, %{candidates: length(names), enqueued: enqueued}}
  end

  defp candidates(opts) do
    query = Ash.Query.sort(Package, name: :asc)

    query =
      if Keyword.get(opts, :only_missing, true) do
        Ash.Query.filter(query, is_nil(hex_meta_fetched_at))
      else
        query
      end

    query
    |> Ash.Query.select([:name])
    |> Ash.read!(domain: Portal.Catalog)
    |> Enum.map(& &1.name)
  end

  defp maybe_limit(names, nil), do: names
  defp maybe_limit(names, limit) when is_integer(limit) and limit > 0, do: Enum.take(names, limit)
  defp maybe_limit(names, _limit), do: names
end
