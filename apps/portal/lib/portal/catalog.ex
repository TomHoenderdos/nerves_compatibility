defmodule Portal.Catalog do
  @moduledoc """
  Ash domain for compatibility data.

  Holds the package catalog, scan runs, per-system results, content-addressed
  build artifacts, and admin-editable package overrides. Populated by the
  builder Oban worker (Phase 3); read by the public LiveView/JSON surface.
  """

  use Ash.Domain

  require Ash.Query

  alias Portal.Catalog.{Artifact, Cache, Package, PackageOverride, Run, SystemLog, SystemResult}
  alias Portal.Repo

  @statuses ~w(pass fail error skipped unknown)

  # The dashboard reads these tables whole, so every query on its path names the
  # columns it needs. `catalog_system_results` is the largest table in the
  # database: 843 MB on disk as of 2026-09-10, of which 829 MB is TOAST, and
  # 1,501 MB uncompressed once the `dependency_scans` jsonb is decoded, against
  # 54 MB for `beam_scan`. Nothing the dashboard renders reads either. Loading
  # them anyway decoded that blob into the heap on every call, several calls per
  # render, which is what made a single page load cost gigabytes and run the
  # node out of memory.
  #
  # `Portal.Catalog.Ingestion` no longer stores the `footprint.file_manifest`
  # that was 75% of `dependency_scans`, and `Portal.Catalog.ManifestBackfill`
  # removes it from rows written before that — so the figures above are an
  # upper bound once the backfill has been run. Naming columns is not
  # contingent on either: the remaining blob is still far larger than what
  # these queries render.
  # Deliberately no `:log_tail`. The dashboard reads the system results of the
  # latest run of every package — 9,187 rows in production as of 2026-09-10,
  # carrying 29 MB of log tails that Postgres serialized and the node decoded
  # into binaries on every render, so that `sample_log/1` could keep one of
  # them per failure cluster. The id is carried instead, and the sample is
  # fetched by id at the end.
  @annotated_fields [
    :id,
    :run_id,
    :system_pkg,
    :status,
    :failure_category,
    :hex_version_tested
  ]
  @stats_fields [:system_pkg, :system_version, :status]
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
    resource(PackageOverride)
  end

  @doc """
  Returns the schema-v2 `latest_by_pkg.json` shape from Catalog rows.
  """
  def latest_by_pkg_json(package_name \\ nil)

  # Only the whole-catalog form is memoized. It is the expensive one -- every
  # package, its latest run and that run's system results, folded in Elixir --
  # and it is what `/packages` and the public JSON index both call. The
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
  """
  def stats_json do
    Cache.fetch(:stats_json, &compute_stats_json/0)
  end

  defp compute_stats_json do
    results =
      SystemResult
      |> Ash.Query.select(@stats_fields)
      |> Ash.read!(domain: __MODULE__)

    %{
      schema: 2,
      generated_at: generated_at(),
      counts: counts(results),
      by_system:
        results
        |> Enum.group_by(&system_key/1)
        |> Map.new(fn {key, rows} -> {key, counts(rows, false)} end),
      last_run_finished_at: last_finished_at(run_summaries())
    }
  end

  @doc """
  Everything the dashboard renders, from one pass over the catalog.

  The functions below each derive their answer from `latest_annotated_systems/0`
  and from the runs table. Called one by one, as the dashboard used to, they
  repeat both loads per caller. Threading the loaded rows through instead keeps
  a render to a single pass.
  """
  def dashboard(cluster_limit \\ 3, recent_limit \\ 10) do
    Cache.fetch({:dashboard, cluster_limit, recent_limit}, fn ->
      compute_dashboard(cluster_limit, recent_limit)
    end)
  end

  defp compute_dashboard(cluster_limit, recent_limit) do
    annotated = latest_annotated_systems()
    runs = run_summaries()

    pkgs = package_name_map()

    %{
      counts: package_status_counts(annotated),
      clusters: failure_clusters(annotated, cluster_limit),
      native: native_breakdown(),
      rates: pass_rate_per_system(annotated),
      recent_pass: recent_runs(:pass, recent_limit, runs, pkgs),
      recent_fail: recent_runs(:fail, recent_limit, runs, pkgs),
      last_run: last_finished_at(runs)
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
  Returns the precompiled package manifest shape for a package.
  """
  def precompiled_manifest(package_name) do
    with [package] <- packages(package_name),
         runs when runs != [] <- runs_for_package(package.id),
         results when results != [] <- manifest_results_for_runs(Enum.map(runs, & &1.id)) do
      artifacts_by_system_result_id =
        results
        |> Enum.map(& &1.id)
        |> artifacts_for_system_results()
        |> Enum.group_by(& &1.system_result_id)

      versions = precompiled_versions(runs, results, artifacts_by_system_result_id)

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

  @doc "Per-system pass counts over the latest run of every package."
  def pass_rate_per_system, do: pass_rate_per_system(latest_annotated_systems())

  @doc false
  def pass_rate_per_system(annotated) do
    annotated
    |> Enum.group_by(& &1.system_pkg)
    |> Enum.map(fn {system_pkg, rows} ->
      total = length(rows)
      pass = Enum.count(rows, &(&1.status == :pass))

      %{
        system_pkg: system_pkg,
        pass: pass,
        total: total,
        rate: if(total > 0, do: pass / total, else: 0.0)
      }
    end)
    |> Enum.sort_by(& &1.system_pkg)
  end

  @doc "Most recently finished passing (:pass) or failing (:fail/:error) runs."
  def recent_runs(status, limit \\ 5), do: recent_runs(status, limit, run_summaries())

  @doc false
  def recent_runs(status, limit, runs), do: recent_runs(status, limit, runs, package_name_map())

  # Two columns, not the row: this map is only ever asked for a name, and
  # `catalog_packages` carries a description and a `native_components` jsonb
  # blob that nothing here looks at.
  #
  # It arrives as an argument because `dashboard/2` needs both a passing and a
  # failing list, and building it inside meant reading every package row twice
  # per render to answer the same question.
  @doc false
  def recent_runs(status, limit, runs, pkgs) do
    wanted = if status == :pass, do: [:pass], else: [:fail, :error]

    runs
    |> Enum.filter(&(&1.overall_status in wanted and not is_nil(&1.finished_at)))
    |> Enum.sort_by(& &1.finished_at, {:desc, DateTime})
    # One row per package. A package that gets re-checked often (jason, while
    # the build pipeline was being tuned) would otherwise fill the whole list
    # with its own history and hide every other package. Runs with no package
    # keep their own key so they cannot collapse into each other.
    |> Enum.uniq_by(&(&1.package_id || &1.id))
    |> Enum.take(limit)
    |> Enum.map(fn run ->
      %{
        package: pkgs[run.package_id],
        version: run.version_tested,
        finished_at: run.finished_at,
        overall_status: run.overall_status
      }
    end)
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
    Cache.fetch(:package_status_counts, fn ->
      package_status_counts(latest_annotated_systems())
    end)
  end

  @doc false
  def package_status_counts(annotated) do
    by_pkg =
      annotated
      |> Enum.group_by(& &1.package)
      |> Enum.map(fn {_pkg, rows} ->
        Portal.Catalog.Rollup.overall_status(Enum.map(rows, & &1.status))
      end)

    %{
      unique: length(by_pkg),
      pass: Enum.count(by_pkg, &(&1 == :pass)),
      fail: Enum.count(by_pkg, &(&1 == :fail)),
      partial: Enum.count(by_pkg, &(&1 == :partial)),
      skipped: Enum.count(by_pkg, &(&1 == :skipped)),
      unknown: Enum.count(by_pkg, &(&1 == :unknown))
    }
  end

  @doc "Non-pass systems grouped by failure_category with occurrence + distinct-package counts."
  def failure_clusters(limit \\ 10) do
    Cache.fetch({:failure_clusters, limit}, fn ->
      failure_clusters(latest_annotated_systems(), limit)
    end)
  end

  @doc false
  def failure_clusters(annotated, limit) do
    annotated
    |> Enum.filter(&(&1.status in [:fail, :error] and not is_nil(&1.failure_category)))
    |> Enum.group_by(& &1.failure_category)
    |> Enum.map(fn {category, rows} ->
      {title, hint} =
        Map.get(@failure_meta, category, {category, "Build failures in this category."})

      entries =
        Enum.map(rows, fn r ->
          %{
            package: r.package,
            version: r.version,
            arch_label: Portal.Catalog.Architecture.label(r.system_pkg),
            nif_language: r.nif_language,
            detail: nil
          }
        end)

      %{
        category: category,
        title: title,
        hint: hint,
        systems: length(rows),
        packages: rows |> Enum.map(& &1.package) |> Enum.uniq() |> length(),
        entries: entries,
        sample_log: sample_log(rows)
      }
    end)
    |> Enum.sort_by(& &1.systems, :desc)
    |> Enum.take(limit)
  end

  # Shortest non-empty log_tail in the cluster, last 40 lines.
  #
  # One row, chosen by Postgres. This used to fold over the log tails already
  # loaded on every annotated row, which meant the dashboard paid for ~35,000
  # of them to render at most ten. Sorting by length in the database sends one.
  #
  # Raw SQL because Ash has no first-class sort over `octet_length/1`, and
  # `octet_length` rather than `String.length/1` because the two only disagree
  # on multi-byte input, where the byte count is the better proxy for "least
  # log to read" anyway.
  defp sample_log([]), do: nil

  defp sample_log(rows) do
    ids = Enum.map(rows, &Ecto.UUID.dump!(&1.id))

    %{rows: found} =
      Repo.query!(
        """
        SELECT log_tail
        FROM catalog_system_results
        WHERE id = ANY($1) AND log_tail IS NOT NULL AND log_tail <> ''
        ORDER BY octet_length(log_tail) ASC
        LIMIT 1
        """,
        [ids]
      )

    case found do
      [[log]] -> log |> String.split("\n") |> Enum.take(-40) |> Enum.join("\n")
      [] -> nil
    end
  end

  @doc "Packages grouped by native implementation language (NIF + ports), plus a pure-Elixir bucket."
  def native_breakdown do
    Package
    |> Ash.Query.select([:name, :native_components])
    |> Ash.read!(domain: __MODULE__)
    |> Enum.flat_map(fn pkg ->
      nc = pkg.native_components || %{}
      langs = [nc["nif_language"] | nc["port_languages"] || []] |> Enum.reject(&is_nil/1)

      if langs == [],
        do: [{"Pure Elixir / none", pkg.name}],
        else: Enum.map(langs, &{&1, pkg.name})
    end)
    |> Enum.group_by(fn {lang, _} -> lang end, fn {_, name} -> name end)
    |> Enum.map(fn {language, names} ->
      %{language: language, packages: names |> Enum.uniq() |> length()}
    end)
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

  # Two columns of the whole table, for the callers that only need to label a
  # run with a package name. `packages(nil)` above stays wide because
  # `latest_by_pkg_json/1` renders the full package row through
  # `package_json/3`.
  defp package_names do
    Package
    |> Ash.Query.select([:id, :name])
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(domain: __MODULE__)
  end

  defp package_name_map, do: package_names() |> Map.new(&{&1.id, &1.name})

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

  defp run_summaries do
    Run
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

  defp annotated_results_for_runs([]), do: []

  defp annotated_results_for_runs(run_ids) do
    SystemResult
    |> Ash.Query.filter(run_id in ^run_ids)
    |> Ash.Query.sort(system_pkg: :asc)
    |> Ash.Query.select(@annotated_fields)
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

  defp artifacts_for_system_results([]), do: []

  defp artifacts_for_system_results(system_result_ids) do
    Artifact
    |> Ash.Query.filter(system_result_id in ^system_result_ids)
    |> Ash.read!(domain: __MODULE__)
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

  defp precompiled_versions(runs, results, artifacts_by_system_result_id) do
    Enum.reduce(runs, %{}, fn run, acc ->
      run_results = Enum.filter(results, &(&1.run_id == run.id and &1.system_pkg != "host"))

      systems =
        Enum.reduce(run_results, %{}, fn result, system_acc ->
          stored_shas =
            artifacts_by_system_result_id
            |> Map.get(result.id, [])
            |> MapSet.new(& &1.sha256)

          case file_manifest(result, stored_shas) do
            nil -> system_acc
            manifest -> Map.put(system_acc, result.system_pkg, manifest)
          end
        end)

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

  defp counts(results, include_total? \\ true) do
    base = Map.new(@statuses, &{&1, 0})

    counted =
      Enum.reduce(results, base, fn result, acc ->
        Map.update!(acc, Atom.to_string(result.status), &(&1 + 1))
      end)

    if include_total?, do: Map.put(counted, "total", length(results)), else: counted
  end

  defp last_finished_at(runs) do
    runs
    |> Enum.map(& &1.finished_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort(DateTime)
    |> List.last()
    |> iso8601()
  end

  # Latest system results across all packages, annotated with the package name.
  defp latest_annotated_systems do
    packages = package_names()
    runs = latest_runs(packages)

    run_to_pkg =
      packages
      |> Enum.reduce(%{}, fn pkg, acc ->
        case Map.get(runs, pkg.id) do
          nil -> acc
          run -> Map.put(acc, run.id, pkg.name)
        end
      end)

    run_to_pkg
    |> Map.keys()
    |> annotated_results_for_runs()
    |> Enum.map(fn sr ->
      %{
        package: Map.get(run_to_pkg, sr.run_id),
        system_pkg: sr.system_pkg,
        status: sr.status,
        failure_category: sr.failure_category,
        id: sr.id,
        version: sr.hex_version_tested,
        nif_language: nil
      }
    end)
  end

  defp system_key(result), do: "#{result.system_pkg}@#{result.system_version}"

  defp generated_at, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
