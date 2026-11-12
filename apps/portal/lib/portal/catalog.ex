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
      select_merge: 2,
      subquery: 1,
      where: 3,
      windows: 3
    ]

  alias Portal.ArtifactStore

  alias Portal.Catalog.{
    Artifact,
    ArtifactMembership,
    BulkSweep,
    CoverageReport,
    FindingTriage,
    Cache,
    Package,
    PackageOverride,
    ReleaseDownloads,
    Run,
    RunMemory,
    SystemAbi,
    SystemLog,
    SystemResult,
    ToolchainBuild,
    UnrecordedOptionalDeps,
    VersionBackfill
  }

  alias Portal.Precompiled.Withheld
  alias Portal.Repo

  @statuses ~w(pass fail error skipped unknown)

  # The keys of a published file manifest, each the top directory its
  # entries' paths sit under.
  @manifest_keys ["ebin", "priv"]

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
    :failure_category,
    :carried_from_run_id
  ]
  # The precompiled manifest is the one caller that genuinely needs `beam_scan`
  # — the file manifest lives inside it — and needs nothing else wide.
  @manifest_fields [
    :id,
    :run_id,
    :system_pkg,
    :system_version,
    :beam_scan,
    :carried_from_run_id,
    :compile_env,
    :deps_lock,
    :unpublished_at,
    :compile_env_rule
  ]
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
    resource(BulkSweep)
    resource(ToolchainBuild)
    resource(ReleaseDownloads)
    resource(CoverageReport)
    resource(RunMemory)
    resource(SystemAbi)
  end

  @doc """
  Returns the schema-v2 `latest_by_pkg.json` shape from Catalog rows.
  """
  def latest_by_pkg_json(package_name \\ nil)

  # Only the whole-catalog form is memoized. It is the expensive one -- every
  # package, its latest run and that run's system results, folded in Elixir --
  # and only `/api/packages` asks for it (`/packages` reads a page at a time
  # through `Portal.Catalog.Browse`). The cache makes repeated hits share one
  # computation a minute, and `Portal.Catalog.Warmup` fills it at boot. The
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
  production, and every `StatsLive` mount and `/api/stats` hit asks.
  `catalog_system_results_stats_index` covers the three grouped columns
  so the count can be an index-only scan, and the cache keeps even that off
  the request path.

  Carried results are left out: a partial run copies the systems it did not
  rebuild from the previous run (`carried_from_run_id`), and counting those
  copies would add a result for every build nobody ran. The index is partial
  on the same condition, so the scan stays index-only.
  """
  def stats_json do
    Cache.fetch(:stats_json, &compute_stats_json/0)
  end

  defp compute_stats_json do
    groups =
      from(s in "catalog_system_results",
        where: is_nil(s.carried_from_run_id),
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
  The architecture each of the given runs built on, as `%{run_id => arch}`
  keyed by the runs' `run_id` strings; a run from before architectures were
  recorded is left out. The package page shows it beside each result.
  """
  @spec runs_arch([String.t()]) :: %{String.t() => String.t()}
  def runs_arch([]), do: %{}

  def runs_arch(run_ids) when is_list(run_ids) do
    Run
    |> Ash.Query.filter(run_id in ^run_ids and not is_nil(arch))
    |> Ash.Query.select([:run_id, :arch])
    |> Ash.read!(domain: __MODULE__)
    |> Map.new(&{&1.run_id, &1.arch})
  end

  @doc """
  When each of the given runs finished, as `%{run_id => finished_at}`. The
  package page uses it to date results carried from an earlier run.
  """
  def runs_finished_at([]), do: %{}

  def runs_finished_at(run_ids) when is_list(run_ids) do
    Run
    |> Ash.Query.filter(id in ^run_ids)
    |> Ash.Query.select([:id, :finished_at])
    |> Ash.read!(domain: __MODULE__)
    |> Map.new(&{&1.id, &1.finished_at})
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

  # A name in byte order. Every name in the triage orders sorts this way, as
  # the check rows' package lists do: under a locale collation (en_US.utf8 in
  # production) underscores and case are ignored at first, so a check's
  # first-listed package would not be the one it sorted by.
  defmacrop c_order(name) do
    quote do
      fragment("? COLLATE \"C\"", unquote(name))
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
    package_name: nil,
    type: nil,
    sort: nil
  }
  # The grouped sorts (by package, by type): a window over the group first --
  # its new findings or all of them -- then the order inside the groups.
  @grouped_list_sorts %{
    package_new: {:new, :package_name, :package},
    package_count: {:count, :package_name, :package},
    package_type: {:new, :package_name, :package_then_analysis},
    type_new: {:new, :analysis, :analysis},
    type_count: {:count, :analysis, :analysis}
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
  `:confidence` or `:newest`; or, grouped by package, `:package_new`,
  `:package_count` or `:package_type`; or, grouped by type, `:type_new` or
  `:type_count`.
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
  `triage_page/2` for a list grouped by `group` (`:package_name` or
  `:analysis`), capped at `per_group` rows *per group* rather than overall, so
  one big group cannot fill the page and leave the others out: every group
  with a matching finding keeps at least its first row. Groups and the rows
  inside them come in the same order `triage_page/2` gives them for
  `filters.sort`, which must be one of the grouped sorts or `:package` /
  `:analysis` for the matching `group`. The total is every matching row.
  """
  def triage_grouped_page(filters, group, per_group)
      when group in [:package_name, :analysis] and is_integer(per_group) and per_group > 0 do
    f = Map.merge(@triage_defaults, filters)
    scope = triage_scope(f)

    # A window's own ORDER BY cannot hold another window, so the rank inside
    # a group orders by the inner keys alone, and the group's weight (its new
    # or all findings) is carried out beside it for the outer order.
    {weight, inner} =
      case Map.fetch(@grouped_list_sorts, f.sort) do
        {:ok, {:new, ^group, inner}} -> {new_in(group), inner}
        {:ok, {:count, ^group, inner}} -> {count_in(group), inner}
        :error when f.sort in [:package, :analysis] -> {dynamic([t], fragment("0")), f.sort}
      end

    ranked =
      scope
      |> windows([t],
        in_group: [
          partition_by: ^[dynamic([t], field(t, ^group))],
          order_by:
            ^(list_order(inner) ++
                [asc: dynamic([t], c_order(t.title)), asc: dynamic([t], t.id)])
        ]
      )
      |> select([t, l: l], %{
        id: t.id,
        stale: fragment("? IS DISTINCT FROM ?", l.id, t.last_seen_run_id),
        group: field(t, ^group),
        rank: over(row_number(), :in_group)
      })
      |> select_merge(^%{weight: weight})

    # Ties on the weight fall to the group's name, as the inner keys of every
    # grouped sort lead with it; then the rank keeps each group's own order.
    page =
      from(r in subquery(ranked),
        where: r.rank <= ^per_group,
        order_by: [desc: r.weight, asc: c_order(r.group), asc: r.rank],
        select: {r.id, r.stale}
      )
      |> Repo.all()
      |> Enum.map(fn {id, stale?} -> {Ecto.UUID.load!(id), stale?} end)

    {load_triage_rows(page), Repo.aggregate(scope, :count)}
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

  @doc """
  Per package among the findings matching `filters`: how many there are, how
  many are new, and the version of the package's latest argus run -- or, for
  a package whose findings are all stale, the newest version they were seen
  in. One query, keyed by package name.
  """
  def triage_packages(filters) do
    f = Map.merge(@triage_defaults, filters)

    f
    |> triage_scope()
    |> group_by([t], t.package_name)
    |> select(
      [t, l: l],
      {t.package_name,
       %{
         count: count(t.id),
         new: filter(count(t.id), t.status == "new"),
         version: coalesce(max(l.version), max(t.last_seen_version))
       }}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Per analysis (argus's type) among the findings matching `filters`: how many
  there are, how many are new, and in how many packages. One query, keyed by
  analysis.
  """
  def triage_types(filters) do
    f = Map.merge(@triage_defaults, filters)

    f
    |> triage_scope()
    |> group_by([t], t.analysis)
    |> select(
      [t],
      {t.analysis,
       %{
         count: count(t.id),
         new: filter(count(t.id), t.status == "new"),
         packages: count(t.package_name, :distinct)
       }}
    )
    |> Repo.all()
    |> Map.new()
  end

  @filter_option_limit 50

  @doc """
  The values the triage page's type and package pickers offer: each analysis
  and each package with how many findings it has, most first, at most
  #{@filter_option_limit} each. Each list applies every filter except its
  own, so a count is what picking that value would show.
  """
  def triage_filter_options(filters) do
    f = Map.merge(@triage_defaults, filters)

    %{
      analyses: filter_option_counts(%{f | analysis: nil}, :analysis),
      packages: filter_option_counts(%{f | package: nil}, :package_name)
    }
  end

  defp filter_option_counts(f, column) do
    f
    |> triage_scope()
    |> group_by([t], field(t, ^column))
    |> order_by(^[desc: dynamic([t], count(t.id)), asc: dynamic([t], c_order(field(t, ^column)))])
    |> limit(@filter_option_limit)
    |> select([t], {field(t, ^column), count(t.id)})
    |> Repo.all()
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
    filters |> Map.put(:check, check) |> triage_matching!(scope, attrs, admin)
  end

  @doc """
  `triage_check!/5` for one package: every finding of `package_name` (an
  exact name, unlike the package search) that matches `filters`, or with
  `scope` `:new` only the new ones.
  """
  def triage_package!(filters, package_name, scope, attrs, admin)
      when is_binary(package_name) and scope in [:all, :new] do
    filters |> Map.put(:package_name, package_name) |> triage_matching!(scope, attrs, admin)
  end

  @doc """
  `triage_check!/5` for one type: every finding whose analysis is exactly
  `analysis` and that matches `filters`, or with `scope` `:new` only the new
  ones. The type is ANDed onto the filters, so a type filter still applies.
  """
  def triage_type!(filters, analysis, scope, attrs, admin)
      when is_binary(analysis) and scope in [:all, :new] do
    filters |> Map.put(:type, analysis) |> triage_matching!(scope, attrs, admin)
  end

  defp triage_matching!(filters, scope, attrs, admin) do
    query = @triage_defaults |> Map.merge(filters) |> triage_scope()
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
    |> triage_where(:package_name, f.package_name)
    |> triage_where(:type, f.type)
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

  defp triage_where(query, :package_name, name),
    do: where(query, [t], t.package_name == ^name)

  # The by-type group action's type, kept apart from the `analysis` filter so
  # the two AND rather than one replacing the other.
  defp triage_where(query, :type, analysis), do: where(query, [t], t.analysis == ^analysis)

  defp triage_where(query, :include_stale, true), do: query

  defp triage_where(query, :include_stale, false),
    do: where(query, [t, l: l], l.id == t.last_seen_run_id)

  # Every order ends on the id so a page is stable between renders.
  defp triage_list_order(sort) do
    case Map.fetch(@grouped_list_sorts, sort) do
      {:ok, {:new, column, inner}} -> [desc: new_in(column)] ++ list_order(inner)
      {:ok, {:count, column, inner}} -> [desc: count_in(column)] ++ list_order(inner)
      :error -> list_order(sort)
    end
    |> Kernel.++(asc: dynamic([t], c_order(t.title)), asc: dynamic([t], t.id))
  end

  defp list_order(sort) do
    severity = dynamic([t], severity_rank(t.severity))
    package = dynamic([t], c_order(t.package_name))
    analysis = dynamic([t], c_order(t.analysis))

    case sort do
      :package -> [asc: package, asc: severity]
      :analysis -> [asc: analysis, asc: severity, asc: package]
      :package_then_analysis -> [asc: package, asc: analysis, asc: severity]
      :confidence -> [desc_nulls_last: dynamic([t], confidence(t.finding)), asc: severity]
      :newest -> [desc: dynamic([t], t.updated_at), desc: dynamic([t], t.inserted_at)]
      _severity -> [asc: severity, asc: package]
    end
  end

  # New findings in the row's group (its package or its type), over the rows
  # the filters keep: a window rather than a join, so the list stays one query.
  defp new_in(column) do
    dynamic(
      [t],
      fragment(
        "count(*) FILTER (WHERE ? = 'new') OVER (PARTITION BY ?)",
        t.status,
        field(t, ^column)
      )
    )
  end

  defp count_in(column) do
    dynamic([t], fragment("count(*) OVER (PARTITION BY ?)", field(t, ^column)))
  end

  defp triage_check_order(sort) do
    count = dynamic([t], count(t.id))
    severity = dynamic([t], severity_rank(t.severity))
    analysis = dynamic([t], c_order(t.analysis))

    case sort do
      :severity -> [asc: severity, desc: count]
      :package -> [asc: dynamic([t], min(c_order(t.package_name))), desc: count]
      :analysis -> [asc: analysis, asc: severity, desc: count]
      :confidence -> [desc_nulls_last: dynamic([t], max(confidence(t.finding))), desc: count]
      :newest -> [desc: dynamic([t], max(t.updated_at))]
      _count -> [desc: count, asc: severity]
    end
    |> Kernel.++(asc: analysis, asc: dynamic([t], c_order(t.title)), asc: severity)
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
      select: %{package_id: r.package_id, id: r.id, version: r.version_tested}
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
  Returns the precompiled package manifest shape for a package (format 1,
  `versions[v][target] = entry`), or `nil` when it has nothing to publish.
  """
  @spec precompiled_manifest(String.t()) :: map() | nil
  def precompiled_manifest(package_name) do
    case precompiled_sources(package_name) do
      nil -> nil
      sources -> manifest_v1(sources)
    end
  end

  @doc """
  Returns the format-2 manifest of a package (`versions[v]["builds"]`, a build
  list; see `PRECOMPILED_API.md`), or `nil` when it has nothing to publish.

  Its builds are every run result format 1 publishes, and every passing,
  unrevoked `Portal.Catalog.ToolchainBuild` whose files this host holds. A
  build without `elixir`, `otp`, `deps`, `package_checksum` or `compile_env`
  is left out: a client cannot match it. One build is kept per target,
  toolchain (`"<elixir minor>/<otp>"`), system version, dependency lock and
  config variant, the newest. A named config variant of a toolchain build
  carries `build["config_variant"]` and is listed only beside its served
  default build (`Portal.Precompiled.Withheld.config_variant_served?/2`).
  """
  @spec precompiled_manifest_v2(String.t()) :: map() | nil
  def precompiled_manifest_v2(package_name) do
    case precompiled_sources(package_name) do
      nil -> nil
      sources -> manifest_v2(sources)
    end
  end

  @doc """
  Both manifest formats of a package from one load of its runs, toolchain
  builds and memberships, for the batch, which renders both for every package.

  `absent` lists the stored shas of the package that this host did not hold
  when it rendered: the only filesystem input of the manifests, since a blob
  that is present stays present (the store only adds blobs).
  """
  @spec precompiled_manifests(String.t()) :: %{
          v1: map() | nil,
          v2: map() | nil,
          absent: [String.t()]
        }
  def precompiled_manifests(package_name) do
    case precompiled_sources(package_name) do
      nil ->
        %{v1: nil, v2: nil, absent: []}

      sources ->
        %{v1: manifest_v1(sources), v2: manifest_v2(sources), absent: sources.absent_shas}
    end
  end

  # Per package, a digest of every row `precompiled_sources/1` reads, and of
  # the builder state it filters runs by. `xmin` is the transaction that last
  # wrote the row, so it changes on any update, including the plain SQL ones
  # that leave `updated_at` alone (`Portal.Catalog.ManifestModeRepair`
  # rewrites `beam_scan` that way). A builder's `xmin` is in it too: by value
  # alone, publishing turned on and off again would read as no change. The
  # columns that decide publication
  # (revocation, carried-from, builder publishing and status, toolchain build
  # status) are in it as values too. Memberships are only ever inserted and
  # deleted, and number millions, so they are an order-independent count and
  # sum of row hashes rather than a sorted digest. `format/2` keeps a NULL
  # column's place, so no two rows' fields can shift into each other.
  @precompiled_fingerprints_sql """
  WITH runs AS (
    SELECT r.package_id,
           md5(string_agg(format('%s|%s|%s|%s|%s|%s|%s|%s|%s', r.id, r.xmin, r.updated_at,
                                 r.revoked_at, r.builder_id, b.publishing, b.status,
                                 b.xmin, b.updated_at),
                          ',' ORDER BY r.id)) AS fp
    FROM catalog_runs r
    LEFT JOIN builders b ON b.id = r.builder_id
    GROUP BY r.package_id
  ), results AS (
    SELECT r.package_id,
           md5(string_agg(format('%s|%s|%s|%s|%s', s.id, s.xmin, s.updated_at,
                                 s.carried_from_run_id, pg_column_size(s.beam_scan)),
                          ',' ORDER BY s.id)) AS fp
    FROM catalog_system_results s
    JOIN catalog_runs r ON r.id = s.run_id
    GROUP BY r.package_id
  ), result_files AS (
    SELECT r.package_id, count(*) AS n,
           sum(hashtextextended(format('%s|%s|%s|%s', m.id, m.xmin, m.system_result_id, m.sha256), 0)) AS h
    FROM catalog_artifact_memberships m
    JOIN catalog_system_results s ON s.id = m.system_result_id
    JOIN catalog_runs r ON r.id = s.run_id
    GROUP BY r.package_id
  ), toolchain AS (
    SELECT t.package_id,
           md5(string_agg(format('%s|%s|%s|%s|%s', t.id, t.xmin, t.updated_at, t.status,
                                 t.revoked_at),
                          ',' ORDER BY t.id)) AS fp
    FROM catalog_toolchain_builds t
    GROUP BY t.package_id
  ), toolchain_files AS (
    SELECT t.package_id, count(*) AS n,
           sum(hashtextextended(format('%s|%s|%s|%s', m.id, m.xmin, m.toolchain_build_id, m.sha256), 0)) AS h
    FROM catalog_artifact_memberships m
    JOIN catalog_toolchain_builds t ON t.id = m.toolchain_build_id
    GROUP BY t.package_id
  )
  SELECT p.name,
         md5(format('%s/%s/%s/%s/%s/%s/%s/%s', p.id, runs.fp, results.fp, rf.n, rf.h,
                    tc.fp, tf.n, tf.h))
  FROM catalog_packages p
  LEFT JOIN runs ON runs.package_id = p.id
  LEFT JOIN results ON results.package_id = p.id
  LEFT JOIN result_files rf ON rf.package_id = p.id
  LEFT JOIN toolchain tc ON tc.package_id = p.id
  LEFT JOIN toolchain_files tf ON tf.package_id = p.id
  WHERE runs.package_id IS NOT NULL OR tc.package_id IS NOT NULL
  """

  @doc """
  A fingerprint per package name of every database input of
  `precompiled_manifests/1`: equal fingerprints at two times mean the package's
  rows did not change in between, so its manifests are the same bytes unless
  one of its `absent` blobs arrived. One query over the catalog, which reads no
  `beam_scan` value, for `Portal.Precompiled.Batches`. Read it before the
  manifests it vouches for: a write in between then only makes the next
  fingerprint differ. The withheld package list (`Portal.Precompiled.Withheld`)
  is part of every fingerprint, so a change to it renders every package again.
  """
  @spec precompiled_fingerprints() :: %{String.t() => String.t()}
  def precompiled_fingerprints do
    %{rows: rows} = Repo.query!(@precompiled_fingerprints_sql, [], timeout: :timer.minutes(2))
    withheld = Enum.join(Withheld.packages(), ",")
    Map.new(rows, fn [name, fingerprint] -> {name, fingerprint <> "|withheld:" <> withheld} end)
  end

  # `Withheld.records_config_reads?/1` for the toolchain build aliased
  # `table`, NULL-safe: rule 1 next to a `compile_env` list, written by the
  # row's own run (a NULL `run_id` never matches).
  records_config_reads = fn table ->
    "coalesce(#{table}.compile_env_rule = 1 AND #{table}.compile_env IS NOT NULL " <>
      "AND #{table}.compile_env_run_id = #{table}.run_id, false)"
  end

  # `Portal.Precompiled.Withheld` in SQL, for the queries that select
  # published files without rendering a manifest: `$W` is its package list.
  # `p` is the package, `s` a system result, `r` its run and `b` the run it
  # was carried from; a result's closure is its own lock, else the lock of the
  # run that built it, as `build_inputs/2` publishes it. No lock (anything
  # but a JSON object) is an unknown closure and withheld while the list is
  # not empty, as `Withheld.withheld?/4` reads `nil`, whatever the row
  # records. `$E` is `Withheld.records_config_reads?/1`: rule 1 next to a
  # `compile_env`, for a system result only on `pure_elixir`, for a toolchain
  # build only when its own run wrote the rule (`compile_env_run_id`); it lifts the
  # closure check alone, and `coalesce` keeps a NULL from deciding either
  # way. A withdrawn result (`unpublished_at`) is withheld too: one
  # predicate, used by every query that selects published files.
  @withheld_lock_clause """
  NOT (cardinality($W::text[]) > 0
       AND CASE WHEN jsonb_typeof($L) = 'object'
                THEN NOT coalesce($E, false)
                     AND (p.name = ANY($W::text[]) OR $L ?| $W::text[])
                ELSE true END)
  """
  @withheld_result_clause "s.unpublished_at IS NULL AND " <>
                            (@withheld_lock_clause
                             |> String.replace(
                               "$L",
                               "coalesce(s.deps_lock, CASE WHEN s.carried_from_run_id IS NULL " <>
                                 "THEN r.deps_lock ELSE b.deps_lock END)"
                             )
                             |> String.replace(
                               "$E",
                               "(s.compile_env_rule = 1 AND s.compile_env IS NOT NULL " <>
                                 "AND s.system_pkg = 'pure_elixir')"
                             ))
  @withheld_toolchain_clause @withheld_lock_clause
                             |> String.replace("$L", "t.deps_lock")
                             |> String.replace(
                               "$E",
                               "(t.compile_env_rule = 1 AND t.compile_env IS NOT NULL " <>
                                 "AND t.compile_env_run_id = t.run_id)"
                             )

  # `Withheld.config_variant_served?/2` for the toolchain build `t` of the
  # package `p`: a default always; a named variant only when it records its
  # own config reads and its default (same version, toolchain, builder
  # version and optional-deps variant) is served, that is a pass, not
  # revoked and not withheld (`@withheld_toolchain_clause` for that row).
  # Every selector that applies `@withheld_toolchain_clause` applies this
  # beside it.
  @withheld_default_clause @withheld_lock_clause
                           |> String.replace("$L", "dd.deps_lock")
                           |> String.replace("$E", records_config_reads.("dd"))
  @config_variant_served_clause """
  (t.config_variant = 'default'
   OR (#{records_config_reads.("t")}
       AND EXISTS (SELECT 1 FROM catalog_toolchain_builds dd
                   WHERE dd.package_id = t.package_id
                     AND dd.version = t.version
                     AND dd.toolchain = t.toolchain
                     AND dd.builder_version = t.builder_version
                     AND dd.variant = t.variant
                     AND dd.config_variant = 'default'
                     AND dd.status = 'pass'
                     AND dd.revoked_at IS NULL
                     AND #{@withheld_default_clause})))
  """

  @packages_with_precompiled_files_sql_template """
  SELECT p.name
  FROM catalog_packages p
  JOIN catalog_runs r ON r.package_id = p.id
  JOIN catalog_system_results s ON s.run_id = r.id
  JOIN catalog_artifact_memberships m ON m.system_result_id = s.id
  LEFT JOIN catalog_runs b ON b.id = s.carried_from_run_id
  LEFT JOIN builders rb ON rb.id = r.builder_id
  LEFT JOIN builders bb ON bb.id = b.builder_id
  WHERE r.revoked_at IS NULL
    AND (s.carried_from_run_id IS NULL OR b.revoked_at IS NULL)
    AND (r.builder_id IS NULL OR (rb.publishing AND rb.status = 'enrolled'))
    AND (s.carried_from_run_id IS NULL OR b.builder_id IS NULL OR (bb.publishing AND bb.status = 'enrolled'))
    AND #{@withheld_result_clause}
  UNION
  SELECT p.name
  FROM catalog_packages p
  JOIN catalog_toolchain_builds t ON t.package_id = p.id
  JOIN catalog_artifact_memberships m ON m.toolchain_build_id = t.id
  WHERE t.revoked_at IS NULL
    AND t.status = 'pass'
    AND #{@withheld_toolchain_clause}
    AND #{@config_variant_served_clause}
  ORDER BY 1
  """
  @packages_with_precompiled_files_sql String.replace(
                                         @packages_with_precompiled_files_sql_template,
                                         "$W",
                                         "$1"
                                       )

  @doc """
  Names of packages with at least one stored precompiled file on a run that is
  not revoked, or on a passing toolchain build that is not revoked. A remote
  builder's run (and a result carried from one) counts only while the
  builder is enrolled and publishing, as in `precompiled_manifest/1`. A
  result or build whose closure has a withheld package
  (`Portal.Precompiled.Withheld`) does not count, nor does a named config
  variant that is not served beside its default
  (`Portal.Precompiled.Withheld.config_variant_served?/2`).
  """
  @spec packages_with_precompiled_files() :: [String.t()]
  def packages_with_precompiled_files do
    %{rows: rows} =
      Portal.Repo.query!(@packages_with_precompiled_files_sql, [Withheld.packages()])

    List.flatten(rows)
  end

  # When a reopenable row is due: 7 days after its build or its last attempt
  # ($4), a day after a transient attempt ($3), never once it has had
  # `ToolchainBuild.transient_cap/0` ($8) transient results in a row.
  @reopen_due """
  (t.transient_attempts < $8::integer
   AND coalesce(t.attempted_at, t.finished_at, t.updated_at)
       <= CASE WHEN t.transient_attempts > 0 THEN $3::timestamp ELSE $4::timestamp END)
  """

  # A skipped row the verdict before rule 2 refused for a reason rule 2 no
  # longer has (precompiled portability spec, section 7): a runtime program
  # call, executable lookup or shell, or the `:os.type`/`system_architecture`
  # grep. Rebuilt once under rule 2: a day after the row's build at the
  # earliest, a day after a transient attempt, a week after any other attempt
  # (an error rebuild keeps the rule-1 row and resets its transient count, so
  # a daily floor would rebuild it every day), and only once a rule-2 build
  # exists on the toolchain that is newer than the row: before any build host
  # runs a rule-2 image nothing reopens, and a row an older image wrote after
  # the last rule-2 build (a rollback) is not rebuilt again. The two
  # comparisons stay separate: `least()` would drop a NULL newest-rule-2 time
  # and reopen everything. Every NULL (no rule-2 build yet, a row with no
  # reason) reads as "not reopened": the clause sits under a NOT, where a
  # NULL would make the live row not live. The word "nerves" stays a refusal
  # under rule 2, so a `nerves-specific source` row is not reopened; rebar
  # `platform_define`, native, priv and every trace reason stay as they are
  # too.
  @rule1_reopen """
  coalesce(coalesce(t.portability_rule, 1) < 2
   AND (t.reason ~ '^calls (System\\.(cmd|shell|find_executable)|os:(cmd|find_executable)|erlang:open_port|Port\\.open)/'
        OR t.reason IN ('calls a shell', 'runs an OS command', 'calls an executable lookup')
        OR t.reason ~ '^OS-specific \\(.*: (:os\\.type\\(|os:type\\(|system_architecture)\\)$')
   AND t.transient_attempts < $8::integer
   AND coalesce(t.attempted_at, t.finished_at, t.updated_at)
       <= CASE WHEN t.attempted_at IS NULL OR t.transient_attempts > 0
               THEN $3::timestamp ELSE $4::timestamp END
   AND coalesce(t.attempted_at, t.finished_at, t.updated_at) <
       (SELECT max(r2.finished_at) FROM catalog_toolchain_builds r2
        WHERE r2.toolchain = $1 AND r2.builder_version = $2 AND r2.portability_rule = 2),
   false)
  """

  # A skipped row judged under an older judge revision (precompiled judge
  # refinements spec, "Rollout"): its `judge_revision` is NULL (before
  # revisions) or below the newest revision any row of the toolchain and
  # builder version carries. Reopened once per revision, whatever its reason
  # or rule, when due (`@reopen_due`), and only while its last activity is
  # older than the newest build at that newest revision: before any build
  # host writes a revision nothing reopens, and a row an older image wrote
  # after the last newest-revision build (a rollback) is not rebuilt again.
  # Revoked rows stay closed by the branch this sits in, transient-capped
  # ones by `@reopen_due`. Every NULL reads as "not reopened", as in
  # `@rule1_reopen`. Keyed on the revision only, never on reason text.
  #
  # A reopened row whose rebuild errors or fails keeps its old revision and
  # recurs on the existing weekly rules (`@reopen_due`), as `@rule1_reopen`'s
  # do. Every node running the `:toolchain` queue must run the same worker
  # image and the same `NCC_JUDGE_MAKEFILE_RULE2`: a node at a lower revision
  # rebuilds a reopened row at that revision, which the next sweep reopens
  # again, a loop of one rebuild per row a week for as long as the fleet is
  # mixed. A reopen ranks after every new build (`reopen` in
  # `toolchain_backlog/3`).
  @judge_reopen """
  coalesce(coalesce(t.judge_revision, 0) <
     (SELECT max(jr.judge_revision) FROM catalog_toolchain_builds jr
      WHERE jr.toolchain = $1 AND jr.builder_version = $2)
   AND #{@reopen_due}
   AND coalesce(t.attempted_at, t.finished_at, t.updated_at) <
     (SELECT max(jf.finished_at) FROM catalog_toolchain_builds jf
      WHERE jf.toolchain = $1 AND jf.builder_version = $2
        AND jf.judge_revision =
          (SELECT max(jm.judge_revision) FROM catalog_toolchain_builds jm
           WHERE jm.toolchain = $1 AND jm.builder_version = $2)),
   false)
  """

  # An `error` row of a version only the version backfill nominates
  # (`Portal.Catalog.VersionBackfill`) is built again only under a newer judge
  # revision: its last activity is older than the first build at the newest
  # revision any row of the toolchain and builder version carries. An old
  # release whose deps do not resolve, or that does not compile, errors the
  # same way every day, and the row records nothing that tells that from a
  # transient error (a deterministic `deps_get_failed` included), so the
  # day-old-error rule does not apply to it. A `builder_version` bump is a new
  # identity and builds it anyway. NULL (no revision yet) reads as "not
  # reopened".
  @backfill_error_reopen """
  coalesce(coalesce(t.attempted_at, t.finished_at, t.updated_at) <
     (SELECT min(bf.finished_at) FROM catalog_toolchain_builds bf
      WHERE bf.toolchain = $1 AND bf.builder_version = $2
        AND bf.judge_revision =
          (SELECT max(bm.judge_revision) FROM catalog_toolchain_builds bm
           WHERE bm.toolchain = $1 AND bm.builder_version = $2)),
   false)
  """

  # A live row of the identity (see `@toolchain_candidates_sql`'s comment for
  # what is live): `t` is the row; `$PKG`, `$VERSION`, `$VARIANT` and
  # `$CONFIG` are the candidate's package id, version, variant and config
  # variant, which each query fills in.
  @live_row_clause """
  EXISTS (
    SELECT 1 FROM catalog_toolchain_builds t
    WHERE t.package_id = $PKG
      AND t.version = $VERSION
      AND t.toolchain = $1
      AND t.builder_version = $2
      AND t.variant = $VARIANT
      AND t.config_variant = $CONFIG
      AND (
        (
          t.revoked_at IS NOT NULL
          AND NOT (
            -- `ToolchainBuild.withheld_revocation/0`
            t.revoked_reason IS NOT DISTINCT FROM 'withheld closure'
            AND NOT #{records_config_reads.("t")}
            AND #{@reopen_due}
          )
        )
        OR (
          t.revoked_at IS NULL
          AND t.status = 'pass'
          AND NOT (
            (
              coalesce(t.optional_deps ->> 'reason', '') IN ('deps_get_failed', 'timeout')
              OR NOT #{records_config_reads.("t")}
              OR t.transient_attempts > 0
            )
            AND #{@reopen_due}
          )
        )
        OR (
          t.revoked_at IS NULL
          AND t.status = 'skipped'
          AND NOT (
            (
              (t.reason IS NOT DISTINCT FROM 'ships priv files' OR t.transient_attempts > 0)
              AND #{@reopen_due}
            )
            OR #{@rule1_reopen}
            OR $JUDGE_REOPEN
          )
        )
        OR (
          t.revoked_at IS NULL
          AND t.status = 'error'
          AND (
            coalesce(t.finished_at, t.updated_at) > $3::timestamp
            OR ($BACKFILL AND NOT #{@backfill_error_reopen})
          )
        )
        OR (
          t.revoked_at IS NULL
          AND t.status = 'fail'
          AND coalesce(t.finished_at, t.updated_at) > $4::timestamp
        )
      )
  )
  """

  # `@live_row_clause` for one query's candidate columns, `backfill` the SQL
  # boolean for a version only the version backfill nominates. `judge_reopen?`
  # false leaves `@judge_reopen` out: a candidate whose identity is live that
  # way is one only `@judge_reopen` reopened (`reopen` in
  # `toolchain_backlog/3`).
  live_row = fn package_id, version, variant, config_variant, judge_reopen?, backfill ->
    @live_row_clause
    |> String.replace("$JUDGE_REOPEN", if(judge_reopen?, do: @judge_reopen, else: "false"))
    |> String.replace("$BACKFILL", backfill)
    |> String.replace("$PKG", package_id)
    |> String.replace("$VERSION", version)
    |> String.replace("$VARIANT", variant)
    |> String.replace("$CONFIG", config_variant)
  end

  # A pure BEAM package `p`: no NIF language and no port language, read as
  # `native_breakdown/0` reads them. A package with no `native_components` at
  # all counts as pure, since the worker writes the map whenever it can see
  # the source.
  @pure_beam_clause """
  (p.native_components ->> 'nif_language' IS NULL
   AND NOT EXISTS (
     SELECT 1
     FROM jsonb_array_elements_text(
       CASE
         WHEN jsonb_typeof(p.native_components -> 'port_languages') = 'array'
         THEN p.native_components -> 'port_languages'
       END
     ) AS l(lang)
     WHERE l.lang IS NOT NULL
   ))
  """

  # The system result `s` of the run `r` is evidence the version is pure: a
  # passing `host` compile or `registry_deps` assessment of its own (not
  # carried from an earlier run) in a run that is not revoked.
  @pure_evidence_clause """
  (s.system_pkg IN ('host', 'registry_deps')
   AND s.status = 'pass'
   AND s.carried_from_run_id IS NULL
   AND r.revoked_at IS NULL)
  """

  # Toolchain builds wanted (`toolchain_backlog/3`): one row per package
  # version and variant, with the newest `finished_at` of the version's
  # qualifying runs and the package's hex.pm recent downloads.
  #
  # A version qualifies on a passing `host` compile of its own in a run that is
  # not revoked (`@pure_evidence_clause`), of a pure BEAM package
  # (`@pure_beam_clause`). Its own: a partial run carries the results it did
  # not build from an earlier run, host included for a targets run, and a copy
  # shows nothing about this image. The run's other systems do not matter, so
  # a targets or argus-only run that compiled the host itself counts.
  #
  # A passing `registry_deps` result qualifies the same way: the bulk
  # intake's registry assessment (`Portal.Catalog.RegistryAssessment`), which
  # records a version only once `Portal.NativeClosure` found no native code in
  # its dependency closure and compiled nothing. Its `native_components` is
  # `%{"compatibility_basis" => "registry_deps"}`, no NIF or port language, so
  # the pure-BEAM test above reads it as pure, as the closure check did. This
  # only nominates the version: the toolchain build compiles the package on
  # the host itself and the portability judge runs on that compile, so a
  # registry pass never gets anything served that was not built and judged.
  # A version with no compile on file would otherwise never get a toolchain
  # build at all.
  #
  # The versions in $BACKFILL_PACKAGES/$BACKFILL_VERSIONS (pairwise) qualify
  # too, with no run of their own and no `finished_at`: older Hex releases of
  # popular packages already known to be pure (`Portal.Catalog.VersionBackfill`,
  # which reads the registry in Elixir). Only `toolchain_backlog/3` fills them
  # in ($16/$17); every other reader of this query gets empty lists. A version
  # that also qualifies on a run is one row, with that run's `finished_at`.
  # `backfill` marks a version only the backfill nominates: its `error` rows
  # follow `@backfill_error_reopen` rather than the day-old-error rule, and
  # `Portal.Workers.ToolchainSweep` caps how many it takes per run.
  #
  # The `with` variant is wanted for every qualifying version, the `without`
  # one only once a passing, unrevoked `with` build reports an optional
  # dependency it added: for a package with none the two builds are the same.
  # The `without` one is also wanted when the `with` build was skipped under
  # rule 2, whatever the reason, and added an optional dependency: the skip
  # may come from an optional dependency (a host-tainted, natively built or
  # target-reading one, or one whose download the trace could not judge),
  # which the `without` build does not have. Each `without` build is judged
  # on its own.
  # A `with` build from before builds recorded them reports nothing, so the
  # versions in $5/$6 (packages and versions, pairwise) want theirs too:
  # `Portal.Catalog.UnrecordedOptionalDeps` asks the registry which of those
  # rows declare one, in Elixir, since the query cannot.
  #
  # A live row for the identity, variant included, removes it: `pass` and
  # `skipped` at any age, `error` younger than a day ($3), `fail` younger than
  # 7 days ($4), and any revoked row, whatever its status. A revoke is a human
  # decision, and only a `builder_version` bump makes a new identity to build
  # again. Some rows are verdicts no longer once they are due (`@reopen_due`:
  # 7 days after their build or last attempt, a day after a transient
  # "could not be judged", never once they have had
  # `ToolchainBuild.transient_cap/0` ($8) of those in a row): a `pass` that
  # dropped its optional dependencies for a transient reason (a Hex hiccup or
  # a slow fetch); a `pass` that does not record its compile-time config
  # reads (`Withheld.records_config_reads?/1`: from before builds recorded
  # them, or from a rolled-back worker image, which then costs one rebuild a
  # week); a `skipped` for shipping priv files,
  # which the worker now judges file by file; any other `pass` or `skipped`
  # whose rebuild came back as a transient "could not be judged"; a
  # `skipped` row the verdict before rule 2 refused for a runtime call or
  # the OS grep (`@rule1_reopen`, which has its own timing), once; and a
  # revoked row an operator marked as revoked for its withheld closure
  # (`revoked_reason`, `mark_withheld_revoked/2`) that does not record its
  # config reads either. Each stays as it is until the new build replaces
  # it; a rebuild that fails records its attempt on the kept row
  # (`attempted_at`, `Portal.Workers.ToolchainBuild`, and
  # `transient_attempts` for a transient one), and the age counts from that
  # attempt. `finished_at` stays the build's own.
  #
  # `refresh` marks a version whose only reason to build is a `pass` row that
  # does not record its config reads and is not withheld ($7,
  # `Portal.Precompiled.Withheld`): it is already served, so it ranks after
  # every other candidate. A withheld one is not served at all and ranks as a
  # new version does.
  #
  # Only `default` config variant rows decide a default's candidacy; named
  # variants are wanted by their own query (`@config_variant_candidates_sql`).
  @toolchain_candidates_template """
  SELECT e.package, e.version, v.variant, 'default'::text AS config_variant,
         e.finished_at, e.recent,
         EXISTS (
           SELECT 1 FROM catalog_toolchain_builds o
           WHERE o.package_id = e.package_id
             AND o.version = e.version
             AND o.toolchain = $1
             AND o.builder_version = $2
             AND o.variant = v.variant
             AND o.config_variant = 'default'
             AND o.status = 'pass'
             AND o.revoked_at IS NULL
             AND NOT #{records_config_reads.("o")}
             AND NOT (cardinality($7::text[]) > 0
                      AND (e.package = ANY($7::text[])
                           OR CASE WHEN jsonb_typeof(o.deps_lock) = 'object'
                                   THEN o.deps_lock ?| $7::text[] ELSE true END))
         ) AS refresh,
         0 AS rank,
         #{live_row.("e.package_id", "e.version", "v.variant", "'default'", false, "e.backfill")} AS reopen,
         e.backfill
  FROM (
    SELECT q.package_id, q.package, q.version, max(q.finished_at) AS finished_at, q.recent,
           bool_and(q.backfill) AS backfill
    FROM (
      SELECT p.id AS package_id, p.name AS package, r.version_tested AS version,
             r.finished_at, p.hex_downloads_recent AS recent, false AS backfill
      FROM catalog_packages p
      JOIN catalog_runs r ON r.package_id = p.id
      JOIN catalog_system_results s ON s.run_id = r.id
      WHERE #{@pure_evidence_clause}
        AND #{@pure_beam_clause}
      UNION ALL
      SELECT p.id, p.name, b.version, NULL, p.hex_downloads_recent, true
      FROM unnest($BACKFILL_PACKAGES::text[], $BACKFILL_VERSIONS::text[]) AS b(package, version)
      JOIN catalog_packages p ON p.name = b.package
    ) q
    GROUP BY q.package_id, q.package, q.version, q.recent
  ) e
  CROSS JOIN (VALUES ('with'), ('without')) AS v(variant)
  WHERE (
      v.variant = 'with'
      OR (e.package, e.version) IN (SELECT * FROM unnest($5::text[], $6::text[]))
      OR EXISTS (
        SELECT 1 FROM catalog_toolchain_builds w
        WHERE w.package_id = e.package_id
          AND w.version = e.version
          AND w.toolchain = $1
          AND w.builder_version = $2
          AND w.variant = 'with'
          AND w.config_variant = 'default'
          AND (
            w.status = 'pass'
            OR (w.status = 'skipped' AND w.portability_rule = 2)
          )
          AND w.revoked_at IS NULL
          AND jsonb_typeof(w.optional_deps -> 'added') = 'array'
          AND jsonb_array_length(w.optional_deps -> 'added') > 0
      )
    )
    AND NOT #{live_row.("e.package_id", "e.version", "v.variant", "'default'", true, "e.backfill")}
  """

  # A candidate's `major.minor.patch` as a numeric array, for ordering
  # versions newest first (text order puts 1.9.0 above 1.10.0). NULL for a
  # string that does not start that way, which sorts last.
  @candidate_version_order "(regexp_match(c.version, '^(\\d+)\\.(\\d+)\\.(\\d+)'))::numeric[]"

  # `toolchain_backlog/3`'s ranking of the candidates `c` (release downloads
  # `d`), most wanted first.
  @backlog_order """
  c.reopen,
  c.config_variant = 'default',
  c.recent DESC NULLS LAST,
  d.downloads DESC NULLS LAST,
  c.finished_at DESC NULLS LAST,
  #{@candidate_version_order} DESC NULLS LAST,
  c.version DESC,
  c.variant = 'without',
  c.rank,
  c.package
  """

  @toolchain_candidates_sql @toolchain_candidates_template
                            |> String.replace("$BACKFILL_PACKAGES", "'{}'")
                            |> String.replace("$BACKFILL_VERSIONS", "'{}'")
  @toolchain_candidates_backfill_sql @toolchain_candidates_template
                                     |> String.replace("$BACKFILL_PACKAGES", "$16")
                                     |> String.replace("$BACKFILL_VERSIONS", "$17")

  # `@withheld_toolchain_clause` for the default row aliased `d` (its package
  # `p`, the withheld list in $7).
  default_not_withheld =
    @withheld_lock_clause
    |> String.replace("$W", "$7")
    |> String.replace("$L", "d.deps_lock")
    |> String.replace("$E", records_config_reads.("d"))

  # Named config variants wanted (precompiled portability spec, R7): for a
  # `default` row that is a served pass recording its config reads, one
  # candidate per enabled variant whose overlay cut down to the {app, key}
  # pairs the row's `compile_env` read is non-empty and the first of its
  # kind in rank order (`Compatibility.ConfigVariants.wanted/2`, which a test
  # holds this to). Served: not revoked and not withheld
  # (`@withheld_toolchain_clause`, which for a row recording its config reads
  # asks only for a recorded lock). $9: config variants can be stored
  # (`ToolchainIdentity`) and some are enabled; $10..$14:
  # `ConfigVariants.rows/1`, column-wise. A live row of the variant's own
  # identity removes it, as for a default. Never a refresh: a named variant
  # is a new build. Its `rank` orders a version's variants as `wanted/2` does.
  @config_variant_candidates_sql """
  SELECT p.name AS package, d.version, d.variant, cv.name AS config_variant,
         d.finished_at, p.hex_downloads_recent AS recent, false AS refresh,
         cv.rank,
         #{live_row.("d.package_id", "d.version", "d.variant", "cv.name", false, "false")} AS reopen,
         false AS backfill
  FROM catalog_toolchain_builds d
  JOIN catalog_packages p ON p.id = d.package_id
  CROSS JOIN LATERAL (
    SELECT w.name, w.rank
    FROM (
      SELECT o.name, o.rank,
             row_number() OVER (
               PARTITION BY array_agg(o.item ORDER BY o.item) ORDER BY o.rank
             ) AS first
      FROM unnest($10::text[], $11::integer[], $12::text[], $13::text[], $14::text[])
             AS o(name, rank, app, key, item)
      WHERE (o.app, o.key) IN (
        SELECT ce ->> 'app', ce -> 'path' ->> 0 FROM unnest(d.compile_env) AS ce
      )
      GROUP BY o.name, o.rank
    ) w
    WHERE w.first = 1
  ) cv
  WHERE $9::boolean
    AND d.toolchain = $1
    AND d.builder_version = $2
    AND d.config_variant = 'default'
    AND d.status = 'pass'
    AND d.revoked_at IS NULL
    AND #{records_config_reads.("d")}
    AND #{default_not_withheld}
    AND NOT #{live_row.("d.package_id", "d.version", "d.variant", "cv.name", true, "false")}
  """

  @doc """
  Toolchain builds to make on `toolchain` at `builder_version`, at most
  `limit` that are not refreshes and at most `limit` refreshes (see below),
  each a package version and its optional-deps `variant`
  (see `Portal.Catalog.ToolchainBuild`): every version whose own `host`
  compile passed on a non-revoked run, or whose registry assessment
  (`registry_deps`, `Portal.Catalog.RegistryAssessment`) passed on one, of a
  package with no native components, is wanted `:with` its optional
  dependencies, and also
  `:without` them once a `:with` build reports adding one, or, for a `:with`
  build from before builds reported them, once the registry shows the
  version declares one (`Portal.Catalog.UnrecordedOptionalDeps`, the one
  part of the backlog that asks Hex). A variant with a
  live `Portal.Catalog.ToolchainBuild` of its own is left out (see the
  query's comment for what is live). An already served build that only
  needs its compile-time config reads recorded comes after every other
  candidate, and says so as `refresh: true`. The limit applies to each of
  the two kinds on its own, so a backlog of new builds longer than `limit`
  never cuts the refreshes off: `Portal.Workers.ToolchainSweep` reserves part
  of its cap for them, and has to see them to fill it.

  A registry pass compiled nothing: it only nominates the version. The
  toolchain build compiles it on the host and the portability judge runs on
  that compile, so nothing unbuilt is ever served. A registry-only version is
  new work, so it ranks with the other new defaults, ahead of every reopen.

  Older Hex releases of popular packages are wanted too, with no run of their
  own (`Portal.Catalog.VersionBackfill`, the `:backfill` option, default its
  `wanted/0`): of the packages already known to be pure (a `host` or
  `registry_deps` pass of any version, no native components), the 100 most
  downloaded on hex.pm get their last 10 releases and the 500 most
  downloaded their last 4, retired releases and pre-releases left out
  (`Portal.Toolchains.version_backfill/0`). Each is a new default under the
  same variant and live-row rules, judged on its own build, so it ranks with
  the other new defaults and ahead of every reopen. Reading the release lists
  is the other part of the backlog that asks Hex, from `repo.hex.pm` and
  through `Portal.HexDeps`'s one-hour cache. Such a version says so as
  `backfill: true` (a reopen or refresh never does), and the limit applies to it on its
  own as well, so a long backfill never pushes other new builds past
  `limit`: `Portal.Workers.ToolchainSweep` gives backfill only a share of its
  defaults. Its `error` rows are built again only under a newer judge
  revision or `builder_version`, not a day later (see the query's comment).
  Callers that build every toolchain pass `:backfill` once
  (`VersionBackfill.wanted/0`), so the registry is read once per sweep.

  Each row names its `config_variant`: `"default"`, or a named
  `Compatibility.ConfigVariants` variant of a served default build. Only rows
  of the default config variant decide whether a default build is wanted, so
  a named variant's row never stands in for the default's. Named rows that
  are not refreshes come first, ahead of every new default: they are bounded
  (at most a few per served default build), and a long default backlog would
  otherwise leave them past `limit` on every call.

  `reopen: true` marks a candidate whose only reason to build is that its
  skipped row was judged under an older judge revision (`@judge_reopen`): not
  a new identity, and not reopened by any other rule. Those rank after every
  other candidate that is not a refresh, named or default, so a revision bump
  never pushes a new build past `limit`; `Portal.Workers.ToolchainSweep`
  gives them only the slots the new builds leave free.
  This assumes every node running the `:toolchain` queue runs the same worker
  image and the same `NCC_JUDGE_MAKEFILE_RULE2`; a fleet at mixed judge
  revisions rebuilds the same reopened rows every week.

  Most wanted first, so a capped sweep builds what projects resolve before
  what nobody asks for: by the package's hex.pm recent downloads, then, within
  a package, by the release's own downloads
  (`Portal.Catalog.ReleaseDownloads`), then newest run first (a backfilled
  release has none, so it follows the versions with a run), then newest
  version first by `major.minor.patch`, and `:with` ahead of `:without`. So
  an old release of a much downloaded package comes before the newest release
  of a little downloaded one. An unknown count sorts
  after every known one, zero included: it is not known demand.
  """
  @spec toolchain_backlog(String.t(), pos_integer(), non_neg_integer(), keyword()) :: [
          %{
            package: String.t(),
            version: String.t(),
            variant: :with | :without,
            config_variant: String.t(),
            refresh: boolean(),
            reopen: boolean(),
            backfill: boolean()
          }
        ]
  def toolchain_backlog(toolchain, builder_version, limit, opts \\ []) do
    backfill = Keyword.get_lazy(opts, :backfill, &VersionBackfill.wanted/0)

    %{rows: rows} =
      Repo.query!(
        """
        WITH candidates AS (
          #{@toolchain_candidates_backfill_sql}
          UNION ALL
          #{@config_variant_candidates_sql}
        )
        SELECT package, version, variant, config_variant, refresh, reopen, backfill
        FROM (
          SELECT c.package, c.version, c.variant, c.config_variant, c.refresh, c.reopen,
                 c.backfill AND NOT c.reopen AND NOT c.refresh AS backfill,
                 row_number() OVER (
                   PARTITION BY c.refresh, c.backfill AND NOT c.reopen AND NOT c.refresh
                   ORDER BY #{@backlog_order}
                 ) AS place,
                 row_number() OVER (
                   PARTITION BY c.refresh
                   ORDER BY #{@backlog_order}
                 ) AS overall
          FROM candidates c
          LEFT JOIN catalog_release_downloads d
            ON d.package = c.package AND d.version = c.version
        ) ranked
        WHERE place <= $15
        ORDER BY refresh, overall
        """,
        toolchain_params(
          toolchain,
          builder_version,
          UnrecordedOptionalDeps.wanted(toolchain, builder_version)
        ) ++ config_variant_params() ++ [limit | backfill_params(backfill)]
      )

    Enum.map(rows, fn [package, version, variant, config_variant, refresh, reopen, backfill] ->
      %{
        package: package,
        version: version,
        variant: variant(variant),
        config_variant: config_variant,
        refresh: refresh,
        reopen: reopen,
        backfill: backfill
      }
    end)
  end

  defp variant("with"), do: :with
  defp variant("without"), do: :without

  @doc """
  The packages `Portal.Catalog.VersionBackfill` may reach back into, as
  `{name, rank}` in rank order: of the `limit` packages with the most hex.pm
  recent downloads (rank 1 the most; a package without a count is unranked),
  those already known to be pure. Known: at least one non-revoked run of the
  package, any version, has a `host` or `registry_deps` pass of its own, and
  the package records no native components, as `toolchain_backlog/3` reads
  both. The rank is among every counted package, so a native package in the
  top still takes its place.
  """
  @spec version_backfill_packages(non_neg_integer()) :: [{String.t(), pos_integer()}]
  def version_backfill_packages(limit) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT p.name, p.rank
        FROM (
          SELECT id, name, native_components,
                 row_number() OVER (ORDER BY hex_downloads_recent DESC, name) AS rank
          FROM catalog_packages
          WHERE hex_downloads_recent IS NOT NULL
        ) p
        WHERE p.rank <= $1
          AND #{@pure_beam_clause}
          AND EXISTS (
            SELECT 1
            FROM catalog_runs r
            JOIN catalog_system_results s ON s.run_id = r.id
            WHERE r.package_id = p.id
              AND #{@pure_evidence_clause}
          )
        ORDER BY p.rank
        """,
        [limit]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  # `@toolchain_candidates_backfill_sql`'s $16/$17: the backfill pairs,
  # column-wise.
  defp backfill_params(pairs) do
    {packages, versions} = Enum.unzip(pairs)
    [packages, versions]
  end

  @doc """
  The backlog versions whose release downloads are worth asking hex.pm for
  (`Portal.Workers.ReleaseDownloadsRefresh`): across every configured
  toolchain at the current `builder_version`, the `top_packages` packages
  with the most recent downloads that still have backlog, and of each at
  most `versions_per_package`, newest run first.

  Older releases the version backfill nominates (`Portal.Catalog.VersionBackfill`)
  are not ranked here: asking for them would read the registry, and they
  already rank after the versions with a run inside their package.

  A package without a recent download count is left out: release counts only
  order versions inside a package, and a package with no count of its own
  sorts after every counted one whatever its releases say. The result is
  most downloaded package first, and never holds more than
  `top_packages * versions_per_package` entries.

  A package whose only backlog, on every toolchain, refreshes builds already
  served (`refresh` in `toolchain_backlog/3`) comes after every package with
  something new to build, however downloaded; inside a package such a
  version comes after the others the same way.
  """
  @spec toolchain_backlog_to_rank(pos_integer(), pos_integer()) :: [
          %{package: String.t(), version: String.t()}
        ]
  def toolchain_backlog_to_rank(top_packages, versions_per_package) do
    builder_version = Portal.Toolchains.builder_version()

    # Each toolchain's rows are bounded by the same caps, so the merge below
    # holds at most toolchains * caps rows.
    rows =
      for %{toolchain: toolchain} <- Portal.Toolchains.images(),
          row <- backlog_to_rank(toolchain, builder_version, top_packages, versions_per_package),
          uniq: true,
          do: row

    rows
    |> Enum.group_by(fn {package, recent, _finished_at, _version, _refresh} ->
      {package, recent}
    end)
    |> Enum.sort_by(fn {{package, recent}, rows} -> {all_refresh?(rows), -recent, package} end)
    |> Enum.take(top_packages)
    |> Enum.flat_map(fn {{package, _recent}, rows} ->
      rows
      |> Enum.group_by(fn {_package, _recent, _finished_at, version, _refresh} -> version end)
      |> Enum.map(fn {_version, [row | _] = same} -> put_elem(row, 4, all_refresh?(same)) end)
      |> Enum.sort(&ranks_before?/2)
      |> Enum.take(versions_per_package)
      |> Enum.map(fn {_package, _recent, _finished_at, version, _refresh} ->
        %{package: package, version: version}
      end)
    end)
  end

  # A package or version is only a refresh when it is one on every toolchain.
  defp all_refresh?(rows), do: Enum.all?(rows, &elem(&1, 4))

  # A version to build before a version to refresh, then newest run first.
  defp ranks_before?({_, _, _, _, false}, {_, _, _, _, true}), do: true
  defp ranks_before?({_, _, _, _, true}, {_, _, _, _, false}), do: false
  defp ranks_before?(a, b), do: newer_run?(a, b)

  defp backlog_to_rank(toolchain, builder_version, top_packages, versions_per_package) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH candidates AS (#{@toolchain_candidates_sql}),
        -- Both variants of a version share its release's downloads; a
        -- version is a refresh only when every variant it wants is one.
        versions AS (
          SELECT package, recent, max(finished_at) AS finished_at, version,
                 bool_and(refresh) AS refresh
          FROM candidates
          GROUP BY package, recent, version
        ),
        -- Packages with something to build before packages that only
        -- refresh what is already served.
        top AS (
          SELECT package, recent
          FROM versions
          WHERE recent IS NOT NULL
          GROUP BY package, recent
          ORDER BY bool_and(refresh), recent DESC, package
          LIMIT $9
        ),
        ranked AS (
          SELECT c.package, c.recent, c.finished_at, c.version, c.refresh,
                 row_number() OVER (
                   PARTITION BY c.package
                   ORDER BY c.refresh, c.finished_at DESC NULLS LAST, c.version DESC
                 ) AS rank
          FROM versions c
          JOIN top t ON t.package = c.package
        )
        SELECT package, recent, finished_at, version, refresh
        FROM ranked
        WHERE rank <= $10
        """,
        toolchain_params(toolchain, builder_version) ++ [top_packages, versions_per_package]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  # Newest run first, no run time last, version breaking a tie: the order the
  # query above ranks a package's versions in, kept across toolchains.
  defp newer_run?({_, _, same, a, _}, {_, _, same, b, _}), do: a >= b
  defp newer_run?({_, _, nil, _, _}, _other), do: false
  defp newer_run?(_row, {_, _, nil, _, _}), do: true
  defp newer_run?({_, _, a, _, _}, {_, _, b, _, _}), do: NaiveDateTime.compare(a, b) == :gt

  @doc """
  Per configured toolchain (`Portal.Toolchains.images/0`), at the current
  `builder_version`: how many non-revoked toolchain builds of the default
  config variant have each status, and how many builds `toolchain_backlog/3` would still make (a version
  wanted with and without its optional dependencies counts twice). The count
  asks Hex nothing, so it leaves out the `without` builds that only the
  registry shows a pre-recording `with` build needs
  (`Portal.Catalog.UnrecordedOptionalDeps`) and the older releases of popular
  packages (`Portal.Catalog.VersionBackfill`).
  """
  @spec toolchain_counts() :: %{
          String.t() => %{
            pass: non_neg_integer(),
            skipped: non_neg_integer(),
            error: non_neg_integer(),
            fail: non_neg_integer(),
            backlog: non_neg_integer()
          }
        }
  def toolchain_counts do
    builder_version = Portal.Toolchains.builder_version()

    %{rows: rows} =
      Repo.query!(
        """
        SELECT toolchain, status, count(*)
        FROM catalog_toolchain_builds
        WHERE builder_version = $1 AND revoked_at IS NULL AND config_variant = 'default'
        GROUP BY toolchain, status
        """,
        [builder_version]
      )

    statuses = Map.new(rows, fn [toolchain, status, count] -> {{toolchain, status}, count} end)

    Map.new(Portal.Toolchains.images(), fn %{toolchain: toolchain} ->
      counts =
        Map.new(~w(pass skipped error fail)a, fn status ->
          {status, Map.get(statuses, {toolchain, Atom.to_string(status)}, 0)}
        end)

      {toolchain, Map.put(counts, :backlog, toolchain_backlog_count(toolchain, builder_version))}
    end)
  end

  defp toolchain_backlog_count(toolchain, builder_version) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM (
          #{@toolchain_candidates_sql}
          UNION ALL
          #{@config_variant_candidates_sql}
        ) candidates
        """,
        toolchain_params(toolchain, builder_version) ++ config_variant_params()
      )

    count
  end

  # `@config_variant_candidates_sql`'s $9..$14: whether named variants can be
  # stored and some are enabled, then the enabled overlays' rows column-wise.
  defp config_variant_params do
    enabled = Portal.Toolchains.config_variants()
    rows = Compatibility.ConfigVariants.rows(enabled)
    ready = enabled != [] and Portal.Catalog.ToolchainIdentity.config_variants_ready?()

    [ready | Enum.map(0..4, fn i -> Enum.map(rows, &elem(&1, i)) end)]
  end

  # `unrecorded` is `Portal.Catalog.UnrecordedOptionalDeps.wanted/2`'s answer,
  # which asks Hex: only the sweep's own backlog passes it. The ranking for
  # release downloads and the admin page's counts leave those `without`
  # builds out rather than ask Hex for a number.
  defp toolchain_params(toolchain, builder_version, unrecorded \\ {[], []}) do
    now = NaiveDateTime.utc_now()
    {packages, versions} = unrecorded

    [
      toolchain,
      builder_version,
      NaiveDateTime.add(now, -1, :day),
      NaiveDateTime.add(now, -7, :day),
      packages,
      versions,
      Withheld.packages(),
      ToolchainBuild.transient_cap()
    ]
  end

  @doc """
  Pulls a run's files from precompiled publication. Manifests and batches skip
  a revoked run; the next batch drops it for every client.
  """
  @spec revoke_run(String.t()) :: {:ok, Run.t()} | {:error, :not_found}
  def revoke_run(run_id) do
    case Run |> Ash.Query.filter(run_id == ^run_id) |> Ash.read_one!(domain: __MODULE__) do
      nil -> {:error, :not_found}
      run -> run |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update(domain: __MODULE__)
    end
  end

  @doc "Revokes what rule 2 alone published (`Portal.Precompiled.ToolchainRevocation.revoke/1`)."
  defdelegate revoke_toolchain_builds(opts),
    to: Portal.Precompiled.ToolchainRevocation,
    as: :revoke

  @withheld_revocation ToolchainBuild.withheld_revocation()

  @doc """
  Marks revoked toolchain builds as revoked for their withheld closure
  (`ToolchainBuild.withheld_revocation/0`), so the backlog rebuilds each once
  with its compile-time config reads recorded and the rebuild un-revokes it
  (`Portal.Catalog.Ingestion`). Only a row that is revoked, records no config
  reads (`Portal.Precompiled.Withheld.records_config_reads?/1`) and whose
  closure has a withheld package
  (`Portal.Precompiled.Withheld`) is marked; every other id comes back under
  `skipped` with the reason. `dry_run: true`, the default, changes nothing.

  Each row is marked in its own transaction under the toolchain build
  identity's lock (`Portal.Catalog.Ingestion.lock_toolchain_identity/1`),
  checked again there, so an ingest of the same identity cannot interleave.
  """
  @spec mark_withheld_revoked([String.t()], keyword()) :: %{
          marked: [String.t()],
          skipped: [{String.t(), String.t()}]
        }
  def mark_withheld_revoked(ids, opts \\ []) when is_list(ids) do
    dry_run = Keyword.get(opts, :dry_run, true)
    packages = Withheld.packages()
    rows = toolchain_builds_by_id(ids)

    %{marked: marked, skipped: skipped} =
      Enum.reduce(ids, %{marked: [], skipped: []}, fn id, acc ->
        case mark_one(Map.get(rows, id), packages, dry_run) do
          :ok -> %{acc | marked: [id | acc.marked]}
          {:skip, why} -> %{acc | skipped: [{id, why} | acc.skipped]}
        end
      end)

    %{marked: Enum.reverse(marked), skipped: Enum.reverse(skipped)}
  end

  defp toolchain_builds_by_id(ids) do
    uuids = for id <- ids, {:ok, uuid} <- [Ecto.UUID.cast(id)], do: uuid

    ToolchainBuild
    |> Ash.Query.filter(id in ^uuids)
    |> Ash.Query.load(:package)
    |> Ash.read!(domain: __MODULE__)
    |> Map.new(&{&1.id, &1})
  end

  defp mark_one(row, packages, true), do: markable(row, packages)

  defp mark_one(row, packages, false) do
    with :ok <- markable(row, packages) do
      {:ok, result} = Repo.transaction(fn -> mark_locked(row, packages) end)
      result
    end
  end

  # Re-reads the row under the identity lock: what the first read saw may
  # have changed before the lock was taken.
  defp mark_locked(row, packages) do
    :ok = Portal.Catalog.Ingestion.lock_toolchain_identity(toolchain_lock_identity(row))

    current = toolchain_builds_by_id([row.id])[row.id]

    with :ok <- markable(current, packages) do
      current
      |> Ash.Changeset.for_update(:mark_withheld_revoked, %{})
      |> Ash.update(domain: __MODULE__)
      |> marked()
    end
  end

  # The action's filter matches only a revoked row: a stale record is one
  # that was un-revoked meanwhile. Any other error is reported as itself.
  defp marked({:ok, _row}), do: :ok

  defp marked({:error, %Ash.Error.Invalid{errors: errors} = error}) do
    if Enum.all?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)),
      do: {:skip, "not revoked"},
      else: {:skip, "not marked: " <> Exception.message(error)}
  end

  defp marked({:error, error}), do: {:skip, "not marked: " <> Exception.message(error)}

  @doc false
  # The identity a stored toolchain build's ingest locks on
  # (`Portal.Catalog.Ingestion.lock_toolchain_identity/1`). `row` has its
  # package loaded.
  def toolchain_lock_identity(%ToolchainBuild{} = row) do
    %{
      package: row.package.name,
      version: row.version,
      toolchain: row.toolchain,
      builder_version: row.builder_version,
      variant: row.variant,
      config_variant: row.config_variant
    }
  end

  defp markable(nil, _packages), do: {:skip, "no such toolchain build"}
  defp markable(%ToolchainBuild{revoked_at: nil}, _packages), do: {:skip, "not revoked"}

  defp markable(%ToolchainBuild{revoked_reason: reason}, _packages)
       when is_binary(reason) and reason != @withheld_revocation,
       do: {:skip, "revoked for another reason: " <> reason}

  defp markable(row, packages) do
    cond do
      Withheld.records_config_reads?(row) -> {:skip, "already records its config reads"}
      Withheld.withheld?(row.package.name, row.deps_lock, packages) -> :ok
      true -> {:skip, "closure has no withheld package"}
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

  @published_sha256_sql_template """
  SELECT 1
  FROM catalog_artifact_memberships m
  JOIN catalog_system_results s ON s.id = m.system_result_id
  JOIN catalog_runs r ON r.id = s.run_id
  JOIN catalog_packages p ON p.id = r.package_id
  LEFT JOIN catalog_runs b ON b.id = s.carried_from_run_id
  LEFT JOIN builders rb ON rb.id = r.builder_id
  LEFT JOIN builders bb ON bb.id = b.builder_id
  WHERE m.sha256 = $1
    AND r.revoked_at IS NULL
    AND (s.carried_from_run_id IS NULL OR b.revoked_at IS NULL)
    AND (r.builder_id IS NULL OR (rb.publishing AND rb.status = 'enrolled'))
    AND (s.carried_from_run_id IS NULL OR b.builder_id IS NULL OR (bb.publishing AND bb.status = 'enrolled'))
    AND #{@withheld_result_clause}
  UNION ALL
  SELECT 1
  FROM catalog_artifact_memberships m
  JOIN catalog_toolchain_builds t ON t.id = m.toolchain_build_id
  JOIN catalog_packages p ON p.id = t.package_id
  WHERE m.sha256 = $1
    AND t.revoked_at IS NULL
    AND t.status = 'pass'
    AND #{@withheld_toolchain_clause}
    AND #{@config_variant_served_clause}
  LIMIT 1
  """
  @published_sha256_sql String.replace(@published_sha256_sql_template, "$W", "$2")

  @doc """
  Whether some published build's file manifest names `sha256`: the blob
  endpoint serves only those. The same gate as `packages_with_precompiled_files/0`
  and the manifests: an unrevoked run whose builder, if any, is enrolled and
  publishing (for a carried result, the carrying run's builder too), or a
  passing unrevoked toolchain build, either one not withheld
  (`Portal.Precompiled.Withheld`). A blob a non-publishing or revoked
  builder uploaded, or one only withheld builds own, has an `Artifact` row
  and a file but is not served; so has one only named config variants own
  whose default is not served
  (`Portal.Precompiled.Withheld.config_variant_served?/2`).
  """
  @spec published_sha256?(String.t()) :: boolean()
  # The SQL is a module constant; the digest is a bound parameter the caller
  # validated, and the withheld list a bound parameter too.
  # sobelow_skip ["SQL.Query"]
  def published_sha256?(sha256) when is_binary(sha256) do
    %{rows: rows} = Portal.Repo.query!(@published_sha256_sql, [sha256, Withheld.packages()])
    rows != []
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
  # `pure_elixir` (host compile + inspection),
  # `Portal.Catalog.RegistryAssessment`'s `registry_deps` (registry data only)
  # and `Portal.Catalog.ToolingSkip`'s `nerves_tooling` (never built). None is a
  # Nerves system, and each always carries the same status, so any per-system
  # figure that counted them would show a phantom system at 100% or 0%.
  @assessment_systems ~w(pure_elixir registry_deps nerves_tooling)

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
    "Build timeout" =>
      {"Build timeout",
       "The build was still running when it hit the wall-clock limit and was stopped. Usually a package that compiles a large native library from source for every target."},
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

  @doc """
  Packages whose newest tested versions all failed, longest streak first.

  A streak counts distinct versions from the newest down until one whose latest
  run did not fail or error: a package that fails on three releases in a row
  and passed on the fourth-newest has a streak of 3. A version counts by its
  latest run, so a rebuild that passed clears it. Each entry carries the newest
  `:versions` as a `chain`, newest first, with the version's status and the
  failure category most of its failing systems were sorted into, so the reader
  can see at a glance whether every release fails the same way (likely genuine,
  or systemic on our side) or the cause moves between releases.

  Options: `:min_streak` (2), `:limit` packages (100), `:versions` per chain (4).
  Cached like the other dashboard aggregates.
  """
  @spec failing_version_streaks(keyword()) :: [map()]
  def failing_version_streaks(opts \\ []) do
    min_streak = Keyword.get(opts, :min_streak, 2)
    limit = Keyword.get(opts, :limit, 100)
    versions = Keyword.get(opts, :versions, 4)

    Cache.fetch({:failing_version_streaks, min_streak, limit, versions}, fn ->
      compute_failing_version_streaks(min_streak, limit, versions)
    end)
  end

  # One SQL pass: the latest run per (package, version), ranked newest first
  # per package, the rank of the first non-failing version per package, and
  # from that the streak. Window functions, so raw SQL rather than Ecto's
  # query DSL. `finished_at` ties fall to `inserted_at`, as the latest-run
  # index does.
  @streaks_sql """
  WITH per_version AS (
    SELECT DISTINCT ON (r.package_id, r.version_tested)
           r.id AS run_id, r.package_id, r.version_tested, r.overall_status,
           r.finished_at, r.inserted_at
    FROM catalog_runs r
    WHERE r.finished_at IS NOT NULL AND r.overall_status IS NOT NULL
    ORDER BY r.package_id, r.version_tested, r.finished_at DESC, r.inserted_at DESC
  ), ranked AS (
    SELECT pv.*,
           row_number() OVER (PARTITION BY pv.package_id
                              ORDER BY pv.finished_at DESC, pv.inserted_at DESC) AS rn
    FROM per_version pv
  ), totals AS (
    SELECT package_id, max(rn) AS total FROM ranked GROUP BY package_id
  ), first_ok AS (
    SELECT package_id, min(rn) AS rn FROM ranked
    WHERE overall_status NOT IN ('fail', 'error') GROUP BY package_id
  ), top AS (
    SELECT t.package_id, p.name, t.total, COALESCE(f.rn, t.total + 1) - 1 AS streak
    FROM totals t
    JOIN catalog_packages p ON p.id = t.package_id
    LEFT JOIN first_ok f ON f.package_id = t.package_id
    WHERE COALESCE(f.rn, t.total + 1) - 1 >= $1
    ORDER BY streak DESC, p.name ASC
    LIMIT $2
  )
  SELECT top.name, top.streak, top.total,
         k.run_id, k.version_tested, k.overall_status, k.finished_at
  FROM top
  JOIN ranked k ON k.package_id = top.package_id AND k.rn <= $3
  ORDER BY top.streak DESC, top.name ASC, k.rn ASC
  """

  defp compute_failing_version_streaks(min_streak, limit, versions) do
    rows = Repo.query!(@streaks_sql, [min_streak, limit, versions]).rows
    categories = rows |> Enum.map(&Enum.at(&1, 3)) |> run_failure_categories()

    rows
    |> Enum.chunk_by(&hd/1)
    |> Enum.map(fn [[name, streak, total | _] | _] = package_rows ->
      chain =
        for [_, _, _, run_id, version, status, finished_at] <- package_rows do
          %{
            version: version,
            status: String.to_existing_atom(status),
            category: Map.get(categories, run_id),
            # Raw rows carry the column's `timestamp` as a NaiveDateTime; the
            # column is UTC by convention, as the resource types it.
            finished_at: DateTime.from_naive!(finished_at, "Etc/UTC")
          }
        end

      %{
        package: name,
        streak: streak,
        versions_tested: total,
        last_failed_at: hd(chain).finished_at,
        chain: chain
      }
    end)
  end

  # The failure category most of a run's failing systems fell into, per run.
  # Ties go to the category that sorts first, so a run reads the same every time.
  defp run_failure_categories([]), do: %{}

  defp run_failure_categories(run_ids) do
    from(s in "catalog_system_results",
      where: s.run_id in ^run_ids,
      where: s.status in ["fail", "error"] and not is_nil(s.failure_category),
      group_by: [s.run_id, s.failure_category],
      order_by: [asc: s.run_id, desc: count(), asc: s.failure_category],
      select: {s.run_id, s.failure_category}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {run_id, category}, acc -> Map.put_new(acc, run_id, category) end)
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

  # Everything either manifest format is rendered from, read once: the
  # package's unrevoked runs and their results (minus those carried from a
  # revoked run), its published toolchain builds, which stored blobs each of
  # them owns, and which of those blobs this host holds. A result or build
  # whose dependency closure has a withheld package
  # (`Portal.Precompiled.Withheld`) is left out here, before anything is
  # rendered from it, and so is a named config variant whose default is not
  # among the builds left (`Withheld.config_variant_served?/2`).
  defp precompiled_sources(package_name) do
    case packages(package_name) do
      [package] ->
        withheld = Withheld.packages()
        runs = precompiled_runs(package.id)

        results =
          package.id
          |> unrevoked_manifest_results(runs)
          |> reject_withheld_results(package.name, runs, withheld)

        shas_by_system_result_id =
          results |> Enum.map(& &1.id) |> manifest_shas_for_system_results()

        served =
          package.id
          |> published_toolchain_builds()
          |> Enum.reject(&Withheld.withheld?(package.name, &1.deps_lock, withheld, &1))

        toolchain_builds = Enum.filter(served, &Withheld.config_variant_served?(&1, served))

        shas_by_toolchain_build_id =
          toolchain_builds |> Enum.map(& &1.id) |> manifest_shas_for_toolchain_builds()

        stored = stored_shas(Map.merge(shas_by_system_result_id, shas_by_toolchain_build_id))
        present = MapSet.filter(stored, &ArtifactStore.present?/1)

        %{
          runs: runs,
          results: results,
          shas_by_system_result_id: shas_by_system_result_id,
          toolchain_builds: toolchain_builds,
          shas_by_toolchain_build_id: shas_by_toolchain_build_id,
          present_shas: present,
          absent_shas: stored |> MapSet.difference(present) |> Enum.sort()
        }

      _ ->
        nil
    end
  end

  # A result's closure is its own lock, else that of the run that built it,
  # as `build_inputs/2` publishes it. A withdrawn result (`unpublished_at`) is
  # left out the same way.
  defp reject_withheld_results(results, package_name, runs, withheld) do
    runs_by_id = Map.new(runs, &{&1.id, &1})

    Enum.reject(results, fn result ->
      built_by = Map.get(runs_by_id, result.carried_from_run_id || result.run_id)
      deps = result.deps_lock || (built_by && built_by.deps_lock)

      not is_nil(result.unpublished_at) or
        Withheld.withheld?(package_name, deps, withheld, result)
    end)
  end

  defp unrevoked_manifest_results(_package_id, []), do: []

  defp unrevoked_manifest_results(package_id, runs) do
    hidden = MapSet.union(revoked_run_ids(package_id), unpublished_run_ids(package_id))

    runs
    |> Enum.map(& &1.id)
    |> manifest_results_for_runs()
    |> Enum.reject(&(&1.carried_from_run_id in hidden))
  end

  defp manifest_v1(sources) do
    versions =
      precompiled_versions(
        sources.runs,
        sources.results,
        sources.shas_by_system_result_id,
        sources.present_shas
      )

    if versions == %{} do
      nil
    else
      %{
        versions: versions,
        updated_at:
          sources.runs
          |> Enum.map(& &1.finished_at)
          |> Enum.reject(&is_nil/1)
          |> Enum.max(DateTime, fn -> nil end)
          |> iso8601()
      }
    end
  end

  # Builds are `{version, finished_at, build}` until the end, so the newest of
  # each key can be picked and `updated_at` taken over what is published.
  defp manifest_v2(sources) do
    builds =
      (run_builds(sources) ++ toolchain_builds_v2(sources))
      |> Enum.filter(&matchable?/1)
      |> newest_per_key()

    if builds == [] do
      nil
    else
      %{
        "format" => 2,
        "versions" =>
          builds
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 2))
          |> Map.new(fn {version, list} ->
            {version, %{"builds" => Enum.sort_by(list, &build_order/1)}}
          end),
        "updated_at" =>
          builds
          |> Enum.map(&elem(&1, 1))
          |> Enum.reject(&is_nil/1)
          |> Enum.max(DateTime, fn -> nil end)
          |> iso8601()
      }
    end
  end

  # Every result format 1 could publish, not only the newest per system:
  # format 2 keeps one per toolchain, so an older build under another
  # toolchain stays reachable. Dated by the run that built it.
  defp run_builds(sources) do
    runs_by_id = Map.new(sources.runs, &{&1.id, &1})

    for result <- sources.results,
        result.system_pkg != "host",
        stored = Map.get(sources.shas_by_system_result_id, result.id, MapSet.new()),
        files = file_manifest(result, stored, sources.present_shas),
        files != nil do
      built_by = built_by(runs_by_id, result)
      version = Map.fetch!(runs_by_id, result.run_id).version_tested

      build =
        built_by
        |> build_inputs(result)
        |> Map.put("dep_env", "prod")
        |> Map.put("mix_target", mix_target(result.system_pkg))
        |> put_declared(built_by.declared)

      {version, built_by.finished_at,
       Map.merge(files, %{"target" => result.system_pkg, "build" => build})}
    end
  end

  # The portal makes every build with the dependency compiled as `prod`, which
  # is what Mix compiles any dependency as unless the project overrides it.
  defp toolchain_builds_v2(sources) do
    for tb <- sources.toolchain_builds,
        stored = Map.get(sources.shas_by_toolchain_build_id, tb.id, MapSet.new()),
        files = toolchain_files(tb.file_manifest, stored, sources.present_shas),
        files != nil do
      build = %{
        "elixir" => tb.elixir,
        "otp" => tb.otp,
        "dep_env" => "prod",
        "mix_target" => "host",
        "system_version" => nil,
        "deps" => tb.deps_lock,
        "compile_env" => tb.compile_env,
        "package_checksum" => tb.package_checksum,
        "run_id" => tb.run_id,
        "image_digest" => tb.image_digest
      }

      build =
        build
        |> put_config_variant(tb.config_variant)
        |> put_declared(tb.declared)
        |> put_manager(tb.manager)

      {tb.version, tb.finished_at,
       Map.merge(files, %{"target" => "pure_elixir", "build" => build})}
    end
  end

  # Informational: the client matches a variant by its recorded
  # `compile_env`, and ignores this key. Left out for the default, so a
  # package without named variants renders the bytes it always did.
  defp put_config_variant(build, "default"), do: build
  defp put_config_variant(build, name), do: Map.put(build, "config_variant", name)

  # Every dependency the package declares, as the build's lock listed it.
  # Format 2 only, and left out when the row has none, so a build made before
  # it was recorded renders the bytes it always did.
  defp put_declared(build, nil), do: build
  defp put_declared(build, declared), do: Map.put(build, "declared", declared)

  # The manager Mix built the package with, as the worker's trace recorded
  # it (precompiled judge refinements, item 1). A client skips a build whose
  # manager differs from its own dependency's. Left out when unknown, so a
  # build made before it was recorded renders the bytes it always did.
  defp put_manager(build, nil), do: build
  defp put_manager(build, manager), do: Map.put(build, "manager", manager)

  # The MIX_TARGET a build was compiled under. The worker sets it from
  # `NccWorker.Systems`, whose target for `nerves_system_<x>` is always `<x>`;
  # pure_elixir and toolchain builds are host builds. A client checks it for a
  # dependency that reads `Mix.target()` at compile time.
  defp mix_target("nerves_system_" <> name), do: name
  defp mix_target(_), do: "host"

  defp matchable?({_version, _finished_at, %{"build" => build}}) do
    Enum.all?(["elixir", "otp", "deps", "package_checksum", "compile_env"], &(build[&1] != nil))
  end

  # A client takes a system build only at its own system version, so each
  # system version is its own key; `pure_elixir` builds all have nil there.
  # Config variants of one build (precompiled portability spec, R7) are
  # listed side by side, each its own key; a rebuild of a variant, of any
  # builder version, still replaces its predecessor. Run results are all
  # the default variant.
  defp newest_per_key(builds) do
    builds
    |> Enum.group_by(fn {version, _finished_at, %{"target" => target, "build" => build}} ->
      {version, target, "#{elixir_minor(build["elixir"])}/#{build["otp"]}",
       build["system_version"], build["deps"], build["config_variant"] || "default"}
    end)
    |> Enum.map(fn {_key, group} -> Enum.max_by(group, &recency/1) end)
  end

  defp elixir_minor(elixir), do: elixir |> String.split(".") |> Enum.take(2) |> Enum.join(".")

  # A build without a finished_at is older than any with one; the run id breaks
  # a tie so the pick, and so the manifest's bytes, do not depend on read order.
  defp recency({_version, nil, %{"build" => build}}), do: {-1, build["run_id"] || ""}

  defp recency({_version, finished_at, %{"build" => build}}),
    do: {DateTime.to_unix(finished_at, :microsecond), build["run_id"] || ""}

  defp build_order(%{"target" => target, "build" => build}),
    do: {target, build["elixir"], build["otp"], build["run_id"] || ""}

  defp published_toolchain_builds(package_id) do
    ToolchainBuild
    |> Ash.Query.filter(package_id == ^package_id and status == :pass and is_nil(revoked_at))
    |> Ash.Query.select([
      :id,
      :version,
      :toolchain,
      :builder_version,
      :variant,
      :config_variant,
      :status,
      :revoked_at,
      :elixir,
      :otp,
      :image_digest,
      :run_id,
      :deps_lock,
      :package_checksum,
      :declared,
      :manager,
      :compile_env,
      :compile_env_rule,
      :compile_env_run_id,
      :file_manifest,
      :finished_at
    ])
    |> Ash.read!(domain: __MODULE__)
  end

  defp manifest_shas_for_toolchain_builds([]), do: %{}

  defp manifest_shas_for_toolchain_builds(toolchain_build_ids) do
    ArtifactMembership
    |> Ash.Query.filter(toolchain_build_id in ^toolchain_build_ids)
    |> Ash.Query.select([:toolchain_build_id, :sha256])
    |> Ash.read!(domain: __MODULE__)
    |> Enum.group_by(& &1.toolchain_build_id, & &1.sha256)
    |> Map.new(fn {id, shas} -> {id, MapSet.new(shas)} end)
  end

  # A toolchain build's manifest is only the package's own files, so unlike a
  # run's, every entry must be publishable: a file with no membership, an
  # unsafe path or mode, or a blob this host lacks leaves the build out rather
  # than shipping it without that file.
  defp toolchain_files(%{} = manifest, stored_shas, present_shas) do
    count =
      length(manifest_entries(manifest, "ebin")) + length(manifest_entries(manifest, "priv"))

    case published_files(manifest, stored_shas, present_shas) do
      %{"ebin" => ebin, "priv" => priv} = files when length(ebin) + length(priv) == count -> files
      _ -> nil
    end
  end

  defp toolchain_files(_manifest, _stored_shas, _present_shas), do: nil

  # Runs come newest first, and an entry is taken from the first run that has
  # one: each (version, system) is published from exactly one build, its
  # newest. Merging every run over the result made the oldest one win. An
  # entry whose files are not all on this host yet counts as none, so the
  # version falls back to its newest build that a client can fetch whole.
  defp precompiled_versions(runs, results, shas_by_system_result_id, present_shas) do
    runs_by_id = Map.new(runs, &{&1.id, &1})

    Enum.reduce(runs, %{}, fn run, acc ->
      run_results = Enum.filter(results, &(&1.run_id == run.id and &1.system_pkg != "host"))

      systems =
        precompiled_systems(runs_by_id, run_results, shas_by_system_result_id, present_shas)

      if systems == %{} do
        acc
      else
        Map.update(acc, run.version_tested, systems, &Map.merge(systems, &1))
      end
    end)
  end

  # The newest run first, with what a client needs to know about how it was
  # built: a precompiled file is usable only with the exact Elixir, OTP and
  # system it was built against.
  defp precompiled_runs(package_id) do
    Run
    |> Ash.Query.filter(package_id == ^package_id)
    |> Ash.Query.filter(is_nil(revoked_at))
    # A remote builder's runs publish only while it is enrolled and an admin
    # has turned its publishing on; local runs (no builder) always do.
    |> Ash.Query.filter(
      is_nil(builder_id) or (builder.publishing == true and builder.status == :enrolled)
    )
    |> Ash.Query.sort(finished_at: :desc, inserted_at: :desc)
    |> Ash.Query.select([
      :id,
      :run_id,
      :version_tested,
      :finished_at,
      :inserted_at,
      :toolchain,
      :image_digest,
      :deps_lock,
      :package_checksum,
      :declared,
      :revoked_at
    ])
    |> Ash.read!(domain: __MODULE__)
  end

  # A carried system result keeps the carrying run's `run_id` and names its
  # true builder in `carried_from_run_id` (see `built_by/2`). Revoking that
  # builder must still hide the result everywhere it was carried forward to,
  # so the manifest rejects any carried result whose builder is in this set
  # before `precompiled_versions/4` ever sees it.
  defp revoked_run_ids(package_id) do
    Run
    |> Ash.Query.filter(package_id == ^package_id and not is_nil(revoked_at))
    |> Ash.Query.select([:id])
    |> Ash.read!(domain: __MODULE__)
    |> MapSet.new(& &1.id)
  end

  # The remote runs `precompiled_runs/1` leaves out (builder not publishing or
  # not enrolled). A result carried from one onto a local run is hidden with
  # it, as `packages_with_precompiled_files/0` hides it.
  defp unpublished_run_ids(package_id) do
    Run
    |> Ash.Query.filter(package_id == ^package_id and not is_nil(builder_id))
    |> Ash.Query.filter(not (builder.publishing == true and builder.status == :enrolled))
    |> Ash.Query.select([:id])
    |> Ash.read!(domain: __MODULE__)
    |> MapSet.new(& &1.id)
  end

  # `deps` is the package's dependency closure as the build locked it: their
  # macros are expanded into its BEAMs, so a client may use the entry only when
  # its own lock has every one at the same version and checksum. A firmware
  # run's per-target optional-dependency pass can leave a system with its own
  # lock (the run's plus the optional deps it kept), which takes priority over
  # the run's; a system without one (every system before the pass existed, a
  # target the pass did not touch, or a carried row) falls back to the run's.
  defp build_inputs(run, result) do
    toolchain = run.toolchain || %{}

    %{
      "elixir" => toolchain["elixir"],
      "otp" => toolchain["erlang"],
      "system_version" => result.system_version,
      "run_id" => run.run_id,
      "image_digest" => run.image_digest,
      "deps" => result.deps_lock || run.deps_lock,
      "compile_env" => result.compile_env,
      "package_checksum" => run.package_checksum
    }
  end

  # A system result a partial run carried forward was built by an earlier run
  # of the same package, under that run's toolchain, image and lock, so that is
  # the run its entry has to describe. `precompiled_manifest/1` has already
  # dropped any result carried from a revoked run, so a carried result's
  # builder is always among `runs_by_id` here. A `nil` carried_from_run_id
  # covers both a result that was never carried and one whose builder was
  # hard-deleted (the foreign key nils it on delete) -- either way, the
  # carrying run (`result.run_id`) is the right fallback.
  defp built_by(runs_by_id, %{carried_from_run_id: nil} = result) do
    Map.fetch!(runs_by_id, result.run_id)
  end

  defp built_by(runs_by_id, result) do
    Map.fetch!(runs_by_id, result.carried_from_run_id)
  end

  defp file_manifest(result, stored_shas, present_shas) do
    case get_in(result.beam_scan || %{}, ["footprint", "file_manifest"]) do
      %{} = manifest -> published_files(manifest, stored_shas, present_shas)
      _ -> nil
    end
  end

  # The entries of a manifest a client may fetch: the ones owned by this build,
  # all of them safe to write, each under the key its own path names, and all
  # on this host. An owned file with an unsafe path, a path under the other
  # key or no publishable mode, or one this host lacks, leaves the whole
  # manifest out: a client then compiles the package rather than installing
  # it without that file.
  #
  # A client installs `ebin` entries as the package's code and `priv` entries
  # as its data, and the host checks a toolchain build's priv files
  # (`Portal.Catalog.ToolchainPriv`) by path. An entry whose path and key
  # disagree is something no build writes; it is not served under either.
  defp published_files(manifest, stored_shas, present_shas) do
    owned =
      Map.new(@manifest_keys, &{&1, owned_entries(manifest_entries(manifest, &1), stored_shas)})

    files = owned |> Map.values() |> Enum.concat()

    cond do
      files == [] -> nil
      not Enum.all?(owned, &all_publishable?/1) -> nil
      Enum.all?(files, &MapSet.member?(present_shas, &1["sha256"])) -> Map.new(owned, &publish/1)
      true -> nil
    end
  end

  defp owned_entries(entries, stored_shas),
    do: Enum.filter(entries, &(is_map(&1) and MapSet.member?(stored_shas, &1["sha256"])))

  defp all_publishable?({key, entries}), do: Enum.all?(entries, &publishable?(&1, key))

  defp publishable?(entry, key),
    do:
      safe_path?(entry["path"]) and under_key?(entry["path"], key) and
        publish_mode(entry["mode"]) != nil

  defp under_key?(path, key), do: String.starts_with?(path, key <> "/")

  # The row keeps what the build saw; a client gets 0644 or 0755.
  defp publish({key, entries}),
    do: {key, Enum.map(entries, &Map.put(&1, "mode", publish_mode(&1["mode"])))}

  defp manifest_entries(manifest, key) do
    case Map.get(manifest, key) do
      entries when is_list(entries) -> entries
      _ -> []
    end
  end

  # Builders ingest into the shared database but keep blobs in their own store,
  # and the web host pulls them minutes later, so a row can name a blob this
  # host cannot serve yet. Each distinct sha is checked once per request, with
  # the same test the file endpoint applies before it serves one
  # (`precompiled_sources/1`).
  defp stored_shas(shas_by_owner_id) do
    shas_by_owner_id
    |> Map.values()
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
  end

  # `path` and `mode` come from JSON the build container wrote, which the
  # package under test can control, and a client writes each file at `path`
  # with `mode`. Only plain files under the package's own ebin/ and priv/.
  defp safe_path?(path) when is_binary(path) do
    segments = String.split(path, "/")

    hd(segments) in @manifest_keys and length(segments) > 1 and
      Enum.all?(segments, &(&1 not in ["", ".", ".."])) and not String.contains?(path, <<0>>)
  end

  defp safe_path?(_path), do: false

  @doc """
  The mode a manifest publishes for a file whose build recorded `mode`, or
  `nil` when it publishes none.

  A published mode is exactly rw-r--r-- or rwxr-xr-x (`0o100644`,
  `0o100755`), which is all a client accepts: 0755 when the build saw any
  execute bit, 0644 otherwise. Builds leave files 0664, 0555, 0700 and the
  like, and publishing those as is would make the client refuse the whole
  dependency. A mode that is missing, not an integer, not a regular file's (a
  symlink, a device) or carries setuid, setgid or sticky publishes none.
  """
  @spec publish_mode(term()) :: 0o100644 | 0o100755 | nil
  def publish_mode(mode) when is_integer(mode) and mode >= 0 and mode <= 0o177777 do
    type = Bitwise.band(mode, 0o170000)
    special = Bitwise.band(mode, 0o7000)

    cond do
      type not in [0, 0o100000] or special != 0 -> nil
      Bitwise.band(mode, 0o111) != 0 -> 0o100755
      true -> 0o100644
    end
  end

  def publish_mode(_mode), do: nil

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
  #
  # Public for `Portal.Catalog.TopFailing`, so `/failing` and `/packages/<name>`
  # share this one rule; `version_tested` and `finished_at` are selected for it.
  @doc false
  def latest_results do
    latest =
      from(r in "catalog_runs",
        distinct: r.package_id,
        order_by: [asc: r.package_id, desc: r.finished_at, desc: r.inserted_at],
        select: %{
          id: r.id,
          package_id: r.package_id,
          version_tested: r.version_tested,
          finished_at: r.finished_at
        }
      )

    from(s in "catalog_system_results", join: r in subquery(latest), on: r.id == s.run_id)
  end

  defp system_key(result), do: "#{result.system_pkg}@#{result.system_version}"

  defp generated_at, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp precompiled_systems(runs_by_id, run_results, shas_by_system_result_id, present_shas) do
    Enum.reduce(run_results, %{}, fn result, system_acc ->
      stored_shas = Map.get(shas_by_system_result_id, result.id, MapSet.new())

      case file_manifest(result, stored_shas, present_shas) do
        nil ->
          system_acc

        manifest ->
          Map.put(
            system_acc,
            result.system_pkg,
            Map.put(manifest, "build", build_inputs(built_by(runs_by_id, result), result))
          )
      end
    end)
  end
end
