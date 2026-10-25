defmodule Portal.Catalog.ManifestModeRepair do
  @moduledoc """
  Copies each file's real mode from a run's footprint into the manifest its
  system results publish.

  The worker's beam scan recorded `mode` 0644 for every archived file, while
  the run footprint (`catalog_runs.footprint["per_system"][system]
  ["file_manifest"]`) kept what `File.stat/1` saw. The precompiled manifests
  are rendered from the beam scan's `footprint.file_manifest`, so executables
  under `priv/` (port binaries, scripts) were published without their
  executable bit and a client's `chmod` left them unrunnable on the device.

  For every system result of a non-revoked run with a non-empty published
  `priv/` list, each `ebin/` and `priv/` entry is looked up by `path` and
  `sha256` in that system's footprint manifest, and where the footprint holds
  a different integer mode the entry takes it. The real mode is stored as is;
  `Portal.Catalog` reduces it to 0644 or 0755 when it publishes. A result whose
  run footprint has no entry for its system (runs older than per-system
  footprints) is skipped and counted.

  It runs once, from the admin Maintenance page (`Portal.Workers.ManifestModeRepair`),
  or by hand:

      bin/portal eval 'Portal.Catalog.ManifestModeRepair.run(dry_run: true)'

  ## Safety

  Results are read in id order, 200 per batch, and each batch's updates
  commit in one transaction. An update only lands while the stored manifest is
  still the one the repair read, so a concurrent rewrite is never overwritten.
  A second run finds every mode already equal and updates nothing. Clients see
  the repair with the next signed batch (`Portal.Workers.PrecompiledBatch`,
  every 15 minutes).
  """

  require Logger

  alias Portal.Repo

  @batch_size 200
  @first_id "00000000-0000-0000-0000-000000000000"

  @select_sql """
  SELECT sr.id,
         sr.beam_scan->'footprint'->'file_manifest',
         r.footprint->'per_system'->sr.system_pkg->'file_manifest'
  FROM catalog_system_results AS sr
  JOIN catalog_runs AS r ON r.id = sr.run_id
  WHERE r.revoked_at IS NULL
    AND jsonb_typeof(r.footprint->'per_system') = 'object'
    AND jsonb_typeof(sr.beam_scan->'footprint'->'file_manifest'->'priv') = 'array'
    AND sr.beam_scan->'footprint'->'file_manifest'->'priv' <> '[]'::jsonb
    AND sr.id > $1
  ORDER BY sr.id
  LIMIT $2
  """

  @update_sql """
  UPDATE catalog_system_results
  SET beam_scan = jsonb_set(beam_scan, '{footprint,file_manifest}', $1::jsonb)
  WHERE id = $2
    AND beam_scan->'footprint'->'file_manifest' = $3::jsonb
  """

  @type report :: %{
          results_scanned: non_neg_integer(),
          results_updated: non_neg_integer(),
          results_skipped: non_neg_integer(),
          files_updated: non_neg_integer(),
          by_mode: %{integer() => pos_integer()},
          dry_run: boolean()
        }

  @doc """
  Repairs published file modes.

  Options:

    * `:dry_run` - count what would change and write nothing (default `false`)
    * `:limit` - scan at most this many system results (default: all)

  Returns the report it logs. `by_mode` counts the repaired files by the mode
  they now carry.
  """
  @spec run(keyword()) :: report()
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    limit = Keyword.get(opts, :limit)

    report =
      batches(@first_id, limit, dry_run?, %{
        results_scanned: 0,
        results_updated: 0,
        results_skipped: 0,
        files_updated: 0,
        by_mode: %{},
        dry_run: dry_run?
      })

    Logger.info(
      "ManifestModeRepair#{if dry_run?, do: " dry run"}: scanned #{report.results_scanned} " <>
        "results, #{if dry_run?, do: "would update", else: "updated"} #{report.results_updated} " <>
        "(#{report.files_updated} files, by mode #{inspect(report.by_mode)}), " <>
        "skipped #{report.results_skipped} without a footprint for their system"
    )

    report
  end

  defp batches(_after_id, 0, _dry_run?, report), do: report

  defp batches(after_id, limit, dry_run?, report) do
    size = if limit, do: min(limit, @batch_size), else: @batch_size

    case Repo.query!(@select_sql, [Ecto.UUID.dump!(after_id), size]).rows do
      [] ->
        report

      rows ->
        report = repair_batch(rows, dry_run?, report)
        [last_id | _] = List.last(rows)
        batches(Ecto.UUID.load!(last_id), limit && limit - length(rows), dry_run?, report)
    end
  end

  defp repair_batch(rows, dry_run?, report) do
    work = fn ->
      Enum.reduce(rows, report, fn row, acc -> repair_row(row, dry_run?, acc) end)
    end

    if dry_run? do
      work.()
    else
      {:ok, report} = Repo.transaction(work)
      report
    end
  end

  defp repair_row([_id, _published, built], _dry_run?, report)
       when not is_map(built) do
    %{
      report
      | results_scanned: report.results_scanned + 1,
        results_skipped: report.results_skipped + 1
    }
  end

  defp repair_row([id, published, built], dry_run?, report) do
    report = %{report | results_scanned: report.results_scanned + 1}
    modes = built_modes(built)

    {repaired, changed} =
      Enum.reduce(["ebin", "priv"], {published, []}, fn key, {manifest, changed} ->
        case Map.get(manifest, key) do
          entries when is_list(entries) ->
            {entries, key_changed} = repair_entries(entries, modes)
            {Map.put(manifest, key, entries), changed ++ key_changed}

          _ ->
            {manifest, changed}
        end
      end)

    cond do
      changed == [] -> report
      dry_run? or updated?(id, repaired, published) -> count(report, changed)
      true -> report
    end
  end

  defp updated?(id, repaired, published) do
    %Postgrex.Result{num_rows: n} = Repo.query!(@update_sql, [repaired, id, published])
    n == 1
  end

  defp count(report, changed) do
    %{
      report
      | results_updated: report.results_updated + 1,
        files_updated: report.files_updated + length(changed),
        by_mode: Enum.reduce(changed, report.by_mode, &Map.update(&2, &1, 1, fn n -> n + 1 end))
    }
  end

  # `{path, sha256} => mode` over both of the footprint's lists, integers only.
  defp built_modes(built) do
    for key <- ["ebin", "priv"],
        entries = Map.get(built, key),
        is_list(entries),
        %{"path" => path, "sha256" => sha, "mode" => mode} <- entries,
        is_integer(mode),
        into: %{},
        do: {{path, sha}, mode}
  end

  defp repair_entries(entries, modes) do
    Enum.map_reduce(entries, [], fn
      %{"path" => path, "sha256" => sha} = entry, changed ->
        mode = Map.get(modes, {path, sha})

        if is_integer(mode) and mode != entry["mode"],
          do: {Map.put(entry, "mode", mode), [mode | changed]},
          else: {entry, changed}

      entry, changed ->
        {entry, changed}
    end)
  end
end
