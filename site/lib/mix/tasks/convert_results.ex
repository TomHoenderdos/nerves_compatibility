defmodule Mix.Tasks.ConvertResults do
  @moduledoc """
  Converts worker result.json files into the index formats expected by the site generator.

  Usage:
      mix convert_results --input compat_test_results --output public/data
  """

  use Mix.Task

  @beam_flag_keys ["start_callback", "nif", "shell", "app_env", "os_env", "os_exec", "halt"]

  @shortdoc "Convert worker results to site index format"

  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [input: :string, output: :string],
        aliases: [i: :input, o: :output]
      )

    input_dir = opts[:input] || "compat_test_results"
    output_dir = opts[:output] || "public/data"

    IO.puts("Converting results from #{input_dir} to #{output_dir}")

    # Find all result JSON files
    result_files = Path.wildcard(Path.join(input_dir, "*.json"))

    if result_files == [] do
      IO.puts("No result files found in #{input_dir}")
      System.halt(1)
    end

    # Load all results
    results =
      Enum.map(result_files, fn file ->
        {:ok, content} = File.read(file)
        {:ok, data} = JSON.decode(content)
        data
      end)

    # Generate indexes
    packages_by_version = generate_packages_by_version(results)
    stats = generate_stats(packages_by_version, results)

    # Write output files
    File.mkdir_p!(output_dir)

    packages_json = JSON.encode_to_iodata!(packages_by_version)
    File.write!(Path.join(output_dir, "packages_by_version.json"), packages_json)
    IO.puts("✓ Written packages_by_version.json")

    # Also write latest_by_pkg.json for backward compatibility
    latest_by_pkg = generate_latest_by_package_compat(packages_by_version)
    latest_json = JSON.encode_to_iodata!(latest_by_pkg)
    File.write!(Path.join(output_dir, "latest_by_pkg.json"), latest_json)
    IO.puts("✓ Written latest_by_pkg.json (backward compat)")

    stats_json = JSON.encode_to_iodata!(stats)
    File.write!(Path.join(output_dir, "stats.json"), stats_json)
    IO.puts("✓ Written stats.json")

    copy_logs(input_dir, output_dir)

    IO.puts("Conversion complete!")
  end

  # Copy the per-package log directories from input to output, so
  # <pkg>.html's relative ../../data/logs/<pkg>/<system>.log links resolve.
  # The orchestrator's copy_results/2 puts logs under
  # compat_test_results/logs/<pkg>/, but convert_results alone only wrote
  # the JSON indexes — which left log links in the rendered site broken.
  defp copy_logs(input_dir, output_dir) do
    src = Path.join(input_dir, "logs")
    dst = Path.join(output_dir, "logs")

    if File.dir?(src) do
      File.rm_rf!(dst)
      File.cp_r!(src, dst)
      count = src |> File.ls!() |> length()
      IO.puts("✓ Copied logs for #{count} package(s)")
    end
  end

  # Generate packages indexed by package@version key.
  # This allows us to track multiple versions of the same package.
  defp generate_packages_by_version(results) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    primary_packages =
      results
      |> Enum.map(fn result ->
        pkg_name = result["package"]["name"]
        pkg_version = result["package"]["version"]

        forced_status = result["forced_status"]

        result_systems =
          cond do
            forced_status in ["pass", "fail", "skipped"] ->
              %{
                "forced@admin" => %{
                  "system_pkg" => "forced",
                  "system_version" => "admin_override",
                  "status" => forced_status,
                  "hex_version_tested" => pkg_version,
                  "run_id" => result["run_id"] || "forced",
                  "log_path" => "logs/#{pkg_name}/forced.log"
                }
              }

            true ->
              result["systems"] || %{}
          end

        systems =
          result_systems
          |> Enum.map(fn {system_name, sys_result} ->
            system_version = system_version_for(result, system_name)
            key = build_system_key(system_name, system_version)

            value = %{
              "system_pkg" => system_name,
              "system_version" => system_version,
              "status" => sys_result["status"],
              "hex_version_tested" => pkg_version,
              "run_id" => result["run_id"],
              "log_path" => "logs/#{pkg_name}/#{system_name}.log",
              "deterministic" => Map.get(sys_result, "deterministic"),
              "determinism_changes" => Map.get(sys_result, "determinism_changes")
            }

            {key, value}
          end)
          |> Map.new()

        footprint =
          result["package"]["footprint"] ||
            %{
              "file_manifest" => %{"ebin" => [], "priv" => []}
            }

        beam_scan_summary = summarize_beam_scan(result)
        dependency_scans = summarize_dependency_scans(result)

        native_components = result["package"]["native_components"]
        github_url = result["package"]["github_url"]
        source_changes = result["package"]["source_changes"]

        pkg_data =
          %{
            "package_name" => pkg_name,
            "description" => result["package"]["description"] || "Package #{pkg_name}",
            "latest_version" => pkg_version,
            "version" => pkg_version,
            "last_run_at" => result["finished_at"],
            "dependencies" => result["package"]["dependencies"] || [],
            "github_url" => github_url,
            "native_components" => native_components,
            "source_changes" => source_changes,
            "footprint" => footprint,
            "systems" => systems
          }
          |> maybe_put_beam_scan(beam_scan_summary)
          |> maybe_put_dependency_scans(dependency_scans)

        pkg_key = "#{pkg_name}@#{pkg_version}"
        {pkg_key, pkg_data}
      end)
      |> Map.new()

    # Extract dependency packages from dependency_scans
    dependency_packages = extract_dependency_packages(results)

    # Merge primary and dependency packages, ensuring failures are preserved
    all_packages = merge_packages(primary_packages, dependency_packages)

    %{
      "schema" => 3,
      "generated_at" => now,
      "packages" => all_packages
    }
  end

  # Generate backward-compatible latest_by_pkg structure (schema 2)
  # Groups by package name and keeps only the latest version
  defp generate_latest_by_package_compat(packages_by_version) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    latest_packages =
      packages_by_version["packages"]
      |> Enum.group_by(fn {_key, pkg_data} -> pkg_data["package_name"] end)
      |> Enum.map(fn {pkg_name, entries} ->
        # Find the latest version
        {_key, latest_pkg} =
          entries
          |> Enum.max_by(fn {_key, pkg_data} ->
            version_tuple(pkg_data["version"] || "0.0.0")
          end)

        {pkg_name, latest_pkg}
      end)
      |> Map.new()

    %{
      "schema" => 2,
      "generated_at" => now,
      "packages" => latest_packages
    }
  end

  defp generate_stats(latest_by_pkg, results) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    package_counts = package_counts(latest_by_pkg)
    beam_stats = beam_stats(latest_by_pkg)

    # Build by_system counts
    by_system =
      results
      |> Enum.flat_map(fn result ->
        result_systems = result["systems"] || %{}

        Enum.map(result_systems, fn {system_name, sys_result} ->
          system_version = system_version_for(result, system_name)
          key = build_system_key(system_name, system_version)
          {key, sys_result["status"]}
        end)
      end)
      |> Enum.group_by(fn {key, _status} -> key end, fn {_key, status} -> status end)
      |> Enum.map(fn {key, statuses} ->
        counts = %{
          "pass" => Enum.count(statuses, &(&1 == "pass")),
          "fail" => Enum.count(statuses, &(&1 == "fail")),
          "error" => Enum.count(statuses, &(&1 == "error")),
          "skipped" => Enum.count(statuses, &(&1 == "skipped")),
          "unknown" => Enum.count(statuses, &(&1 == "unknown"))
        }

        {key, counts}
      end)
      |> Map.new()

    # Get the latest finished_at timestamp
    last_run_finished_at =
      results
      |> Enum.map(& &1["finished_at"])
      |> Enum.max(fn -> now end)

    %{
      "schema" => 2,
      "generated_at" => now,
      "counts" => package_counts,
      "by_system" => by_system,
      "beam_stats" => beam_stats,
      "last_run_finished_at" => last_run_finished_at
    }
  end

  defp beam_stats(latest_by_pkg) do
    packages = latest_by_pkg["packages"] || %{}

    acc = %{
      "packages_with_beam_scan" => 0,
      "languages" => %{},
      "packages_with_nif" => 0,
      "packages_with_protocols" => 0,
      "packages_with_start_callback" => 0,
      "packages_with_shell" => 0,
      "packages_with_halt" => 0,
      "total_beam_count" => 0,
      "packages_with_beam_count" => 0
    }

    acc =
      packages
      |> Enum.reduce(acc, fn {_pkg, pkg_data}, acc ->
        case pkg_data["beam_scan"] do
          %{} = scan ->
            acc
            |> increment("packages_with_beam_scan")
            |> count_languages(Map.get(scan, "languages", []))
            |> maybe_increment("packages_with_nif", flag_on?(scan, "nif"))
            |> maybe_increment("packages_with_protocols", protocols_present?(scan))
            |> maybe_increment("packages_with_start_callback", flag_on?(scan, "start_callback"))
            |> maybe_increment("packages_with_shell", flag_on?(scan, "shell"))
            |> maybe_increment("packages_with_halt", flag_on?(scan, "halt"))
            |> accumulate_beam_count(Map.get(scan, "beam_count"))

          _ ->
            acc
        end
      end)

    avg_beam_count =
      case acc["packages_with_beam_count"] do
        0 -> nil
        n -> Float.round(acc["total_beam_count"] / n, 1)
      end

    acc
    |> Map.drop(["total_beam_count"])
    |> Map.put("avg_beam_count_per_pkg", avg_beam_count)
  end

  defp increment(acc, key) do
    Map.update!(acc, key, &(&1 + 1))
  end

  defp maybe_increment(acc, _key, false), do: acc
  defp maybe_increment(acc, key, true), do: increment(acc, key)

  defp flag_on?(scan, key) do
    scan
    |> Map.get("flags", %{})
    |> Map.get(key, false)
    |> truthy?()
  end

  defp protocols_present?(scan) do
    protocols = Map.get(scan, "protocols", %{})

    Enum.any?([Map.get(protocols, "defined", []), Map.get(protocols, "impls", [])], fn list ->
      is_list(list) and list != []
    end)
  end

  defp count_languages(acc, languages) when is_list(languages) do
    lang_counts = Map.get(acc, "languages")

    updated =
      languages
      |> Enum.map(&to_string/1)
      |> Enum.reduce(lang_counts, fn lang, counts -> Map.update(counts, lang, 1, &(&1 + 1)) end)

    Map.put(acc, "languages", updated)
  end

  defp count_languages(acc, _), do: acc

  defp accumulate_beam_count(acc, nil), do: acc

  defp accumulate_beam_count(acc, count) when is_integer(count) and count >= 0 do
    acc
    |> Map.update!("total_beam_count", &(&1 + count))
    |> Map.update!("packages_with_beam_count", &(&1 + 1))
  end

  defp accumulate_beam_count(acc, _), do: acc

  defp package_counts(latest_by_pkg) do
    packages = latest_by_pkg["packages"] || %{}

    # Count unique package names (excluding version)
    unique_packages =
      packages
      |> Enum.map(fn {pkg_key, _pkg_data} ->
        # Extract package name from "package@version" key
        case String.split(pkg_key, "@", parts: 2) do
          [name, _version] -> name
          _ -> pkg_key
        end
      end)
      |> Enum.uniq()
      |> length()

    # Count package/version combinations and their statuses
    version_counts =
      packages
      |> Enum.reduce(
        %{
          "total_versions" => 0,
          "pass" => 0,
          "fail" => 0,
          "error" => 0,
          "skipped" => 0,
          "unknown" => 0
        },
        fn {_pkg, pkg_data}, acc ->
          systems = pkg_data["systems"] || %{}
          statuses = systems |> Map.values() |> Enum.map(&Map.get(&1, "status", "unknown"))

          status =
            cond do
              Enum.any?(statuses, &(&1 == "error")) -> "error"
              Enum.any?(statuses, &(&1 == "fail")) -> "fail"
              Enum.any?(statuses, &(&1 == "pass")) -> "pass"
              Enum.any?(statuses, &(&1 == "skipped")) -> "skipped"
              true -> "unknown"
            end

          acc
          |> Map.update!("total_versions", &(&1 + 1))
          |> Map.update!(status, &(&1 + 1))
        end
      )

    # Return counts with unique packages as "total"
    version_counts
    |> Map.put("total", unique_packages)
  end

  # Compose the system index key. Real systems get `<name>@<version>`; the
  # synthetic "forced@..." sinks (Gleam skip / admin override) are
  # already composite, so appending another @version produced silly keys
  # like "forced@admin@unknown@unknown". Leave those alone.
  defp build_system_key(system_name, system_version) do
    if String.starts_with?(to_string(system_name), "forced") do
      to_string(system_name)
    else
      "#{system_name}@#{system_version}"
    end
  end

  defp system_version_for(result, "host") do
    toolchain = result["toolchain"] || %{}
    elixir = toolchain["elixir"] || "unknown"
    erlang = toolchain["erlang"] || "unknown"
    "Elixir #{elixir} / Erlang #{erlang}"
  end

  defp system_version_for(result, system_name), do: get_system_version(result, system_name)

  defp get_system_version(result, system_name) do
    # First try to get it from the system_version field if available
    case get_in(result, ["systems", system_name, "system_version"]) do
      nil ->
        # Fall back to extracting from log_tail
        case result["systems"][system_name]["log_tail"] do
          nil ->
            "unknown"

          log_tail ->
            # Look for pattern like "  nerves_system_rpi4 1.32.0" in the Unchanged section
            regex = ~r/^  #{Regex.escape(system_name)} ([\d.]+)$/m

            case Regex.run(regex, log_tail) do
              [_, version] -> version
              _ -> "unknown"
            end
        end

      version when is_binary(version) ->
        version

      _ ->
        "unknown"
    end
  end

  defp maybe_put_beam_scan(pkg_data, nil), do: pkg_data
  defp maybe_put_beam_scan(pkg_data, scan), do: Map.put(pkg_data, "beam_scan", scan)

  defp maybe_put_dependency_scans(pkg_data, scans) when is_map(scans),
    do: Map.put(pkg_data, "dependency_scans", scans)

  defp summarize_beam_scan(result) do
    systems = result["systems"] || %{}

    scans =
      systems
      |> Enum.reduce([], fn {system_name, sys_result}, acc ->
        case sys_result["beam_scan"] do
          %{} = scan ->
            system_version = system_version_for(result, system_name)
            [{system_name, system_version, scan} | acc]

          _ ->
            acc
        end
      end)
      |> Enum.reverse()

    case scans do
      [] -> nil
      _ -> build_beam_summary(scans)
    end
  end

  defp build_beam_summary(scans) do
    flags = merge_beam_flags(scans)
    languages = collect_languages(scans)
    start_modules = collect_start_modules(scans)
    protocols = collect_protocols(scans)
    samples = collect_samples(scans)
    counts = collect_counts(scans)

    beam_count =
      scans
      |> Enum.map(fn {_sys, _ver, scan} -> scan["beam_count"] end)
      |> Enum.reject(&is_nil/1)
      |> List.first()

    scanned_systems = Enum.map(scans, fn {sys, ver, _scan} -> "#{sys}@#{ver}" end)

    errors =
      scans
      |> Enum.flat_map(fn {_sys, _ver, scan} -> Map.get(scan, "errors", []) end)
      |> Enum.uniq()

    %{
      "flags" => flags,
      "languages" => languages,
      "beam_count" => beam_count,
      "start_modules" => start_modules,
      "protocols" => protocols,
      "samples" => samples,
      "counts" => counts,
      "scanned_systems" => scanned_systems,
      "errors" => errors
    }
  end

  defp summarize_dependency_scans(result) do
    systems = result["systems"] || %{}

    systems
    |> Enum.reduce(%{}, fn {_system_name, sys_result}, acc ->
      case sys_result["dependency_scans"] do
        %{} = deps -> Map.merge(acc, deps, fn _k, v1, _v2 -> v1 end)
        _ -> acc
      end
    end)
  end

  defp merge_beam_flags(scans) do
    Enum.reduce(@beam_flag_keys, %{}, fn key, acc ->
      present =
        Enum.any?(scans, fn {_sys, _ver, scan} ->
          scan
          |> Map.get("flags", %{})
          |> Map.get(key, false)
          |> truthy?()
        end)

      Map.put(acc, key, present)
    end)
  end

  defp collect_languages(scans) do
    scans
    |> Enum.flat_map(fn {_sys, _ver, scan} -> Map.get(scan, "languages", []) end)
    |> Enum.uniq()
  end

  defp collect_start_modules(scans) do
    scans
    |> Enum.flat_map(fn {_sys, _ver, scan} -> Map.get(scan, "start_modules", []) end)
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp collect_protocols(scans) do
    defined =
      scans
      |> Enum.flat_map(fn {_sys, _ver, scan} -> get_in(scan, ["protocols", "defined"]) || [] end)
      |> Enum.uniq()
      |> Enum.take(12)

    impls =
      scans
      |> Enum.flat_map(fn {_sys, _ver, scan} -> get_in(scan, ["protocols", "impls"]) || [] end)
      |> Enum.uniq()
      |> Enum.take(12)

    %{"defined" => defined, "impls" => impls}
  end

  defp collect_samples(scans) do
    Enum.reduce(@beam_flag_keys, %{}, fn key, acc ->
      samples =
        scans
        |> Enum.flat_map(fn {_sys, _ver, scan} ->
          scan
          |> Map.get("evidence", %{})
          |> Map.get(key, [])
          |> Enum.map(&format_evidence/1)
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.take(4)

      Map.put(acc, key, samples)
    end)
  end

  defp collect_counts(scans) do
    Enum.reduce(@beam_flag_keys, %{}, fn key, acc ->
      count =
        scans
        |> Enum.reduce(0, fn {_sys, _ver, scan}, total ->
          base =
            if key == "start_callback" do
              Map.get(scan, "start_modules", [])
            else
              scan |> Map.get("evidence", %{}) |> Map.get(key, [])
            end

          total + length(base || [])
        end)

      Map.put(acc, key, count)
    end)
  end

  defp format_evidence(%{"beam" => beam, "mfa" => mfa}) do
    cond do
      beam != "" and mfa != "" -> beam <> " " <> mfa
      mfa != "" -> mfa
      beam != "" -> beam
      true -> nil
    end
  end

  defp format_evidence(_), do: nil

  defp truthy?(value) when value in [true, "true", 1], do: true
  defp truthy?(_), do: false

  # Extract dependency packages from dependency_scans across all results.
  # For each dependency, create a package entry with systems inherited from
  # the parent package.
  defp extract_dependency_packages(results) do
    results
    |> Enum.flat_map(fn result ->
      parent_pkg = result["package"]["name"]
      parent_status = result["forced_status"]

      result_systems = result["systems"] || %{}

      result_systems
      |> Enum.flat_map(fn {system_name, sys_result} ->
        # Only process successful parent builds
        status = sys_result["status"]
        dependency_scans = sys_result["dependency_scans"]

        if status == "pass" && is_map(dependency_scans) do
          system_version = system_version_for(result, system_name)
          system_key = "#{system_name}@#{system_version}"
          run_id = result["run_id"]

          dependency_scans
          |> Enum.map(fn {dep_key, dep_scan} ->
            {dep_name, dep_version} = parse_dep_key(dep_key)

            dep_footprint = dep_scan["footprint"]

            dep_system_data = %{
              "system_pkg" => system_name,
              "system_version" => system_version,
              "status" => "pass",
              "hex_version_tested" => dep_version,
              "run_id" => run_id,
              "log_path" => "logs/#{parent_pkg}/#{system_name}.log",
              "deterministic" => nil,
              "determinism_changes" => nil,
              "derived_from" => parent_pkg
            }

            {dep_name, dep_version, system_key, dep_system_data, dep_scan, dep_footprint}
          end)
        else
          # For failed builds, mark all dependencies as failed too
          if parent_status == "fail" && is_map(dependency_scans) do
            system_version = system_version_for(result, system_name)
            system_key = "#{system_name}@#{system_version}"
            run_id = result["run_id"]

            dependency_scans
            |> Enum.map(fn {dep_key, dep_scan} ->
              {dep_name, dep_version} = parse_dep_key(dep_key)

              dep_footprint = dep_scan["footprint"]

              dep_system_data = %{
                "system_pkg" => system_name,
                "system_version" => system_version,
                "status" => "fail",
                "hex_version_tested" => dep_version,
                "run_id" => run_id,
                "log_path" => "logs/#{parent_pkg}/#{system_name}.log",
                "deterministic" => nil,
                "determinism_changes" => nil,
                "derived_from" => parent_pkg
              }

              {dep_name, dep_version, system_key, dep_system_data, dep_scan, dep_footprint}
            end)
          else
            []
          end
        end
      end)
    end)
    |> Enum.group_by(fn {dep_name, _dep_version, _system_key, _system_data, _scan, _footprint} ->
      dep_name
    end)
    |> Enum.map(fn {dep_name, entries} ->
      # Get the latest version for this dependency
      dep_version =
        entries
        |> Enum.map(fn {_, v, _, _, _, _} -> v end)
        |> Enum.max_by(&version_tuple/1, fn -> "0.0.0" end)

      # Collect all system entries for this dependency
      systems =
        entries
        |> Enum.map(fn {_, _, system_key, system_data, _scan, _footprint} ->
          {system_key, system_data}
        end)
        |> Map.new()

      # Get beam scan from one of the entries (they should all be similar)
      beam_scan =
        entries
        |> Enum.find_value(fn {_, _, _, _, scan, _} -> scan end)

      # Collect per-system footprint data
      per_system_footprint =
        entries
        |> Enum.map(fn {_, _, _system_key, system_data, _scan, fp} ->
          system_name = system_data["system_pkg"]
          # Only include footprint if it exists and is not nil
          if fp && is_map(fp) do
            {system_name, fp}
          else
            nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Map.new()

      # Use first non-empty manifest as representative
      first_manifest =
        entries
        |> Enum.find_value(fn {_, _, _, _, _, fp} ->
          if fp && is_map(fp) && fp["file_manifest"] do
            fp["file_manifest"]
          end
        end) || %{"ebin" => [], "priv" => []}

      footprint = %{
        "file_manifest" => first_manifest,
        "per_system" => per_system_footprint
      }

      # Determine overall status: if any system failed, package is failed
      overall_status =
        systems
        |> Map.values()
        |> Enum.any?(fn sys -> sys["status"] == "fail" end)
        |> if(do: "fail", else: "pass")

      last_run_at =
        entries
        |> Enum.map(fn {_, _, _, system_data, _, _} ->
          system_data["run_id"]
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.max(fn -> nil end)

      pkg_data = %{
        "package_name" => dep_name,
        "description" => "Found via dependency scan. Awaiting full scan.",
        "latest_version" => dep_version,
        "version" => dep_version,
        "last_run_at" => last_run_at,
        "dependencies" => [],
        "footprint" => footprint,
        "systems" => systems,
        "is_dependency" => true,
        "overall_status" => overall_status
      }

      pkg_data =
        if beam_scan do
          pkg_data
          |> maybe_put_beam_scan(normalize_beam_scan_for_dependency(beam_scan))
        else
          pkg_data
        end

      pkg_key = "#{dep_name}@#{dep_version}"
      {pkg_key, pkg_data}
    end)
    |> Map.new()
  end

  defp parse_dep_key(dep_key) when is_binary(dep_key) do
    case String.split(dep_key, "@", parts: 2) do
      [name, version] -> {name, version}
      [name] -> {name, "unknown"}
    end
  end

  defp version_tuple(version_str) do
    case Version.parse(version_str) do
      {:ok, v} -> {v.major, v.minor, v.patch}
      _ -> {0, 0, 0}
    end
  end

  defp normalize_beam_scan_for_dependency(scan) when is_map(scan) do
    %{
      "flags" => scan["flags"] || %{},
      "start_modules" => scan["start_modules"] || [],
      "protocols" => scan["protocols"] || %{"defined" => [], "impls" => []},
      "evidence" => scan["evidence"] || %{},
      "languages" => scan["languages"] || [],
      "beam_count" => scan["beam_count"]
    }
  end

  # Merge primary packages with dependency packages.
  # Rule: If a package fails anywhere, it should always show as failed.
  defp merge_packages(primary_packages, dependency_packages) do
    all_package_names =
      MapSet.union(
        MapSet.new(Map.keys(primary_packages)),
        MapSet.new(Map.keys(dependency_packages))
      )

    all_package_names
    |> Enum.map(fn pkg_name ->
      primary = Map.get(primary_packages, pkg_name)
      dependency = Map.get(dependency_packages, pkg_name)

      merged_data =
        case {primary, dependency} do
          {nil, nil} ->
            nil

          {primary_data, nil} ->
            primary_data

          {nil, dep_data} ->
            dep_data

          {primary_data, dep_data} ->
            # Merge systems from both
            merged_systems = Map.merge(dep_data["systems"], primary_data["systems"])

            # Determine overall status - if either failed, mark as failed
            primary_failed? =
              primary_data["systems"]
              |> Map.values()
              |> Enum.any?(fn sys -> sys["status"] == "fail" end)

            dep_failed? =
              dep_data["systems"]
              |> Map.values()
              |> Enum.any?(fn sys -> sys["status"] == "fail" end)

            overall_status = if primary_failed? or dep_failed?, do: "fail", else: "pass"

            # Primary data takes precedence for most fields
            primary_data
            |> Map.put("systems", merged_systems)
            |> Map.put("overall_status", overall_status)
        end

      {pkg_name, merged_data}
    end)
    |> Enum.reject(fn {_, data} -> is_nil(data) end)
    |> Map.new()
  end
end
