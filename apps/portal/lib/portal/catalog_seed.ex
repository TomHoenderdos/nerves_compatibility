defmodule Portal.CatalogSeed do
  @moduledoc """
  Queues a build for every hex.pm package the catalogue has never tested.

  `Portal.Workers.UpdateCheck` deliberately only looks at packages we already
  have -- a registry package we have never built is not stale, it is absent --
  and `Portal.UpstreamBackfill` seeds from the upstream site's list, which is
  roughly 2,850 names. Neither closes the gap against the registry itself, which
  is where the other ~19,700 packages are. This does.

  ## Why the registry and not the hex.pm API

  `Portal.HexRegistry.snapshot/1` is two signed CDN requests for all 22,000-odd
  packages. Asking the API for a package list instead would be thousands of
  requests against a service we are a guest on, to answer a question the
  registry already answers in one.

  The registry carries `latest_version`, but this does not use it. Resolving the
  version is `Portal.ScanRequests.create_once/1`'s job, and duplicating that
  decision here would mean two places that can disagree about what "latest"
  means -- retired releases in particular.

  ## Pacing

  Each name becomes its own `Portal.Workers.Backfill` job, staggered one per
  second. That is not politeness about the insert -- it is that every one of
  those jobs asks hex.pm to resolve a version, and twenty thousand of those in
  a burst is an outage we would be causing. One per second also means the sweep
  survives a restart with nothing lost: jobs already inserted keep their
  schedule, and re-running skips them.

  ## Idempotence

  Safe to re-run. `Backfill` is unique per package per day, `create_once/1` is
  idempotent against an open request, and `Portal.Workers.Build` is unique on
  package/version/image. A second pass on the same day is a no-op; a pass
  tomorrow re-checks only what is still missing, because the diff is recomputed
  against the catalogue each time.

  ## Priority

  Jobs carry `source: catalog_seed`, the lowest priority band. This matters more
  than it looks: seeding inserts tens of thousands of rows, and anything sharing
  its priority would tie and lose on insertion order for weeks. `Portal.ScanRequests`
  documents the split.
  """

  require Logger

  alias Portal.Workers.Backfill

  @type report :: %{
          registry: non_neg_integer(),
          known: non_neg_integer(),
          missing: non_neg_integer(),
          enqueued: non_neg_integer()
        }

  @doc """
  Enqueue a `Backfill` job for every registry package not in the catalogue.

  Options:

    * `:limit` - only enqueue the first N missing packages. The count is still
      reported in full, so a dry run tells you the size of the job it did not do.
    * `:stagger_ms` - spacing between jobs (default `1000`).
    * `:dry_run` - compute and report the diff, enqueue nothing (default `false`).

  `:missing` is the size of the gap; `:enqueued` counts jobs this call actually
  created. On a re-run the two diverge, and that difference is the progress
  report: everything already queued is skipped.
  """
  @spec run(keyword()) :: {:ok, report()} | {:error, term()}
  def run(opts \\ []) do
    with {:ok, entries} <- registry().snapshot() do
      known = known_names()
      registry = MapSet.new(entries, & &1.name)

      missing =
        registry
        |> MapSet.difference(known)
        |> Enum.sort()

      report = %{
        registry: MapSet.size(registry),
        known: MapSet.size(known),
        missing: length(missing),
        enqueued: 0
      }

      if Keyword.get(opts, :dry_run, false) do
        Logger.info("Catalog seed dry run: #{inspect(report)}")
        {:ok, report}
      else
        enqueued = enqueue_all(maybe_limit(missing, Keyword.get(opts, :limit)), opts)
        report = %{report | enqueued: enqueued}
        Logger.info("Catalog seed: #{inspect(report)}")
        {:ok, report}
      end
    end
  end

  # One query, two columns wide, against a table of a few thousand rows. Reading
  # it through Ash would load every attribute including the ones that hold build
  # output, to answer a question about names.
  defp known_names do
    %{rows: rows} = Portal.Repo.query!("SELECT name FROM catalog_packages")
    MapSet.new(rows, fn [name] -> name end)
  end

  # Resolved at runtime, not compile time, matching `Portal.Workers.UpdateCheck`:
  # the tests swap it with `Application.put_env/3`.
  defp registry, do: Application.get_env(:portal, :hex_registry_source, Portal.HexRegistry)

  defp maybe_limit(names, nil), do: names
  defp maybe_limit(names, limit) when is_integer(limit) and limit > 0, do: Enum.take(names, limit)

  defp enqueue_all(names, opts) do
    stagger_ms = Keyword.get(opts, :stagger_ms, 1000)

    names
    |> Enum.with_index()
    |> Enum.reduce(0, fn {name, index}, acc ->
      job =
        Backfill.new(%{package: name, source: "catalog_seed"},
          schedule_in: div(index * stagger_ms, 1000)
        )

      case Oban.insert(job) do
        # Oban answers a uniqueness collision with `{:ok, job}`, not an error.
        # Counting it would report a re-run as having queued twenty thousand
        # packages it actually skipped, and that number is the whole point of
        # the report.
        {:ok, %Oban.Job{conflict?: true}} ->
          acc

        {:ok, _job} ->
          acc + 1

        {:error, reason} ->
          Logger.warning("Catalog seed enqueue failed for #{name}: #{inspect(reason)}")
          acc
      end
    end)
  end
end
