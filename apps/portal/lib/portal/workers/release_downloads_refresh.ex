defmodule Portal.Workers.ReleaseDownloadsRefresh do
  @moduledoc """
  Weekly cron (queue `:intake`) that fetches hex.pm's download count for the
  toolchain backlog versions of the most downloaded packages and stores them
  as `Portal.Catalog.ReleaseDownloads`, which `Portal.Catalog.toolchain_backlog/3`
  orders a package's versions by.

  Only what can change an order is asked about: backlog versions
  (`Portal.Catalog.toolchain_backlog_to_rank/2`) of the `:top_packages`
  packages by recent downloads (default 200), at most
  `:versions_per_package` (default 5) each, newest first. The requests are
  made here, one at a time and 1.5 s apart, like the package metadata
  refresh, so a full run of 1,000 stays under hex.pm's unauthenticated rate
  limit. A 429 anyway stops the run, keeping what was stored: the rest would
  only collect more 429s, and next week's run starts over. Any other failure
  skips that version.

  Reordering the backlog is all this does; building stays
  `Portal.Workers.ToolchainSweep`'s.

  Unique for a week while one is still waiting or running, and not retried:
  a second run, or a retry, inside the week would ask hex.pm the same
  questions again inside the rate limit window that may have stopped the
  first. A finished run does not block the next week's cron insert.
  """

  use Oban.Worker,
    queue: :intake,
    max_attempts: 1,
    unique: [period: 7 * 86_400, states: :incomplete]

  require Logger

  alias Portal.Catalog
  alias Portal.Catalog.ReleaseDownloads

  @top_packages 200
  @versions_per_package 5
  @stagger_ms 1_500

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, _counts} = run()
    :ok
  end

  @doc """
  Fetch and store the counts now.

  Options: `:top_packages` and `:versions_per_package` (the caps above);
  `:fetch`, a `(package, version -> result)` in place of
  `Portal.HexPm.release_downloads/2`, and `:sleep`, in place of
  `Process.sleep/1`, for tests.

  `requested` counts the hex.pm requests made, `stored` the counts written,
  and `stopped` is `:rate_limited` when a 429 ended the run early.
  """
  @spec run(keyword()) ::
          {:ok,
           %{
             requested: non_neg_integer(),
             stored: non_neg_integer(),
             stopped: :rate_limited | nil
           }}
  def run(opts \\ []) do
    fetch = Keyword.get(opts, :fetch, &Portal.HexPm.release_downloads/2)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)

    candidates =
      Catalog.toolchain_backlog_to_rank(
        Keyword.get(opts, :top_packages, @top_packages),
        Keyword.get(opts, :versions_per_package, @versions_per_package)
      )

    counts =
      candidates
      |> Enum.with_index()
      |> Enum.reduce_while(%{requested: 0, stored: 0, stopped: nil}, fn
        {release, index}, acc ->
          if index > 0, do: sleep.(@stagger_ms)
          acc = %{acc | requested: acc.requested + 1}

          case fetch.(release.package, release.version) do
            {:ok, downloads} ->
              {:cont, %{acc | stored: acc.stored + store(release, downloads)}}

            {:error, :rate_limited} ->
              {:halt, %{acc | stopped: :rate_limited}}

            {:error, _reason} ->
              {:cont, acc}
          end
      end)

    Logger.info(
      "Release downloads refresh: #{counts.stored} of #{length(candidates)} stored, " <>
        "#{counts.requested} requested" <>
        if(counts.stopped, do: ", stopped: #{counts.stopped}", else: "")
    )

    {:ok, counts}
  end

  defp store(release, downloads) do
    ReleaseDownloads
    |> Ash.Changeset.for_create(:upsert, %{
      package: release.package,
      version: release.version,
      downloads: downloads,
      fetched_at: DateTime.utc_now()
    })
    |> Ash.create(domain: Catalog)
    |> case do
      {:ok, _row} ->
        1

      {:error, error} ->
        Logger.warning(
          "Release downloads for #{release.package} #{release.version} not stored: " <>
            Exception.message(error)
        )

        0
    end
  end
end
