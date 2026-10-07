defmodule Portal.Catalog do
  @moduledoc """
  Ash domain for compatibility data.

  Holds the package catalog, scan runs, per-system results, content-addressed
  build artifacts, and admin-editable package overrides. Populated by the
  builder Oban worker (Phase 3); read by the public LiveView/JSON surface.
  """

  use Ash.Domain

  require Ash.Query

  import Ecto.Query,
    only: [
      dynamic: 2,
      from: 2,
      group_by: 3,
      limit: 2,
      order_by: 2,
      select: 3,
      subquery: 1,
      where: 3
    ]

  alias Portal.Catalog.{
    Artifact,
    ArtifactMembership,
    FindingTriage,
    Cache,
    Package,
    PackageOverride,
    Run,
    SystemLog,
    SystemResult
  }

  alias Portal.Repo

  @statuses ~w(pass fail error skipped unknown)

  # Every read here names the columns it needs. `catalog_system_results` is
  # the largest table in the database: 843 MB on disk as of 2026-09-10, of
  # which 829 MB is TOAST, and 1,501 MB uncompressed once the
  # `dependency_scans` jsonb is decoded, against 54 MB for `beam_scan`. When
  # the dashboard was still folded in Elixir it loaded those blobs it never
  # rendered, decoding them into the heap several times per render, which is
  # what made a single page load cost gigabytes and run the node out of memory.
  #
  # `Portal.Catalog.Ingestion` no longer stores the `footprint.file_manifest`
  # that was 75% of `dependency_scans`, and `Portal.Catalog.ManifestBackfill`
  # removes it from rows written before that — so the figures above are an
  # upper bound once the backfill has been run. Naming columns is not
  # contingent on either: the remaining blob is still far larger than what
  # these queries render.
  @run_fields [
    :id,
    :run_id,
    :package_id,
    :version_tested,
    :overall_status,
    :finished_at,
    :inserted_at
  ]
  # Everything on a system result except the three jsonb blobs. The badge and
  # `latest_system_results/1` render status, the failure category and the log
  # tail; `dependency_scans` alone is 275 MB across the table and `beam_scan`
  # another 10 MB, and decoding either to answer "is this package passing?" is
  # the exact shape of the read that ran the node out of memory.
  @summary_fields [
    :id,
    :run_id,
    :system_pkg,
    :system_version,
    :status,
    :firmware_size_bytes,
    :duration_sec,
    :hex_version_tested,
    :log_path,
    :log_tail,
    :failure_category
  ]
  # The precompiled manifest is the one caller that genuinely needs `beam_scan`
  # — the file manifest lives inside it — and needs nothing else wide.
  @manifest_fields [:id, :run_id, :system_pkg, :beam_scan]
  @json_fields [
    :run_id,
    :system_pkg,
    :system_version,
    :status,
    :firmware_size_bytes,
    :hex_version_tested,
    :log_path
  ]

  resources do
    resource(Package)
    resource(Run)
    resource(SystemResult)
    resource(SystemLog)
    resource(Artifact)
    resource(ArtifactMembership)
    resource(PackageOverride)
    resource(FindingTriage)
  end

  @doc """
  Returns the schema-v2 `latest_by_pkg.json` shape from Catalog rows.
  """
  def latest_by_pkg_json(package_name \\ nil)

  # Only the whole-catalog form is memoized. It is the expensive one -- every
  # package, its latest run and that run's system results, folded in Elixir --
  # and nothing routed calls it any more: `/packages` reads a page at a time
  # through `Portal.Catalog.Browse`, and `/api/packages` was disabled on
  # 2026-10-06. It is kept, with `PortalWeb.CatalogApiController`, so that API
  # can come back. The
  # single-package form is a filtered read of one row, and caching it would key
  # the table by package name: the cache has no per-key eviction, so browsing
  # the catalog would leave an entry per package behind forever.
  def latest_by_pkg_json(nil) do
    Cache.fetch(:latest_by_pkg_json, fn -> compute_latest_by_pkg_json(nil) end)
  end

  def latest_by_pkg_json(package_name), do: compute_latest_by_pkg_json(package_name)

  defp compute_latest_by_pkg_json(package_name) do
    packages = packages(package_name)
    runs = latest_runs(packages)

    systems_by_run_id =
      runs
      |> Map.values()
      |> Enum.map(& &1.id)
      |> json_results_for_runs()
      |> Enum.group_by(& &1.run_id)

    package_entries =
      packages
      |> Enum.reduce(%{}, fn package, acc ->
        run = Map.get(runs, package.id)
        system_results = if run, do: Map.get(systems_by_run_id, run.id, []), else: []
        Map.put(acc, package.name, package_json(package, run, system_results))
      end)

    %{
      schema: 2,
      generated_at: generated_at(),
      packages: package_entries
    }
  end

  @doc """
  Returns the schema-v2 `stats.json` shape from Catalog rows.

  Counted in Postgres. This used to read every system result through Ash --
  47,455 rows on production on 2026-10-06 -- and fold them in Elixir, and a
  cold `GET /api/stats` took 15.1s. Grouped, the same answer is a few dozen
  rows.

  Still cached. The grouping touches every row of `catalog_system_results`,
  the widest table in the database: a plain scan of it takes ~70ms on
  production, and every `StatsLive` mount asks (as did `/api/stats` until it
  was disabled on 2026-10-06). `catalog_system_results_stats_index` covers the three grouped columns
  so the count can be an index-only scan, and the cache keeps even that off
  the request path.
  """
  def stats_json do
    Cache.fetch(:stats_json, &compute_stats_json/0)
  end

  defp compute_stats_json do
    groups =
      from(s in "catalog_system_results",
        group_by: [s.system_pkg, s.system_version, s.status],
        select: {s.system_pkg, s.system_version, s.status, count()}
      )
      |> Repo.all()

    %{
      schema: 2,
      generated_at: generated_at(),
      counts: counts(groups),
      # Assessments are verdicts, not systems; `counts` above still includes
      # them, as it always has for `host`.
      by_system:
        groups
        |> Enum.reject(fn {system_pkg, _, _, _} -> assessment_system?(system_pkg) end)
        |> Enum.group_by(fn {system_pkg, version, _, _} -> "#{system_pkg}@#{version}" end)
        |> Map.new(fn {key, rows} -> {key, counts(rows, false)} end),
      last_run_finished_at: iso8601(last_finished_at())
    }
  end

  @doc """
  Everything the dashboard renders.

  Each part is an aggregate Postgres computes over the latest run of every
  package (`latest_results/0`) or over the runs table, and only the answer
  crosses into the node. They used to be folded in Elixir from every package,
  its latest run and that run's system results, and `/` took ~1s on
  production while each rebuild held one of the pool's five connections.
  With 22,000 packages, 23,295 runs and 46,590 system results seeded
  locally, a cold `dashboard(3, 10)` went from ~1,380ms to ~170ms; most of
  what is left is the cluster entries and sample logs.

  Still cached: the page is mounted twice per visit and the numbers only move
  when a build lands.
  """
  def dashboard(cluster_limit \\ 3, recent_limit \\ 10) do
    Cache.fetch({:dashboard, cluster_limit, recent_limit}, fn ->
      compute_dashboard(cluster_limit, recent_limit)
    end)
  end

  defp compute_dashboard(cluster_limit, recent_limit) do
    %{
      counts: compute_package_status_counts(),
      clusters: compute_failure_clusters(cluster_limit),
      native: native_breakdown(),
      rates: pass_rate_per_system(),
      recent_pass: recent_runs(:pass, recent_limit),
      recent_fail: recent_runs(:fail, recent_limit),
      last_run: iso8601(last_finished_at())
    }
  end

  @doc """
  Returns the latest system results for a package, or `nil` if the package is unknown.
  """
  def latest_system_results(package_name) do
    case packages(package_name) do
      [package] ->
        case latest_runs([package]) |> Map.get(package.id) do
          nil -> []
          run -> summary_results_for_runs([run.id])
        end

      [] ->
        nil
    end
  end

  @doc """
  The argus result of the package's latest run, or nil. Its own query because
  `@run_fields` leaves `argus` out: every other reader of runs would otherwise
  load the findings for nothing.
  """
  def latest_argus(package_name) do
    with [package] <- packages(package_name),
         [run] <-
           Run
           |> Ash.Query.filter(package_id == ^package.id)
           |> Ash.Query.sort(finished_at: :desc, inserted_at: :desc)
           |> Ash.Query.select([:id, :argus])
           |> Ash.Query.limit(1)
           |> Ash.read!(domain: __MODULE__) do
      run.argus
    else
      _ -> nil
    end
  end

  @doc "Fingerprints of `package_name`'s findings an admin has triaged as ignored."
  def ignored_fingerprints(package_name) do
    from(t in "catalog_finding_triage",
      where: t.package_name == ^package_name and t.status == "ignored",
      select: t.fingerprint
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # error < warning < info, anything else last.
  defmacrop severity_rank(severity) do
    quote do
      fragment(
        "CASE ? WHEN 'error' THEN 0 WHEN 'warning' THEN 1 WHEN 'info' THEN 2 ELSE 3 END",
        unquote(severity)
      )
    end
  end

  # `finding.confidence` as a numeric (a `Decimal`) when it is a JSON number,
  # else NULL, so a missing value or a label sorts last instead of failing the
  # cast. numeric rather than float8: a jsonb number can exceed a double's
  # range, and that cast would raise "out of range" for the whole page.
  defmacrop confidence(finding) do
    quote do
      fragment(
        "CASE WHEN jsonb_typeof(?->'confidence') = 'number' THEN (?->'confidence')::numeric END",
        unquote(finding),
        unquote(finding)
      )
    end
  end

  @triage_defaults %{
    status: [:new, :confirmed],
    severity: ["error", "warning", "info"],
    analysis: nil,
    package: nil,
    include_stale: false,
    check: nil,
    sort: nil
  }
  @triage_statuses [:new, :confirmed, :false_positive, :reported, :ignored]
  @triage_status_order %{new: 0, confirmed: 1, reported: 2, false_positive: 3, ignored: 4}

  @doc """
  argus findings for the admin triage list, each with `stale?`: true when the
  package's latest run *in which argus ran* no longer reports it. A newer run
  where argus was skipped or failed says nothing about a finding. See
  `@triage_defaults` for the filters and their defaults.
  """
  def triage_list(filters \\ %{}) do
    {rows, _total} = triage_page(filters, nil)
    rows
  end

  @doc """
  `triage_list/1` capped at `limit` rows (nil for all), with the number of rows
  that matched before the cap. Filtering, the stale check and the order all run
  in Postgres; only the rows on the page are loaded, `finding` jsonb included.
  `filters.sort` is `:severity` (the default), `:package`, `:analysis`,
  `:confidence` or `:newest`.
  """
  def triage_page(filters, limit) do
    f = Map.merge(@triage_defaults, filters)
    scope = triage_scope(f)

    page =
      scope
      |> order_by(^triage_list_order(f.sort))
      |> then(&if(limit, do: limit(&1, ^limit), else: &1))
      |> select([t, l: l], {t.id, fragment("? IS DISTINCT FROM ?", l.id, t.last_seen_run_id)})
      |> Repo.all()
      |> Enum.map(fn {id, stale?} -> {Ecto.UUID.load!(id), stale?} end)

    total = if limit, do: Repo.aggregate(scope, :count), else: length(page)
    {load_triage_rows(page), total}
  end

  @doc """
  One row per argus check -- analysis, title and severity -- among the findings
  matching `filters`, counted in Postgres: findings, distinct packages and
  their names, a per-status breakdown, the highest numeric confidence and the
  latest change.
  `filters.sort` is `:count` (the default), `:severity`, `:package` (first
  package name), `:analysis`, `:confidence` or `:newest`.
  """
  def triage_checks(filters) do
    f = Map.merge(@triage_defaults, filters)

    f
    |> triage_scope()
    |> group_by([t], [t.analysis, t.title, t.severity])
    |> order_by(^triage_check_order(f.sort))
    |> select([t], %{
      analysis: t.analysis,
      title: t.title,
      severity: t.severity,
      count: count(t.id),
      packages: count(t.package_name, :distinct),
      package_names:
        fragment(
          "array_agg(DISTINCT ? COLLATE \"C\" ORDER BY ? COLLATE \"C\")",
          t.package_name,
          t.package_name
        ),
      confidence: max(confidence(t.finding)),
      new: filter(count(t.id), t.status == "new"),
      confirmed: filter(count(t.id), t.status == "confirmed"),
      false_positive: filter(count(t.id), t.status == "false_positive"),
      reported: filter(count(t.id), t.status == "reported"),
      ignored: filter(count(t.id), t.status == "ignored")
    })
    |> Repo.all()
    |> Enum.map(fn row ->
      {by_status, rest} = Map.split(row, @triage_statuses)
      Map.put(rest, :by_status, by_status)
    end)
  end

  @doc "Whether one triage row's package has a newer argus run that no longer reports it."
  def triage_stale?(%FindingTriage{package_name: name, last_seen_run_id: run_id}) do
    Map.get(latest_argus_run_ids([name]), name) != run_id
  end

  @doc "Non-stale triage rows per status, counted in Postgres."
  def triage_counts do
    counts =
      from(t in "catalog_finding_triage",
        join: p in "catalog_packages",
        on: p.name == t.package_name,
        join: l in subquery(latest_argus_runs()),
        on: l.package_id == p.id and l.id == t.last_seen_run_id,
        group_by: t.status,
        select: {t.status, count(t.id)}
      )
      |> Repo.all()
      |> Map.new()

    Map.new(@triage_status_order, fn {status, _} ->
      {status, Map.get(counts, Atom.to_string(status), 0)}
    end)
  end

  @doc """
  Sets an admin's verdict on one finding. A `:note` key absent from `attrs`
  leaves the note as it is, so a keyboard status change keeps what was written.
  """
  def triage!(id, attrs, admin) do
    FindingTriage
    |> Ash.get!(id, domain: __MODULE__)
    |> Ash.Changeset.for_update(
      :triage,
      attrs |> Map.take([:status, :note]) |> Map.put(:updated_by, admin.username)
    )
    |> Ash.update!(domain: __MODULE__)
  end

  @doc "One triage row with its `finding` and `stale?`, or nil."
  def triage_row(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        FindingTriage
        |> Ash.Query.filter(id == ^uuid)
        |> Ash.read_one!(domain: __MODULE__)
        |> then(&(&1 && %{triage: &1, stale?: triage_stale?(&1)}))

      :error ->
        nil
    end
  end

  @doc """
  Sets `attrs` on every finding of `check` (analysis, title and severity) that
  matches `filters` -- or, with `scope` `:new`, only those still `new`. Returns
  how many rows changed. A blank note leaves each row's note alone.
  """
  def triage_check!(filters, %{analysis: _, title: _, severity: _} = check, scope, attrs, admin)
      when scope in [:all, :new] do
    query = Map.merge(@triage_defaults, filters) |> Map.put(:check, check) |> triage_scope()
    query = if scope == :new, do: where(query, [t], t.status == "new"), else: query

    query
    |> select([t], t.id)
    |> Repo.all()
    |> Enum.map(&Ecto.UUID.load!/1)
    |> triage_many!(attrs, admin)
  end

  @doc """
  Sets `attrs` on the findings with these ids. The ids come from the browser,
  so anything that is not a UUID of an existing row is ignored. Returns how
  many rows changed; an unknown status changes none.
  """
  def triage_many!(ids, attrs, admin) do
    ids = ids |> List.wrap() |> Enum.flat_map(&uuid/1) |> Enum.uniq()
    status = Enum.find(@triage_statuses, &(Atom.to_string(&1) == to_string(attrs[:status])))
    triage_ids!(ids, status, attrs, admin)
  end

  defp triage_ids!([], _status, _attrs, _admin), do: 0
  defp triage_ids!(_ids, nil, _attrs, _admin), do: 0

  defp triage_ids!(ids, status, attrs, admin) do
    input =
      %{status: status, updated_by: admin.username}
      |> then(&if(attrs[:note] in [nil, ""], do: &1, else: Map.put(&1, :note, attrs[:note])))

    %Ash.BulkResult{status: :success, records: records} =
      FindingTriage
      |> Ash.Query.filter(id in ^ids)
      |> Ash.bulk_update!(:triage, input,
        domain: __MODULE__,
        strategy: [:atomic, :stream],
        return_records?: true,
        select: [:id]
      )

    length(records)
  end

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> [uuid]
      :error -> []
    end
  end

  defp uuid(_), do: []

  # Every triage read shares this: the filters, plus a left join to each
  # package's latest argus run that tells current findings from stale ones.
  defp triage_scope(f) do
    from(t in "catalog_finding_triage",
      left_join: p in "catalog_packages",
      on: p.name == t.package_name,
      left_join: l in subquery(latest_argus_runs()),
      as: :l,
      on: l.package_id == p.id,
      where: t.status in ^Enum.map(f.status, &Atom.to_string/1) and t.severity in ^f.severity
    )
    |> triage_where(:analysis, f.analysis)
    |> triage_where(:package, f.package)
    |> triage_where(:check, f.check)
    |> triage_where(:include_stale, f.include_stale)
  end

  defp triage_where(query, _key, nil), do: query
  defp triage_where(query, :package, ""), do: query
  defp triage_where(query, :analysis, analysis), do: where(query, [t], t.analysis == ^analysis)

  # strpos rather than LIKE so `%` and `_` in the search are literal.
  defp triage_where(query, :package, package),
    do: where(query, [t], fragment("strpos(?, ?) > 0", t.package_name, ^package))

  defp triage_where(query, :check, %{analysis: analysis, title: title, severity: severity}) do
    where(
      query,
      [t],
      t.analysis == ^analysis and t.title == ^title and t.severity == ^severity
    )
  end

  defp triage_where(query, :include_stale, true), do: query

  defp triage_where(query, :include_stale, false),
    do: where(query, [t, l: l], l.id == t.last_seen_run_id)

  # Every order ends on the id so a page is stable between renders.
  defp triage_list_order(sort) do
    severity = dynamic([t], severity_rank(t.severity))

    case sort do
      :package ->
        [asc: dynamic([t], t.package_name), asc: severity]

      :analysis ->
        [asc: dynamic([t], t.analysis), asc: severity, asc: dynamic([t], t.package_name)]

      :confidence ->
        [desc_nulls_last: dynamic([t], confidence(t.finding)), asc: severity]

      :newest ->
        [desc: dynamic([t], t.updated_at), desc: dynamic([t], t.inserted_at)]

      _severity ->
        [asc: severity, asc: dynamic([t], t.package_name)]
    end
    |> Kernel.++(asc: dynamic([t], t.title), asc: dynamic([t], t.id))
  end

  defp triage_check_order(sort) do
    count = dynamic([t], count(t.id))
    severity = dynamic([t], severity_rank(t.severity))

    case sort do
      :severity -> [asc: severity, desc: count]
      :package -> [asc: dynamic([t], min(t.package_name)), desc: count]
      :analysis -> [asc: dynamic([t], t.analysis)]
      :confidence -> [desc_nulls_last: dynamic([t], max(confidence(t.finding))), desc: count]
      :newest -> [desc: dynamic([t], max(t.updated_at))]
      _count -> [desc: count, asc: severity]
    end
    |> Kernel.++(asc: dynamic([t], t.analysis), asc: dynamic([t], t.title), asc: severity)
  end

  defp load_triage_rows([]), do: []

  defp load_triage_rows(page) do
    ids = Enum.map(page, &elem(&1, 0))

    rows =
      FindingTriage
      |> Ash.Query.filter(id in ^ids)
      |> Ash.read!(domain: __MODULE__)
      |> Map.new(&{&1.id, &1})

    for {id, stale?} <- page, row = rows[id], do: %{triage: row, stale?: stale?}
  end

  # Per package, the newest run whose argus result is `ok`; a run without a
  # finished_at sorts after every finished one (Postgres puts NULLs first under
  # DESC otherwise). DISTINCT ON keeps
  # it to one row per package in Postgres instead of loading run history.
  defp latest_argus_runs do
    from(r in "catalog_runs",
      where: fragment("?->>'status' = 'ok'", r.argus),
      distinct: r.package_id,
      order_by: [asc: r.package_id, desc_nulls_last: r.finished_at, desc: r.inserted_at],
      select: %{package_id: r.package_id, id: r.id}
    )
  end

  defp latest_argus_run_ids(names) do
    from(l in subquery(latest_argus_runs()),
      join: p in "catalog_packages",
      on: p.id == l.package_id,
      where: p.name in ^names,
      select: {p.name, l.id}
    )
    |> Repo.all()
    |> Map.new(fn {name, id} -> {name, Ecto.UUID.load!(id)} end)
  end

  @export_batch 200

  @doc """
  argus results as a lazy stream of string-keyed maps, one per run, for the
  admin NDJSON export.

  Options:

    * `:scope` -- `:latest` (default) is each package's newest run whose argus
      result is `ok`; `:all` is every run that carries an argus result,
      including `error` and `skipped`, so failure rates are visible.
    * `:since` -- a `DateTime`; only runs finished at or after it.
    * `:batch_size` -- rows per query (default #{@export_batch}).

  Pages by `(finished_at, id)` keyset rather than `Repo.stream/2`, which would
  hold one transaction open for the whole download. Each finding carries its
  `fingerprint` and the admin's current `triage` verdict, so the export is
  enough to compute false-positive rates per analysis and per argus version.
  """
  def argus_export(opts \\ []) do
    scope = Keyword.get(opts, :scope, :latest)
    since = Keyword.get(opts, :since)
    batch = Keyword.get(opts, :batch_size, @export_batch)

    Stream.resource(
      fn -> nil end,
      &export_page(&1, scope, since, batch),
      fn _ -> :ok end
    )
  end

  defp export_page(:done, _scope, _since, _batch), do: {:halt, :done}

  defp export_page(cursor, scope, since, batch) do
    case export_batch(scope, since, cursor, batch) do
      [] ->
        {:halt, :done}

      rows ->
        last = List.last(rows)
        next = if length(rows) < batch, do: :done, else: {last.sort_at, last.id}
        {export_lines(rows), next}
    end
  end

  defp export_batch(scope, since, cursor, batch) do
    from(r in "catalog_runs",
      join: p in "catalog_packages",
      on: p.id == r.package_id,
      where: not is_nil(r.argus),
      order_by: [asc: coalesce(r.finished_at, r.inserted_at), asc: r.id],
      limit: ^batch,
      select: %{
        id: type(r.id, Ecto.UUID),
        sort_at: type(coalesce(r.finished_at, r.inserted_at), :utc_datetime_usec),
        run_id: r.run_id,
        version: r.version_tested,
        finished_at: type(r.finished_at, :utc_datetime_usec),
        image_digest: r.image_digest,
        argus: r.argus,
        package: p.name
      }
    )
    |> export_scope(scope)
    |> then(fn q ->
      if since, do: where(q, [r], r.finished_at >= ^since), else: q
    end)
    |> then(fn
      q when is_nil(cursor) ->
        q

      q ->
        {at, id} = cursor

        where(
          q,
          [r],
          fragment(
            "(coalesce(?, ?), ?) > (?, ?)",
            r.finished_at,
            r.inserted_at,
            r.id,
            ^at,
            type(^id, Ecto.UUID)
          )
        )
    end)
    |> Repo.all()
  end

  defp export_scope(query, :all), do: query

  defp export_scope(query, :latest) do
    from([r, _p] in query,
      join: l in subquery(latest_argus_runs()),
      on: l.id == r.id
    )
  end

  defp export_lines(rows) do
    findings =
      Enum.flat_map(rows, fn row ->
        row.argus |> Map.get("findings") |> List.wrap() |> Enum.map(&{row.package, &1})
      end)

    fingerprints =
      for {package, %{} = f} <- findings, do: FindingTriage.fingerprint(package, f)

    triage =
      from(t in "catalog_finding_triage",
        where: t.fingerprint in ^Enum.uniq(fingerprints),
        select:
          {t.fingerprint, %{"status" => t.status, "note" => t.note, "updated_by" => t.updated_by}}
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(rows, fn row ->
      %{
        "package" => row.package,
        "package_version" => row.version,
        "run_id" => row.run_id,
        "finished_at" => row.finished_at && DateTime.to_iso8601(row.finished_at),
        "image_digest" => row.image_digest,
        "argus" => Map.drop(row.argus, ["findings"]),
        "findings" =>
          row.argus
          |> Map.get("findings")
          |> List.wrap()
          |> Enum.map(fn
            %{} = f ->
              fp = FindingTriage.fingerprint(row.package, f)
              Map.merge(f, %{"fingerprint" => fp, "triage" => Map.get(triage, fp)})

            other ->
              other
          end)
      }
    end)
  end

  @doc "Fetches the committed run and package name needed to resume ingest completion."
  def committed_run(run_id) do
    Run
    |> Ash.Query.filter(run_id == ^run_id)
    |> Ash.Query.select([:id, :run_id, :overall_status, :package_id])
    |> Ash.Query.load(package: [:name])
    |> Ash.read_one(domain: __MODULE__)
  end

  @doc """
  A package's hex.pm metadata: its author-declared links and its owners.

  Read straight from the row rather than folded into `latest_by_pkg_json/1`,
  for two reasons. That function's shape is the public JSON API, and this is
  presentation data the API has never promised. And it is cached on a TTL,
  which would mean a metadata refresh took up to the TTL to appear on the page
  it exists to fill in -- for one indexed single-row read, that is a bad trade.

  Returns `nil` for an unknown package, and `hex_meta_fetched_at: nil` for a
  known one nobody has fetched yet. The page needs to tell those apart from a
  package that genuinely declares no links.
  """
  @spec package_hex_meta(String.t()) :: map() | nil
  def package_hex_meta(package_name) when is_binary(package_name) do
    Package
    |> Ash.Query.filter(name == ^package_name)
    |> Ash.Query.select([:hex_links, :hex_owners, :hex_meta_fetched_at])
    |> Ash.read_one!(domain: __MODULE__)
    |> case do
      nil ->
        nil

      package ->
        %{
          links: package.hex_links || %{},
          owners: package.hex_owners || [],
          fetched_at: package.hex_meta_fetched_at
        }
    end
  end

  @doc """
  Returns the precompiled package manifest shape for a package.
  """
  def precompiled_manifest(package_name) do
    with [package] <- packages(package_name),
         runs when runs != [] <- runs_for_package(package.id),
         results when results != [] <- manifest_results_for_runs(Enum.map(runs, & &1.id)) do
      shas_by_system_result_id =
        results
        |> Enum.map(& &1.id)
        |> manifest_shas_for_system_results()

      versions = precompiled_versions(runs, results, shas_by_system_result_id)

      if versions == %{} do
        nil
      else
        %{
          versions: versions,
          updated_at:
            runs
            |> Enum.map(& &1.finished_at)
            |> Enum.reject(&is_nil/1)
            |> Enum.max(DateTime, fn -> nil end)
            |> iso8601()
        }
      end
    else
      _ -> nil
    end
  end

  @doc """
  Returns a stored artifact by SHA256, or `nil` if unknown.
  """
  def artifact_by_sha256(sha256) do
    Artifact
    |> Ash.Query.filter(sha256 == ^sha256)
    |> Ash.read!(domain: __MODULE__)
    |> List.first()
  end

  @doc """
  The stored build log for one system of a package's latest run.

  Resolves the same run the package page renders. Returns `:error` when the
  package, the system, or the log is missing — logs exist for failures only,
  and only for builds that ran after this feature shipped.
  """
  @spec system_log(String.t(), String.t()) :: {:ok, map()} | :error
  def system_log(package_name, system_pkg) do
    with [package] <- packages(package_name),
         %{} = run <- Map.get(latest_runs([package]), package.id),
         %{} = result <- system_result_for(run.id, system_pkg),
         %{} = log <- log_for_system_result(result.id) do
      {:ok,
       %{
         package_name: package_name,
         system_pkg: system_pkg,
         status: Atom.to_string(result.status),
         run_id: run.run_id,
         version_tested: run.version_tested,
         body: log.body,
         byte_size: log.byte_size,
         truncated: log.truncated
       }}
    else
      _ -> :error
    end
  end

  # System entries that are verdicts rather than builds: `NccWorker.Worker`'s
  # `pure_elixir` (host compile + inspection) and
  # `Portal.Catalog.RegistryAssessment`'s `registry_deps` (registry data only).
  # Neither is a Nerves system, and both are always `pass`, so any per-system
  # figure that counted them would show a phantom system at ~100%.
  @assessment_systems ~w(pure_elixir registry_deps)

  @doc """
  Whether `system_pkg` names an assessment (a compatibility verdict with no
  firmware build behind it) rather than a Nerves system.
  """
  @spec assessment_system?(String.t() | atom()) :: boolean()
  def assessment_system?(system_pkg), do: to_string(system_pkg) in @assessment_systems

  @doc """
  Whether `system_pkg` belongs in a per-system breakdown. False for
  assessments and for the synthetic `forced@...` placeholder.
  """
  @spec real_system?(String.t() | atom()) :: boolean()
  def real_system?(system_pkg) do
    not (synthetic_system?(system_pkg) or assessment_system?(system_pkg))
  end

  @doc "Per-system pass counts over the latest run of every package."
  def pass_rate_per_system do
    from([s, _r] in latest_results(),
      group_by: s.system_pkg,
      select: {s.system_pkg, count(), filter(count(), s.status == "pass")}
    )
    |> Repo.all()
    |> Enum.filter(fn {system_pkg, _, _} -> real_system?(system_pkg) end)
    |> Enum.map(fn {system_pkg, total, pass} ->
      %{system_pkg: system_pkg, pass: pass, total: total, rate: pass / total}
    end)
    |> Enum.sort_by(& &1.system_pkg)
  end

  # `forced@admin@unknown` is not a Nerves system. `NccWorker.Worker` emits it as
  # a placeholder when a package is skipped administratively -- retired, or a
  # language the builder will not attempt -- so that the run still carries one
  # system entry. Counting it here would put a permanent 0/279 row in a list
  # whose whole subject is how well each real system builds. The stats page
  # already drops it for the same reason.
  defp synthetic_system?(system_pkg) do
    String.starts_with?(to_string(system_pkg), "forced")
  end

  @doc """
  Most recently finished passing (:pass) or failing (:fail/:error) runs.

  One row per package, at its newest qualifying run. A package that gets
  re-checked often (jason, while the build pipeline was being tuned) would
  otherwise fill the whole list with its own history and hide every other
  package. Every run counts here, not only each package's latest.
  """
  def recent_runs(status, limit \\ 5) do
    wanted = if status == :pass, do: ["pass"], else: ["fail", "error"]

    newest_per_package =
      from(r in "catalog_runs",
        where: r.overall_status in ^wanted and not is_nil(r.finished_at),
        distinct: r.package_id,
        order_by: [asc: r.package_id, desc: r.finished_at, desc: r.inserted_at],
        select: %{
          package_id: r.package_id,
          version: r.version_tested,
          finished_at: r.finished_at,
          overall_status: r.overall_status
        }
      )

    from(r in subquery(newest_per_package),
      left_join: p in "catalog_packages",
      on: p.id == r.package_id,
      order_by: [desc: r.finished_at],
      limit: ^limit,
      select: %{
        package: p.name,
        version: r.version,
        finished_at: type(r.finished_at, :utc_datetime_usec),
        overall_status: r.overall_status
      }
    )
    |> Repo.all()
    |> Enum.map(&%{&1 | overall_status: String.to_existing_atom(&1.overall_status)})
  end

  @failure_meta %{
    "NIF built for wrong architecture" =>
      {"NIF built for wrong architecture",
       "A dependency's NIF was compiled for the host, not the Nerves target — the scrub-otp step rejects it at firmware-build time. Usually fixable by forcing a clean rebuild of the dep for the target."},
    "Precompiled NIF missing for target" =>
      {"Precompiled NIF missing for this target",
       "The package ships a precompiled NIF but no build exists for the Nerves target triple. The package vendor would need to add the triple to their release."},
    "Dependency resolution failed" =>
      {"Dependency resolution failed",
       "A dependency could not be resolved or fetched. Often a version skew or a git/path dep that Hex can't satisfy."},
    "Compilation error" =>
      {"Compilation error",
       "The package's own source failed to compile — often a syntax issue triggered by a newer Elixir, or a missing macro dependency."},
    "Other / unclassified" =>
      {"Other / unclassified",
       "Build failures that don't match a known pattern. See the representative log for the specific cause."}
  }

  @doc "One bucket per package via Rollup.overall_status over its latest run's systems."
  def package_status_counts do
    Cache.fetch(:package_status_counts, &compute_package_status_counts/0)
  end

  # `Portal.Catalog.Rollup.overall_status/1` in SQL: the WHENs are its `cond`
  # clauses, in the same order. A package whose latest run has no system
  # results has no row here, and is not counted, as before.
  defp compute_package_status_counts do
    buckets =
      from([s, r] in latest_results(),
        group_by: r.package_id,
        select: %{
          bucket:
            fragment(
              """
              CASE
                WHEN bool_or(? IN ('fail', 'error')) THEN 'fail'
                WHEN bool_and(? = 'pass') THEN 'pass'
                WHEN bool_and(? = 'skipped') THEN 'skipped'
                WHEN bool_or(? = 'pass') THEN 'partial'
                ELSE 'unknown'
              END
              """,
              s.status,
              s.status,
              s.status,
              s.status
            )
        }
      )

    counted =
      from(b in subquery(buckets), group_by: b.bucket, select: {b.bucket, count()})
      |> Repo.all()
      |> Map.new()

    %{
      unique: counted |> Map.values() |> Enum.sum(),
      pass: Map.get(counted, "pass", 0),
      fail: Map.get(counted, "fail", 0),
      partial: Map.get(counted, "partial", 0),
      skipped: Map.get(counted, "skipped", 0),
      unknown: Map.get(counted, "unknown", 0)
    }
  end

  @doc "Non-pass systems grouped by failure_category with occurrence + distinct-package counts."
  def failure_clusters(limit \\ 10) do
    Cache.fetch({:failure_clusters, limit}, fn -> compute_failure_clusters(limit) end)
  end

  # Three queries: the ranked categories, the entries of the ones that made the
  # cut, and one sample log per category. A tie in `systems` goes to the
  # category that sorts first by bytes, which is the order the Elixir fold
  # this replaced gave (`Enum.group_by/2` into a small map, then a stable
  # sort).
  defp compute_failure_clusters(limit) do
    ranked =
      from([s, r] in failing_latest_results(),
        group_by: s.failure_category,
        order_by: [
          desc: selected_as(:systems),
          asc: fragment("? COLLATE \"C\"", s.failure_category)
        ],
        limit: ^limit,
        select: %{
          category: s.failure_category,
          systems: selected_as(count(), :systems),
          packages: count(r.package_id, :distinct)
        }
      )
      |> Repo.all()

    categories = Enum.map(ranked, & &1.category)
    entries = cluster_entries(categories)
    samples = sample_logs(categories)

    Enum.map(ranked, fn %{category: category} = cluster ->
      {title, hint} =
        Map.get(@failure_meta, category, {category, "Build failures in this category."})

      Map.merge(cluster, %{
        title: title,
        hint: hint,
        entries: Map.get(entries, category, []),
        sample_log: Map.get(samples, category)
      })
    end)
  end

  defp failing_latest_results do
    from([s, _r] in latest_results(),
      where: s.status in ["fail", "error"] and not is_nil(s.failure_category)
    )
  end

  defp cluster_entries([]), do: %{}

  defp cluster_entries(categories) do
    from([s, r] in failing_latest_results(),
      join: p in "catalog_packages",
      on: p.id == r.package_id,
      where: s.failure_category in ^categories,
      order_by: [asc: s.system_pkg, asc: p.name],
      select: {s.failure_category, p.name, s.hex_version_tested, s.system_pkg}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_, package, version, system_pkg} ->
      %{
        package: package,
        version: version,
        arch_label: Portal.Catalog.Architecture.label(system_pkg),
        nif_language: nil,
        detail: nil
      }
    end)
  end

  # The shortest non-empty log_tail in each cluster, last 40 lines.
  #
  # Chosen by Postgres, one row per category: the latest runs carried 29 MB of
  # log tails on production as of 2026-09-10, and a cluster shows one.
  #
  # `octet_length` rather than `String.length/1` because the two only disagree
  # on multi-byte input, where the byte count is the better proxy for "least
  # log to read" anyway.
  defp sample_logs([]), do: %{}

  defp sample_logs(categories) do
    from([s, _r] in failing_latest_results(),
      where: s.failure_category in ^categories,
      where: not is_nil(s.log_tail) and s.log_tail != "",
      distinct: s.failure_category,
      order_by: [asc: s.failure_category, asc: fragment("octet_length(?)", s.log_tail)],
      select: {s.failure_category, s.log_tail}
    )
    |> Repo.all()
    |> Map.new(fn {category, log} ->
      {category, log |> String.split("\n") |> Enum.take(-40) |> Enum.join("\n")}
    end)
  end

  @doc """
  Packages grouped by native implementation language (NIF + ports), plus a
  pure-Elixir bucket.

  Counted in Postgres rather than by reading every package's
  `native_components` blob into the node. A package lists its NIF language and
  its port languages; nulls are dropped, a package with none left is pure
  Elixir, and a package is counted once per language however often it lists
  it. A `port_languages` that is not a list counts as empty.
  """
  def native_breakdown do
    %{rows: rows} =
      Repo.query!("""
      SELECT coalesce(l.lang, 'Pure Elixir / none'), count(DISTINCT p.name)
      FROM catalog_packages p
      LEFT JOIN LATERAL (
        SELECT p.native_components ->> 'nif_language' AS lang
        UNION ALL
        SELECT jsonb_array_elements_text(
          CASE
            WHEN jsonb_typeof(p.native_components -> 'port_languages') = 'array'
            THEN p.native_components -> 'port_languages'
          END
        )
      ) l ON l.lang IS NOT NULL
      GROUP BY 1
      """)

    rows
    |> Enum.map(fn [language, packages] -> %{language: language, packages: packages} end)
    # Byte order, then a stable sort by count: how the Elixir fold this
    # replaced ordered ties.
    |> Enum.sort_by(& &1.language)
    |> Enum.sort_by(& &1.packages, :desc)
  end

  @doc """
  Name and last-run timestamp of every package, sorted by name.

  For `/sitemap.xml`, which needs one `<url>` per package and nothing else.
  Two columns rather than the row: `catalog_packages` also carries a
  description and a `native_components` blob the sitemap never looks at.
  """
  def package_slugs do
    Package
    |> Ash.Query.select([:name, :last_run_at])
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(domain: __MODULE__)
  end

  defp packages(nil) do
    Package
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(domain: __MODULE__)
  end

  defp packages(name) do
    Package
    |> Ash.Query.filter(name == ^name)
    |> Ash.read!(domain: __MODULE__)
  end

  defp latest_runs([]), do: %{}

  defp latest_runs(packages) do
    package_ids = Enum.map(packages, & &1.id)

    Run
    |> Ash.Query.filter(package_id in ^package_ids)
    |> Ash.Query.sort(finished_at: :desc, inserted_at: :desc)
    |> Ash.Query.select(@run_fields)
    |> Ash.read!(domain: __MODULE__)
    |> Enum.reduce(%{}, fn run, acc -> Map.put_new(acc, run.package_id, run) end)
  end

  # Named columns, like every other read here. Unselected, this loaded
  # `catalog_runs.log` — the whole `runner.log` of every run of the package —
  # for a caller that reads `id`, `version_tested` and `finished_at`.
  defp runs_for_package(package_id) do
    Run
    |> Ash.Query.filter(package_id == ^package_id)
    |> Ash.Query.sort(finished_at: :desc, inserted_at: :desc)
    |> Ash.Query.select(@run_fields)
    |> Ash.read!(domain: __MODULE__)
  end

  defp json_results_for_runs([]), do: []

  defp json_results_for_runs(run_ids) do
    SystemResult
    |> Ash.Query.filter(run_id in ^run_ids)
    |> Ash.Query.sort(system_pkg: :asc)
    |> Ash.Query.select(@json_fields)
    |> Ash.read!(domain: __MODULE__)
  end

  defp summary_results_for_runs(run_ids) do
    SystemResult
    |> Ash.Query.filter(run_id in ^run_ids)
    |> Ash.Query.sort(system_pkg: :asc)
    |> Ash.Query.select(@summary_fields)
    |> Ash.read!(domain: __MODULE__)
  end

  defp manifest_results_for_runs([]), do: []

  defp manifest_results_for_runs(run_ids) do
    SystemResult
    |> Ash.Query.filter(run_id in ^run_ids)
    |> Ash.Query.sort(system_pkg: :asc)
    |> Ash.Query.select(@manifest_fields)
    |> Ash.read!(domain: __MODULE__)
  end

  # Named columns: this table carries the dependency_scans and beam_scan blobs
  # and is the largest in the database, while this page renders neither. Every
  # other reader above does the same, so an unselected read of this table is now
  # the exception worth explaining rather than the default.
  defp system_result_for(run_id, system_pkg) do
    SystemResult
    |> Ash.Query.filter(run_id == ^run_id and system_pkg == ^system_pkg)
    |> Ash.Query.select([:id, :system_pkg, :status])
    |> Ash.read_one!(domain: __MODULE__)
  end

  defp log_for_system_result(system_result_id) do
    SystemLog
    |> Ash.Query.filter(system_result_id == ^system_result_id)
    |> Ash.read_one!(domain: __MODULE__)
  end

  # Which stored blobs each system result's manifest may publish, as a sha set
  # per system result id.
  #
  # This reads `catalog_artifact_memberships`, not `catalog_artifacts`. The
  # artifact table is a registry keyed by sha alone, so asking it "which blobs
  # belong to this system result?" can only ever return the ones that happened
  # to be ingested first — which silently emptied 72% of published manifests.
  # See `Portal.Catalog.ArtifactMembership`.
  defp manifest_shas_for_system_results([]), do: %{}

  defp manifest_shas_for_system_results(system_result_ids) do
    ArtifactMembership
    |> Ash.Query.filter(system_result_id in ^system_result_ids)
    |> Ash.Query.select([:system_result_id, :sha256])
    |> Ash.read!(domain: __MODULE__)
    |> Enum.group_by(& &1.system_result_id, & &1.sha256)
    |> Map.new(fn {id, shas} -> {id, MapSet.new(shas)} end)
  end

  defp package_json(package, run, system_results) do
    %{
      description: package.description,
      latest_version: package.latest_version,
      last_run_at: iso8601(package.last_run_at),
      native_components: package.native_components,
      systems:
        system_results
        |> Enum.map(fn result -> {system_key(result), system_result_json(result, run)} end)
        |> Map.new()
    }
  end

  defp system_result_json(result, run) do
    %{
      system_pkg: result.system_pkg,
      system_version: result.system_version,
      status: Atom.to_string(result.status),
      firmware_size_bytes: result.firmware_size_bytes,
      hex_version_tested: result.hex_version_tested,
      run_id: run && run.run_id,
      log_path: result.log_path
    }
  end

  defp precompiled_versions(runs, results, shas_by_system_result_id) do
    Enum.reduce(runs, %{}, fn run, acc ->
      run_results = Enum.filter(results, &(&1.run_id == run.id and &1.system_pkg != "host"))

      systems =
        precompiled_systems(run_results, shas_by_system_result_id)

      if systems == %{} do
        acc
      else
        Map.update(acc, run.version_tested, systems, &Map.merge(&1, systems))
      end
    end)
  end

  defp file_manifest(result, stored_shas) do
    manifest = get_in(result.beam_scan || %{}, ["footprint", "file_manifest"])

    if manifest do
      filtered = %{
        "ebin" => filter_manifest_entries(Map.get(manifest, "ebin", []), stored_shas),
        "priv" => filter_manifest_entries(Map.get(manifest, "priv", []), stored_shas)
      }

      if filtered["ebin"] == [] and filtered["priv"] == [], do: nil, else: filtered
    end
  end

  defp filter_manifest_entries(entries, stored_shas) do
    Enum.filter(entries, fn entry ->
      is_map(entry) and MapSet.member?(stored_shas, entry["sha256"])
    end)
  end

  # Over `{system_pkg, system_version, status, count}` groups.
  defp counts(groups, include_total? \\ true) do
    base = Map.new(@statuses, &{&1, 0})

    counted =
      Enum.reduce(groups, base, fn {_, _, status, n}, acc ->
        Map.update!(acc, status, &(&1 + n))
      end)

    if include_total?,
      do: Map.put(counted, "total", Enum.sum_by(groups, &elem(&1, 3))),
      else: counted
  end

  defp last_finished_at do
    from(r in "catalog_runs", select: type(max(r.finished_at), :utc_datetime_usec))
    |> Repo.one()
  end

  # The system results of every package's latest run, as `[s, r]`. Latest is
  # the rule `latest_runs/1` and `Portal.Catalog.Browse` apply -- newest
  # `finished_at`, then newest `inserted_at`; plain `DESC`, so an unfinished
  # run sorts first. Postgres 17 has no loose index scan for DISTINCT ON, so
  # it does not skip through `catalog_runs_package_latest_index` one package at
  # a time; on production-shaped data the planner reads `catalog_runs` with a
  # seq scan and a small sort, ~3ms.
  defp latest_results do
    latest =
      from(r in "catalog_runs",
        distinct: r.package_id,
        order_by: [asc: r.package_id, desc: r.finished_at, desc: r.inserted_at],
        select: %{id: r.id, package_id: r.package_id}
      )

    from(s in "catalog_system_results", join: r in subquery(latest), on: r.id == s.run_id)
  end

  defp system_key(result), do: "#{result.system_pkg}@#{result.system_version}"

  defp generated_at, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp precompiled_systems(run_results, shas_by_system_result_id) do
    Enum.reduce(run_results, %{}, fn result, system_acc ->
      stored_shas = Map.get(shas_by_system_result_id, result.id, MapSet.new())

      case file_manifest(result, stored_shas) do
        nil -> system_acc
        manifest -> Map.put(system_acc, result.system_pkg, manifest)
      end
    end)
  end
end
