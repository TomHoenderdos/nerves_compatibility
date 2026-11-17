defmodule Portal.Catalog.SystemVersionBackfill do
  @moduledoc """
  Gives passing target results recorded without a `system_version` the
  version they were built against, where that version is proven, and
  counts the rest. Nothing runs this on its own: no job and no schedule
  calls it. The operator counts, reads the report, and acts.

  ## Why rows have no version

  Until `NccWorker.Worker.system_version/3` read it from the project's
  `mix.lock` (2026-11-03), the worker took a target's system version from
  the "Unchanged:" listing a per-target `mix deps.get` printed. Hex 2.6.0
  (published 2026-10-23) stopped printing that listing, and the worker
  image installs the newest Hex at build time, so every image built after
  it recorded no version for any target. Those images ran from 2026-10-25
  until the fixed image replaced them on 2026-11-04. A row without a
  version matches no precompiled client.

  ## What is proven

  Nothing the portal kept names the version: `result.json` lives only in
  the scratch dir, the run's `deps_lock` is the package's closure, which
  leaves the systems out, and the log tail of a pass is Hex 2.6.0's
  listing, which names none. What is known is when the build ran and how
  its lock was made: a fresh `mix nerves.new` project with no `mix.lock`,
  resolved by `mix deps.get`, which picks the highest version of each
  system its requirements allow. A row is filled with release `V` of its
  system only when all of these hold:

    1. **Timeline.** The build ran between `lo` and `hi`: the earlier of
       the building run's `finished_at` and `inserted_at`, less a day (a
       build's ceiling is `Portal.Builder.total_timeout_ms/0`, two hours),
       and the later of the two, plus an hour. No release of the system
       was published between those (hex.pm's own publication times,
       `Portal.HexPm.release_times/2`), so the releases the resolution
       could see are exactly those published before `lo`, and `V` is the
       highest of them, neither a pre-release nor retired.
    2. **Closure.** Nothing in the build could ask for another release:
       the package is not itself a Nerves system or toolchain, and neither
       the run's closure nor the row's own optional-dependency lock names a
       `nerves_system_*` (`nerves_system_br` included) or
       `nerves_toolchain_*` package. Those are what a system release
       depends on besides `nerves`, which the worker pins exactly. A run
       without a recorded closure is not filled.
    3. **Corroboration.** Every resolution the catalog did record for the
       system whose own window (rule 1) places it on `V`, built by a run
       whose closure passes rule 2, chose `V`, and there is at least one.
       A value this backfill wrote is not a recorded resolution, so an
       earlier call's fills never vouch for a later call's.
       That checks the parts of the argument the portal cannot read back
       per row: the template's requirement, the Hex registry the build
       fetched, the worker's pins.

  The building run is the run a carried copy was carried from
  (`carried_from_run_id`), else the row's own. Every row that fails a rule
  stays NULL and is counted under its reason in `left_null`:
  `:hex_unavailable`, `:release_in_window`, `:newest_release_unusable`,
  `:no_closure`, `:closure_names_nerves`, `:uncorroborated`,
  `:contradicted`.

  ## Safety

    * `fill/1` counts unless given `dry_run: false`;
    * one call fills at most `limit:` rows (default 500), in id order,
      in one statement that re-checks each row is still a pass without a
      version, so it never overwrites a value;
    * it is idempotent: a filled row is no longer a candidate;
    * every row a call fills gets a `catalog_system_version_backfills`
      row with the value, its evidence and the call's `filled_at`;
      `backfills/0` lists them and `undo/1` sets the rows one call filled
      back to NULL, only where they still hold the value it wrote, with
      the copies a partial run carried from them since.

  A filled row changes its package's precompiled fingerprint, so the next
  signed batch (`Portal.Workers.PrecompiledBatch`) renders it.

  ## Operator commands (web host, through ops/portal-rpc.sh)

      Portal.Catalog.SystemVersionBackfill.fill()
      Portal.Catalog.SystemVersionBackfill.fill(dry_run: false, limit: 500)
      Portal.Catalog.SystemVersionBackfill.backfills()
      Portal.Catalog.SystemVersionBackfill.undo(~U[2026-11-17 12:00:00.000000Z])

  Repeat the second until it returns `{:filled, 0, _}`.
  """

  require Logger

  alias Portal.Repo

  @default_limit 500
  @before_margin_s 24 * 3600
  @after_margin_s 3600
  @rule "hex_timeline_v1"

  # `$X` is a jsonb value, read as an object or as `{}`, so a key test never
  # meets a scalar.
  @names_nerves "EXISTS (SELECT 1 FROM jsonb_object_keys(CASE WHEN jsonb_typeof($X) = 'object' " <>
                  "THEN $X ELSE '{}'::jsonb END) AS k(key) " <>
                  "WHERE k.key ~ '^nerves_(system|toolchain)_')"

  @nerves_closure "(p.name ~ '^nerves_(system|toolchain)_' OR " <>
                    String.replace(@names_nerves, "$X", "b.deps_lock") <>
                    " OR " <> String.replace(@names_nerves, "$X", "s.deps_lock") <> ")"

  # Passing target results without a version, with the window of the run
  # that built them and what their closure says.
  @candidates_sql """
  SELECT s.id, s.system_pkg,
         least(b.finished_at, b.inserted_at), greatest(b.finished_at, b.inserted_at),
         coalesce(jsonb_typeof(b.deps_lock) = 'object', false),
         #{@nerves_closure}
  FROM catalog_system_results s
  JOIN catalog_runs b ON b.id = coalesce(s.carried_from_run_id, s.run_id)
  JOIN catalog_packages p ON p.id = b.package_id
  WHERE s.status = 'pass' AND s.system_version IS NULL
    AND starts_with(s.system_pkg, 'nerves_system_')
  ORDER BY s.id
  """

  # The resolutions the catalog recorded for `$1`'s systems, by runs
  # inserted between `$2` and `$3` whose closure names no Nerves package;
  # carried copies repeat their builder's row and are left out, and so is a
  # value this backfill wrote and has not undone: it is the conclusion, not
  # evidence for it.
  @recorded_sql """
  SELECT s.system_pkg, s.system_version,
         least(b.finished_at, b.inserted_at), greatest(b.finished_at, b.inserted_at)
  FROM catalog_system_results s
  JOIN catalog_runs b ON b.id = s.run_id
  JOIN catalog_packages p ON p.id = b.package_id
  WHERE s.system_version IS NOT NULL AND s.carried_from_run_id IS NULL
    AND s.system_pkg = ANY($1)
    AND b.inserted_at >= $2 AND b.inserted_at <= $3
    AND jsonb_typeof(b.deps_lock) = 'object'
    AND NOT #{@nerves_closure}
    AND NOT EXISTS (SELECT 1 FROM catalog_system_version_backfills a
                    WHERE a.system_result_id = s.id AND a.undone_at IS NULL)
  """

  @fill_sql """
  WITH picked AS (
    SELECT * FROM unnest($1::uuid[], $2::text[], $3::jsonb[]) AS t(id, version, evidence)
  ), filled AS (
    UPDATE catalog_system_results s
    SET system_version = picked.version, updated_at = $4
    FROM picked
    WHERE s.id = picked.id AND s.system_version IS NULL AND s.status = 'pass'
    RETURNING s.id, s.system_pkg, s.system_version, picked.evidence
  )
  INSERT INTO catalog_system_version_backfills
    (system_result_id, system_pkg, system_version, evidence, filled_at)
  SELECT id, system_pkg, system_version, evidence, $4 FROM filled
  """

  @backfills_sql """
  SELECT filled_at, system_pkg || '@' || system_version, count(*),
         count(*) FILTER (WHERE undone_at IS NOT NULL)
  FROM catalog_system_version_backfills
  GROUP BY filled_at, system_pkg, system_version
  ORDER BY filled_at, 2
  """

  # The rows the fill at `$1` wrote, and the copies a partial run made of
  # one of them since (`Portal.Catalog.Ingestion` copies the version with
  # the row): a copy of the same build and system, holding the value, with
  # no audit row of its own. A build's rows were all NULL before a fill, so
  # such a copy has the value only from the fill.
  @undo_sql """
  WITH filled AS (
    SELECT a.system_result_id, a.system_pkg, a.system_version,
           coalesce(r.carried_from_run_id, r.run_id) AS built_by
    FROM catalog_system_version_backfills a
    JOIN catalog_system_results r ON r.id = a.system_result_id
    WHERE a.filled_at = $1 AND a.undone_at IS NULL
  ), restored AS (
    UPDATE catalog_system_results s
    SET system_version = NULL, updated_at = $2
    FROM filled f
    WHERE s.system_pkg = f.system_pkg AND s.system_version = f.system_version
      AND (s.id = f.system_result_id OR
           (s.carried_from_run_id = f.built_by AND
            NOT EXISTS (SELECT 1 FROM catalog_system_version_backfills o
                        WHERE o.system_result_id = s.id AND o.undone_at IS NULL)))
    RETURNING s.id
  ), marked AS (
    UPDATE catalog_system_version_backfills a
    SET undone_at = $2
    FROM restored
    WHERE a.system_result_id = restored.id AND a.filled_at = $1 AND a.undone_at IS NULL
    RETURNING a.id
  )
  SELECT (SELECT count(*) FROM restored), (SELECT count(*) FROM marked)
  """

  @type reason ::
          :hex_unavailable
          | :release_in_window
          | :newest_release_unusable
          | :no_closure
          | :closure_names_nerves
          | :uncorroborated
          | :contradicted

  @type report :: %{
          candidates: non_neg_integer(),
          provable: non_neg_integer(),
          by_version: %{String.t() => pos_integer()},
          left_null: %{reason() => pos_integer()},
          corroboration: %{String.t() => %{agree: non_neg_integer(), disagree: non_neg_integer()}}
        }

  @doc """
  Counts (the default) or fills the rows the moduledoc's rules prove.

  Options: `dry_run:` (`true`), `limit:` (#{@default_limit}, the most rows
  one call fills), `releases:` (a function from a system's name to
  `Portal.HexPm.release_times/2`'s answer, default that function).

  Returns `{:dry_run, report}` or `{:filled, rows, report}`, where `rows`
  counts the rows changed and `report` also carries `filled_at`, the value
  `undo/1` takes. `report` counts every candidate, by the version it is
  proven at (`by_version`, `"system@version"`) or the reason it stays NULL
  (`left_null`), and for each version the recorded resolutions that agree
  with or contradict it (`corroboration`).
  """
  @spec fill(keyword()) :: {:dry_run, report()} | {:filled, non_neg_integer(), map()}
  def fill(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    unless is_integer(limit) and limit > 0,
      do: raise(ArgumentError, "limit must be a positive integer, got: #{inspect(limit)}")

    releases = Keyword.get(opts, :releases, &Portal.HexPm.release_times/1)
    {report, proven} = prove(releases)

    if Keyword.get(opts, :dry_run, true) do
      {:dry_run, report}
    else
      {rows, at} = write(Enum.take(proven, limit))
      {:filled, rows, Map.put(report, :filled_at, at)}
    end
  end

  @doc """
  Every fill on record, grouped by its `filled_at`, oldest first:
  `%{filled_at, results, undone, by_version}`.
  """
  @spec backfills() :: [
          %{
            filled_at: DateTime.t(),
            results: pos_integer(),
            undone: non_neg_integer(),
            by_version: %{String.t() => pos_integer()}
          }
        ]
  def backfills do
    %{rows: rows} = Repo.query!(@backfills_sql, [])

    rows
    |> Enum.chunk_by(fn [at | _] -> at end)
    |> Enum.map(fn [[at | _] | _] = group ->
      %{
        filled_at: to_utc(at),
        results: group |> Enum.map(&Enum.at(&1, 2)) |> Enum.sum(),
        undone: group |> Enum.map(&Enum.at(&1, 3)) |> Enum.sum(),
        by_version: Map.new(group, fn [_at, key, n, _undone] -> {key, n} end)
      }
    end)
  end

  @doc """
  Sets the rows the fill at `filled_at` gave a version back to NULL, where
  they still hold the value it wrote, and marks their audit rows
  `undone_at`. A copy a partial run carried from one of those rows after
  the fill holds the value too, and goes back to NULL with it. Returns how
  many rows it set back, copies included.
  """
  @spec undo(DateTime.t() | NaiveDateTime.t()) :: {:restored, non_neg_integer()}
  def undo(%DateTime{} = filled_at), do: filled_at |> naive_utc() |> undo()

  def undo(%NaiveDateTime{} = filled_at) do
    %{rows: [[count, audited]]} = Repo.query!(@undo_sql, [filled_at, NaiveDateTime.utc_now()])

    Logger.warning(
      "restored #{count} system versions filled at #{filled_at} to NULL " <>
        "(#{audited} filled, #{count - audited} carried copies)"
    )

    {:restored, count}
  end

  # `{report, proven}`: `proven` is `[{id, version, evidence}]` in id order.
  defp prove(releases) do
    candidates = Repo.query!(@candidates_sql, [], timeout: :timer.minutes(5)).rows
    systems = candidates |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq()
    timelines = Map.new(systems, &{&1, releases.(&1)})

    judged =
      Enum.map(candidates, fn [id, system, lo, hi, closure?, names_nerves?] ->
        {id, system, judge(timelines[system], lo, hi, closure?, names_nerves?)}
      end)

    corroboration = corroborate(judged, timelines)

    {proven, left} =
      Enum.reduce(judged, {[], %{}}, fn
        {id, system, {:ok, version, evidence}}, {proven, left} ->
          case corroboration[key(system, version)] do
            %{agree: agree, disagree: 0} when agree > 0 ->
              evidence = Map.put(evidence, "corroborating", agree)
              {[{id, system, version, evidence} | proven], left}

            %{disagree: n} when n > 0 ->
              {proven, Map.update(left, :contradicted, 1, &(&1 + 1))}

            _ ->
              {proven, Map.update(left, :uncorroborated, 1, &(&1 + 1))}
          end

        {_id, _system, {:error, reason}}, {proven, left} ->
          {proven, Map.update(left, reason, 1, &(&1 + 1))}
      end)

    proven = Enum.reverse(proven)

    report = %{
      candidates: length(candidates),
      provable: length(proven),
      by_version: Enum.frequencies_by(proven, fn {_id, s, v, _e} -> key(s, v) end),
      left_null: left,
      corroboration: corroboration
    }

    {report, Enum.map(proven, fn {id, _s, v, e} -> {id, v, e} end)}
  end

  defp judge({:ok, releases}, lo, hi, closure?, names_nerves?) do
    with {:ok, version, evidence} <- timeline(releases, lo, hi) do
      cond do
        not closure? -> {:error, :no_closure}
        names_nerves? -> {:error, :closure_names_nerves}
        true -> {:ok, version, evidence}
      end
    end
  end

  defp judge(_unavailable, _lo, _hi, _closure?, _names_nerves?), do: {:error, :hex_unavailable}

  # The release a resolution between `lo` and `hi` picked, when only one
  # can have been the newest throughout.
  defp timeline(releases, lo, hi) do
    from = lo |> to_utc() |> DateTime.add(-@before_margin_s)
    to = hi |> to_utc() |> DateTime.add(@after_margin_s)

    {before, rest} = Enum.split_with(releases, &(DateTime.compare(&1.published_at, from) != :gt))
    inside? = Enum.any?(rest, &(DateTime.compare(&1.published_at, to) != :gt))
    newest = Enum.max_by(before, &Version.parse!(&1.version), Version, fn -> nil end)

    cond do
      inside? ->
        {:error, :release_in_window}

      is_nil(newest) or newest.retired or Version.parse!(newest.version).pre != [] ->
        {:error, :newest_release_unusable}

      true ->
        next = rest |> Enum.map(& &1.published_at) |> Enum.min(DateTime, fn -> nil end)

        {:ok, newest.version,
         %{
           "rule" => @rule,
           "window" => [DateTime.to_iso8601(from), DateTime.to_iso8601(to)],
           "published_at" => DateTime.to_iso8601(newest.published_at),
           "next_published_at" => next && DateTime.to_iso8601(next)
         }}
    end
  end

  # For each version a candidate is proven at, the recorded resolutions of
  # its system that rule 1 places on that version, split by whether they
  # chose it.
  defp corroborate(judged, timelines) do
    wanted =
      for {_id, system, {:ok, version, _e}} <- judged, uniq: true, do: {system, version}

    if wanted == [] do
      %{}
    else
      {from, to} = recorded_span(wanted, timelines)
      systems = wanted |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      empty = Map.new(wanted, fn {s, v} -> {key(s, v), %{agree: 0, disagree: 0}} end)

      %{rows: rows} =
        Repo.query!(@recorded_sql, [systems, from, to], timeout: :timer.minutes(5))

      Enum.reduce(rows, empty, &count_recorded(&1, &2, timelines))
    end
  end

  # One recorded resolution, counted under the version rule 1 places it on
  # when that is a version some candidate is proven at.
  defp count_recorded([system, recorded, lo, hi], acc, timelines) do
    with {:ok, releases} <- timelines[system],
         {:ok, version, _e} <- timeline(releases, lo, hi),
         %{} = counts <- acc[key(system, version)] do
      field = if recorded == version, do: :agree, else: :disagree
      Map.put(acc, key(system, version), Map.update!(counts, field, &(&1 + 1)))
    else
      _ -> acc
    end
  end

  # Runs inserted from the first wanted version's publication to a day after
  # the next release (or now), which holds every run rule 1 can place on one.
  defp recorded_span(wanted, timelines) do
    bounds =
      Enum.map(wanted, fn {system, version} ->
        {:ok, releases} = timelines[system]
        published = Enum.find(releases, &(&1.version == version)).published_at

        next =
          releases
          |> Enum.map(& &1.published_at)
          |> Enum.filter(&(DateTime.compare(&1, published) == :gt))
          |> Enum.min(DateTime, &DateTime.utc_now/0)

        {published, next}
      end)

    from = bounds |> Enum.map(&elem(&1, 0)) |> Enum.min(DateTime)
    to = bounds |> Enum.map(&elem(&1, 1)) |> Enum.max(DateTime) |> DateTime.add(@before_margin_s)
    {naive_utc(from), naive_utc(to)}
  end

  defp write([]), do: {0, DateTime.utc_now()}

  defp write(proven) do
    at = NaiveDateTime.utc_now()
    ids = Enum.map(proven, fn {id, _v, _e} -> id end)
    versions = Enum.map(proven, fn {_id, v, _e} -> v end)
    evidence = Enum.map(proven, fn {_id, _v, e} -> e end)

    %{num_rows: rows} = Repo.query!(@fill_sql, [ids, versions, evidence, at])
    Logger.warning("filled the system_version of #{rows} system results at #{at}")
    {rows, to_utc(at)}
  end

  defp key(system, version), do: system <> "@" <> version

  defp naive_utc(%DateTime{} = at),
    do: at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_naive()

  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
end
