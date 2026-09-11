defmodule Portal.Catalog.ManifestBackfill do
  @moduledoc """
  Strips `footprint.file_manifest` out of `catalog_system_results.dependency_scans`
  rows that were written before ingestion stopped storing it.

  `Portal.Catalog.Ingestion.drop_file_manifests/1` keeps new rows clean. This is
  the one-off pass over the rows that predate it — on production, 9,463 of them
  carrying roughly 1.1 GB of manifest JSON.

  ## Why this is not a migration

  `ops/deploy.sh` runs `Ecto.Migrator.run(:up, all: true)` on every deploy from
  `main`. A backfill that deletes data does not belong on that path: merging it
  would destroy the manifests automatically, with no separate decision and no
  moment to take a dump first. It runs when someone asks it to:

      bin/portal eval 'Portal.Catalog.ManifestBackfill.run(dry_run: true)'
      bin/portal eval 'Portal.Catalog.ManifestBackfill.run()'

  or locally through `mix portal.strip_manifests`.

  ## Disk is not returned automatically

  Rewriting a row leaves its old TOAST tuple dead. Plain `VACUUM` marks that
  space reusable by the same table but does not hand it back to the filesystem,
  so `pg_database_size` will barely move. Reclaiming it needs `VACUUM FULL` or
  `pg_repack` on `catalog_system_results`, which is a separate, deliberate
  operation: `VACUUM FULL` takes an `ACCESS EXCLUSIVE` lock and needs room for a
  full second copy of the table while it runs. Production Postgres is a
  container shared with several unrelated apps, so that is a maintenance-window
  decision, not something this function should take on its own.

  ## Safety

  The update is idempotent — its predicate matches only rows that still carry a
  manifest, so a second run finds nothing and an interrupted run resumes where
  it stopped. Batches are committed one at a time rather than held in a single
  transaction, so a 9,000-row pass never sits on a long-lived snapshot.
  """

  require Logger

  alias Portal.Repo

  @default_batch_size 200

  # A row still needs work if any of its dependency scans has an object
  # `footprint` carrying a `file_manifest` key. `->` on a non-object (the
  # `%{"__errors__" => [...]}` map the worker emits on scan failure holds an
  # array) yields NULL rather than raising, so those rows simply do not match.
  @predicate """
  t.dependency_scans IS NOT NULL
    AND jsonb_typeof(t.dependency_scans) = 'object'
    AND EXISTS (
      SELECT 1
      FROM jsonb_each(t.dependency_scans) AS e
      WHERE jsonb_typeof(e.value->'footprint') = 'object'
        AND jsonb_exists(e.value->'footprint', 'file_manifest')
    )
  """

  @strip_sql """
  UPDATE catalog_system_results AS sr
  SET dependency_scans = s.stripped
  FROM (
    SELECT t.id,
           (
             SELECT jsonb_object_agg(
                      e.key,
                      CASE
                        WHEN jsonb_typeof(e.value->'footprint') = 'object'
                        THEN jsonb_set(
                               e.value,
                               '{footprint}',
                               (e.value->'footprint') - 'file_manifest'
                             )
                        ELSE e.value
                      END
                    )
             FROM jsonb_each(t.dependency_scans) AS e
           ) AS stripped
    FROM catalog_system_results AS t
    WHERE #{@predicate}
    ORDER BY t.id
    LIMIT $1
  ) AS s
  WHERE sr.id = s.id
  """

  @count_sql """
  SELECT count(*),
         COALESCE(SUM(manifest_bytes), 0)
  FROM catalog_system_results AS t
  CROSS JOIN LATERAL (
    SELECT COALESCE(
             SUM(octet_length(COALESCE(e.value->'footprint'->'file_manifest', 'null'::jsonb)::text)),
             0
           ) AS manifest_bytes
    FROM jsonb_each(t.dependency_scans) AS e
  ) AS m
  WHERE #{@predicate}
  """

  @type report :: %{
          rows: non_neg_integer(),
          batches: non_neg_integer(),
          manifest_bytes: non_neg_integer(),
          dry_run: boolean()
        }

  @doc """
  Strip stored file manifests.

  Options:

    * `:batch_size` - rows rewritten per statement (default `#{@default_batch_size}`)
    * `:dry_run` - report what would be rewritten and change nothing

  Returns `{:ok, report}`. `:manifest_bytes` is the uncompressed JSON the
  manifests occupy *before* the pass, which is what a dry run is for; it is not
  the disk the database gives back (see the moduledoc).
  """
  @spec run(keyword()) :: {:ok, report()}
  def run(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    dry_run? = Keyword.get(opts, :dry_run, false)

    %Postgrex.Result{rows: [[pending, manifest_bytes]]} = Repo.query!(@count_sql, [])

    if dry_run? do
      Logger.info(
        "ManifestBackfill dry run: #{pending} rows carry #{bytes(manifest_bytes)} of manifests"
      )

      {:ok, %{rows: pending, batches: 0, manifest_bytes: manifest_bytes, dry_run: true}}
    else
      {rows, batches} = strip_batches(batch_size, 0, 0)

      Logger.info(
        "ManifestBackfill stripped #{rows} rows in #{batches} batches, " <>
          "#{bytes(manifest_bytes)} of manifest JSON"
      )

      {:ok, %{rows: rows, batches: batches, manifest_bytes: manifest_bytes, dry_run: false}}
    end
  end

  defp strip_batches(batch_size, rows, batches) do
    case Repo.query!(@strip_sql, [batch_size]) do
      %Postgrex.Result{num_rows: 0} ->
        {rows, batches}

      %Postgrex.Result{num_rows: n} ->
        strip_batches(batch_size, rows + n, batches + 1)
    end
  end

  defp bytes(n) when n < 1_048_576, do: "#{div(n, 1024)} KB"
  defp bytes(n), do: "#{Float.round(n / 1_048_576, 1)} MB"
end
