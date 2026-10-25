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

  Every system result with a non-empty published `priv/` list is read, as long
  as neither the run that carries it nor the run that built it is revoked. A
  carried row (`carried_from_run_id`) reads the builder's footprint: the
  carrying partial run's footprint covers only the systems it rebuilt.

  Each published `ebin/` and `priv/` entry is looked up by `path` and `sha256`:

    * in the footprint's `per_system[system_pkg].file_manifest`, or
    * when the footprint has no entry for that system (runs whose footprint is
      keyed by target name, `rpi4`), in every `per_system` manifest and the
      top-level `file_manifest` together. A key whose entries disagree on the
      mode is left alone and counted in `files_conflicting`.

  A result with no footprint manifest to look in is skipped and counted.

  A row is rewritten only when a repaired mode publishes differently
  (`Portal.Catalog.publish_mode/1`): 0644 against 0664 is counted in
  `results_cosmetic` and left as is, sparing a rewrite of the TOASTed row.
  When a row is rewritten, every entry takes the footprint's raw mode.

  It runs once, from the admin Maintenance page (`Portal.Workers.ManifestModeRepair`),
  or by hand:

      bin/portal eval 'Portal.Catalog.ManifestModeRepair.run(dry_run: true)'

  ## Safety

  One query collects the ids to look at, then they are read and updated in
  chunks of 200, each chunk's updates in one transaction. An update only lands
  while the stored manifest is still the one the repair read, so a concurrent
  rewrite is never overwritten. A second run finds every mode already equal
  and updates nothing. Clients see the repair with the next signed batch
  (`Portal.Workers.PrecompiledBatch`, every 15 minutes).
  """

  require Logger

  alias Portal.{Catalog, Repo}

  @batch_size 200
  @progress_every 10

  @ids_sql """
  SELECT sr.id
  FROM catalog_system_results AS sr
  JOIN catalog_runs AS carrier ON carrier.id = sr.run_id
  JOIN catalog_runs AS r ON r.id = COALESCE(sr.carried_from_run_id, sr.run_id)
  WHERE carrier.revoked_at IS NULL
    AND r.revoked_at IS NULL
    AND jsonb_typeof(sr.beam_scan->'footprint'->'file_manifest'->'priv') = 'array'
    AND sr.beam_scan->'footprint'->'file_manifest'->'priv' <> '[]'::jsonb
  ORDER BY sr.id
  LIMIT $1
  """

  # The whole footprint only when the system's own entry is missing, for the
  # fallback; otherwise just that entry.
  @rows_sql """
  SELECT sr.id,
         sr.beam_scan->'footprint'->'file_manifest',
         r.footprint->'per_system'->sr.system_pkg->'file_manifest',
         CASE
           WHEN r.footprint->'per_system'->sr.system_pkg->'file_manifest' IS NULL
           THEN r.footprint
         END
  FROM catalog_system_results AS sr
  JOIN catalog_runs AS r ON r.id = COALESCE(sr.carried_from_run_id, sr.run_id)
  WHERE sr.id = ANY($1)
  ORDER BY sr.id
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
          results_cosmetic: non_neg_integer(),
          results_skipped: non_neg_integer(),
          results_fallback: non_neg_integer(),
          files_updated: non_neg_integer(),
          files_conflicting: non_neg_integer(),
          by_mode: %{integer() => pos_integer()},
          dry_run: boolean()
        }

  @doc """
  Repairs published file modes.

  Options:

    * `:dry_run` - count what would change and write nothing (default `false`)
    * `:limit` - a positive integer: look at most at this many system results
      (default: all)

  Returns the report it logs. `files_updated` and `by_mode` count the files of
  rewritten rows, by the raw mode they now carry.
  """
  @spec run(keyword()) :: report()
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    limit = Keyword.get(opts, :limit)

    unless is_nil(limit) or (is_integer(limit) and limit > 0) do
      raise ArgumentError, "limit must be a positive integer, got: #{inspect(limit)}"
    end

    ids = ids(limit)
    batches = Enum.chunk_every(ids, @batch_size)
    total = length(batches)

    report =
      batches
      |> Enum.with_index(1)
      |> Enum.reduce(empty_report(dry_run?), fn {chunk, n}, report ->
        report = repair_batch(chunk, dry_run?, report)

        if rem(n, @progress_every) == 0 do
          Logger.info("ManifestModeRepair: batch #{n}/#{total}, #{summary(report)}")
        end

        report
      end)

    Logger.info("ManifestModeRepair#{if dry_run?, do: " dry run"} done: #{summary(report)}")
    report
  end

  defp empty_report(dry_run?) do
    %{
      results_scanned: 0,
      results_updated: 0,
      results_cosmetic: 0,
      results_skipped: 0,
      results_fallback: 0,
      files_updated: 0,
      files_conflicting: 0,
      by_mode: %{},
      dry_run: dry_run?
    }
  end

  defp summary(report) do
    "scanned #{report.results_scanned} results, " <>
      "#{if report.dry_run, do: "would update", else: "updated"} #{report.results_updated} " <>
      "(#{report.files_updated} files, by mode #{inspect(report.by_mode)}), " <>
      "#{report.results_cosmetic} differing only in unpublished bits, " <>
      "#{report.results_fallback} matched across the footprint, " <>
      "#{report.files_conflicting} files with conflicting modes, " <>
      "skipped #{report.results_skipped} without a footprint manifest"
  end

  defp ids(limit) do
    # `LIMIT NULL` is no limit.
    Repo.query!(@ids_sql, [limit], timeout: :timer.minutes(10)).rows
    |> Enum.map(fn [id] -> id end)
  end

  defp repair_batch(ids, dry_run?, report) do
    rows = Repo.query!(@rows_sql, [ids]).rows

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

  defp repair_row([id, published, own, footprint], dry_run?, report) do
    report = %{report | results_scanned: report.results_scanned + 1}

    case modes(own, footprint) do
      :none ->
        %{report | results_skipped: report.results_skipped + 1}

      {how, modes} ->
        report =
          if how == :fallback,
            do: %{report | results_fallback: report.results_fallback + 1},
            else: report

        repair_manifest(id, published, modes, dry_run?, report)
    end
  end

  defp repair_manifest(id, published, modes, dry_run?, report) do
    {repaired, changed, conflicting} =
      Enum.reduce(["ebin", "priv"], {published, [], 0}, fn key, {manifest, changed, conflicts} ->
        case Map.get(manifest, key) do
          entries when is_list(entries) ->
            {entries, {key_changed, key_conflicts}} = repair_entries(entries, modes)
            {Map.put(manifest, key, entries), changed ++ key_changed, conflicts + key_conflicts}

          _ ->
            {manifest, changed, conflicts}
        end
      end)

    report = %{report | files_conflicting: report.files_conflicting + conflicting}

    published? =
      Enum.any?(changed, fn {old, new} ->
        Catalog.publish_mode(old) != Catalog.publish_mode(new)
      end)

    cond do
      changed == [] -> report
      not published? -> %{report | results_cosmetic: report.results_cosmetic + 1}
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
        by_mode:
          Enum.reduce(changed, report.by_mode, fn {_old, new}, acc ->
            Map.update(acc, new, 1, &(&1 + 1))
          end)
    }
  end

  # `{:own | :fallback, %{{path, sha256} => mode | :conflict}}`, or `:none`
  # when there is no footprint manifest to look in.
  defp modes(%{} = own, _footprint), do: {:own, mode_map([own])}

  defp modes(_own, %{} = footprint) do
    per_system =
      case footprint["per_system"] do
        %{} = systems -> for {_system, %{"file_manifest" => %{} = m}} <- systems, do: m
        _ -> []
      end

    top =
      case footprint["file_manifest"] do
        %{} = m -> [m]
        _ -> []
      end

    case per_system ++ top do
      [] -> :none
      manifests -> {:fallback, mode_map(manifests)}
    end
  end

  defp modes(_own, _footprint), do: :none

  defp mode_map(manifests) do
    for manifest <- manifests,
        key <- ["ebin", "priv"],
        entries = Map.get(manifest, key),
        is_list(entries),
        %{"path" => path, "sha256" => sha, "mode" => mode} <- entries,
        is_integer(mode),
        reduce: %{} do
      acc ->
        Map.update(acc, {path, sha}, mode, fn
          ^mode -> mode
          _other -> :conflict
        end)
    end
  end

  # `{entries, {[{old, new}], conflicts}}`
  defp repair_entries(entries, modes) do
    Enum.map_reduce(entries, {[], 0}, fn
      %{"path" => path, "sha256" => sha} = entry, {changed, conflicts} ->
        old = entry["mode"]

        case Map.get(modes, {path, sha}) do
          :conflict ->
            {entry, {changed, conflicts + 1}}

          mode when is_integer(mode) and mode != old ->
            {Map.put(entry, "mode", mode), {[{old, mode} | changed], conflicts}}

          _ ->
            {entry, {changed, conflicts}}
        end

      entry, acc ->
        {entry, acc}
    end)
  end
end
