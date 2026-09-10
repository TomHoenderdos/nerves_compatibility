defmodule Portal.Catalog do
  @moduledoc """
  Ash domain for compatibility data.

  Holds the package catalog, scan runs, per-system results, content-addressed
  build artifacts, and admin-editable package overrides. Populated by the
  builder Oban worker (Phase 3); read by the public LiveView/JSON surface.
  """

  use Ash.Domain

  require Ash.Query

  alias Portal.Catalog.{Artifact, Package, PackageOverride, Run, SystemLog, SystemResult}

  @statuses ~w(pass fail error skipped unknown)

  # The dashboard reads these tables whole, so every query on its path names the
  # columns it needs. `catalog_system_results` is 304 MB, of which 275 MB is the
  # `dependency_scans` jsonb and 10 MB the `beam_scan` jsonb; nothing the
  # dashboard renders reads either. Loading them anyway decoded ~300 MB of blob
  # into the heap on every call, several calls per render, which is what made a
  # single page load cost gigabytes and run the node out of memory.
  @annotated_fields [
    :run_id,
    :system_pkg,
    :status,
    :failure_category,
    :log_tail,
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
  def latest_by_pkg_json(package_name \\ nil) do
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
    annotated = latest_annotated_systems()
    runs = run_summaries()

    %{
      counts: package_status_counts(annotated),
      clusters: failure_clusters(annotated, cluster_limit),
      native: native_breakdown(),
      rates: pass_rate_per_system(annotated),
      recent_pass: recent_runs(:pass, recent_limit, runs),
      recent_fail: recent_runs(:fail, recent_limit, runs),
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
          run -> system_results_for_runs([run.id])
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
         results when results != [] <- system_results_for_runs(Enum.map(runs, & &1.id)) do
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
  def recent_runs(status, limit, runs) do
    wanted = if status == :pass, do: [:pass], else: [:fail, :error]
    pkgs = Package |> Ash.read!(domain: __MODULE__) |> Map.new(&{&1.id, &1})

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
        package: pkgs[run.package_id] && pkgs[run.package_id].name,
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
  def package_status_counts, do: package_status_counts(latest_annotated_systems())

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
  def failure_clusters(limit \\ 10), do: failure_clusters(latest_annotated_systems(), limit)

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
  defp sample_log(rows) do
    rows
    |> Enum.map(& &1.log_tail)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.min_by(&String.length/1, fn -> nil end)
    |> case do
      nil -> nil
      log -> log |> String.split("\n") |> Enum.take(-40) |> Enum.join("\n")
    end
  end

  @doc "Packages grouped by native implementation language (NIF + ports), plus a pure-Elixir bucket."
  def native_breakdown do
    Package
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

  defp runs_for_package(package_id) do
    Run
    |> Ash.Query.filter(package_id == ^package_id)
    |> Ash.Query.sort(finished_at: :desc, inserted_at: :desc)
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

  defp system_results_for_runs([]), do: []

  defp system_results_for_runs(run_ids) do
    SystemResult
    |> Ash.Query.filter(run_id in ^run_ids)
    |> Ash.Query.sort(system_pkg: :asc)
    |> Ash.read!(domain: __MODULE__)
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
    packages = packages(nil)
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
        log_tail: sr.log_tail,
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
