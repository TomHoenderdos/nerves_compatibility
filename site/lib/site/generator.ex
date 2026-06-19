defmodule Site.Generator do
  @moduledoc """
  Generates static HTML pages from compatibility index files.
  """

  alias Compatibility.Index.{LatestByPackage, Stats}

  @doc """
  Generates the static site.

  Options:
    * `:input_dir` - Directory containing the JSON index files (required)
    * `:output_dir` - Directory to write the generated site (required)
    * `:metadata_file` - Path to package_metadata.json (optional)
  """
  @spec generate(keyword()) :: :ok | {:error, term()}
  def generate(opts) do
    input_dir = Keyword.fetch!(opts, :input_dir)
    output_dir = Keyword.fetch!(opts, :output_dir)
    metadata_file = Keyword.get(opts, :metadata_file, "../package_metadata.json")

    # Load package metadata
    metadata =
      case Compatibility.PackageMetadata.load(metadata_file) do
        {:ok, m} -> m
        {:error, _} -> %Compatibility.PackageMetadata{}
      end

    # Try to load the new format first, fall back to old format
    packages_result =
      case load_index(input_dir, "packages_by_version.json", &LatestByPackage.load/1) do
        {:ok, packages} -> {:ok, packages}
        {:error, _} -> load_index(input_dir, "latest_by_pkg.json", &LatestByPackage.load/1)
      end

    with {:ok, packages_data} <- packages_result,
         {:ok, stats} <- load_index(input_dir, "stats.json", &Stats.load/1) do
      # Create output directories
      site_dir = Path.join(output_dir, "site")
      packages_dir = Path.join([output_dir, "site", "packages"])
      data_dir = Path.join(output_dir, "data")
      manifests_dir = Path.join([output_dir, "site", "manifests"])

      File.mkdir_p!(site_dir)
      File.mkdir_p!(packages_dir)
      File.mkdir_p!(data_dir)
      File.mkdir_p!(manifests_dir)

      # Copy data files
      if input_dir != data_dir, do: copy_data_files(input_dir, data_dir)

      # Generate precompiled manifests from result files
      results_dir = determine_results_dir(input_dir)
      Site.PrecompiledManifest.generate_manifests(results_dir, manifests_dir)

      # Dep names that appear somewhere but haven't been scanned yet.
      # Shared between the index (autocomplete) and the per-package generator
      # (placeholder HTML files). Derive once to keep the two in sync.
      all_pkgs_index = build_all_packages_index(packages_data.packages)
      placeholder_names = missing_dep_names(packages_data.packages, all_pkgs_index)

      # Cluster data is computed once and reused by the dashboard (top-3
      # teaser) and the full failure-clusters page.
      clusters = Site.FailureCluster.compute(results_dir)

      latest_by_pkg = get_latest_per_package(packages_data)

      # Dashboard landing page.
      generate_index_page(site_dir, latest_by_pkg, stats, placeholder_names, clusters)

      # Browsable package list with client-side filters.
      generate_packages_page(site_dir, latest_by_pkg, placeholder_names)

      # Generate stats page
      generate_stats_page(site_dir, stats)

      # Generate scan request page
      generate_request_scan_page(site_dir)

      # Generate package detail pages (one per version) plus placeholder
      # pages for the dep names above.
      generate_package_pages(
        packages_dir,
        packages_data,
        metadata,
        all_pkgs_index,
        placeholder_names
      )

      # Generate failure clusters page — groups every fail by normalized
      # log-tail signature so the root causes blocking the most packages
      # are visible at a glance.
      generate_failure_clusters_page(site_dir, clusters)

      # Generate warnings page — non-fatal quality signals (non-determinism,
      # halt calls, shell usage, etc.) drawn from beam_scan flags + per-system
      # deterministic property.
      generate_warnings_page(site_dir, latest_by_pkg)

      :ok
    end
  end

  defp generate_warnings_page(site_dir, latest_by_pkg) do
    warnings = Site.WarningCluster.compute(latest_by_pkg.packages)
    template_path = template_path("warnings.html.eex")

    content =
      EEx.eval_file(template_path,
        assigns: %{warnings: warnings, nav_html: Site.Nav.render(:warnings)}
      )

    File.write!(Path.join(site_dir, "warnings.html"), content)
  end

  defp generate_failure_clusters_page(site_dir, clusters) do
    template_path = template_path("failure_clusters.html.eex")

    content =
      EEx.eval_file(template_path,
        assigns: %{clusters: clusters, nav_html: Site.Nav.render(:clusters)}
      )

    File.write!(Path.join(site_dir, "failure_clusters.html"), content)
  end

  defp generate_request_scan_page(site_dir) do
    template_path = template_path("request_scan.html.eex")

    content =
      EEx.eval_file(template_path,
        assigns: %{nav_html: Site.Nav.render(:request_scan)}
      )

    File.write!(Path.join(site_dir, "request_scan.html"), content)
  end

  # -- New browsable packages page --------------------------------------
  defp generate_packages_page(site_dir, latest_by_pkg, placeholder_names) do
    template_path = template_path("packages.html.eex")

    rows =
      latest_by_pkg.packages
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {name, pkg} ->
        version = pkg.version || pkg.latest_version || "unknown"
        key = "#{name}@#{version}"

        system_statuses =
          for {sys_key, sys} <- pkg.systems,
              not String.starts_with?(to_string(sys.system_pkg || ""), "forced") do
            short = Site.Architecture.label(sys.system_pkg)

            %{
              key: sys_key,
              short: short,
              status: Atom.to_string(sys.status)
            }
          end
          |> Enum.sort_by(& &1.short)

        %{
          name: name,
          version: version,
          filename: "#{String.replace(key, "/", "_")}.html",
          description: pkg.description || "",
          overall: get_overall_status(pkg) |> Atom.to_string(),
          systems: system_statuses,
          # Mirrors the dashboard tile's buckets: "rust" / "zig" / "c" /
          # "language unknown" / "none" / "unknown". One axis for filtering
          # instead of two (NIF vs port).
          native: native_code_bucket_for_row(pkg),
          avg_footprint_bytes: avg_target_footprint(pkg),
          last_run_at: pkg.last_run_at
        }
      end)

    placeholders =
      placeholder_names
      |> Enum.sort()
      |> Enum.map(fn name ->
        %{name: name, filename: "#{String.replace(name, "/", "_")}.html"}
      end)

    rows_json = JSON.encode!(rows)
    placeholders_json = JSON.encode!(placeholders)

    content =
      EEx.eval_file(template_path,
        assigns: %{
          rows_json: rows_json,
          placeholders_json: placeholders_json,
          total_packages: length(rows),
          total_placeholders: length(placeholders),
          nav_html: Site.Nav.render(:packages)
        }
      )

    File.write!(Path.join(site_dir, "packages.html"), content)
  end

  # -- Dashboard tile data -----------------------------------------------

  @spec native_code_distribution([{String.t(), map()}]) ::
          [%{language: String.t(), count: non_neg_integer()}]
  defp native_code_distribution(packages) do
    # The primary compatibility question for a Nerves target is "does this
    # package require native code to be cross-compiled?" — NIF vs port
    # companion is an implementation detail we surface on detail pages,
    # not the top-level tile.
    #
    # "Has native code" is union of:
    #   * beam_scan.flags.nif == true   (package loads a NIF at runtime)
    #   * native_components.port_languages contains :c  (ships a compiled
    #     companion binary in priv/)
    #
    # Shell/python/ruby port companions aren't native code for our purposes
    # (scripts don't need cross-compilation). `System.cmd("git", ...)`
    # calling a system tool on PATH also isn't native code — that's a
    # runtime dependency signal, tracked elsewhere if needed.
    #
    # Language attribution prefers the NIF language (most specific) over
    # port-companion language. If either signal exists but neither language
    # was identified, we report "language unknown" rather than "none".
    packages
    |> Enum.map(fn {_name, pkg} -> native_code_bucket(pkg) end)
    |> Enum.reject(&(&1 == :excluded))
    |> Enum.frequencies()
    |> Enum.map(fn {lang, count} -> %{language: lang, count: count} end)
    |> Enum.sort_by(fn %{count: c, language: l} -> {-c, l} end)
  end

  # Mean of per-system total_bytes across target (non-host) systems. Returns
  # nil when there's no per-system data yet. "Host" is excluded because host
  # builds use the build-machine's ABI and aren't representative of what
  # lands on a Nerves target.
  @spec avg_target_footprint(map()) :: non_neg_integer() | nil
  defp avg_target_footprint(pkg) do
    per_sys =
      pkg
      |> Map.get(:footprint)
      |> case do
        %{per_system: ps} when is_map(ps) -> ps
        %{"per_system" => ps} when is_map(ps) -> ps
        _ -> %{}
      end

    sizes =
      per_sys
      |> Enum.reject(fn {sys, _} -> to_string(sys) == "host" end)
      |> Enum.map(fn {_, entry} ->
        case entry do
          %{total_bytes: n} when is_integer(n) -> n
          %{"total_bytes" => n} when is_integer(n) -> n
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    case sizes do
      [] -> nil
      _ -> div(Enum.sum(sizes), length(sizes))
    end
  end

  defp native_code_bucket(pkg) do
    scan = Map.get(pkg, :beam_scan)
    nif_lang = get_in(pkg, [Access.key(:native_components), :nif_language])
    ports = get_in(pkg, [Access.key(:native_components), :port_languages]) || []
    has_compiled_port? = Enum.any?(ports, &(&1 == :c))

    # `nif_language` is misnamed — NccWorker.NativeLang detects the language
    # of any native code found in source (mix.exs rustler/zigler deps,
    # c_src + elixir_make), which may compile into either a NIF (load_nif)
    # or a port companion. Treat it as a language attribution regardless
    # of whether beam_scan saw a NIF at runtime — nerves_uevent, for
    # instance, is a C port and would otherwise read as "none" here.
    cond do
      all_systems_forced_or_skipped?(pkg) ->
        # Package wasn't really scanned (admin override, Gleam skip, toolchain
        # depends on nerves_system_br, etc.) — it's not signal about native
        # code, so bucket as "not scanned" for the dashboard distribution.
        :excluded

      is_nil(scan) ->
        "not scanned"

      is_atom(nif_lang) and not is_nil(nif_lang) ->
        Atom.to_string(nif_lang)

      has_compiled_port? ->
        "c"

      scan_has_nif?(scan) ->
        "language unknown"

      true ->
        "none"
    end
  end

  # native_code_bucket flags all-skipped packages as :excluded so the
  # dashboard distribution can drop them; the Packages-page row view wants
  # a concrete string instead, so re-map to "not scanned".
  defp native_code_bucket_for_row(pkg) do
    case native_code_bucket(pkg) do
      :excluded -> "not scanned"
      bucket -> bucket
    end
  end

  defp all_systems_forced_or_skipped?(pkg) do
    systems = Map.get(pkg, :systems) || %{}

    case Map.values(systems) do
      [] ->
        # No systems in the result at all — probably a runner-side failure.
        # Leave in the distribution under "not scanned" so it's visible
        # rather than silently dropped.
        false

      values ->
        Enum.all?(values, fn sys ->
          # :skipped can be real (Gleam) or admin-forced; either way the
          # package wasn't really exercised for native-code detection.
          # system_pkg for forced results is "forced@admin" in the parsed
          # index, so use starts_with? instead of literal equality.
          sys.status == :skipped or String.starts_with?(to_string(sys.system_pkg || ""), "forced")
        end)
    end
  end

  defp scan_has_nif?(%{flags: flags}) when is_map(flags) do
    Map.get(flags, :nif) == true or Map.get(flags, "nif") == true
  end

  defp scan_has_nif?(_), do: false

  @spec system_pass_rates(map()) :: [%{system: String.t(), pass: integer(), total: integer()}]
  defp system_pass_rates(%{by_system: by_system}) when is_map(by_system) do
    by_system
    # "forced@..." isn't a real Nerves system — it's the synthetic bucket we
    # use for Gleam-skipped and admin-forced results. Filter it out of the
    # per-system pass-rate tile so it doesn't read as a 0% system.
    |> Enum.reject(fn {sys_key, _} -> String.starts_with?(to_string(sys_key), "forced") end)
    |> Enum.map(fn {sys_key, counts} ->
      # counts is a Compatibility.Index.Stats.SystemCounts struct — pull named fields
      # rather than enumerating. Defensive get_in for non-struct maps too.
      pass = get_count(counts, :pass)
      fail = get_count(counts, :fail)
      error = get_count(counts, :error)
      skipped = get_count(counts, :skipped)
      unknown = get_count(counts, :unknown)

      %{
        # by_system keys look like "nerves_system_x86_64@1.24.3"; strip the
        # "@version" tail and run through Architecture.label so the tile
        # shows arch names.
        system:
          sys_key
          |> to_string()
          |> String.split("@")
          |> hd()
          |> Site.Architecture.label(),
        full_key: sys_key,
        pass: pass,
        fail: fail,
        skipped: skipped,
        total: pass + fail + error + skipped + unknown
      }
    end)
    |> Enum.reject(&(&1.total == 0))
    |> Enum.sort_by(&(-&1.total))
  end

  defp system_pass_rates(_), do: []

  defp get_count(counts, key) when is_map(counts) do
    Map.get(counts, key) || Map.get(counts, Atom.to_string(key)) || 0
  end

  defp get_count(_, _), do: 0

  defp determine_results_dir(input_dir) do
    # The input_dir contains the index files (packages_by_version.json, stats.json)
    # The raw result files are in compat_test_results directory at project root
    expanded_input = Path.expand(input_dir)

    # Go up two levels from public/data to get to project root
    project_root = Path.dirname(Path.dirname(expanded_input))
    results_dir = Path.join(project_root, "compat_test_results")

    if File.dir?(results_dir) do
      results_dir
    else
      # Fallback: if input_dir itself contains result.json files, use it
      input_dir
    end
  end

  defp load_index(input_dir, filename, loader_fn) do
    path = Path.join(input_dir, filename)

    if File.exists?(path) do
      loader_fn.(path)
    else
      {:error, {:file_not_found, path}}
    end
  end

  # Extract the latest version for each package name from packages_by_version data
  defp get_latest_per_package(packages_data) do
    latest_packages =
      packages_data.packages
      |> Enum.group_by(fn {key, pkg_data} ->
        pkg_data.package_name || extract_package_name_from_key(key) ||
          extract_package_name(pkg_data)
      end)
      |> Enum.map(fn {pkg_name, entries} ->
        # Find the latest version
        {_key, latest_pkg} =
          entries
          |> Enum.max_by(fn {_key, pkg_data} ->
            version = pkg_data.version || pkg_data.latest_version || "0.0.0"
            version_tuple(version)
          end)

        {pkg_name, latest_pkg}
      end)
      |> Map.new()

    %{packages_data | packages: latest_packages}
  end

  defp extract_package_name_from_key(pkg_key) when is_binary(pkg_key) do
    # Extract package name from "package@version" key
    case String.split(pkg_key, "@", parts: 2) do
      [name, _version] -> name
      _ -> nil
    end
  end

  defp extract_package_name_from_key(_), do: nil

  defp extract_package_name(pkg_data) do
    # Fallback: try to extract from description or use a default
    desc = pkg_data.description

    case desc do
      "Dependency package (" <> rest ->
        String.trim_trailing(rest, ")")

      desc when is_binary(desc) ->
        desc |> String.split() |> List.first() || "unknown"

      _ ->
        "unknown"
    end
  end

  defp version_tuple(version_str) when is_binary(version_str) do
    case Version.parse(version_str) do
      {:ok, v} -> {v.major, v.minor, v.patch}
      _ -> {0, 0, 0}
    end
  end

  defp version_tuple(_), do: {0, 0, 0}

  defp copy_data_files(input_dir, data_dir) do
    for file <- [
          "latest_by_pkg.json",
          "packages_by_version.json",
          "latest_by_pkg_system.json",
          "stats.json"
        ] do
      src = Path.join(input_dir, file)
      dst = Path.join(data_dir, file)

      if File.exists?(src) do
        File.cp!(src, dst)
      end
    end

    # Copy logs directory if it exists
    logs_src = Path.join(input_dir, "logs")
    logs_dst = Path.join(data_dir, "logs")

    if File.dir?(logs_src) do
      File.rm_rf!(logs_dst)
      File.cp_r!(logs_src, logs_dst)
    end
  end

  defp generate_index_page(site_dir, latest_by_pkg, stats, placeholder_names, clusters) do
    template_path = template_path("index.html.eex")

    # Sort packages by name
    packages =
      latest_by_pkg.packages
      |> Enum.sort_by(fn {name, _} -> name end)

    # Create JSON for JavaScript search. Includes real packages plus entries
    # for each dep-name that has a placeholder page, so the main-page search
    # can surface "not scanned yet" packages too. Placeholder entries use the
    # bare name as both search key and filename.
    real_entries =
      Enum.map(packages, fn {name, pkg} ->
        version = pkg.version || pkg.latest_version || "unknown"
        description = pkg.description || ""
        pkg_key = "#{name}@#{version}"
        safe_pkg_key = String.replace(pkg_key, "/", "_")
        %{name: pkg_key, filename: "#{safe_pkg_key}.html", description: description}
      end)

    placeholder_entries =
      placeholder_names
      |> Enum.sort()
      |> Enum.map(fn name ->
        safe_name = String.replace(name, "/", "_")

        %{
          name: name,
          filename: "#{safe_name}.html",
          description: "(not scanned yet)"
        }
      end)

    packages_json = JSON.encode!(real_entries ++ placeholder_entries)

    # Calculate top 10 recently checked passing packages (exclude any with failures/errors)
    recently_passing =
      latest_by_pkg.packages
      |> Enum.filter(fn {_name, pkg} ->
        pkg.last_run_at != nil and all_passing?(pkg)
      end)
      |> Enum.sort_by(
        fn {_name, pkg} ->
          case DateTime.from_iso8601(pkg.last_run_at) do
            {:ok, dt, _} -> dt
            _ -> ~U[1970-01-01 00:00:00Z]
          end
        end,
        {:desc, DateTime}
      )
      |> Enum.take(10)

    # Calculate top 10 recently checked failing packages (any fail/error/skipped) and exclude all-pass)
    recently_failing =
      latest_by_pkg.packages
      |> Enum.filter(fn {_name, pkg} ->
        pkg.last_run_at != nil and any_nonpass?(pkg)
      end)
      |> Enum.sort_by(
        fn {_name, pkg} ->
          case DateTime.from_iso8601(pkg.last_run_at) do
            {:ok, dt, _} -> dt
            _ -> ~U[1970-01-01 00:00:00Z]
          end
        end,
        {:desc, DateTime}
      )
      |> Enum.take(10)

    top_clusters = Enum.take(clusters, 3)
    native_breakdown = native_code_distribution(packages)
    per_system = system_pass_rates(stats)

    assigns = %{
      packages: packages,
      packages_json: packages_json,
      stats: stats,
      generated_at: latest_by_pkg.generated_at,
      recently_passing: recently_passing,
      recently_failing: recently_failing,
      top_clusters: top_clusters,
      native_breakdown: native_breakdown,
      per_system: per_system,
      nav_html: Site.Nav.render(:home)
    }

    content = EEx.eval_file(template_path, assigns: assigns)

    output_path = Path.join(site_dir, "index.html")
    File.write!(output_path, content)
  end

  defp all_passing?(pkg) do
    Enum.any?(pkg.systems) and
      Enum.all?(pkg.systems, fn {_k, sys} -> sys.status == :pass end)
  end

  defp any_nonpass?(pkg) do
    Enum.any?(pkg.systems, fn {_key, sys_result} ->
      sys_result.status in [:fail, :error]
    end)
  end

  defp get_overall_status(pkg_data) do
    if Enum.empty?(pkg_data.systems) do
      :unknown
    else
      statuses = Enum.map(pkg_data.systems, fn {_key, sys} -> sys.status end)

      cond do
        # All-skipped package (Gleam, admin override with status=skipped)
        # shouldn't read as :partial — it was never exercised.
        Enum.all?(statuses, &(&1 == :skipped)) -> :skipped
        Enum.all?(statuses, &(&1 == :pass)) -> :pass
        Enum.any?(statuses, &(&1 in [:fail, :error])) -> :fail
        true -> :partial
      end
    end
  end

  # For each package name, keep the entry with the highest version — that's
  # the one we want dep tables to link to. The value is everything the
  # template needs to render a dep row (link target + status).
  defp build_all_packages_index(packages) do
    packages
    |> Enum.group_by(fn {_key, data} ->
      data.package_name || extract_package_name(data)
    end)
    |> Enum.reject(fn {name, _} -> is_nil(name) or name == "" end)
    |> Enum.map(fn {name, entries} ->
      {key, data} =
        entries
        |> Enum.max_by(
          fn {_k, d} -> (d.version || d.latest_version || "0.0.0") |> version_tuple() end,
          fn -> List.first(entries) end
        )

      {name,
       %{
         link: "#{String.replace(key, "/", "_")}.html",
         status: get_overall_status(data),
         version: data.version || data.latest_version
       }}
    end)
    |> Map.new()
  end

  # Returns the set of package names that are named as dependencies by any
  # package in the index but aren't themselves in the index. Each one gets a
  # minimal placeholder page so dep links are never dead ends.
  defp missing_dep_names(packages, all_packages) do
    packages
    |> Enum.flat_map(fn {_key, data} -> data.dependencies || [] end)
    |> Enum.map(& &1.name)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reject(&Map.has_key?(all_packages, &1))
  end

  defp generate_stats_page(site_dir, stats) do
    template_path = template_path("stats.html.eex")

    assigns = %{
      generated_at: stats.generated_at,
      counts: stats.counts,
      by_system: stats.by_system,
      last_run_finished_at: stats.last_run_finished_at,
      beam_stats: Map.get(stats, :beam_stats, %{}),
      nav_html: Site.Nav.render(:stats)
    }

    content = EEx.eval_file(template_path, assigns: assigns)

    output_path = Path.join(site_dir, "stats.html")
    File.write!(output_path, content)
  end

  defp generate_package_pages(
         packages_dir,
         packages_data,
         metadata,
         all_packages,
         placeholder_names
       ) do
    template_path = template_path("package.html.eex")
    badges_dir = Path.join(Path.dirname(packages_dir), "badges")
    File.mkdir_p!(badges_dir)

    real_pkg_keys = Map.keys(packages_data.packages)

    for {pkg_key, pkg_data} <- packages_data.packages do
      # Extract package name and version from struct fields (schema 3) or fallback
      pkg_name =
        pkg_data.package_name || extract_package_name_from_key(pkg_key) ||
          extract_package_name(pkg_data)

      pkg_version = pkg_data.version || pkg_data.latest_version

      # Sort systems by key
      systems = Enum.sort_by(pkg_data.systems, fn {key, _} -> key end)

      # Get package metadata
      pkg_meta = Compatibility.PackageMetadata.get(metadata, pkg_name)

      # Generate badge (use package name, not package@version)
      badge_svg = Site.Badge.generate(pkg_name, pkg_data)
      safe_name = String.replace(pkg_name, "/", "_")
      badge_path = Path.join(badges_dir, "#{safe_name}.svg")
      File.write!(badge_path, badge_svg)

      # Create filename with version: circuits_gpio@2.1.2.html
      safe_pkg_key = String.replace(pkg_key, "/", "_")
      output_filename = "#{safe_pkg_key}.html"

      # Find all versions of this package
      all_versions =
        packages_data.packages
        |> Enum.filter(fn {key, data} ->
          data_pkg_name =
            data.package_name || extract_package_name_from_key(key) ||
              extract_package_name(data)

          data_pkg_name == pkg_name
        end)
        |> Enum.map(fn {key, data} ->
          version = data.version || data.latest_version
          overall_status = get_overall_status(data)
          safe_key = String.replace(key, "/", "_")

          %{
            version: version,
            status: overall_status,
            key: key,
            safe_key: safe_key
          }
        end)
        |> Enum.sort_by(& &1.version, {:desc, Version})

      assigns = %{
        package_name: pkg_name,
        package_version: pkg_version,
        package_key: pkg_key,
        package: pkg_data,
        systems: systems,
        all_packages: all_packages,
        all_versions: all_versions,
        metadata: pkg_meta,
        # Mean footprint across target (non-host) systems — the top-level
        # footprint.total_bytes isn't populated by the worker, so the old
        # header pill always read as 0 B. Computed the same way as the
        # Packages-page column.
        avg_footprint_bytes: avg_target_footprint(pkg_data),
        format_bytes: &format_bytes/1,
        # Package pages live under packages/, so nav links need "../" to
        # reach the site root.
        nav_html: Site.Nav.render(:home, "../")
      }

      content = EEx.eval_file(template_path, assigns: assigns)

      output_path = Path.join(packages_dir, output_filename)
      File.write!(output_path, content)
    end

    generate_placeholder_pages(packages_dir, placeholder_names, real_pkg_keys)
  end

  # Writes a minimal page for each dep-name referenced by some package but
  # never itself scanned. The filename (<name>.html, no version) matches what
  # the template's dep link falls back to when all_packages has no entry for
  # a name — so clicking a dep link never 404s.
  #
  # Also cleans up orphan files left behind when a package transitions from
  # "placeholder only" to "has a real version page" (e.g. when it later
  # shows up in some scanned package's dependency_scans). The keep-set
  # includes BOTH the current placeholder names AND every real package
  # key — bare-name keys (older index schemas) shouldn't be mistaken for
  # orphans.
  defp generate_placeholder_pages(packages_dir, placeholder_names, real_pkg_keys) do
    keep =
      [placeholder_names, real_pkg_keys]
      |> Enum.concat()
      |> Enum.map(fn name -> "#{String.replace(name, "/", "_")}.html" end)
      |> MapSet.new()

    for dep_name <- placeholder_names do
      safe_name = String.replace(dep_name, "/", "_")
      output_path = Path.join(packages_dir, "#{safe_name}.html")
      File.write!(output_path, placeholder_html(dep_name))
    end

    case File.ls(packages_dir) do
      {:ok, entries} ->
        for name <- entries,
            String.ends_with?(name, ".html"),
            not MapSet.member?(keep, name) do
          File.rm(Path.join(packages_dir, name))
        end

      _ ->
        :ok
    end
  end

  defp placeholder_html(dep_name) do
    nav = Site.Nav.render(:none, "../") |> IO.iodata_to_binary()

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <title>#{dep_name} — not scanned yet</title>
      <style>
        #{Site.Nav.css()}
        main.page { max-width: 720px; }
        .card { background: #f9fafb; border: 1px solid #e5e7eb; border-radius: 8px; padding: 20px; }
        code { background: #e5e7eb; padding: 2px 6px; border-radius: 3px; }
      </style>
    </head>
    <body>
      #{nav}
      <main class="page">
        <h1>#{dep_name}</h1>
        <p class="subtitle">Referenced as a dependency but not yet scanned.</p>
        <div class="card">
          <p>This package appears in the <code>deps</code> list of another package that has been tested,
          but the Nerves Compatibility scanner hasn't processed <code>#{dep_name}</code> itself yet.</p>
          <p>It's in the queue — check back later, or look at its page on
          <a href="https://hex.pm/packages/#{dep_name}" target="_blank" rel="noopener">hex.pm</a>.</p>
        </div>
      </main>
    </body>
    </html>
    """
  end

  # Resolves a template filename to an absolute path. Checks :site, :template_dir
  # env first so callers running inside an escript (where priv/ lives in a zip
  # archive that File.read can't reach into) can point at a real on-disk
  # templates directory. Falls back to the installed app's priv in the normal
  # mix-run case.
  @spec template_path(String.t()) :: String.t()
  defp template_path(filename) do
    dir =
      Application.get_env(:site, :template_dir) ||
        Application.app_dir(:site, "priv/templates")

    Path.join(dir, filename)
  end

  @spec format_bytes(integer()) :: String.t()
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 1)} GB"
end
