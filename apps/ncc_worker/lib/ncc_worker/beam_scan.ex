defmodule NccWorker.BeamScan do
  @moduledoc """
  Runs BeamScanner against the built release and normalizes results so they are
  safe to serialize in worker output.
  """

  @max_evidence 30

  @spec analyze(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def analyze(build_path, package_name) do
    with {:ok, package_dir} <- find_package_dir(build_path, package_name) do
      scan = BeamScanner.analyze(package_dir)
      {:ok, normalize(scan)}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:beam_scan_failed, Exception.message(error)}}
  end

  @spec analyze_dependencies(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def analyze_dependencies(build_path, _package_name) do
    with {:ok, release_paths} <- find_release_paths(build_path),
         {:ok, app_dirs} <- collect_app_dirs(release_paths) do
      scans =
        app_dirs
        |> Enum.map(fn {app, vsn, dir} ->
          key = app <> "@" <> vsn
          {key, run_dependency_scan(dir, key)}
        end)
        |> Map.new()

      {:ok, scans}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:dependency_beam_scan_failed, Exception.message(error)}}
  end

  defp find_package_dir(build_path, package_name) do
    with {:ok, paths} <- find_release_paths(build_path),
         true <- File.dir?(paths.lib_dir),
         {:ok, entries} <- File.ls(paths.lib_dir),
         package_dir when is_binary(package_dir) <-
           Enum.find(entries, &String.starts_with?(&1, package_name <> "-")) do
      {:ok, Path.join(paths.lib_dir, package_dir)}
    else
      false -> {:error, :release_not_found}
      _ -> {:error, :package_release_not_found}
    end
  end

  defp find_release_paths(build_path) do
    rel_dir = Path.join(build_path, "rel")

    with {:ok, releases} <- File.ls(rel_dir),
         release when is_binary(release) <-
           Enum.find(releases, &File.dir?(Path.join(rel_dir, &1))) do
      release_path = Path.join(rel_dir, release)
      lib_dir = Path.join(release_path, "lib")

      erts_lib_dirs =
        release_path
        |> Path.join("erts-*")
        |> Path.wildcard()
        |> Enum.map(&Path.join(&1, "lib"))
        |> Enum.filter(&File.dir?/1)

      {:ok, %{release_path: release_path, lib_dir: lib_dir, erts_lib_dirs: erts_lib_dirs}}
    else
      _ -> {:error, :release_not_found}
    end
  end

  defp collect_app_dirs(paths) do
    roots = [paths.lib_dir | paths.erts_lib_dirs] |> Enum.filter(&File.dir?/1)

    apps =
      roots
      |> Enum.flat_map(&apps_from_root/1)
      |> Enum.uniq_by(fn {app, vsn, _dir} -> {app, vsn} end)

    {:ok, apps}
  end

  defp apps_from_root(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn entry ->
          dir = Path.join(root, entry)

          case {File.dir?(dir), parse_app_version(entry)} do
            {true, {app, vsn}} -> [{app, vsn, dir}]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp parse_app_version(entry) do
    case String.split(entry, "-", parts: 2) do
      [app, vsn] -> {app, vsn}
      _ -> nil
    end
  end

  defp run_dependency_scan(dir, key) do
    scan_result =
      case BeamScanner.analyze(dir) do
        scan when is_map(scan) -> normalize(scan)
        other -> %{"errors" => ["beam scan failed for #{key}: #{inspect(other)}"]}
      end

    # Footprint is now included in the scan result from BeamScanner
    scan_result
  rescue
    error -> %{"errors" => ["beam scan failed for #{key}: #{Exception.message(error)}"]}
  end

  defp normalize(scan) do
    %{
      "flags" => %{
        "start_callback" => safe_bool(scan[:start_callback?]),
        "nif" => safe_bool(scan[:nif_calls?]),
        "shell" => safe_bool(scan[:shell_calls?]),
        "app_env" => safe_bool(scan[:app_env_calls?]),
        "os_env" => safe_bool(scan[:os_env_calls?]),
        "os_exec" => safe_bool(scan[:os_exec_calls?]),
        "halt" => safe_bool(scan[:halt_calls?])
      },
      "start_modules" => scan[:start_callback_modules] |> to_strings(),
      "protocols" => %{
        "defined" => scan[:protocols_defined] |> normalize_protocols(),
        "impls" => scan[:protocol_impls] |> normalize_protocol_impls()
      },
      "evidence" => %{
        "nif" => normalize_evidence(scan[:nif_evidence]),
        "shell" => normalize_evidence(scan[:shell_evidence]),
        "app_env" => normalize_evidence(scan[:app_env_evidence]),
        "os_env" => normalize_evidence(scan[:os_env_evidence]),
        "os_exec" => normalize_evidence(scan[:os_exec_evidence]),
        "halt" => normalize_evidence(scan[:halt_evidence])
      },
      "languages" => scan[:languages] |> to_strings(),
      "beam_count" => scan[:beam_count],
      "footprint" => normalize_footprint(scan[:footprint]),
      "errors" => scan[:errors] |> to_strings()
    }
  end

  defp normalize_evidence(list) when is_list(list) do
    list
    |> Enum.take(@max_evidence)
    |> Enum.map(fn entry ->
      %{
        "beam" => entry[:beam] |> to_string_safe(),
        "file" => entry[:file] |> to_string_safe(),
        "mfa" => entry[:mfa] |> format_mfa()
      }
    end)
  end

  defp normalize_evidence(_), do: []

  defp normalize_protocols(list) when is_list(list) do
    list
    |> Enum.map(fn entry ->
      name = entry[:protocol] |> to_string_safe()

      if entry[:fallback_to_any] do
        name <> " (fallback to any)"
      else
        name
      end
    end)
  end

  defp normalize_protocols(_), do: []

  defp normalize_protocol_impls(list) when is_list(list) do
    list
    |> Enum.map(fn entry ->
      proto = entry[:protocol] |> to_string_safe()
      target = entry[:for] |> inspect_safe()
      impl = entry[:impl] |> to_string_safe()
      proto <> " for " <> target <> " -> " <> impl
    end)
  end

  defp normalize_protocol_impls(_), do: []

  defp normalize_footprint(footprint) when is_map(footprint) do
    # Get the manifest and split it by ebin/priv based on path
    manifest = footprint[:manifest] || []

    {ebin_files, priv_files} =
      manifest
      |> Enum.split_with(fn entry ->
        path = entry[:path] || ""
        String.starts_with?(path, "ebin/")
      end)

    ebin_manifest = normalize_manifest(ebin_files)
    priv_manifest = normalize_manifest(priv_files)

    %{
      "file_count" => footprint[:file_count] || 0,
      "total_bytes" => footprint[:total_bytes] || 0,
      "file_manifest" => %{
        "ebin" => ebin_manifest,
        "priv" => priv_manifest
      }
    }
  end

  defp normalize_footprint(_) do
    %{
      "file_count" => 0,
      "total_bytes" => 0,
      "file_manifest" => %{
        "ebin" => [],
        "priv" => []
      }
    }
  end

  defp normalize_manifest(manifest) when is_list(manifest) do
    Enum.map(manifest, fn entry ->
      %{
        "path" => to_string_safe(entry[:path]),
        "size" => entry[:size] || 0,
        "sha256" => to_string_safe(entry[:sha256]),
        "mode" => entry[:mode] || 33188
      }
    end)
  end

  defp normalize_manifest(_), do: []

  defp to_strings(list) when is_list(list), do: Enum.map(list, &to_string_safe/1)
  defp to_strings(_), do: []

  defp to_string_safe(nil), do: ""
  defp to_string_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_safe(value), do: to_string(value)

  defp inspect_safe(value) when is_binary(value), do: value
  defp inspect_safe(value), do: inspect(value)

  defp format_mfa({mod, fun, arity}) do
    mod_part = to_string_safe(mod)
    fun_part = to_string_safe(fun)
    mod_part <> ":" <> fun_part <> "/" <> to_string_safe(arity)
  end

  defp format_mfa(_other), do: ""

  defp safe_bool(true), do: true
  defp safe_bool(_), do: false
end
