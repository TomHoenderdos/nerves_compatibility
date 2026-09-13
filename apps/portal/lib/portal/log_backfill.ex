defmodule Portal.LogBackfill do
  @moduledoc """
  Rebuilds the packages whose visible failure has no build log.

  `Portal.Workers.Ingest` stores the sanitized log of every failed system result
  from now on, so this module exists for the failures that were ingested before
  it did. There is no way to recover those logs after the fact -- the scratch
  directory they were written to is deleted when the build finishes -- so the
  only way to get one is to run the build again.

  Candidates are failures in the *latest* run of a package, and only those. A
  failure in an older run is not reachable from any page, and
  `Portal.Workers.LogRetention` deletes logs for superseded runs on its next
  pass, so rebuilding one would pay for a log that is thrown away the same
  night.

  Each rebuild is a real multi-target firmware build on the `builds` queue,
  which holds three at a time. At roughly six minutes each, a few hundred
  candidates is several hours of wall clock. They are enqueued at priority 9,
  the lowest Oban offers, so a person waiting on a scan request they submitted
  never sits behind this.

  Meant to be run by hand from a remote console, not on a schedule.
  """

  require Logger

  alias Portal.Workers.Build

  # The `DISTINCT ON` ordering mirrors `Portal.Catalog.latest_runs/1` and
  # `Portal.Workers.LogRetention`'s rule 1 exactly, including the plain `DESC`
  # -- Ash's `:desc` renders to Ecto's `:desc`, which is Postgres's NULLS FIRST.
  # A run with no `finished_at` is therefore the latest run in all three places,
  # so the run this rebuilds is the run the page shows and the run whose log
  # retention will keep.
  @candidates_sql """
  WITH latest AS (
    SELECT DISTINCT ON (package_id) id, package_id, version_tested
    FROM catalog_runs
    ORDER BY package_id, finished_at DESC, inserted_at DESC
  )
  SELECT DISTINCT p.name, latest.version_tested
  FROM catalog_system_results sr
  JOIN latest ON latest.id = sr.run_id
  JOIN catalog_packages p ON p.id = latest.package_id
  LEFT JOIN catalog_system_logs l ON l.system_result_id = sr.id
  WHERE sr.status = 'fail'
    AND l.id IS NULL
  ORDER BY p.name
  """

  @doc """
  Enqueue a forced `Portal.Workers.Build` per package whose latest run has an
  unlogged failure.

  Options:

    * `:limit` - only enqueue the first N packages, for a dry run
    * `:dry_run` - list the candidates without enqueueing anything

  The jobs carry `force: true`, because a `Run` already exists for every one of
  them and `Portal.Workers.Build` would otherwise dedup them away. They carry no
  `image_digest`: the worker resolves the current one on the build host, which
  is the only machine that has the image.
  """
  @spec run(keyword()) :: {:ok, %{candidates: non_neg_integer(), enqueued: non_neg_integer()}}
  def run(opts \\ []) do
    builds = candidates() |> maybe_limit(Keyword.get(opts, :limit))

    enqueued =
      if Keyword.get(opts, :dry_run, false) do
        0
      else
        Enum.reduce(builds, 0, &enqueue/2)
      end

    Logger.info(
      "Log backfill#{if Keyword.get(opts, :dry_run, false), do: " (dry run)", else: ""}: " <>
        "#{enqueued} of #{length(builds)} rebuilds enqueued"
    )

    {:ok, %{candidates: length(builds), enqueued: enqueued}}
  end

  @doc "The package/version pairs `run/1` would rebuild, newest-run failures with no log."
  @spec candidates() :: [{String.t(), String.t()}]
  def candidates do
    %{rows: rows} = Portal.Repo.query!(@candidates_sql, [])
    Enum.map(rows, fn [name, version] -> {name, version} end)
  end

  defp enqueue({name, version}, acc) do
    job = Build.new(%{package: name, version: version, force: true}, priority: 9)

    case Oban.insert(job) do
      {:ok, _job} ->
        acc + 1

      {:error, reason} ->
        Logger.warning("Build enqueue failed for #{name} #{version}: #{inspect(reason)}")
        acc
    end
  end

  defp maybe_limit(builds, nil), do: builds

  defp maybe_limit(builds, limit) when is_integer(limit) and limit > 0,
    do: Enum.take(builds, limit)

  defp maybe_limit(builds, _limit), do: builds
end
